import XCTest
@testable import DistillKit

/// Jira required fields (actions.md): the fields shown, the footer before Create, the value encodings
/// the core reads, saved values per project + type, and the routes.
final class JiraRequiredTests: XCTestCase {
    let team = JiraField(id: "customfield_11063", name: "Team", kind: .option,
                         options: ["Platform", "Payments", "Mobile", "Data", "Developer Experience"].map { JiraOption(id: $0, name: $0) })
    let projects = [JiraProject(key: "TLS", name: "Telus API Marketplace")]
    let types = ["TLS": [JiraIssueType(id: "10001", name: "Task")]]
    let base = ["project": "TLS", "issueType": "Task"]

    func screens(_ extra: [JiraField]) -> [String: JiraCreateScreen] {
        ["TLS|10001": JiraCreateScreen(project: "TLS", typeId: "10001", priorities: ["Critical"], extra: extra)]
    }

    func testTheOwnersCaseFooterNamesTheFieldNotTheId() {
        let c = JiraPick.check(base, projects: projects, types: types, screens: screens([team]))
        XCTAssertEqual(c?.field, "jira.customfield_11063")
        XCTAssertEqual(c?.footer, "Fill in Team first")
        XCTAssertNil(JiraPick.check(base.merging(["jira.customfield_11063": "Platform"]) { $1 }, projects: projects, types: types, screens: screens([team])))
        // A saved value for TLS · Task fills it.
        XCTAssertNil(JiraPick.check(base, projects: projects, types: types, screens: screens([team]),
                                    defaults: ["TLS|Task": ["customfield_11063": JiraRequiredDefault(name: "Team", value: "Platform")]]))
    }

    func testAFieldDistillCantFillKeepsCreateOff() {
        let rollout = JiraField(id: "customfield_300", name: "Rollout plan", kind: .unsupported)
        let c = JiraPick.check(base.merging(["jira.customfield_11063": "Platform"]) { $1 }, projects: projects, types: types, screens: screens([team, rollout]))
        XCTAssertEqual(c?.footer, "Rollout plan can only be filled in Jira")
    }

    func testShownFieldsAndWords() {
        let optional = JiraField(id: "customfield_9", name: "Squad", required: false, kind: .text)
        let jiraFills = JiraField(id: "customfield_8", name: "Region", kind: .option, hasDefault: true)
        XCTAssertEqual(JiraRequired.shown([team, optional, jiraFills], defaults: [:]).map(\.name), ["Team"], "optional fields stay hidden")
        XCTAssertEqual(JiraRequired.shown([team, optional], defaults: ["customfield_9": JiraRequiredDefault(name: "Squad", value: "A")]).map(\.name), ["Team", "Squad"])
        XCTAssertEqual(JiraRequired.placeholder("Team"), "Choose a team")
        XCTAssertEqual(JiraRequired.placeholder("Environment"), "Choose an environment")
        XCTAssertEqual(JiraRequired.menuTitle("Team", project: "TLS"), "TEAMS IN TLS")
        XCTAssertEqual(JiraRequired.useForFuture(project: "TLS", type: "Task"), "Use for future TLS Tasks")
    }

    func testValueEncodingsMatchTheCore() {
        let comps = JiraField(id: "components", name: "Components", kind: .options)
        let values = ["jira.components": #"["API","Gateway"]"#, "jira.components:from": #"["API"]"#]
        XCTAssertEqual(JiraRequired.names(values["jira.components"]), ["API", "Gateway"])
        XCTAssertEqual(JiraRequired.fromNote(comps, values: values), ["API"], "only the names the note gave")
        XCTAssertEqual(JiraRequired.fromNote(team, values: ["jira.customfield_11063": "Payments", "jira.customfield_11063:from": "note"]), ["Payments"])
        XCTAssertTrue(JiraRequired.isEmpty("[]"))
        let u = JiraUser(accountId: "acc-aditya", name: "Aditya Pradhan")
        XCTAssertEqual(JiraRequired.user(JiraRequired.encode(u)), u)
        XCTAssertEqual(JiraRequired.initials(u.name), "AP")
        XCTAssertEqual(JiraRequired.dayLabel("2026-10-16"), "Oct 16, 2026")
        XCTAssertEqual(JiraRequired.dayString(JiraRequired.date("2026-10-16")!), "2026-10-16")
        let env = JiraField(id: "e", name: "Environment", kind: .cascading)
        XCTAssertEqual(JiraRequired.display(env, #"["Staging","us-east-1"]"#), "Staging › us-east-1")
    }

    func testSavedValuesPerProjectAndType() {
        var p = ActionPreferences()
        p.setJiraRequiredDefault("TLS|Task", field: "customfield_11063", JiraRequiredDefault(name: "Team", value: "Platform"))
        XCTAssertEqual(p.jiraRequiredDefaults, ["TLS|Task": ["customfield_11063": JiraRequiredDefault(name: "Team", value: "Platform")]])
        XCTAssertEqual(p.value(["types", "jira", "requiredDefaults", "TLS|Task", "customfield_11063", "value"])?.stringValue, "Platform", "the core's shape")
        p.setJiraRequiredDefault("TLS|Task", field: "customfield_11063", nil)
        XCTAssertEqual(p.jiraRequiredDefaults, [:])
        XCTAssertNil(p.value(["types", "jira", "requiredDefaults", "TLS|Task"]), "an empty project + type is removed")
    }

    func testRoutes() async throws {
        StubProtocol.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
        defer { StubProtocol.handler = nil }

        StubProtocol.handler = { _ in (200, Data(#"{"project":"TLS","typeId":"10001","priorities":["Critical"],"fields":[],"extra":[{"id":"customfield_11063","name":"Team","required":true,"kind":"option","options":[{"id":"20100","name":"Platform"}]},{"id":"x","name":"Odd","required":true,"kind":"somethingNew"}]}"#.utf8)) }
        let screen = try await client.jiraCreateScreen("TLS", typeId: "10001")
        XCTAssertEqual(screen.extra.map(\.name), ["Team", "Odd"])
        XCTAssertEqual(screen.extra[0].options.map(\.name), ["Platform"])
        XCTAssertEqual(screen.extra[1].kind, .unsupported, "a kind this build doesn't know can't be filled here")

        StubProtocol.handler = { _ in (200, Data(#"{"users":[{"accountId":"acc-aditya","name":"Aditya Pradhan"}]}"#.utf8)) }
        let people = try await client.jiraUsers("TLS", query: "adi")
        XCTAssertEqual(people, [JiraUser(accountId: "acc-aditya", name: "Aditya Pradhan")])
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/jira/projects/TLS/users")
        XCTAssertEqual(StubProtocol.recorded.last?.query, "q=adi")

        StubProtocol.handler = { _ in (200, Data(#"{"url":"https://acme.atlassian.net/secure/CreateIssueDetails!init.jspa?pid=10000"}"#.utf8)) }
        let url = try await client.jiraCreateURL("j1")
        XCTAssertEqual(url?.host, "acme.atlassian.net")
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/actions/j1/jira-create-url")
    }
}
