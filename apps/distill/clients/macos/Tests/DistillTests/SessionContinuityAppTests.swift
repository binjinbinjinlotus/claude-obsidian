import XCTest
@testable import Distill
@testable import DistillKit

/// A scripted core: `answer(method, path, body)` decides each response; every request is recorded.
final class SessionCoreProtocol: URLProtocol, @unchecked Sendable {
    struct Call { let method: String; let path: String; let query: String?; let body: [String: Any] }
    nonisolated(unsafe) static var calls: [Call] = []
    nonisolated(unsafe) static var answer: ((Call) -> (Int, String))?
    static let lock = NSLock()
    override class func canInit(with request: URLRequest) -> Bool { true }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        var data = request.httpBody
        if data == nil, let stream = request.httpBodyStream {
            stream.open()
            var d = Data()
            let buf = UnsafeMutablePointer<UInt8>.allocate(capacity: 4096)
            while stream.hasBytesAvailable { let n = stream.read(buf, maxLength: 4096); if n <= 0 { break }; d.append(buf, count: n) }
            buf.deallocate()
            stream.close()
            data = d
        }
        let body = (data.flatMap { try? JSONSerialization.jsonObject(with: $0) } as? [String: Any]) ?? [:]
        let call = Call(method: request.httpMethod ?? "", path: request.url?.path ?? "", query: request.url?.query, body: body)
        Self.lock.lock()
        Self.calls.append(call)
        let (status, text) = Self.answer?(call) ?? (200, "{}")
        Self.lock.unlock()
        let response = HTTPURLResponse(url: request.url!, statusCode: status, httpVersion: nil, headerFields: ["Content-Type": "application/json"])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: Data(text.utf8))
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

/// Session continuity in the app: for each place, the resume fails, SessionReplaceConfirm's state
/// appears, Continue sends the same call with newSession, Cancel changes nothing.
@MainActor
final class SessionContinuityAppTests: XCTestCase {
    static func gone(place: String, reason: String = "notFound", action: String) -> String {
        #"{"error":{"code":"session_unavailable","message":"This \#(place)’s AI session isn’t available anymore.","place":"\#(place)","reason":"\#(reason)","detail":"No conversation found with session ID: s-1","action":"\#(action)"}}"#
    }

    private var job: Job!
    private var opened: [URL] = []

