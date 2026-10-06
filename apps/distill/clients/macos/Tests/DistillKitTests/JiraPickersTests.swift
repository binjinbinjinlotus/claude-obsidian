import XCTest
@testable import DistillKit

/// Jira pickers (actions.md): matching, search, the core's words for a value outside the lists, the
/// caption, and the routes with their `error.jira` kinds.
final class JiraPickersTests: XCTestCase {
    let projects = [JiraProject(key: "PX", name: "Project X"), JiraProject(key: "TLS", name: "Telus Platform")]
    let types = [JiraIssueType(id: "10001", name: "Task"), JiraIssueType(id: "10002", name: "Bug")]

    func testMatchingAndSearch() {
        XCTAssertEqual(JiraPick.key("TLS · Telus Platform"), "TLS")
        XCTAssertEqual(JiraPick.key(" tls "), "TLS")
        XCTAssertEqual(JiraPick.project("tls", in: projects)?.label, "TLS · Telus Platform")
        XCTAssertEqual(JiraPick.project("Telus platform", in: projects)?.key, "TLS", "by name too")
        XCTAssertNil(JiraPick.project("NOPE", in: projects))
        XCTAssertEqual(JiraPick.type(nil, in: types)?.id, "10001", "Task when empty, as the core")
        XCTAssertEqual(JiraPick.type("bug", in: types)?.name, "Bug")
        XCTAssertEqual(JiraPick.search("tel", in: projects).map(\.key), ["TLS"])
        XCTAssertEqual(JiraPick.search("p", in: projects).map(\.key), ["PX", "TLS"])
        XCTAssertEqual(JiraPick.search("", in: projects).count, 2)
    }

    func testTheCoresWordsForAValueOutsideTheLists() {
        XCTAssertEqual(JiraPick.priorityProblem("Medium", project: "TLS", priorities: ["P1 - Critical", "P3 - Normal"]), "Medium isn’t a priority in TLS. Pick one:")
        XCTAssertNil(JiraPick.priorityProblem("p3 - normal", project: "TLS", priorities: ["P1 - Critical", "P3 - Normal"]), "case is Jira’s to fix")
        XCTAssertNil(JiraPick.priorityProblem("Medium", project: "TLS", priorities: nil), "no Priority on the screen: hidden, not wrong")
        XCTAssertNil(JiraPick.priorityProblem("", project: "TLS", priorities: ["P1"]))
        XCTAssertEqual(JiraPick.typeProblem("Story", project: "TLS", types: types), "Story isn’t an issue type in TLS. Pick one:")
        XCTAssertNil(JiraPick.typeProblem("task", project: "TLS", types: types))
        XCTAssertEqual(JiraPick.projectProblem("NOPE", projects: projects), "NOPE isn’t a Jira project you can create tickets in. Pick one:")
        XCTAssertNil(JiraPick.projectProblem("TLS · Telus Platform", projects: projects))
        XCTAssertEqual(JiraPick.hiddenNote("Priority"), "Priority isn’t used in this project")
    }

    func testCheckGivesTheFieldAndTheFooter() {
        let screens = ["TLS|10001": JiraCreateScreen(project: "TLS", typeId: "10001", priorities: ["P1 · Blocker", "P3 · Major"])]
        let t = ["TLS": types]
        let bad = JiraPick.check(["project": "TLS · Telus Platform", "issueType": "Task", "priority": "Medium"], projects: projects, types: t, screens: screens)
        XCTAssertEqual(bad?.field, "priority")
        XCTAssertEqual(bad?.message, "Medium isn’t a priority in TLS. Pick one:")
        XCTAssertEqual(bad?.footer, "Pick a priority TLS uses")
        XCTAssertEqual(JiraPick.check(["project": "TLS", "issueType": "Story"], projects: projects, types: t, screens: screens)?.footer, "Pick a type TLS has")
        XCTAssertEqual(JiraPick.check(["project": "NOPE"], projects: projects, types: t, screens: screens)?.footer, "Pick a project you can create in")
        XCTAssertNil(JiraPick.check(["project": "TLS", "issueType": "Task", "priority": "p3 · major"], projects: projects, types: t, screens: screens))
        XCTAssertNil(JiraPick.check(["project": "TLS", "priority": "Medium"], projects: nil, types: t, screens: screens), "offline: Create stays on")
        XCTAssertNil(JiraPick.check(["project": "PX", "priority": "Medium"], projects: projects, types: t, screens: screens), "lists not loaded yet: nothing marked")
    }

