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

    func testScreenNeedsTheProjectTheTypeAndItsScreen() {
        let store = ActionsStore()
        let values = ["project": "tls · Telus", "issueType": "task"]
        XCTAssertNil(store.jiraScreen(values), "no projects loaded")
        store.jiraProjects = JiraProjectList(site: "s", account: nil, fetchedAt: Date(), projects: [JiraProject(key: "TLS", name: "Telus")])
        XCTAssertNil(store.jiraScreen(values), "no types loaded")
        store.jiraTypes = ["TLS": [JiraIssueType(id: "1", name: "Task"), JiraIssueType(id: "2", name: "Bug")]]
        XCTAssertNil(store.jiraScreen(values), "no screen loaded")
        store.jiraScreens = ["TLS|2": JiraCreateScreen(project: "TLS", typeId: "2", priorities: nil)]
        XCTAssertNil(store.jiraScreen(values), "another type's screen")
        store.jiraScreens["TLS|1"] = JiraCreateScreen(project: "TLS", typeId: "1", priorities: nil)
        let hit = store.jiraScreen(values)
        XCTAssertEqual(hit?.project, "TLS")
        XCTAssertEqual(hit?.type, "Task", "Jira's spelling")
        XCTAssertEqual(hit?.screen.typeId, "1")
        XCTAssertNil(store.jiraScreen(["project": "OPS", "issueType": "Task"]), "a project outside the list")
    }

    func testWithoutTheAppNothingIsSavedOrRead() {
        let store = ActionsStore()
        XCTAssertEqual(store.jiraRequiredDefaults, [:])
        store.setJiraRequiredDefault(project: "TLS", type: "Task", field: JiraField(id: "a", name: "A", kind: .text), value: "x")
        XCTAssertEqual(store.jiraRequiredDefaults, [:])
    }

    func testSavedValuesAreKeyedByTheProjectAndTypeAndKeepTheFieldName() {
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        let store = e.actions
        let field = JiraField(id: "cf_env", name: "Environment", kind: .cascading)
        store.setJiraRequiredDefault(project: " tls ", type: " Bug ", field: field, value: #"["Staging","us-east-1"]"#)
        XCTAssertEqual(store.jiraRequiredDefaults, ["TLS|Bug": ["cf_env": JiraRequiredDefault(name: "Environment", value: #"["Staging","us-east-1"]"#)]])
        XCTAssertEqual(e.settings.actionPreferences?.jiraRequiredDefaults["TLS|Bug"]?["cf_env"]?.name, "Environment", "saved in the app's settings")
        store.setJiraRequiredDefault(project: "TLS", type: "Bug", field: field, value: nil)
        XCTAssertEqual(store.jiraRequiredDefaults, [:])
    }

    func testAStoreIsReusedOnlyForItsOwnModel() {
        // A freed model's store left at the address a new model gets: of(_:) must not hand it over.
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        let stale = ActionsStore()
        weak var gone: AppModel?
        do {
            let old = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
            stale.engine = old
            gone = old
        }
        XCTAssertNil(gone)
        XCTAssertNil(stale.engine)
        let other = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        let otherStore = ActionsStore.of(other)
        ActionsStore.stores[ObjectIdentifier(e)] = stale
        let stray = ActionsStore()
        ActionsStore.stores[ObjectIdentifier(stray)] = stray  // a freed model's entry under another key
        let store = ActionsStore.of(e)
        XCTAssertFalse(store === stale)
        XCTAssertTrue(store.engine === e)
        XCTAssertTrue(ActionsStore.of(e) === store, "then reused for the same model")
        XCTAssertTrue(e.actions === store)
        XCTAssertFalse(ActionsStore.stores.values.contains { $0.engine == nil }, "stores of freed models are dropped")
        XCTAssertNil(ActionsStore.stores[ObjectIdentifier(stray)])
        XCTAssertTrue(ActionsStore.of(other) === otherStore, "a live model keeps its store")
    }

    func testRequiredFieldsSectionIsInTheSettingsIndex() {
        let jira = SettingsActionType(id: "jira", label: "Jira ticket", pluralLabel: "Jira tickets")
        let hit = SettingsIndex.search("required", in: SettingsIndex.all(types: [jira]))
        XCTAssertTrue(hit.contains { $0.title == "Required fields, per project and type" })
    }
}
