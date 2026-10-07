import XCTest
import DistillKit
@testable import Distill

/// Settings edits (SettingsEdits.swift) beyond the round trips in SettingsEditTests: the
/// taxonomy edits, the defaults each getter falls back to, runner and model choices, and titles.
final class SettingsEditsTests: XCTestCase {
    private func runner(_ id: String, enabled: Bool = false, defaultModel: String = "", models: [String] = [], effort: [String] = [],
                        tasks: [String] = [], capabilities: [String] = []) throws -> RunnerInfo {
        try XCTUnwrap(DTO.make(.object([
            "id": .string(id), "enabled": .bool(enabled), "defaultModel": .string(defaultModel),
            "models": .array(models.map { .object(["id": .string($0), "label": .string($0.uppercased())]) }),
            "effortLevels": .array(effort.map(JSONValue.string)), "tasks": .array(tasks.map(JSONValue.string)),
            "capabilities": .array(capabilities.map(JSONValue.string)),
        ])))
    }

    // MARK: Sources

    func testSlugsAreNormalizedAndUnique() {
        XCTAssertEqual(SettingsEdits.slug("GitHub review", taken: []), "github-review")
        XCTAssertEqual(SettingsEdits.slug("Docs/Specs", taken: []), "docs-specs", "a slash is a word break, not a folder")
        XCTAssertEqual(SettingsEdits.slug("2024", taken: []), "source", "nothing usable: a plain id")
        XCTAssertEqual(SettingsEdits.slug("Slack", taken: ["slack"]), "slack-2")
        XCTAssertEqual(SettingsEdits.slug("Slack", taken: ["slack", "slack-2", "slack-3"]), "slack-4")
    }

    func testGroupEditsIgnoreBlanksAndUnknownGroups() {
        var s = Settings()
        SettingsEdits.addSource("   ", toGroup: "discussion", in: &s)
        SettingsEdits.addGroup("\n", in: &s)
        SettingsEdits.renameGroup("discussion", to: " ", in: &s)
        SettingsEdits.addSource("Discord", toGroup: "nowhere", in: &s)
        SettingsEdits.removeSource("slack", fromGroup: "nowhere", in: &s)
        SettingsEdits.renameGroup("nowhere", to: "X", in: &s)
        XCTAssertNil(s.sourceTaxonomy, "nothing changed: settings keep following the default")
        SettingsEdits.addSource("  Discord  ", toGroup: "discussion", in: &s)
        XCTAssertEqual(SettingsEdits.taxonomy(s)[0].sources.last, SourceDefinition(id: "discord", label: "Discord"))
        // A group's own id is taken too.
        SettingsEdits.addSource("Reference", toGroup: "personal", in: &s)
        XCTAssertEqual(SettingsEdits.taxonomy(s)[2].sources.last?.id, "reference-2")
    }

    func testRenameAndRemove() {
        var s = Settings()
        SettingsEdits.renameGroup("reference", to: "  Reading  ", in: &s)
        XCTAssertEqual(SettingsEdits.taxonomy(s).map(\.label), ["Discussion", "Reading", "Personal"])
        XCTAssertEqual(SettingsEdits.taxonomy(s)[1].id, "reference", "the id stays")
        SettingsEdits.removeSource("paper", fromGroup: "reference", in: &s)
        XCTAssertEqual(SettingsEdits.taxonomy(s)[1].sources.map(\.id), ["web-page", "document"])
        SettingsEdits.removeSource("slack", fromGroup: "reference", in: &s)
        XCTAssertEqual(SettingsEdits.taxonomy(s)[0].sources.first?.id, "slack", "only from the named group")
        SettingsEdits.removeGroup("personal", in: &s)
        XCTAssertEqual(SettingsEdits.taxonomy(s).map(\.id), ["discussion", "reference"])
        SettingsEdits.addGroup("Work", in: &s)
        XCTAssertEqual(SettingsEdits.taxonomy(s).last, SourceGroup(id: "work", label: "Work", sources: []))
        SettingsEdits.removeGroup("work", in: &s)
        SettingsEdits.removeGroup("discussion", in: &s)
        SettingsEdits.removeGroup("reference", in: &s)
        XCTAssertEqual(s.sourceTaxonomy, [], "an empty list is kept, not the default")
        XCTAssertEqual(SettingsEdits.defaultTaxonomy, SourceGroup.defaultTaxonomy)
    }

