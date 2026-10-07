import XCTest
@testable import Distill
@testable import DistillKit

/// Jira required fields in the app (actions.md): the footer keeps Create off until Team is filled, "Use for
/// future TLS Tasks" saves the value per project + type, and Settings can find the section.
@MainActor
final class JiraRequiredAppTests: XCTestCase {
    func testFooterAndUseForFuture() {
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        let store = e.actions
        store.loadFixture(types: [], items: [])
        let team = JiraField(id: "customfield_11063", name: "Team", kind: .option, options: [JiraOption(id: "20100", name: "Platform")])
        store.jiraProjects = JiraProjectList(site: "https://acme.atlassian.net", account: nil, fetchedAt: Date(), projects: [JiraProject(key: "TLS", name: "Telus API Marketplace")])
        store.jiraTypes = ["TLS": [JiraIssueType(id: "10001", name: "Task")]]
        store.jiraScreens = ["TLS|10001": JiraCreateScreen(project: "TLS", typeId: "10001", priorities: ["Critical"], extra: [team])]
        let values = ["project": "TLS", "issueType": "Task"]

        XCTAssertEqual(store.jiraScreen(values)?.screen.extra.map(\.name), ["Team"])
        XCTAssertEqual(store.jiraCheck(values)?.footer, "Fill in Team first", "Create stays off")
        XCTAssertNil(store.jiraCheck(values.merging(["jira.customfield_11063": "Platform"]) { $1 }))

        // Use for future TLS Tasks: saved in settings, and the footer clears for every TLS Task.
        store.setJiraRequiredDefault(project: "TLS", type: "Task", field: team, value: "Platform")
        XCTAssertEqual(e.settings.actionPreferences?.jiraRequiredDefaults["TLS|Task"]?["customfield_11063"]?.value, "Platform")
        XCTAssertNil(store.jiraCheck(values))
        store.setJiraRequiredDefault(project: "TLS", type: "Task", field: team, value: nil)
        XCTAssertEqual(store.jiraCheck(values)?.footer, "Fill in Team first")
    }

    func testRequiredFieldsSectionIsInTheSettingsIndex() {
        let jira = SettingsActionType(id: "jira", label: "Jira ticket", pluralLabel: "Jira tickets")
        let hit = SettingsIndex.search("required", in: SettingsIndex.all(types: [jira]))
        XCTAssertTrue(hit.contains { $0.title == "Required fields, per project and type" })
    }
}
