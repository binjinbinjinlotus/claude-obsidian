import XCTest
import DistillKit
@testable import Distill

/// The Settings search index against the canvas (SettingsNav 2 and 3), section
/// ids for deep links, and the Settings edits for actions.
final class SettingsCatalogTests: XCTestCase {
    private let all = SettingsIndex.all(types: SettingsActionType.builtIn)

    func testPromptMatchesSevenSettingsLikeTheBoard() {
        let results = SettingsIndex.search("prompt", in: all)
        XCTAssertEqual(results.count, 7)
        let counts = SettingsIndex.counts(results)
        XCTAssertEqual(counts[.actions], 6)
        XCTAssertEqual(counts[.models], 1)
        XCTAssertEqual(Set(results.map(\.crumb)), ["Actions › Slack message", "Actions › Jira ticket", "Actions › Confluence page", "Models for tasks"])
        XCTAssertFalse(results.contains { $0.crumb.contains("Email") }, "reserved types have no prompts")
    }

    func testNoMatches() {
        XCTAssertTrue(SettingsIndex.search("webhook", in: all).isEmpty)
        XCTAssertTrue(SettingsIndex.search("   ", in: all).isEmpty)
    }

    func testEveryWordMustMatchAndCaseIsIgnored() {
        XCTAssertEqual(SettingsIndex.search("WAIT file", in: all).map(\.title), ["Wait before picking up a file"])
        XCTAssertTrue(SettingsIndex.search("wait webhook", in: all).isEmpty)
    }

    func testEverySectionHasSearchableSettings() {
        let sections = Set(SettingsIndex.fixed.map(\.target.section))
        XCTAssertEqual(sections, Set(SettingsSection.allCases))
    }

    func testMatchRanges() {
        let text = "Create prompt · Prompt"
        XCTAssertEqual(SettingsIndex.matches(text, "prompt").map { String(text[$0]) }, ["prompt", "Prompt"])
    }

    func testDeepLinkIDs() {
        XCTAssertEqual(SettingsTarget(id: "connections"), SettingsTarget(.connections))
        XCTAssertEqual(SettingsTarget(id: "models"), SettingsTarget(.models))
        XCTAssertEqual(SettingsTarget(id: "actions/jira"), SettingsTarget(.actions, actionType: "jira"))
        XCTAssertEqual(SettingsTarget(id: "ask-history")?.section, .askHistory)
        XCTAssertNil(SettingsTarget(id: "nope"))
        XCTAssertEqual(SettingsTarget(.actions, actionType: "jira").id, "actions/jira")
        XCTAssertEqual(SettingsSection.allCases.map(\.group), [.general, .general, .general, .general, .general, .general, .ai, .ai, .actions, .actions, .actions])
    }

    func testActionTypeDecodesFromCoreJSON() throws {
        let json = try JSONDecoder.core.decode(JSONValue.self, from: Data(#"""
        {"id":"jira","label":"Jira ticket","pluralLabel":"Jira tickets","enabled":true,"draftWhen":"onRequest","improveAfterEdit":true,
         "defaultDraftPrompt":"Draft {project}","placeholders":["{project}"],"connectionID":"atlassian",
         "fields":[{"key":"project","label":"Project","kind":"text"},{"key":"issueType","label":"Type","kind":"choice"}],
         "handlers":[{"id":"create","label":"Create in Jira","available":true}]}
        """#.utf8))
        let t = try XCTUnwrap(SettingsActionType(json: json))
        XCTAssertEqual(t.draftWhen, "onRequest")
        XCTAssertTrue(t.createsOnClick)
        XCTAssertEqual(t.defaultFields.map(\.key), ["project", "issueType"])
        XCTAssertEqual(t.appName, "Jira")
        XCTAssertNil(SettingsActionType(json: .object([:])))
    }

    func testPromptEditsStoreOnlyRealChanges() {
        let jira = SettingsActionType.builtIn.first { $0.id == "jira" }!
        var s = Settings()
        XCTAssertFalse(SettingsEdits.promptEdited(jira, improve: false, s))
        XCTAssertEqual(SettingsEdits.prompt(jira, improve: false, s), jira.defaultDraftPrompt)
        SettingsEdits.setPrompt(jira, improve: false, text: "Mine", in: &s)
        XCTAssertTrue(SettingsEdits.promptEdited(jira, improve: false, s))
        SettingsEdits.setPrompt(jira, improve: false, text: jira.defaultDraftPrompt, in: &s)
        XCTAssertNil(s.actionPreferences?.draftPrompt("jira"), "typing the default back stores nothing")
        SettingsEdits.setPrompt(jira, improve: false, text: "Mine", in: &s)
        SettingsEdits.setPrompt(jira, improve: false, text: nil, in: &s)
        XCTAssertFalse(SettingsEdits.promptEdited(jira, improve: false, s))
    }

    func testFindingModelPrecedence() {
        var s = Settings()
        XCTAssertEqual(SettingsEdits.findSelection(s), ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "medium"))
        s.taskDefaults["actionFind"] = ModelSelection(runnerID: "codex", model: "gpt")
        XCTAssertEqual(SettingsEdits.findSelection(s).runnerID, "codex")
        SettingsEdits.setActions(&s) { $0.findSelection = ModelSelection(runnerID: "claude-code", model: "haiku") }
        XCTAssertEqual(SettingsEdits.findSelection(s).model, "haiku")
        XCTAssertEqual(SettingsEdits.draftSelection("slack", s).model, "sonnet")
    }

    func testTypeDefaults() {
        let s = Settings()
        let byID = Dictionary(uniqueKeysWithValues: SettingsActionType.builtIn.map { ($0.id, $0) })
        XCTAssertTrue(SettingsEdits.typeEnabled(byID["todo"]!, s))
        XCTAssertFalse(SettingsEdits.typeEnabled(byID["email"]!, s), "reserved")
        XCTAssertTrue(SettingsEdits.typeEnabled(byID["slack"]!, s))
        XCTAssertEqual(SettingsEdits.draftWhen(byID["jira"]!, s), "onFind")
    }
}