    // MARK: Defaults

    func testPreferenceDefaults() {
        let s = Settings()
        XCTAssertEqual(SettingsEdits.labelMatch(s), .any)
        XCTAssertTrue(SettingsEdits.includeUnconfirmed(s))
        XCTAssertTrue(SettingsEdits.keepHistory(s))
        XCTAssertEqual(SettingsEdits.historyDays(s), 10)
        XCTAssertTrue(SettingsEdits.autoLabelQueueFolder(s))
        XCTAssertTrue(SettingsEdits.cliFallbackToAI(s))
        var set = Settings()
        SettingsEdits.setAsk(&set) { $0.labelMatch = .all; $0.includeUnconfirmed = false; $0.keepHistory = false; $0.historyDays = 3 }
        SettingsEdits.setLabeling(&set, autoLabelQueueFolder: false, cliFallbackToAI: false)
        XCTAssertEqual(SettingsEdits.labelMatch(set), .all)
        XCTAssertFalse(SettingsEdits.includeUnconfirmed(set))
        XCTAssertFalse(SettingsEdits.keepHistory(set))
        XCTAssertEqual(SettingsEdits.historyDays(set), 3)
        XCTAssertFalse(SettingsEdits.autoLabelQueueFolder(set))
        XCTAssertFalse(SettingsEdits.cliFallbackToAI(set))
        // Setting one labeling field keeps the other as it was.
        SettingsEdits.setLabeling(&set, cliFallbackToAI: true)
        XCTAssertEqual(set.labeling?.autoLabelQueueFolder, false)
        XCTAssertEqual(set.labeling?.cliFallbackToAI, true)
    }

    func testShortcutsReadBack() {
        var s = Settings()
        XCTAssertNil(SettingsEdits.shortcut(.ask, in: s))
        SettingsEdits.setShortcut(.ask, KeyShortcut("ctrl+opt+space"), in: &s)
        XCTAssertEqual(SettingsEdits.shortcut(.ask, in: s), KeyShortcut("ctrl+opt+space"))
        XCTAssertNil(SettingsEdits.shortcut(.addNote, in: s))
        SettingsEdits.setShortcut(.addNote, KeyShortcut("ctrl+opt+n"), in: &s)
        XCTAssertNotNil(SettingsEdits.shortcut(.ask, in: s), "setting one keeps the other")
        SettingsEdits.setShortcut(.addNote, nil, in: &s)
        XCTAssertNil(s.shortcuts?.addNote)
        XCTAssertNotNil(s.shortcuts?.ask)
    }

    // MARK: Runners and models

    func testRunnerListsAndOptions() {
        var s = Settings()
        SettingsEdits.setRunner("claude-code", enabled: true, in: &s)
        XCTAssertEqual(s.enabledRunners, ["claude-code"], "never listed twice")
        SettingsEdits.setRunner("codex", enabled: false, in: &s)
        XCTAssertEqual(s.enabledRunners, ["claude-code"])
        SettingsEdits.setRunnerOption("codex", "path", "~/bin/codex", in: &s)
        SettingsEdits.setRunnerOption("codex", "extra", "x", in: &s)
        SettingsEdits.setRunnerOption("codex", "path", "  ", in: &s)
        XCTAssertEqual(s.runnerOptions, ["codex": ["extra": "x"]], "a blank value removes only that option")
        XCTAssertEqual(SettingsEdits.optionFields(for: "codex").map(\.name), ["path"])
        XCTAssertEqual(SettingsEdits.optionFields(for: "openai").map(\.placeholder), ["https://api.openai.com/v1"])
        XCTAssertEqual(SettingsEdits.optionFields(for: "openrouter").map(\.placeholder), ["https://openrouter.ai/api/v1"])
        XCTAssertEqual(SettingsEdits.optionFields(for: "ai-sdk").map(\.name), ["packageDir", "provider", "baseURL"])
        XCTAssertEqual(SettingsEdits.optionFields(for: "claude-code").count, 0)
    }

