import XCTest
@testable import DistillKit

/// Where a Slack message goes (action-buttons.md): the same cases as the core
/// (core/src/actions/slack-target.cases.json), the To row's words, Send turned off, and the routes.
final class SlackTargetTests: XCTestCase {
    struct Shared: Decodable {
        struct Case: Decodable { let to: String; let thread: String?; let expect: SlackTarget }
        struct Typed: Decodable { let `in`: String; let out: String? }
        let people: [String: String]
        let cases: [Case]
        let typed: [Typed]
    }

    static func shared() throws -> Shared {
        var url = URL(fileURLWithPath: #filePath)
        for _ in 0..<5 { url.deleteLastPathComponent() }
        let file = url.appendingPathComponent("core/src/actions/slack-target.cases.json")
        return try JSONDecoder().decode(Shared.self, from: Data(contentsOf: file))
    }

    func testEverySharedCaseResolvesLikeTheCore() throws {
        let s = try Self.shared()
        XCTAssertGreaterThan(s.cases.count, 10)
        XCTAssertNil(SlackTarget.parseThread("https://evilslack.com/archives/C0123ABCD/p1759600000123456"), "the host is slack.com exactly")
        for c in s.cases {
            XCTAssertEqual(SlackTarget.resolve(to: c.to, thread: c.thread, lookup: { s.people[$0] }), c.expect, "\(c.to) / \(c.thread ?? "")")
        }
        for t in s.typed { XCTAssertEqual(SlackTarget.typed(t.in), t.out, t.in) }
    }

    func testTypedHandleFollowsTheButtonsPattern() {
        XCTAssertEqual(SlackTarget.typed("aditya", pattern: "^(#\\S+|@\\S+|[CGDUW][A-Z0-9]+)$"), "@aditya")
        XCTAssertNil(SlackTarget.typed("U0456EFGH", pattern: "^@"), "the script would refuse it")
        XCTAssertEqual(SlackTarget.typed("U0456EFGH", pattern: "(("), "U0456EFGH", "a broken pattern is the core's to report")
    }

    func testToRowWords() {
        let people = [SlackPerson(vaultPath: "/v", name: "Aditya Pradhan", target: "@aditya")]
        let lookup = SlackToText.lookup(people, vault: "/v")
        XCTAssertEqual(SlackTarget.resolve(to: "Aditya Pradhan", thread: nil, lookup: SlackToText.lookup(people, vault: "/v/")).target, "@aditya",
                       "the core stores the resolved path; settings may keep a trailing slash")
        let unknown = SlackTarget.resolve(to: "Aditya Pradhan", thread: nil, lookup: SlackToText.lookup(people, vault: "/other"))
        XCTAssertEqual(unknown.ask, "Who is Aditya Pradhan in Slack?")
        XCTAssertEqual(SlackToText.kind(unknown), "Person")

        let known = SlackTarget.resolve(to: "Aditya Pradhan", thread: nil, lookup: lookup)
        XCTAssertEqual(SlackToText.main(known), "Aditya Pradhan (@aditya)")
        XCTAssertEqual(SlackToText.detail(known), "direct message")

        let channel = SlackTarget.resolve(to: "#general", thread: nil, lookup: lookup)
        XCTAssertEqual([SlackToText.kind(channel), SlackToText.main(channel), SlackToText.detail(channel)], ["Channel", "#general", "channel"])

        let thread = SlackTarget.resolve(to: "#eng", thread: "https://acme.slack.com/archives/C0123ABCD/p1759600000123456", lookup: lookup)
        XCTAssertEqual([SlackToText.kind(thread), SlackToText.main(thread), SlackToText.detail(thread)], ["Thread", "#eng", "reply in its thread"])
        let dmThread = SlackTarget.resolve(to: "Aditya Pradhan", thread: "1759600000.123456", lookup: lookup)
        XCTAssertEqual(SlackToText.main(dmThread), "Aditya Pradhan (@aditya)")

        let group = SlackTarget.resolve(to: "Mei, Aditya", thread: nil, lookup: lookup)
        XCTAssertEqual([SlackToText.kind(group), SlackToText.detail(group)], ["Group", "group message"])
        XCTAssertEqual(SlackToText.main(SlackTarget.resolve(to: "", thread: nil, lookup: lookup)), "Choose who gets it")
    }

    func testSendIsOffWithTheReasonUntilTheNameResolves() {
        let send = AutomationButton(id: "send", label: "Send in Slack", scriptId: "s", commandId: "send",
                                    bindings: ["thread": "", "target": "{fields.to}", "text": "{body}"], slot: .send)
        let unknown = SlackTarget.resolve(to: "Aditya Pradhan", thread: nil, lookup: { _ in nil })
        XCTAssertEqual(unknown.blocks(send), "Distill doesn’t know who Aditya Pradhan is in Slack yet. Add their @handle or ID in the To row.")
        XCTAssertNil(SlackTarget.resolve(to: "Aditya Pradhan", thread: nil, lookup: { _ in "@aditya" }).blocks(send))

        // A button that doesn't use the To field isn't stopped by it.
        let toMe = AutomationButton(id: "me", label: "Send to me", scriptId: "s", commandId: "send", bindings: ["target": "@me", "text": "{title}"])
        XCTAssertNil(unknown.blocks(toMe))

        // A thread: the button must fill --thread, or it would post to the channel.
        let thread = SlackTarget.resolve(to: "#eng", thread: "1759600000.123456", lookup: { _ in nil })
        XCTAssertEqual(thread.blocks(send), "This message replies in a thread, but Send in Slack doesn’t fill in a thread. Edit the button and set thread to {fields.thread}.")
        var threaded = send
        threaded.bindings["thread"] = "{fields.thread}"
        XCTAssertNil(thread.blocks(threaded))
        // A fixed target with thread {fields.thread}: a thread Distill can't read is off, never a top-level post (as the core).
        let fixedThread = AutomationButton(id: "eng", label: "Reply in #eng", scriptId: "s", commandId: "send",
                                           bindings: ["thread": "{fields.thread}", "target": "#eng", "text": "{body}"])
        let unreadable = SlackTarget.resolve(to: "#eng", thread: "the standup thread", lookup: { _ in nil })
        XCTAssertEqual(unreadable.blocks(fixedThread), "“the standup thread” isn’t a Slack message link, so Distill can’t tell which thread to reply in.")
        XCTAssertNil(thread.blocks(fixedThread))
        XCTAssertEqual(SlackTarget.placeholders("{a}{{b}}{ c }"), ["a", "c"])
    }

    func testRoutes() async throws {
        StubProtocol.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
        defer { StubProtocol.handler = nil }

        StubProtocol.handler = { _ in (200, Data(#"[{"vaultPath":"/v","name":"Aditya Pradhan","target":"@aditya","savedAt":"2026-10-06T12:00:00Z"}]"#.utf8)) }
        let people = try await client.slackPeople(vault: "/v w")
        XCTAssertEqual(people.map(\.target), ["@aditya"])
        XCTAssertEqual(StubProtocol.recorded.last?.method, "GET")
        XCTAssertTrue(StubProtocol.recorded.last?.path.hasPrefix("/v1/slack-people") ?? false)

        StubProtocol.handler = { _ in (200, Data(#"{"vaultPath":"/v","name":"Aditya Pradhan","target":"@aditya","savedAt":"x"}"#.utf8)) }
        let saved = try await client.rememberSlackPerson(name: "Aditya Pradhan", target: "aditya", vault: "/v")
        XCTAssertEqual(saved.target, "@aditya")
        XCTAssertEqual(StubProtocol.recorded.last?.method, "PUT")
        let body = try JSONDecoder.core.decode(JSONValue.self, from: StubProtocol.recorded.last?.body ?? Data())
        XCTAssertEqual(body["target"], .string("aditya"))

        StubProtocol.handler = { _ in (200, Data(#"{"forgotten":true}"#.utf8)) }
        let forgot = try await client.forgetSlackPerson(name: "Aditya Pradhan", vault: "/v")
        XCTAssertTrue(forgot)
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/slack-people/forget")

        StubProtocol.handler = { _ in (400, Data(#"{"error":{"code":"invalid_request","message":"“Aditya P” isn’t an @handle, a #channel or a Slack ID (U…, C…)."}}"#.utf8)) }
        do {
            _ = try await client.rememberSlackPerson(name: "Aditya Pradhan", target: "Aditya P", vault: "/v")
            XCTFail("expected a refusal")
        } catch let e as CoreClientError {
            XCTAssertEqual(e.description, "“Aditya P” isn’t an @handle, a #channel or a Slack ID (U…, C…).")
        }
    }
}
