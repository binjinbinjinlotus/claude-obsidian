import XCTest
import DistillKit
@testable import Distill

final class ShortcutTests: XCTestCase {
    func testParsesAndFormatsCanonicalForm() throws {
        let s = try XCTUnwrap(KeyShortcut("ctrl+opt+space"))
        XCTAssertEqual(s.modifiers, [.control, .option])
        XCTAssertEqual(s.key, "space")
        XCTAssertEqual(s.stringValue, "ctrl+opt+space")
        XCTAssertEqual(s.displayString, "⌃⌥Space")
    }

    func testAcceptsAliasesAndNormalizesOrder() throws {
        let s = try XCTUnwrap(KeyShortcut("Command+Shift+N"))
        XCTAssertEqual(s.stringValue, "shift+cmd+n")
        XCTAssertEqual(s.displayString, "⇧⌘N")
        XCTAssertEqual(KeyShortcut("alt+control+enter")?.stringValue, "ctrl+opt+return")
        XCTAssertEqual(KeyShortcut("option+f5")?.displayString, "⌥F5")
    }

    func testRejectsUnusableShortcuts() {
        XCTAssertNil(KeyShortcut("n"), "a plain key must not become global")
        XCTAssertNil(KeyShortcut("shift+n"), "shift alone is not enough")
        XCTAssertNil(KeyShortcut("ctrl+"), "missing key")
        XCTAssertNil(KeyShortcut("hyper+n"), "unknown modifier")
        XCTAssertNil(KeyShortcut("ctrl+nosuchkey"))
        XCTAssertNil(KeyShortcut(""))
    }

    func testFunctionKeysNeedNoModifier() {
        XCTAssertEqual(KeyShortcut("f13")?.stringValue, "f13")
    }

    func testRoundTripsEveryKey() {
        for key in KeyShortcut.keyCodes.keys {
            let s = KeyShortcut(modifiers: [.command, .option], key: key)
            XCTAssertEqual(KeyShortcut(s.stringValue), s, key)
        }
    }

    func testCarbonValues() throws {
        let s = try XCTUnwrap(KeyShortcut("ctrl+opt+space"))
        XCTAssertEqual(s.carbonKeyCode, 49)
        XCTAssertNotEqual(s.carbonModifiers, 0)
    }

    func testSettingsShortcutsMapToActions() {
        let settings = DTO.shortcuts(ask: "ctrl+opt+space", addNote: "bogus")
        let map = GlobalShortcuts.shortcuts(from: settings)
        XCTAssertEqual(map[.ask]?.stringValue, "ctrl+opt+space")
        XCTAssertNil(map[.addNote], "an unparsable value registers nothing")
        XCTAssertTrue(GlobalShortcuts.shortcuts(from: nil).isEmpty, "no defaults")
    }
}

final class LabelNameTests: XCTestCase {
    func testNormalizesLikeTheCore() {
        XCTAssertEqual(LabelName.normalize("#Project X"), "project-x")
        XCTAssertEqual(LabelName.normalize("  tea/green "), "tea/green")
        XCTAssertEqual(LabelName.normalize("a.b!c"), "abc")
        XCTAssertNil(LabelName.normalize("2024"), "purely numeric labels are dropped")
        XCTAssertNil(LabelName.normalize("  # "))
    }

    func testParsesLists() {
        XCTAssertEqual(LabelName.parseList("tea, Brewing #gyokuro, tea"), ["tea", "brewing", "gyokuro"])
    }
}

final class LabelStepTests: XCTestCase {
    private let tea = LabelSuggestion(name: "tea", existing: true)
    private let shops = LabelSuggestion(name: "Tea Shops", existing: false)

    func testPendingThenSuggestionsThenApplied() {
        var step = LabelStep(requestID: "r1", title: "Note", suggesting: true)
        XCTAssertEqual(step.phase, .suggesting)
        XCTAssertFalse(step.canApply)

        step.received(requestID: "other", labels: [tea], error: nil)
        XCTAssertEqual(step.phase, .suggesting, "another note's suggestions are ignored")

        step.received(requestID: "r1", labels: [tea, shops], error: nil)
        XCTAssertEqual(step.phase, .choosing)
        XCTAssertEqual(step.chosen, ["tea", "tea-shops"])
        XCTAssertEqual(step.suggestions.map(\.existing), [true, false])
        XCTAssertTrue(step.canApply)

        step.applyStarted()
        XCTAssertEqual(step.phase, .applying)
        step.remove("tea")
        XCTAssertEqual(step.chosen, ["tea", "tea-shops"], "no edits while applying")
        step.applySucceeded(labels: ["tea", "tea-shops"])
        XCTAssertEqual(step.phase, .applied)
        XCTAssertFalse(step.isOpen)
    }