    func testEveryTaskHasItsDefaultModel() {
        var s = Settings()
        s.model = "opus"
        XCTAssertEqual(SettingsEdits.fallbackSelection(.ingest, settings: s), ModelSelection(runnerID: "claude-code", model: "opus"))
        XCTAssertEqual(SettingsEdits.fallbackSelection(.ask, settings: s), ModelSelection(runnerID: "claude-code", model: "opus"))
        XCTAssertEqual(SettingsEdits.fallbackSelection(.imageText, settings: s), ModelSelection(runnerID: "claude-code", model: "haiku", effort: "low"))
        XCTAssertEqual(SettingsEdits.fallbackSelection(.actionFind, settings: s), ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "medium"))
        XCTAssertEqual(SettingsEdits.fallbackSelection(.actionDraft, settings: s), ModelSelection(runnerID: "claude-code", model: "sonnet"))
        XCTAssertEqual(SettingsEdits.fallbackSelection(.actionImprove, settings: s), ModelSelection(runnerID: "claude-code", model: "sonnet"))
        XCTAssertEqual(SettingsEdits.fallbackSelection(.recovery, settings: s), ModelSelection(runnerID: "claude-code", model: "opus", effort: "medium"))
        SettingsEdits.setTaskModel(.ask, model: "haiku", in: &s)
        XCTAssertEqual(SettingsEdits.selection(.ask, settings: s), ModelSelection(runnerID: "claude-code", model: "haiku"))
        XCTAssertEqual(SettingsEdits.selection(.ingest, settings: s).model, "opus", "other tasks keep their default")
    }

    func testChangingTheRunnerResetsTheModelAndUnofferedEffort() throws {
        let sel = ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "high")
        let same = try runner("claude-code", defaultModel: "opus")
        XCTAssertEqual(SettingsEdits.withRunner(sel, same), sel, "the same runner changes nothing")
        let withDefault = try runner("codex", defaultModel: "gpt-5", models: ["gpt-4"], effort: ["high"])
        XCTAssertEqual(SettingsEdits.withRunner(sel, withDefault), ModelSelection(runnerID: "codex", model: "gpt-5", effort: "high"))
        let firstModel = try runner("openai", models: ["gpt-4o", "gpt-4.1"], effort: ["low"])
        XCTAssertEqual(SettingsEdits.withRunner(sel, firstModel), ModelSelection(runnerID: "openai", model: "gpt-4o"))
        let noModels = try runner("custom")
        XCTAssertEqual(SettingsEdits.withRunner(sel, noModels), ModelSelection(runnerID: "custom", model: "sonnet"), "nothing to pick: the model stays")
        let noEffort = ModelSelection(runnerID: "claude-code", model: "sonnet")
        XCTAssertNil(SettingsEdits.withRunner(noEffort, firstModel).effort)
        // A task already on that runner isn't touched.
        var s = Settings()
        SettingsEdits.setTaskRunner(.ask, runner: same, in: &s)
        XCTAssertTrue(s.taskDefaults.isEmpty)
        SettingsEdits.setTaskRunner(.ask, runner: withDefault, in: &s)
        XCTAssertEqual(s.taskDefaults["ask"], ModelSelection(runnerID: "codex", model: "gpt-5"))
    }

    func testRunnerCandidatesForATask() throws {
        var s = Settings()
        s.enabledRunners = ["claude-code", "codex"]
        let claude = try runner("claude-code", tasks: ["ask", "ingest"])
        let codex = try runner("codex", tasks: ["ingest"])
        let openai = try runner("openai", enabled: true, tasks: ["ask"], capabilities: ["structuredOutput"])
        let off = try runner("openrouter", tasks: ["ask"], capabilities: ["structuredOutput"])
        let old = try runner("ai-sdk", enabled: true, capabilities: ["structuredOutput"])
        let plain = try runner("ollama", enabled: true)
        let all = [claude, codex, openai, off, old, plain]
        XCTAssertEqual(SettingsEdits.candidates(for: .ask, runners: all, settings: s).map(\.id), ["claude-code", "openai"])
        XCTAssertEqual(SettingsEdits.candidates(for: .ingest, runners: all, settings: s).map(\.id), ["claude-code", "codex"])
        // Action tasks and recovery accept any runner with structured output (an older core may not list them).
        for task in [AITask.actionFind, .actionDraft, .actionImprove, .recovery] {
            XCTAssertEqual(SettingsEdits.candidates(for: task, runners: all, settings: s).map(\.id), ["openai", "ai-sdk"], task.rawValue)
        }
        XCTAssertEqual(SettingsEdits.candidates(for: .labelSuggest, runners: all, settings: s).map(\.id), [])
        // The current runner stays listed even when it's off.
        XCTAssertEqual(SettingsEdits.candidates(for: .ask, runners: all, settings: s, current: "openrouter").map(\.id), ["claude-code", "openai", "openrouter"])
        s.taskDefaults["ask"] = ModelSelection(runnerID: "openrouter", model: "x")
        XCTAssertEqual(SettingsEdits.candidates(for: .ask, runners: all, settings: s).map(\.id), ["claude-code", "openai", "openrouter"])
    }

    // MARK: Actions

    func testPerTypeOverrides() {
        var s = Settings()
        let slack = ActionTypeInfo(id: "slack", label: "Slack message", enabled: false, draftWhen: "onRequest", improveAfterEdit: true,
                                   defaultDraftPrompt: "Draft it", defaultImprovePrompt: "Improve it")
        XCTAssertFalse(SettingsEdits.typeEnabled(slack, s), "the type's own default")
        XCTAssertTrue(SettingsEdits.typeEnabled(ActionTypeInfo(id: "todo", label: "To do", enabled: false), s), "To do is always on")
        XCTAssertEqual(SettingsEdits.draftWhen(slack, s), "onRequest")
        XCTAssertTrue(SettingsEdits.improveAfterEdit(slack, s))
        XCTAssertEqual(SettingsEdits.prompt(slack, improve: true, s), "Improve it")
        XCTAssertEqual(SettingsEdits.prompt(slack, improve: false, s), "Draft it")
        XCTAssertEqual(SettingsEdits.prompt(ActionTypeInfo(id: "x", label: "X"), improve: true, s), "", "no default: empty")
        XCTAssertEqual(SettingsEdits.improveSelection("slack", s), ModelSelection(runnerID: "claude-code", model: "sonnet"))
        SettingsEdits.setActions(&s) {
            $0.setTypeValue("slack", "enabled", .bool(true))
            $0.setTypeValue("slack", "draftWhen", .string("onFind"))
            $0.setTypeValue("slack", "improveAfterEdit", .bool(false))
            $0.setTypeValue("slack", "improveSelection", .object(["runnerID": .string("codex"), "model": .string("gpt-5")]))
        }
        XCTAssertTrue(SettingsEdits.typeEnabled(slack, s))
        XCTAssertEqual(SettingsEdits.draftWhen(slack, s), "onFind")
        XCTAssertFalse(SettingsEdits.improveAfterEdit(slack, s))
        XCTAssertEqual(SettingsEdits.improveSelection("slack", s), ModelSelection(runnerID: "codex", model: "gpt-5"))
        XCTAssertEqual(SettingsEdits.improveSelection("jira", s).runnerID, "claude-code")
        // A reserved type is off whatever the settings say.
        var email = ActionTypeInfo(id: "email", label: "Email", reserved: true)
        SettingsEdits.setActions(&s) { $0.setTypeValue("email", "enabled", .bool(true)) }
        XCTAssertFalse(SettingsEdits.typeEnabled(email, s))
        email.reserved = false
        XCTAssertTrue(SettingsEdits.typeEnabled(email, s))
    }

    func testImprovePromptEditsAreTheirOwn() {
        var s = Settings()
        let slack = ActionTypeInfo(id: "slack", label: "Slack message", defaultDraftPrompt: "Draft it", defaultImprovePrompt: "Improve it")
        SettingsEdits.setPrompt(slack, improve: true, text: "Shorter", in: &s)
        XCTAssertTrue(SettingsEdits.promptEdited(slack, improve: true, s))
        XCTAssertFalse(SettingsEdits.promptEdited(slack, improve: false, s))
        XCTAssertEqual(SettingsEdits.prompt(slack, improve: true, s), "Shorter")
        XCTAssertEqual(SettingsEdits.prompt(slack, improve: false, s), "Draft it")
        SettingsEdits.setPrompt(slack, improve: true, text: "Improve it", in: &s)
        XCTAssertFalse(SettingsEdits.promptEdited(slack, improve: true, s))
        XCTAssertNil(s.actionPreferences?.improvePrompt("slack"))
    }

    // MARK: Titles

    func testTitles() {
        XCTAssertEqual(AITask.allCases.map { SettingsEdits.taskTitle($0).0 },
                       ["Adding notes", "Ask a question", "Label suggestions", "Text from images", "Finding actions", "Action drafts",
                        "Improving drafts", "Recovery"])
        XCTAssertEqual(SettingsEdits.taskTitle(.imageText).1, "When you click Extract content on an image")
        XCTAssertEqual(SettingsEdits.effortTitle(nil), "Default")
        XCTAssertEqual(SettingsEdits.effortTitle(""), "Default")
        XCTAssertEqual(SettingsEdits.effortTitle("xhigh"), "Extra high")
        XCTAssertEqual(SettingsEdits.effortTitle("medium"), "Medium")
    }

    func testModelTitles() throws {
        let r = try runner("openai", models: ["gpt-4o"])
        XCTAssertEqual(SettingsEdits.modelTitle("gpt-4o", runner: r), "GPT-4O", "the runner's own label")
        XCTAssertEqual(SettingsEdits.modelTitle("claude-opus-5-5", runner: r), "Opus")
        XCTAssertEqual(SettingsEdits.modelTitle("gpt-5", runner: nil), "gpt-5")
        XCTAssertEqual(SettingsEdits.modelTitle("sonnet", runner: nil), "Sonnet")
    }

    func testDTOMakesNothingFromTheWrongShape() {
        let none: RunnerInfo? = DTO.make(.object(["displayName": .string("No id")]))
        XCTAssertNil(none)
    }

    // MARK: App helpers

    func testConnectionMessagesNeverGuess() {
        XCTAssertEqual(AppModel.connectionMessage(CoreClientError.api(status: 501, code: "not_implemented", message: "x"), "Couldn’t connect"),
                       "Update the Distill core to connect accounts.")
        XCTAssertEqual(AppModel.connectionMessage(CoreClientError.api(status: 400, code: "bad", message: "Site is required."), "Couldn’t connect"),
                       "Couldn’t connect: Site is required.")
        XCTAssertEqual(AppModel.connectionMessage(CoreClientError.unreachable("refused"), "Couldn’t disconnect"),
                       "Couldn’t disconnect: the Distill core isn’t running.")
        XCTAssertEqual(AppModel.connectionMessage(CoreClientError.badResponse("x"), "Couldn’t connect"), "Couldn’t connect.")
        XCTAssertEqual(AppModel.connectionMessage(CocoaError(.fileNoSuchFile), "Couldn’t connect"), "Couldn’t connect.")
        // A refused-looking message under another code is shown in its own words.
        XCTAssertEqual(ConnectionProblem.connectFailed(CoreClientError.api(status: 400, code: "other", message: "Didn't accept it")),
                       ConnectionProblem(title: "Didn't accept it", detail: "Nothing was saved."))
        XCTAssertEqual(ConnectionProblem.connectFailed(CoreClientError.api(status: 501, code: "not_implemented", message: "accept")),
                       ConnectionProblem(title: "Update the Distill core to connect accounts.", detail: "Nothing was saved."))
    }

    @MainActor func testIntakeNamesSortByTime() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = .current
        let date = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 9, minute: 5, second: 7))!
        XCTAssertEqual(AppModel.intakeName(prefix: "Pasted", ext: "md", date: date), "Pasted 2026-10-06 090507.md")
    }
}
