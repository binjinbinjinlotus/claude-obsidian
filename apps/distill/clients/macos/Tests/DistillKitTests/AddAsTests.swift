import XCTest
@testable import DistillKit

/// Add as at confirm time (actions.md): the menu, the prefill, what blocks Add, the keys and the request.
final class AddAsTests: XCTestCase {
    static let todo = ActionTypeInfo(id: "todo", label: "To-do", pluralLabel: "To do",
                                     fields: [ActionFieldSpec(key: "due", label: "Due", kind: "date"), ActionFieldSpec(key: "person", label: "People", kind: "person")],
                                     handlers: [ActionHandlerInfo(id: "complete", label: "Complete")])
    static var slack: ActionTypeInfo {
        var t = ActionTypeInfo(id: "slack", label: "Slack message", fields: [ActionFieldSpec(key: "to", label: "To", kind: "person", required: true),
                                                                             ActionFieldSpec(key: "thread", label: "Thread")],
                               handlers: [ActionHandlerInfo(id: "copy", label: "Copy"), ActionHandlerInfo(id: "complete", label: "Complete")])
        t.buttons = [ActionButtonInfo(button: AutomationButton(id: "send", label: "Send in Slack", bindings: ["target": "{fields.to}"], slot: .send))]
        return t
    }
    static let jira = ActionTypeInfo(id: "jira", label: "Jira ticket", fields: [
        ActionFieldSpec(key: "project", label: "Project", required: true),
        ActionFieldSpec(key: "issueType", label: "Type", kind: "choice", choices: ["Task", "Bug"], required: true),
        ActionFieldSpec(key: "assignee", label: "Assignee", kind: "person")],
        handlers: [ActionHandlerInfo(id: "create", label: "Create in Jira"), ActionHandlerInfo(id: "complete", label: "Complete")])
    static let email = ActionTypeInfo(id: "email", label: "Email", reserved: true, handlers: [ActionHandlerInfo(id: "copy", label: "Copy", available: false)])
    static let off = ActionTypeInfo(id: "confluence", label: "Confluence page", enabled: false, handlers: [ActionHandlerInfo(id: "create", label: "Create in Confluence")])
    static let bare = ActionTypeInfo(id: "note", label: "Note", handlers: [ActionHandlerInfo(id: "complete", label: "Complete")])

    static let found = ActionItem(id: "p1", type: "todo", status: .pending, title: "Tell Mei the room is booked",
                                  fields: ["person": "Mei Tanaka", "due": "2026-10-10"], why: "You said you would.")

    func testMenuListsToDoFirstThenTypesWithAHandlerOrButton() {
        let types = [Self.slack, Self.email, Self.todo, Self.jira, Self.off, Self.bare]
        let options = AddAs.options(types)
        XCTAssertEqual(options.map(\.id), ["todo", "slack", "jira"], "reserved, off and handler-less types are left out")
        XCTAssertEqual(options.map(\.detail), ["Added to your to-dos", "Ready to send with Send in Slack", "Written as a draft, then Create in Jira"])
        XCTAssertEqual(AddAs.mainTitle(Self.found, types: types), "Add as to-do")
        var foundSlack = Self.found
        foundSlack.type = "slack"
        XCTAssertEqual(AddAs.mainTitle(foundSlack, types: types), "Add as Slack message")
        // The found type's row says so; the menu ends with the keys.
        XCTAssertEqual(AddAs.foundLine("todo", types: types), "Found as a to-do")
        XCTAssertEqual(AddAs.foundLine("slack", types: types), "Found as a Slack message")
        XCTAssertEqual(AddAs.keysHint(Self.found, types: types), "Return adds as to-do · ⌥Return opens Add as…")
        var copyOnly = Self.slack
        copyOnly.buttons = []
        XCTAssertEqual(AddAs.detail(copyOnly), "Written for you to copy and paste")
    }

    func testPrefillMapsTitleSummaryAndPeople() {
        var item = Self.found
        item.summary = "Mei brings the tea."
        let slack = AddAs.prefill(item, as: Self.slack)
        XCTAssertEqual(slack, AddAs.Draft(type: "slack", title: "Tell Mei the room is booked", body: "Mei brings the tea.", fields: ["to": "Mei Tanaka"]))
        item.body = "Bring the tin."
        XCTAssertEqual(AddAs.prefill(item, as: Self.slack).body, "Bring the tin.", "a body wins over the summary")
        XCTAssertEqual(AddAs.prefill(item, as: Self.jira).fields, ["assignee": "Mei Tanaka"])
        var message = item
        message.type = "slack"; message.fields = ["to": "#tea-club"]
        XCTAssertEqual(AddAs.prefill(message, as: Self.todo).fields, ["person": "#tea-club"], "and back")
    }

    func testRequiredFieldsBlockAddWithTheFieldNamed() {
        var d = AddAs.prefill(Self.found, as: Self.jira)
        XCTAssertEqual(AddAs.blockReason(d, type: Self.jira), "Fill in Project and Type")
        d.fields["project"] = "PX"
        XCTAssertEqual(AddAs.blockReason(d, type: Self.jira), "Fill in Type")
        d.fields["issueType"] = "Bug"
        XCTAssertNil(AddAs.blockReason(d, type: Self.jira))
        d.title = "  "
        XCTAssertEqual(AddAs.blockReason(d, type: Self.jira), "Give it a title")
        var s = AddAs.prefill(Self.found, as: Self.slack)
        XCTAssertNil(AddAs.blockReason(s, type: Self.slack))
        s.fields["to"] = " "
        XCTAssertEqual(AddAs.blockReason(s, type: Self.slack), "Fill in who it goes to")
        XCTAssertEqual(AddAs.bodyLabel(Self.slack), "Text")
    }

    func testReturnAddsAndOptionReturnOpensTheMenu() {
        XCTAssertEqual(AddAs.key(returnWithOption: false), .add)
        XCTAssertEqual(AddAs.key(returnWithOption: true), .openMenu)
    }

    func testRequestSendsTheEditsAndClearsEmptyFields() async throws {
        var d = AddAs.prefill(Self.found, as: Self.slack)
        d.fields["thread"] = "  "
        StubProtocol.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
        defer { StubProtocol.handler = nil }
        StubProtocol.handler = { _ in (200, Data(#"{"actions":[{"id":"p1","type":"slack","status":"ready","title":"Tell Mei","fields":{"to":"Mei Tanaka"},"source":{"kind":"manual"}}]}"#.utf8)) }
        let added = try await client.confirmAction("p1", as: ConfirmAs(d))
        XCTAssertEqual(added?.type, "slack")
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/actions/confirm")
        let body = try JSONDecoder.core.decode(JSONValue.self, from: StubProtocol.recorded.last?.body ?? Data())
        XCTAssertEqual(body["ids"], .array([.string("p1")]))
        XCTAssertEqual(body["as"]?["type"], .string("slack"))
        XCTAssertEqual(body["as"]?["fields"]?["to"], .string("Mei Tanaka"))
        XCTAssertEqual(body["as"]?["fields"]?["thread"], .null, "an emptied field is sent as null")
    }
}
