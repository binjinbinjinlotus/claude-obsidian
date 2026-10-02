import XCTest
@testable import DistillKit

/// Settings.actionPreferences (raw, lenient, unknown nested keys kept) and the
/// v3 connections DTOs and routes.
final class ActionSettingsTests: XCTestCase {
    private func settings(_ json: String) throws -> Settings {
        try JSONDecoder.core.decode(Settings.self, from: Data(json.utf8))
    }

    func testAbsentActionPreferencesReadAsDefaultsAndSendNothing() throws {
        let s = try settings("{}")
        XCTAssertNil(s.actionPreferences)
        let p = s.actionPreferences ?? ActionPreferences()
        for source in ActionPreferences.Source.allCases {
            XCTAssertTrue(p.detectTodos(source))
            XCTAssertTrue(p.detectTypes(source))
            XCTAssertTrue(p.confirm(source))
            XCTAssertEqual(p.disabledTypes(source), [])
        }
        XCTAssertEqual(p.todoSort, "due")
        XCTAssertEqual(p.todoGroup, "due")
        XCTAssertFalse(p.remindOverdue)
        XCTAssertEqual(p.historyDays, 90)
        XCTAssertNil(p.findSelection)
        XCTAssertTrue(Settings.patch(from: s, to: s).isEmpty)
        XCTAssertNil(s.jsonObject()["actionPreferences"], "never written until edited")
    }

