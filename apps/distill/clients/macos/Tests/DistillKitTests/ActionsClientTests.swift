import XCTest
@testable import DistillKit

/// Actions DTOs and routes against the URL stub (see CoreClientTests.StubProtocol).
final class ActionsClientTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
    }

    func respond(_ json: String, status: Int = 200) { StubProtocol.handler = { _ in (status, Data(json.utf8)) } }
    var last: StubProtocol.Recorded { StubProtocol.recorded.last! }
    func bodyJSON() throws -> JSONValue { try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data()) }

    static let slack = #"""
    {"id":"a1","type":"slack","status":"ready","title":"Message to Mei","body":"Hi @Mei","fields":{"to":"Mei Tanaka","due":null,"n":3},
     "why":"She brings the tea","source":{"kind":"note","jobID":"j1","notePath":"wiki/tea-club.md","pageTitle":"Tea club planning","quote":"I'll tell Mei"},
     "createdAt":"2026-10-02T15:44:00Z","updatedAt":"2026-10-02T15:45:00.123Z","draftModel":"Sonnet",
     "events":[{"at":"2026-10-02T15:44:00Z","event":"found"},{"at":"bad","event":"drafted","detail":"Sonnet"}],"future":{"x":1}}
    """#

    func testItemDecodesLeniently() throws {
        let item = try JSONDecoder.core.decode(ActionItem.self, from: Data(Self.slack.utf8))
        XCTAssertEqual(item.type, "slack")
        XCTAssertEqual(item.status, .ready)
        XCTAssertEqual(item.fields, ["to": "Mei Tanaka", "n": "3"])
        XCTAssertEqual(item.source, .note(jobID: "j1", notePath: "wiki/tea-club.md", pageTitle: "Tea club planning", quote: "I'll tell Mei"))
        XCTAssertEqual(item.events.count, 2)
        XCTAssertEqual(item.events[1].at, .distantPast)
        XCTAssertNil(item.error)

        let odd = try JSONDecoder.core.decode(ActionItem.self, from: Data(#"{"id":"x","status":"archived","type":"email","source":{"kind":"calendar"},"fields":"nope"}"#.utf8))
        XCTAssertEqual(odd.status.rawValue, "archived")
        XCTAssertEqual(odd.source, .other(kind: "calendar"))
        XCTAssertEqual(odd.fields, [:])
        XCTAssertEqual(odd.title, "")

        let ask = try JSONDecoder.core.decode(ActionSource.self, from: Data(#"{"kind":"ask","conversationID":"c1","quote":"book it","turnIndex":2,"gap":"no temperature"}"#.utf8))
        XCTAssertEqual(ask.conversationID, "c1")
        guard case .ask(_, _, _, _, let turn, let gap) = ask else { return XCTFail() }
        XCTAssertEqual(turn, 2)
        XCTAssertEqual(gap, "no temperature")
    }

    func testItemRoundTrips() throws {
        let item = try JSONDecoder.core.decode(ActionItem.self, from: Data(Self.slack.utf8))
        let again = try JSONDecoder.core.decode(ActionItem.self, from: JSONEncoder.core.encode(item))
        XCTAssertEqual(item.id, again.id)
        XCTAssertEqual(item.source, again.source)
        XCTAssertEqual(item.fields, again.fields)
    }

    func testTypesAndListQuery() async throws {
        respond(#"{"types":[{"id":"todo","label":"To-do","pluralLabel":"To do","enabled":true,"fields":[],"handlers":[{"id":"complete","label":"Complete"}],"draftWhen":"onFind","improveAfterEdit":false},{"id":"email","label":"Email","reserved":true,"handlers":[{"id":"copy","label":"Copy","available":false,"reason":"Later"}]},{"bad":1}]}"#)
        let types = try await client.actionTypes()
        XCTAssertEqual(types.map(\.id), ["todo", "email"])
        XCTAssertEqual(types[1].pluralLabel, "Email")
        XCTAssertFalse(types[1].isUsable)
        XCTAssertEqual(types[1].handler("copy")?.available, false)
        XCTAssertEqual(last.path, "/v1/action-types")

        respond("{\"actions\":[\(Self.slack),{\"nope\":true}]}")
        let items = try await client.actions(ActionQuery(type: "slack", status: [.done, .sent], history: true, vaultPath: "/v a", text: "a+b"))
        XCTAssertEqual(items.map(\.id), ["a1"])
        XCTAssertEqual(last.path, "/v1/actions")
        XCTAssertEqual(last.query, "type=slack&status=done,sent&history=1&vault=/v%20a&q=a%2Bb")
    }

    func testMutationsUseTheApprovedRoutes() async throws {
        respond(Self.slack)
        _ = try await client.createAction(NewActionInput(title: "Buy tin", fields: ["due": "2026-10-03"]))
        XCTAssertEqual(last.method, "POST"); XCTAssertEqual(last.path, "/v1/actions")
        XCTAssertEqual(try bodyJSON()["title"], .string("Buy tin"))
        XCTAssertEqual(try bodyJSON()["type"], .string("todo"))

        _ = try await client.updateAction("a1", ActionPatch(body: .some(nil), fields: ["due": nil, "to": "Tom"]))
        XCTAssertEqual(last.method, "PATCH"); XCTAssertEqual(last.path, "/v1/actions/a1")
        XCTAssertEqual(try bodyJSON(), .object(["body": .null, "fields": .object(["due": .null, "to": .string("Tom")])]))

        _ = try await client.performAction("a1", handler: "copy")
        XCTAssertEqual(last.path, "/v1/actions/a1/perform")
        XCTAssertEqual(try bodyJSON(), .object(["handler": .string("copy")]))
        _ = try await client.sendAction("a1", to: "jira")
        XCTAssertEqual(last.path, "/v1/actions/a1/send")
        XCTAssertEqual(try bodyJSON(), .object(["type": .string("jira")]))
        for (call, route) in [("draft", "draft"), ("improve", "improve"), ("undo", "undo-improve"), ("remove", "remove"), ("restore", "restore")] {
            switch call {
            case "draft": _ = try await client.draftAction("a1")
            case "improve": _ = try await client.improveAction("a1")
            case "undo": _ = try await client.undoImprove("a1")
            case "remove": _ = try await client.removeAction("a1")
            default: _ = try await client.restoreAction("a1")
            }
            XCTAssertEqual(last.path, "/v1/actions/a1/\(route)")
            XCTAssertEqual(last.method, "POST")
        }

        respond("{\"actions\":[\(Self.slack)]}")
        let confirmed = try await client.confirmActions(["a1"])
        XCTAssertEqual(confirmed.count, 1)
        XCTAssertEqual(last.path, "/v1/actions/confirm")
        XCTAssertEqual(try bodyJSON(), .object(["ids": .array([.string("a1")])]))

        respond(#"{"ids":["a1"],"dismissed":true}"#)
        try await client.dismissActions(["a1"])
        XCTAssertEqual(last.path, "/v1/actions/dismiss")

        respond("{\"actions\":[\(Self.slack)]}")
        let found = try await client.detectAskActions(conversationID: "c 1", turnIndex: 1)
        XCTAssertEqual(found.count, 1)
        XCTAssertEqual(last.path, "/v1/conversations/c 1/actions/detect")
        XCTAssertEqual(try bodyJSON(), .object(["turnIndex": .number(1)]))

        respond("")
        try await client.deleteActionForever("a1")
        XCTAssertEqual(last.method, "DELETE"); XCTAssertEqual(last.path, "/v1/actions/a1")
    }

    func testHandlerFailureIsAnItemNotAnError() async throws {
        respond(#"{"id":"j1","type":"jira","status":"ready","title":"T","error":{"code":"refused","message":"Component is required","field":"component"}}"#)
        let item = try await client.performAction("j1", handler: "create")
        XCTAssertEqual(item.error?.code, "refused")
        XCTAssertEqual(item.error?.field, "component")
        XCTAssertFalse(item.error!.needsSignIn)
    }

    func testOldCoresAreNotAvailable() async {
        respond(#"{"error":{"code":"not_found","message":"no route for GET /v1/actions"}}"#, status: 404)
        do { _ = try await client.actions(); XCTFail() } catch let e as CoreClientError { XCTAssertTrue(e.isNotAvailable) } catch { XCTFail() }
        respond(#"{"error":{"code":"not_implemented","message":"listActionTypes: not implemented"}}"#, status: 501)
        do { _ = try await client.actionTypes(); XCTFail() } catch let e as CoreClientError { XCTAssertTrue(e.isNotAvailable) } catch { XCTFail() }
    }

    func testActionEventsAndJobSummary() throws {
        let event = try CoreEvent.decode(Data("{\"type\":\"action\",\"action\":\(Self.slack)}".utf8))
        guard case .action(let item, let deleted) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(item.id, "a1")
        XCTAssertFalse(deleted)
        let gone = try CoreEvent.decode(Data(#"{"type":"action","action":{"id":"a2"},"deleted":true}"#.utf8))
        XCTAssertEqual(gone, .action(ActionItem(id: "a2", title: "", createdAt: .distantPast), deleted: true))
        // A malformed action event is dropped by the parser, not the stream.
        var parser = SSEParser()
        XCTAssertNil(parser.feed(#"data: {"type":"action","action":{"title":"no id"}}"#))
        XCTAssertEqual(parser.malformed, 1)

        let job = try JSONDecoder.core.decode(Job.self, from: Data(#"{"id":"j","state":"completed","actionsFound":{"status":"done","found":5,"pending":5,"byType":{"todo":3,"slack":1,"jira":1}}}"#.utf8))
        XCTAssertEqual(job.actionsFound?.found, 5)
        XCTAssertEqual(job.actionsFound?.byType["todo"], 3)
        let again = try JSONDecoder.core.decode(Job.self, from: JSONEncoder.core.encode(job))
        XCTAssertEqual(again.actionsFound, job.actionsFound)
    }
}