    func testOwnLabelsWhileWaitingAndRemoval() {
        var step = LabelStep(requestID: "r1", title: "Note", suggesting: true)
        XCTAssertTrue(step.add("My Label"))
        XCTAssertFalse(step.add("123"))
        XCTAssertEqual(step.chosen, ["my-label"])
        XCTAssertTrue(step.canApply, "own labels can be applied before suggestions land")
        step.received(requestID: "r1", labels: [tea], error: nil)
        XCTAssertEqual(step.chosen, ["my-label", "tea"])
        step.remove("tea")
        XCTAssertEqual(step.chosen, ["my-label"])
        XCTAssertEqual(step.chips.map(\.name), ["tea", "my-label"], "an unchosen suggestion stays visible")
        step.toggle("tea")
        XCTAssertEqual(step.chosen, ["my-label", "tea"])
        step.remove("my-label")
        XCTAssertEqual(step.chips.map(\.name), ["tea"], "a removed own label disappears")
    }

    func testEmptyChoiceCannotApply() {
        var step = LabelStep(requestID: "r1", title: "Note", suggesting: true)
        step.received(requestID: "r1", labels: [tea], error: nil)
        step.remove("tea")
        XCTAssertFalse(step.canApply, "Apply with nothing chosen would confirm 'no labels'; Skip is the way out")
        step.applyStarted()
        XCTAssertEqual(step.phase, .choosing)
    }

    func testSuggestionErrorFallsBackToManual() {
        var step = LabelStep(requestID: "r1", title: "Note", suggesting: true)
        step.received(requestID: "r1", labels: [], error: "OpenRouter: API key missing.")
        XCTAssertEqual(step.phase, .choosing)
        XCTAssertEqual(step.suggestError, "OpenRouter: API key missing.")
        XCTAssertTrue(step.add("tea"))
        XCTAssertTrue(step.canApply)
    }

    func testSkip() {
        var step = LabelStep(requestID: "r1", title: "Note", suggesting: true)
        step.skip()
        XCTAssertEqual(step.phase, .skipped)
        step.received(requestID: "r1", labels: [tea], error: nil)
        XCTAssertEqual(step.phase, .skipped, "late suggestions do not reopen a skipped step")
    }

    func testApplyFailureExplainsBatchClaim() {
        var step = LabelStep(requestID: "r1", title: "Note", suggesting: false)
        XCTAssertEqual(step.phase, .choosing)
        step.add("tea")
        step.applyStarted()
        step.applyFailed(CoreClientError.api(status: 409, code: "invalid_state", message: "claimed"))
        XCTAssertEqual(step.phase, .choosing)
        XCTAssertEqual(step.applyError, "The batch already took this note, so label it from Labels instead.")
    }
}

final class ComposeDraftTests: XCTestCase {
    func testSummaryAndRequest() {
        var d = ComposeDraft()
        XCTAssertNotNil(d.blocker)
        d.text = "Gooseneck kettle presets"
        d.source = "in-person"
        d.sourceRef = "  #tea-club  "
        d.images = [DraftImage(url: URL(fileURLWithPath: "/tmp/a.png"), mode: .extract),
                    DraftImage(url: URL(fileURLWithPath: "/tmp/b.jpg"))]
        XCTAssertNil(d.blocker)
        XCTAssertEqual(d.summary, "One note · 1 image attached · 1 image read as text.")
        let r = d.request(suggest: true, vaultPath: "/v")
        XCTAssertEqual(r.title, "Gooseneck kettle presets", "an untitled note takes its first line")
        XCTAssertEqual(r.sourceRef, "#tea-club")
        XCTAssertEqual(r.suggest, .background)
        XCTAssertEqual(r.origin, .app)
        XCTAssertEqual(r.images?.map(\.mode), [.extract, .keep])
        XCTAssertNil(r.labels, "labels are never sent with the note from the app")
        XCTAssertEqual(d.request(suggest: false, vaultPath: nil).suggest, AddNoteRequest.Suggest.none)
    }
}

final class SettingsEditTests: XCTestCase {
    func testSourcesStartFromTheDefaultTaxonomy() {
        var s = Settings()
        XCTAssertNil(s.sourceTaxonomy)
        SettingsEdits.addSource("Discord", toGroup: "discussion", in: &s)
        let groups = SettingsEdits.taxonomy(s)
        XCTAssertEqual(groups.map(\.id), ["discussion", "reference", "personal"])
        XCTAssertEqual(groups[0].sources.last?.id, "discord")
        SettingsEdits.addGroup("Work", in: &s)
        SettingsEdits.addSource("Slack", toGroup: "work", in: &s)
        XCTAssertEqual(SettingsEdits.taxonomy(s).last?.sources.map(\.id), ["slack-2"], "ids stay unique")
        let patch = Settings.patch(from: Settings(), to: s)
        XCTAssertEqual(Set(patch.keys), ["sourceTaxonomy"])
    }