    func testWrongTypedActionPreferencesFallBackToDefaults() throws {
        let s = try settings(#"{"actionPreferences":"nope"}"#)
        XCTAssertNil(s.actionPreferences)
        let t = try settings(#"{"actionPreferences":{"sources":{"notes":{"confirm":"yes"}},"historyDays":"x"}}"#)
        XCTAssertTrue(t.actionPreferences!.confirm(.notes), "a wrong-typed value reads as its default")
        XCTAssertEqual(t.actionPreferences!.historyDays, 90)
    }

    func testEditSendsWholeObjectWithUnknownNestedKeys() throws {
        let old = try settings("""
        {"actionPreferences":{"sources":{"notes":{"detectTodos":true,"detectTypes":true,"confirm":true,"futureFlag":7},
          "ask":{"detectTodos":true,"detectTypes":true,"confirm":true}},
          "types":{"jira":{"draftPrompt":"Mine","futureTypeKey":"x"}},"futureTop":{"a":1},"historyDays":90},
         "someFutureKey":1}
        """)
        var new = old
        new.actionPreferences?.setDetectTodos(.notes, false)
        let patch = Settings.patch(from: old, to: new)
        XCTAssertEqual(Set(patch.keys), ["actionPreferences"])
        let sent = try XCTUnwrap(patch["actionPreferences"])
        XCTAssertEqual(sent["sources"]?["notes"]?["detectTodos"], .bool(false))
        XCTAssertEqual(sent["sources"]?["notes"]?["futureFlag"], .number(7), "unknown nested key survives")
        XCTAssertEqual(sent["types"]?["jira"]?["futureTypeKey"], .string("x"))
        XCTAssertEqual(sent["futureTop"], .object(["a": .number(1)]))
        XCTAssertEqual(sent["historyDays"], .number(90), "untouched numbers round-trip unchanged")
        // And the encoded JSON writes 90, not 90.0.
        let data = try JSONEncoder.core.encode(sent)
        XCTAssertTrue(String(decoding: data, as: UTF8.self).contains("\"historyDays\":90"))
    }

    func testFirstSourceEditWritesTheWholeSourceObject() {
        var p = ActionPreferences()
        p.setConfirm(.ask, false)
        XCTAssertEqual(p.value(["sources", "ask"]), .object(["detectTodos": .bool(true), "detectTypes": .bool(true), "confirm": .bool(false)]))
        XCTAssertNil(p.value(["sources", "notes"]), "the other source stays absent (core default)")
        p.setType("slack", detected: false, from: .notes)
        XCTAssertEqual(p.disabledTypes(.notes), ["slack"])
        p.setType("slack", detected: true, from: .notes)
        XCTAssertEqual(p.disabledTypes(.notes), [])
    }

    func testResetPromptRemovesOnlyThatPrompt() throws {
        let s = try settings(#"{"actionPreferences":{"types":{"jira":{"draftPrompt":"Mine","improvePrompt":"Also mine","enabled":false}}}}"#)
        var p = try XCTUnwrap(s.actionPreferences)
        p.setTypeValue("jira", "draftPrompt", nil)
        XCTAssertNil(p.draftPrompt("jira"))
        XCTAssertEqual(p.improvePrompt("jira"), "Also mine")
        XCTAssertEqual(p.enabled("jira"), false)
    }

    func testSelectionsTodoAndHistory() {
        var p = ActionPreferences()
        p.findSelection = ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "medium")
        XCTAssertEqual(p.findSelection?.effort, "medium")
        p.setTypeValue("slack", "draftSelection", ActionPreferences.json(ModelSelection(runnerID: "openrouter", model: "x")))
        XCTAssertEqual(p.draftSelection("slack")?.runnerID, "openrouter")
        XCTAssertNil(p.value(["types", "slack", "draftSelection", "effort"]), "no effort key when nil")
        p.remindOverdue = true
        XCTAssertEqual(p.value(["todo"]), .object(["defaultSort": .string("due"), "defaultGroup": .string("due"), "remindOverdue": .bool(true)]))
        p.historyDays = 0
        XCTAssertEqual(p.historyDays, 0, "0 = forever")
        p.historyDays = -5
        XCTAssertEqual(p.historyDays, 0)
        p.setFieldDefault("jira", "project", "  PX ")
        XCTAssertEqual(p.fieldDefault("jira", "project"), "PX")
        p.setFieldDefault("jira", "project", "")
        XCTAssertNil(p.fieldDefault("jira", "project"))
    }

    func testConnectionInfoDecodesLeniently() throws {
        let c = try JSONDecoder.core.decode(ConnectionInfo.self, from: Data(#"""
        {"id":"atlassian","label":"Atlassian","status":"signing_in","site":"https://acme.atlassian.net","usedBy":["jira","confluence"]}
        """#.utf8))
        XCTAssertEqual(c.status, .signingIn)
        XCTAssertEqual(c.usedBy, ["jira", "confluence"])
        let future = try JSONDecoder.core.decode(ConnectionInfo.self, from: Data(#"{"id":"x","status":"rate_limited"}"#.utf8))
        XCTAssertEqual(future.status, .error, "an unknown status is never shown as connected")
        XCTAssertEqual(future.label, "x")
    }

    func testConnectRequestNeverPrintsTheToken() {
        let r = ConnectRequest(site: "https://acme.atlassian.net", email: "me@acme.test", token: "fake-token-123")
        XCTAssertFalse("\(r)".contains("fake-token-123"))
        XCTAssertFalse(String(reflecting: r).contains("fake-token-123"))
    }

    func testConnectionEvent() throws {
        let e = try CoreEvent.decode(Data(#"{"type":"connection","connection":{"id":"atlassian","label":"Atlassian","status":"connected","usedBy":[]}}"#.utf8))
        guard case .connection(let c) = e else { return XCTFail("\(e)") }
        XCTAssertEqual(c.status, .connected)
    }

    func testNewTasksDecode() throws {
        let s = try settings(#"{"taskDefaults":{"actionFind":{"runnerID":"claude-code","model":"sonnet","effort":"medium"}}}"#)
        XCTAssertEqual(s.taskDefaults[AITask.actionFind.rawValue]?.effort, "medium")
        XCTAssertEqual(AITask(rawValue: "actionImprove"), .actionImprove)
    }
}

final class ConnectionRouteTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: String(repeating: "f", count: 64)), session: URLSession(configuration: config))
    }

    private func respond(_ json: String, status: Int = 200) { StubProtocol.handler = { _ in (status, Data(json.utf8)) } }
    private var last: StubProtocol.Recorded { StubProtocol.recorded.last! }

    func testConnectionRoutes() async throws {
        respond(#"{"connections":[{"id":"atlassian","label":"Atlassian","status":"not_connected","usedBy":["jira"]},{"bad":true}]}"#)
        let list = try await client.connections()
        XCTAssertEqual(list.map(\.id), ["atlassian"])
        XCTAssertEqual(last.path, "/v1/connections")

        respond(#"{"id":"atlassian","label":"Atlassian","status":"connected","site":"https://acme.atlassian.net","account":"me@acme.test","usedBy":[]}"#)
        let connected = try await client.connect("atlassian", ConnectRequest(site: "https://acme.atlassian.net", email: "me@acme.test", token: "fake"))
        XCTAssertEqual(connected.status, .connected)
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.path, "/v1/connections/atlassian/connect")
        let body = try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data())
        XCTAssertEqual(body, .object(["site": .string("https://acme.atlassian.net"), "email": .string("me@acme.test"), "token": .string("fake")]))

        respond(#"{"url":"https://id.atlassian.com/manage-profile/security/api-tokens"}"#)
        let url = try await client.signInURL("atlassian", site: "https://acme.atlassian.net")
        XCTAssertEqual(url.host, "id.atlassian.com")
        XCTAssertEqual(last.path, "/v1/connections/atlassian/sign-in-url")
        XCTAssertEqual(last.query, "site=https%3A%2F%2Facme.atlassian.net")

        respond(#"{"url":"file:///etc/passwd"}"#)
        do { _ = try await client.signInURL("atlassian"); XCTFail("only web addresses open") } catch {}

        respond(#"{"id":"atlassian","label":"Atlassian","status":"not_connected","usedBy":[]}"#)
        let off = try await client.disconnect("atlassian")
        XCTAssertEqual(off.status, .notConnected)
        XCTAssertEqual(last.path, "/v1/connections/atlassian/disconnect")

        respond(#"{"types":[{"id":"todo","label":"To do"}]}"#)
        let types = try await client.actionTypesJSON()
        XCTAssertEqual(types.first?["id"], .string("todo"))
        XCTAssertEqual(last.path, "/v1/action-types")
    }

    func testOldCoreAnswersNotAvailable() async {
        respond(#"{"error":{"code":"not_found","message":"no route for GET /v1/connections"}}"#, status: 404)
        do {
            _ = try await client.connections()
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertTrue(e.isNotAvailable)
        } catch { XCTFail("\(error)") }
    }
}