    func testRecentPutsTheCurrentProjectFirst() {
        let all = projects + [JiraProject(key: "PAY", name: "Payments"), JiraProject(key: "OPS", name: "Operations")]
        XCTAssertEqual(JiraPick.recent(current: "TLS · Telus Platform", used: ["PAY", "TLS", "GONE", "PX", "OPS"], in: all).map(\.key), ["TLS", "PAY", "PX"])
        XCTAssertEqual(JiraPick.recent(current: nil, used: [], in: all), [])
    }

    func testCaption() {
        XCTAssertEqual(JiraPick.caption(account: "jin@lotusflare.com", fetchedAt: Date(timeIntervalSince1970: 0), now: Date(timeIntervalSince1970: 120)),
                       "From your Jira (jin@lotusflare… · updated 2 min ago)")
        let now = Date(timeIntervalSince1970: 1_000_000)
        XCTAssertEqual(JiraPick.caption(account: "Jin Liu", fetchedAt: now.addingTimeInterval(-180), now: now), "From your Jira (Jin Liu · updated 3 min ago)")
        XCTAssertEqual(JiraPick.caption(account: nil, fetchedAt: now, now: now), "From your Jira (updated just now)")
        XCTAssertEqual(JiraPick.caption(account: "Jin Liu", fetchedAt: now.addingTimeInterval(-7200), now: now), "From your Jira (Jin Liu · updated 2 h ago)")
        XCTAssertEqual(JiraPick.offline, "Couldn’t reach Jira to check these")
    }

    func testRoutesAndProblems() async throws {
        StubProtocol.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
        defer { StubProtocol.handler = nil }

        StubProtocol.handler = { _ in (200, Data(#"{"site":"https://acme.atlassian.net","account":"Jin Liu","fetchedAt":"2026-10-06T15:53:00Z","projects":[{"key":"TLS","name":"Telus Platform"}]}"#.utf8)) }
        let list = try await client.jiraProjects(refresh: true)
        XCTAssertEqual(list.projects.map(\.label), ["TLS · Telus Platform"])
        XCTAssertEqual(list.fetchedAt, CoreDate.parse("2026-10-06T15:53:00Z"))
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/jira/projects")
        XCTAssertEqual(StubProtocol.recorded.last?.query, "refresh=1")

        StubProtocol.handler = { _ in (200, Data(#"{"project":"TLS","types":[{"id":"10001","name":"Task"}]}"#.utf8)) }
        let types = try await client.jiraIssueTypes("TLS")
        XCTAssertEqual(types.types.map(\.name), ["Task"])
        StubProtocol.handler = { _ in (200, Data(#"{"project":"TLS","typeId":"10001","fields":[],"priorities":null}"#.utf8)) }
        let screen = try await client.jiraCreateScreen("TLS", typeId: "10001")
        XCTAssertNil(screen.priorities, "no Priority on the create screen")
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/jira/projects/TLS/types/10001/fields")

        StubProtocol.handler = { _ in (409, Data(#"{"error":{"code":"invalid_state","message":"Couldn’t reach acme.atlassian.net.","jira":"unreachable"}}"#.utf8)) }
        do { _ = try await client.jiraProjects(); XCTFail("expected a problem") } catch let e as JiraListError {
            XCTAssertEqual(e.problem, .unreachable("Couldn’t reach acme.atlassian.net."))
        }
        StubProtocol.handler = { _ in (409, Data(#"{"error":{"code":"invalid_state","message":"Jira isn’t connected.","jira":"not_connected"}}"#.utf8)) }
        do { _ = try await client.jiraProjects(); XCTFail("expected a problem") } catch let e as JiraListError {
            XCTAssertEqual(e.problem, .notConnected("Jira isn’t connected."))
        }
    }
}
