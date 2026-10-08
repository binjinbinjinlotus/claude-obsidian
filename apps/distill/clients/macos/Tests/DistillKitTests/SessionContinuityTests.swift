import XCTest
@testable import DistillKit

/// Session continuity: the typed 409, the job marker and `newSession` on the wire, decoded leniently.
final class SessionContinuityTests: XCTestCase {
    let token = String(repeating: "f", count: 64)
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: token), session: URLSession(configuration: config))
    }

    private let gone = #"{"error":{"code":"session_unavailable","message":"This batch’s AI session isn’t available anymore (Claude Code couldn’t find it). Distill will start a new session to continue.","place":"batch","reason":"notFound","detail":"No conversation found with session ID: s-1","action":"reply","text":"hi"}}"#

    private func body(_ i: Int = -1) -> [String: Any] {
        let r = i < 0 ? StubProtocol.recorded.last! : StubProtocol.recorded[i]
        return (try? JSONSerialization.jsonObject(with: r.body ?? Data())) as? [String: Any] ?? [:]
    }

    func testSessionUnavailableIsTyped() async {
        StubProtocol.handler = { _ in (409, Data(self.gone.utf8)) }
        do {
            try await client.reply("job-1", text: "hi")
            XCTFail("expected session_unavailable")
        } catch let e as CoreClientError {
            let s = try! XCTUnwrap(e.sessionUnavailable)
            XCTAssertEqual(s.place, "batch")
            XCTAssertEqual(s.reason, "notFound")
            XCTAssertEqual(s.action, "reply")
            XCTAssertEqual(s.text, "hi")
            XCTAssertEqual(s.detail, "No conversation found with session ID: s-1")
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.code, "session_unavailable")
            XCTAssertTrue(e.description.contains("isn’t available anymore"))
        } catch { XCTFail("\(error)") }
    }

    func testOrdinaryConflictStaysApiError() async {
        StubProtocol.handler = { _ in (409, Data(#"{"error":{"code":"busy","message":"Job job-1 is running."}}"#.utf8)) }
        do {
            try await client.reply("job-1", text: "hi")
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertNil(e.sessionUnavailable)
            XCTAssertEqual(e, .api(status: 409, code: "busy", message: "Job job-1 is running."))
        } catch { XCTFail("\(error)") }
    }

    func testNewSessionGoesOnTheWire() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"job":null}"#.utf8)) }
        try await client.approve("job-1")
        XCTAssertNil(body()["newSession"], "never sent unless the user confirmed")
        try await client.approve("job-1", newSession: true)
        XCTAssertEqual(body()["newSession"] as? Bool, true)
        try await client.reply("job-1", text: "x", newSession: true)
        XCTAssertEqual(body()["text"] as? String, "x")
        XCTAssertEqual(body()["newSession"] as? Bool, true)
        try await client.allow("job-1", rules: ["WebFetch"], newSession: true)
        XCTAssertEqual(body()["rules"] as? [String], ["WebFetch"])
        StubProtocol.handler = { _ in (200, Data(#"{"argv":["claude","--model","sonnet","seed"]}"#.utf8)) }
        _ = try await client.jobResume("job-1", newSession: true)
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/jobs/job-1/resume")
        XCTAssertEqual(StubProtocol.recorded.last?.query, "newSession=1")
        var req = AskRequest(question: "q", conversationID: "c")
        req.newSession = true
        let json = try JSONSerialization.jsonObject(with: JSONEncoder().encode(req)) as? [String: Any]
        XCTAssertEqual(json?["newSession"] as? Bool, true)
    }

    func testJobMarkerDecodesLeniently() throws {
        let job = try JSONDecoder.core.decode(Job.self, from: Data(#"""
        {"id":"j","vaultPath":"/v","files":[],"sessionID":"s","model":"m","state":"awaitingApproval","createdAt":"2026-10-05T00:00:00Z",
         "updatedAt":"2026-10-05T00:00:00Z","turns":[],"grantedTools":[],"changedPaths":[],
         "sessionUnavailable":{"place":"batch","reason":"missing","message":"m","detail":"d","action":"allow","rules":["WebFetch"],"at":"t"}}
        """#.utf8))
        XCTAssertEqual(job.sessionUnavailable?.reason, "missing")
        XCTAssertEqual(job.sessionUnavailable?.rules, ["WebFetch"])
        let odd = try JSONDecoder.core.decode(Job.self, from: Data(#"{"id":"j","sessionUnavailable":{"reason":7}}"#.utf8))
        XCTAssertEqual(odd.sessionUnavailable?.place, "batch", "wrong types take defaults; the job still decodes")
        let none = try JSONDecoder.core.decode(Job.self, from: Data(#"{"id":"j"}"#.utf8))
        XCTAssertNil(none.sessionUnavailable)
    }

    func testWordingMatchesTheDesign() {
        XCTAssertEqual(SessionReplaceText.heading(place: "batch"), "This batch’s AI session isn’t available anymore")
        XCTAssertEqual(SessionReplaceText.heading(place: "conversation"), "This conversation’s AI session isn’t available anymore")
        XCTAssertEqual(SessionReplaceText.body(place: "batch", reason: "missing", runner: "Claude Code"),
                       "Its history is no longer on this Mac. Distill will start a new session to continue.")
        XCTAssertEqual(SessionReplaceText.body(place: "terminal", reason: "notFound", runner: "Codex"),
                       "Codex couldn’t find it. Distill will open a new session in Terminal instead.")
        XCTAssertEqual(SessionReplaceText.continueTitle(place: "terminal"), "Open new session")
        XCTAssertEqual(SessionReplaceText.continueTitle(place: "batch"), "Continue")
        XCTAssertEqual(SessionReplaceText.body(place: "batch", reason: "fromTheFuture", runner: "X"),
                       "It can’t be resumed. Distill will start a new session to continue.")
    }

    func testEveryReasonAndWhatTheNewSessionCarries() {
        XCTAssertEqual(SessionReplaceText.reason("neverStarted", runner: "Codex"), "it never started: the batch stopped before Codex read the sources")
        XCTAssertEqual(SessionReplaceText.reason("runnerGone", runner: "Codex"), "Codex isn’t available anymore")
        XCTAssertEqual(SessionReplaceText.reason("recovery", runner: "Codex"), "a fresh session may get this batch going again")
        XCTAssertEqual(SessionReplaceText.noun("terminal"), "batch")
        XCTAssertEqual(SessionReplaceText.noun("conversation"), "conversation")
        XCTAssertEqual(SessionReplaceText.heading(place: "conversation", reason: "missing"), "This conversation’s AI session isn’t available anymore")
        XCTAssertEqual(SessionReplaceText.carries(place: "conversation"),
                       "The new session starts with this conversation so far, so your follow-up keeps its context.")
        XCTAssertEqual(SessionReplaceText.carries(place: "terminal"), "It starts with this batch’s sources, labels and plan. The batch in Distill is not changed.")
        XCTAssertEqual(SessionReplaceText.carries(place: "batch"), "The new session starts with this batch’s sources, your labels and the plan you are reviewing.")
        XCTAssertEqual(SessionReplaceText.continueTitle(place: "conversation"), "Continue")
        XCTAssertEqual(SessionReplaceText.runnerName(nil), "Claude Code")
        XCTAssertEqual(SessionReplaceText.runnerName("claude-code"), "Claude Code")
        XCTAssertEqual(SessionReplaceText.runnerName("codex"), "Codex")
        XCTAssertEqual(SessionReplaceText.runnerName("openrouter"), "openrouter")
    }

    func testTheMarkerKeepsEveryFieldToSendAgain() throws {
        let made = SessionUnavailable(place: "batch", reason: "missing", message: "m", detail: "d", action: "approve", text: "t", rules: ["r"],
                                      labels: "later", pages: ["wiki/a.md"], at: "2026-10-06T10:00:00Z")
        XCTAssertEqual([made.action, made.text, made.labels, made.at], ["approve", "t", "later", "2026-10-06T10:00:00Z"])
        XCTAssertEqual(made.rules, ["r"])
        XCTAssertEqual(made.pages, ["wiki/a.md"])
        let decoded = try JSONDecoder.core.decode(SessionUnavailable.self, from: JSONEncoder.core.encode(made))
        XCTAssertEqual(decoded, made)
        XCTAssertEqual(decoded.labels, "later")
        XCTAssertEqual(decoded.pages, ["wiki/a.md"])
    }
}