    private func model(jobs: [Job]? = nil) -> AppModel {
        SessionCoreProtocol.calls = []
        SessionCoreProtocol.answer = nil
        opened = []
        job = Job(id: "job-1", vaultPath: "/tmp/vault", files: ["inbox/a.md"], state: .awaitingApproval)
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionCoreProtocol.self]
        let app = AppModel(fixtureSettings: Settings(), jobs: jobs ?? [job], queue: [], status: nil)
        app.useClientForTesting(CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config)))
        app.openTerminalScript = { [weak self] url in self?.opened.append(url) }
        return app
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func calls(_ suffix: String) -> [SessionCoreProtocol.Call] { SessionCoreProtocol.calls.filter { $0.path.hasSuffix(suffix) } }

    // MARK: Review

    func testReplyGoneShowsConfirmCancelKeepsTheReplyContinueSendsNewSession() async {
        let app = model()
        SessionCoreProtocol.answer = { c in
            c.body["newSession"] as? Bool == true ? (200, #"{"job":null}"#) : (409, Self.gone(place: "batch", action: "reply"))
        }
        app.reply("job-1", text: "Put it on the Gyokuro page")
        await waitUntil { app.sessionPrompt(for: self.job) != nil }
        let p = try! XCTUnwrap(app.sessionPrompt(for: job))
        XCTAssertEqual(p.action, "reply")
        XCTAssertEqual(p.text, "Put it on the Gyokuro page")
        XCTAssertNil(app.lastError, "not an error banner")

        app.cancelSessionPrompt(job)
        XCTAssertNil(app.sessionPrompt(for: job))
        XCTAssertEqual(app.returnedReply?.text, "Put it on the Gyokuro page", "the reply goes back in its box")
        XCTAssertEqual(calls("/reply").count, 1, "Cancel sends nothing")

        app.reply("job-1", text: "Put it on the Gyokuro page")
        await waitUntil { app.sessionPrompt(for: self.job) != nil }
        app.continueInNewSession(job)
        await waitUntil { self.calls("/reply").count == 3 }
        let last = calls("/reply").last!
        XCTAssertEqual(last.body["newSession"] as? Bool, true)
        XCTAssertEqual(last.body["text"] as? String, "Put it on the Gyokuro page")
        XCTAssertNil(app.sessionPrompt(for: job))
    }

    func testApproveGoneThenContinue() async {
        let app = model()
        SessionCoreProtocol.answer = { c in
            c.body["newSession"] as? Bool == true ? (200, #"{"job":null}"#) : (409, Self.gone(place: "batch", reason: "missing", action: "approve"))
        }
        app.approveTracked("job-1")
        await waitUntil { app.sessionPrompt(for: self.job) != nil }
        XCTAssertEqual(app.sessionPrompt(for: job)?.info.reason, "missing")
        XCTAssertFalse(app.isApplying("job-1"), "no Applying… while the user decides")
        app.continueInNewSession(job)
        await waitUntil { self.calls("/approve").count == 2 }
        XCTAssertEqual(calls("/approve").last?.body["newSession"] as? Bool, true)
    }

    func testAllowGoneThenContinueResendsTheRules() async {
        let app = model()
        SessionCoreProtocol.answer = { c in
            c.body["newSession"] as? Bool == true ? (200, #"{"job":null}"#) : (409, Self.gone(place: "batch", action: "allow"))
        }
        app.allow("job-1", rules: ["WebFetch"])
        await waitUntil { app.sessionPrompt(for: self.job) != nil }
        app.continueInNewSession(job)
        await waitUntil { self.calls("/allow").count == 2 }
        XCTAssertEqual(calls("/allow").last?.body["rules"] as? [String], ["WebFetch"])
        XCTAssertEqual(calls("/allow").last?.body["newSession"] as? Bool, true)
    }

    func testAJobMarkerFromAFailedResumeShowsAndCancelHidesIt() async {
        var marked = Job(id: "job-1", vaultPath: "/tmp/vault", files: [], state: .awaitingApproval)
        marked.sessionUnavailable = SessionUnavailable(place: "batch", reason: "notFound", message: "m", detail: "d", action: "reply", text: "go on", at: "t1")
        let app = model(jobs: [marked])
        XCTAssertEqual(app.sessionPrompt(for: marked)?.text, "go on")
        app.cancelSessionPrompt(marked)
        XCTAssertNil(app.sessionPrompt(for: marked), "Cancel hides it")
        XCTAssertTrue(SessionCoreProtocol.calls.isEmpty, "Cancel calls nothing")
        var newer = marked
        newer.sessionUnavailable?.at = "t2"
        XCTAssertNotNil(app.sessionPrompt(for: newer), "a newer refusal shows again")
        app.continueInNewSession(newer)
        await waitUntil { !self.calls("/reply").isEmpty }
        XCTAssertEqual(calls("/reply").last?.body["text"] as? String, "go on")
        XCTAssertEqual(calls("/reply").last?.body["newSession"] as? Bool, true)
    }

    func testAnOrdinaryErrorIsNotASessionPrompt() async {
        let app = model()
        SessionCoreProtocol.answer = { _ in (409, #"{"error":{"code":"busy","message":"Job job-1 is running."}}"#) }
        app.reply("job-1", text: "x")
        await waitUntil { app.lastError != nil }
        XCTAssertEqual(app.lastError, "Job job-1 is running.")
        XCTAssertNil(app.sessionPrompt(for: job))
    }

    // MARK: Open in Terminal

    func testTerminalGoneShowsThePopoverNeverABlindResume() async {
        let app = model()
        SessionCoreProtocol.answer = { c in
            c.query == "newSession=1" ? (200, #"{"argv":["claude","--model","sonnet","seed"]}"#) : (409, Self.gone(place: "terminal", reason: "missing", action: "resume"))
        }
        app.openInTerminal(job)
        await waitUntil { app.terminalSessionPrompt != nil }
        XCTAssertEqual(app.terminalSessionPrompt?.info.place, "terminal")
        XCTAssertTrue(opened.isEmpty, "no claude --resume fallback for a gone session")

        app.terminalSessionPrompt = nil // Cancel
        XCTAssertTrue(opened.isEmpty)

        app.openInTerminal(job)
        await waitUntil { app.terminalSessionPrompt != nil }
        app.continueTerminalInNewSession(job)
        await waitUntil { !self.opened.isEmpty }
        XCTAssertEqual(calls("/resume").last?.query, "newSession=1")
        let script = try! String(contentsOf: opened[0], encoding: .utf8)
        XCTAssertFalse(script.contains("--resume"))
        XCTAssertTrue(script.contains("'seed'"))
    }

    func testTerminalCoreErrorsAreNotSwallowed() async {
        let app = model()
        SessionCoreProtocol.answer = { _ in (500, #"{"error":{"code":"internal_error","message":"boom"}}"#) }
        app.openInTerminal(job)
        await waitUntil { app.lastError != nil }
        XCTAssertEqual(app.lastError, "boom")
        XCTAssertTrue(opened.isEmpty, "no local fallback for a core error")
    }

    // MARK: Ask

    func testAskFollowUpGoneCancelRestoresTheQuestionContinueAsksInANewSession() async {
        let app = model()
        let cid = "11111111-1111-4111-8111-111111111111"
        SessionCoreProtocol.answer = { c in
            guard c.path == "/v1/ask" else { return (200, #"{"conversations":[]}"#) }
            if c.body["newSession"] as? Bool == true {
                return (200, #"{"conversationID":"\#(cid)","answer":"No temperature for gyokuro.","citations":[],"gaps":[],"costUSD":0,"notices":["Started a new session"]}"#)
            }
            return (409, Self.gone(place: "conversation", action: "ask"))
        }
        let ask = app.ask
        ask.main.conversationID = cid
        ask.main.draft = "And gyokuro?"
        ask.send(ask.main)
        await waitUntil { !ask.main.isRunning }
        guard case .sessionUnavailable(let s) = ask.main.pending?.status else { return XCTFail("expected the confirmation") }
        XCTAssertEqual(s.place, "conversation")

        ask.cancelSessionReplace(ask.main)
        XCTAssertNil(ask.main.pending)
        XCTAssertEqual(ask.main.draft, "And gyokuro?", "the question goes back in the box")
        XCTAssertEqual(calls("/v1/ask").count, 1)

        ask.send(ask.main)
        await waitUntil { !ask.main.isRunning }
        ask.continueInNewSession(ask.main)
        await waitUntil { ask.main.entries.count == 1 }
        XCTAssertEqual(calls("/v1/ask").last?.body["newSession"] as? Bool, true)
        XCTAssertEqual(calls("/v1/ask").last?.body["conversationID"] as? String, cid)
        XCTAssertEqual(ask.main.entries.first?.response.answer, "No temperature for gyokuro.")
    }

    func testAskOrdinaryFailureStaysCouldNotAnswer() async {
        let app = model()
        SessionCoreProtocol.answer = { c in
            c.path == "/v1/ask" ? (500, #"{"error":{"code":"internal_error","message":"ask: Claude Code failed: 529"}}"#) : (200, #"{"conversations":[]}"#)
        }
        let ask = app.ask
        ask.main.conversationID = "11111111-1111-4111-8111-111111111111"
        ask.main.draft = "q"
        ask.send(ask.main)
        await waitUntil { !ask.main.isRunning }
        guard case .failed = ask.main.pending?.status else { return XCTFail("expected an ordinary failure") }
    }
}