    func testClearingAShortcutSendsTheWholeObjectWithoutIt() {
        var old = Settings()
        old.shortcuts = DTO.shortcuts(ask: "ctrl+opt+space", addNote: "ctrl+opt+n")
        var new = old
        SettingsEdits.setShortcut(.ask, nil, in: &new)
        let patch = Settings.patch(from: old, to: new)
        // The core replaces top-level keys (shallow merge), so the omitted key is cleared.
        XCTAssertEqual(patch, ["shortcuts": .object(["addNote": .string("ctrl+opt+n")])])
        SettingsEdits.setShortcut(.addNote, KeyShortcut("cmd+shift+k"), in: &new)
        XCTAssertEqual(new.shortcuts?.addNote, "shift+cmd+k")
    }

    func testLabelingAndAskPreferencesKeepTheOtherField() {
        var s = Settings()
        XCTAssertTrue(SettingsEdits.autoLabelQueueFolder(s))
        SettingsEdits.setLabeling(&s, cliFallbackToAI: false)
        XCTAssertEqual(Settings.patch(from: Settings(), to: s), ["labeling": .object(["cliFallbackToAI": .bool(false)])])
        SettingsEdits.setLabeling(&s, autoLabelQueueFolder: false)
        XCTAssertEqual(s.labeling?.cliFallbackToAI, false)
        XCTAssertEqual(s.labeling?.autoLabelQueueFolder, false)

        SettingsEdits.setAsk(&s) { $0.historyDays = 3 }
        SettingsEdits.setAsk(&s) { $0.labelMatch = .all }
        XCTAssertEqual(Settings.patch(from: Settings(), to: s)["askPreferences"],
                       .object(["historyDays": .number(3), "labelMatch": .string("all")]))
        XCTAssertEqual(SettingsEdits.historyDays(Settings()), 10)
    }

    func testTaskDefaultsAndEffortReset() throws {
        var s = Settings()
        XCTAssertEqual(SettingsEdits.selection(.labelSuggest, settings: s), ModelSelection(runnerID: "claude-code", model: "haiku", effort: "low"))
        SettingsEdits.setTaskEffort(.labelSuggest, effort: nil, in: &s)
        XCTAssertEqual(Settings.patch(from: Settings(), to: s)["taskDefaults"],
                       .object(["labelSuggest": .object(["runnerID": .string("claude-code"), "model": .string("haiku")])]),
                       "Default effort is sent by leaving effort out of the selection")
        let openrouter: RunnerInfo = try XCTUnwrap(DTO.make(.object([
            "id": .string("openrouter"), "displayName": .string("OpenRouter"), "defaultModel": .string("google/gemini-2.5-flash"),
            "tasks": .array([.string("labelSuggest")]), "effortLevels": .array([]),
        ])))
        SettingsEdits.setTaskEffort(.labelSuggest, effort: "low", in: &s)
        SettingsEdits.setTaskRunner(.labelSuggest, runner: openrouter, in: &s)
        XCTAssertEqual(s.taskDefaults["labelSuggest"], ModelSelection(runnerID: "openrouter", model: "google/gemini-2.5-flash"))
    }

    func testRunnerTogglesAndOptions() {
        var s = Settings()
        SettingsEdits.setRunner("openai", enabled: true, in: &s)
        XCTAssertEqual(s.enabledRunners, ["claude-code", "openai"])
        SettingsEdits.setRunner("openai", enabled: false, in: &s)
        XCTAssertEqual(s.enabledRunners, ["claude-code"])
        SettingsEdits.setRunnerOption("openai", "baseURL", " https://example.test/v1 ", in: &s)
        XCTAssertEqual(s.runnerOptions, ["openai": ["baseURL": "https://example.test/v1"]])
        let before = s
        SettingsEdits.setRunnerOption("openai", "baseURL", "", in: &s)
        XCTAssertEqual(Settings.patch(from: before, to: s), ["runnerOptions": .object([:])])
    }

    func testObsidianURL() throws {
        let url = try XCTUnwrap(AppModel.obsidianURL(vaultPath: "/Users/me/Work notes", page: "wiki/a b.md"))
        XCTAssertEqual(url.absoluteString, "obsidian://open?vault=Work%20notes&file=wiki/a%20b.md")
    }
}
