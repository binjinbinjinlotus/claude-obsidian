import Foundation
import DistillKit

/// Builds DistillKit values that have no public memberwise init (fixtures),
/// through their tolerant decoders.
enum DTO {
    static func make<T: Decodable>(_ json: JSONValue) -> T? {
        guard let data = try? JSONEncoder.core.encode(json) else { return nil }
        return try? JSONDecoder.core.decode(T.self, from: data)
    }
}

/// Edits for the Settings sections added in v2. Every edit changes one
/// top-level key of `Settings`; `Settings.patch` then sends that whole key and
/// the core replaces it (a shallow merge, `engine/index.ts` updateSettings),
/// so clearing a nested value means sending the object without it.
enum SettingsEdits {
    // MARK: Sources

    /// `DEFAULT_SOURCE_TAXONOMY` in contracts.ts.
    static let defaultTaxonomy: [SourceGroup] = SourceGroup.defaultTaxonomy

    static func taxonomy(_ s: Settings) -> [SourceGroup] { s.sourceTaxonomy ?? defaultTaxonomy }

    /// "GitHub review" → "github-review" (unique within `taken`).
    static func slug(_ label: String, taken: Set<String>) -> String {
        let base = LabelName.normalize(label.replacingOccurrences(of: "/", with: " ")) ?? "source"
        var id = base, n = 2
        while taken.contains(id) { id = "\(base)-\(n)"; n += 1 }
        return id
    }

    private static func allSourceIDs(_ groups: [SourceGroup]) -> Set<String> {
        Set(groups.flatMap { $0.sources.map(\.id) } + groups.map(\.id))
    }

    static func addSource(_ label: String, toGroup groupID: String, in s: inout Settings) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var groups = taxonomy(s)
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].sources.append(SourceDefinition(id: slug(trimmed, taken: allSourceIDs(groups)), label: trimmed))
        s.sourceTaxonomy = groups
    }

    static func removeSource(_ sourceID: String, fromGroup groupID: String, in s: inout Settings) {
        var groups = taxonomy(s)
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].sources.removeAll { $0.id == sourceID }
        s.sourceTaxonomy = groups
    }

    static func addGroup(_ label: String, in s: inout Settings) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var groups = taxonomy(s)
        groups.append(SourceGroup(id: slug(trimmed, taken: allSourceIDs(groups)), label: trimmed, sources: []))
        s.sourceTaxonomy = groups
    }

    static func renameGroup(_ groupID: String, to label: String, in s: inout Settings) {
        let trimmed = label.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        var groups = taxonomy(s)
        guard let i = groups.firstIndex(where: { $0.id == groupID }) else { return }
        groups[i].label = trimmed
        s.sourceTaxonomy = groups
    }

    static func removeGroup(_ groupID: String, in s: inout Settings) {
        var groups = taxonomy(s)
        groups.removeAll { $0.id == groupID }
        s.sourceTaxonomy = groups
    }

    // MARK: Labels / Ask preferences

    static func labelMatch(_ s: Settings) -> LabelMatch { s.askPreferences?.labelMatch ?? .any }
    static func includeUnconfirmed(_ s: Settings) -> Bool { s.askPreferences?.includeUnconfirmed ?? true }
    static func keepHistory(_ s: Settings) -> Bool { s.askPreferences?.keepHistory ?? true }
    static func historyDays(_ s: Settings) -> Int { s.askPreferences?.historyDays ?? 10 }
    static func autoLabelQueueFolder(_ s: Settings) -> Bool { s.labeling?.autoLabelQueueFolder ?? true }
    static func cliFallbackToAI(_ s: Settings) -> Bool { s.labeling?.cliFallbackToAI ?? true }

    static func setAsk(_ s: inout Settings, _ edit: (inout AskPreferences) -> Void) {
        var p = s.askPreferences ?? AskPreferences()
        edit(&p)
        s.askPreferences = p
    }

    static func setLabeling(_ s: inout Settings, autoLabelQueueFolder: Bool? = nil, cliFallbackToAI: Bool? = nil) {
        s.labeling = LabelingPreferences(autoLabelQueueFolder: autoLabelQueueFolder ?? s.labeling?.autoLabelQueueFolder,
                                  cliFallbackToAI: cliFallbackToAI ?? s.labeling?.cliFallbackToAI)
    }

    // MARK: Shortcuts

    static func shortcut(_ action: ShortcutAction, in s: Settings) -> KeyShortcut? {
        GlobalShortcuts.shortcuts(from: s.shortcuts)[action]
    }

    /// nil clears it (the key is left out, which the core reads as "off").
    static func setShortcut(_ action: ShortcutAction, _ shortcut: KeyShortcut?, in s: inout Settings) {
        var ask = s.shortcuts?.ask, note = s.shortcuts?.addNote
        switch action {
        case .ask: ask = shortcut?.stringValue
        case .addNote: note = shortcut?.stringValue
        }
        s.shortcuts = ShortcutSettings(ask: ask, addNote: note)
    }

    // MARK: Runners

    static func setRunner(_ id: String, enabled: Bool, in s: inout Settings) {
        var list = s.enabledRunners.filter { $0 != id }
        if enabled { list.append(id) }
        s.enabledRunners = list
    }

    /// Empty value removes the option.
    static func setRunnerOption(_ runnerID: String, _ name: String, _ value: String, in s: inout Settings) {
        var all = s.runnerOptions ?? [:]
        var options = all[runnerID] ?? [:]
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        options[name] = trimmed.isEmpty ? nil : trimmed
        all[runnerID] = options.isEmpty ? nil : options
        s.runnerOptions = all
    }

    /// Non-secret options shown in a runner's Set up sheet (`runnerOptions.<id>`).
    static func optionFields(for runnerID: String) -> [(name: String, label: String, placeholder: String)] {
        switch runnerID {
        case "codex": return [("path", "codex binary", "~/.local/bin/codex")]
        case "openai": return [("baseURL", "Base URL", "https://api.openai.com/v1")]
        case "openrouter": return [("baseURL", "Base URL", "https://openrouter.ai/api/v1")]
        case "ai-sdk": return [("packageDir", "Package folder (npm i ai @ai-sdk/openai)", "~/ai-sdk"),
                               ("provider", "Provider", "openai"),
                               ("baseURL", "Base URL", "optional")]
        default: return []
        }
    }

    // MARK: Task defaults

    /// What a task uses when `taskDefaults` has no entry (core `defaultSelection`).
    static func fallbackSelection(_ task: AITask, settings: Settings) -> ModelSelection {
        switch task {
        case .ingest, .ask: return ModelSelection(runnerID: "claude-code", model: settings.model)
        case .labelSuggest, .imageText: return ModelSelection(runnerID: "claude-code", model: "haiku", effort: "low")
        case .actionFind: return ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "medium")
        case .actionDraft, .actionImprove: return ModelSelection(runnerID: "claude-code", model: "sonnet")
        }
    }

    static func selection(_ task: AITask, settings: Settings) -> ModelSelection {
        settings.taskDefaults[task.rawValue] ?? fallbackSelection(task, settings: settings)
    }

    /// Changing the runner resets the model to that runner's default and drops
    /// an effort it does not offer.
    static func withRunner(_ selection: ModelSelection, _ runner: RunnerInfo) -> ModelSelection {
        var sel = selection
        guard sel.runnerID != runner.id else { return sel }
        sel.runnerID = runner.id
        sel.model = runner.defaultModel.isEmpty ? (runner.models.first?.id ?? sel.model) : runner.defaultModel
        if let effort = sel.effort, !runner.effortLevels.contains(effort) { sel.effort = nil }
        return sel
    }

    static func setTaskRunner(_ task: AITask, runner: RunnerInfo, in s: inout Settings) {
        let sel = selection(task, settings: s)
        guard sel.runnerID != runner.id else { return }
        s.taskDefaults[task.rawValue] = withRunner(sel, runner)
    }

    static func setTaskModel(_ task: AITask, model: String, in s: inout Settings) {
        var sel = selection(task, settings: s)
        sel.model = model
        s.taskDefaults[task.rawValue] = sel
    }

    /// nil = the runner's own default effort.
    static func setTaskEffort(_ task: AITask, effort: String?, in s: inout Settings) {
        var sel = selection(task, settings: s)
        sel.effort = effort
        s.taskDefaults[task.rawValue] = sel
    }

    /// Runners that are on and can do `task`; the current one stays listed.
    /// Action tasks need only structured output, so a runner from a core that
    /// doesn't list them yet still qualifies by its capabilities.
    static func candidates(for task: AITask, runners: [RunnerInfo], settings: Settings, current: String? = nil) -> [RunnerInfo] {
        let current = current ?? selection(task, settings: settings).runnerID
        let isAction = task == .actionFind || task == .actionDraft || task == .actionImprove
        return runners.filter { r in
            (r.enabled || settings.enabledRunners.contains(r.id) || r.id == current)
                && (r.tasks.contains(task) || (isAction && r.capabilities.contains("structuredOutput")))
        }
    }

    // MARK: Actions (actionPreferences)

    static func actions(_ s: Settings) -> ActionPreferences { s.actionPreferences ?? ActionPreferences() }

    static func setActions(_ s: inout Settings, _ edit: (inout ActionPreferences) -> Void) {
        var p = actions(s)
        edit(&p)
        s.actionPreferences = p
    }

    /// The finding model as the core reads it: findSelection, then taskDefaults.actionFind, then Sonnet.
    static func findSelection(_ s: Settings) -> ModelSelection {
        actions(s).findSelection ?? selection(.actionFind, settings: s)
    }

    static func draftSelection(_ typeID: String, _ s: Settings) -> ModelSelection {
        actions(s).draftSelection(typeID) ?? selection(.actionDraft, settings: s)
    }

    static func improveSelection(_ typeID: String, _ s: Settings) -> ModelSelection {
        actions(s).improveSelection(typeID) ?? selection(.actionImprove, settings: s)
    }

    static func typeEnabled(_ t: SettingsActionType, _ s: Settings) -> Bool {
        if t.reserved { return false }
        if t.id == "todo" { return true }
        return actions(s).enabled(t.id) ?? t.enabled
    }

    static func draftWhen(_ t: SettingsActionType, _ s: Settings) -> String { actions(s).draftWhen(t.id) ?? t.draftWhen }
    static func improveAfterEdit(_ t: SettingsActionType, _ s: Settings) -> Bool { actions(s).improveAfterEdit(t.id) ?? t.improveAfterEdit }

    /// The prompt in use: the user's, or the type's default.
    static func prompt(_ t: SettingsActionType, improve: Bool, _ s: Settings) -> String {
        (improve ? actions(s).improvePrompt(t.id) : actions(s).draftPrompt(t.id)) ?? ((improve ? t.defaultImprovePrompt : t.defaultDraftPrompt) ?? "")
    }

    static func promptEdited(_ t: SettingsActionType, improve: Bool, _ s: Settings) -> Bool {
        let stored = improve ? actions(s).improvePrompt(t.id) : actions(s).draftPrompt(t.id)
        return stored != nil && stored != ((improve ? t.defaultImprovePrompt : t.defaultDraftPrompt) ?? "")
    }

    /// Text equal to the default (or nil) removes the key, so the core uses its built-in prompt.
    static func setPrompt(_ t: SettingsActionType, improve: Bool, text: String?, in s: inout Settings) {
        let defaultText = (improve ? t.defaultImprovePrompt : t.defaultDraftPrompt) ?? ""
        let value: JSONValue? = text.flatMap { $0 == defaultText ? nil : .string($0) }
        setActions(&s) { $0.setTypeValue(t.id, improve ? "improvePrompt" : "draftPrompt", value) }
    }

    static func taskTitle(_ task: AITask) -> (String, String) {
        switch task {
        case .ingest: return ("Adding notes", "Ingest batches into the vault")
        case .ask: return ("Ask a question", "Answers from your vault")
        case .labelSuggest: return ("Label suggestions", "After a note is queued")
        case .imageText: return ("Text from images", "When you click Extract content on an image")
        case .actionFind: return ("Finding actions", "After a batch is applied, and on Ask answers")
        case .actionDraft: return ("Action drafts", "Writing drafts, set per type in Actions")
        case .actionImprove: return ("Improving drafts", "After you edit, set per type in Actions")
        }
    }

    static func effortTitle(_ effort: String?) -> String {
        guard let effort, !effort.isEmpty else { return "Default" }
        return effort == "xhigh" ? "Extra high" : effort.prefix(1).uppercased() + effort.dropFirst()
    }

    static func modelTitle(_ model: String, runner: RunnerInfo?) -> String {
        if let option = runner?.models.first(where: { $0.id == model }) { return option.label }
        let short = ModelChoice.shortName(model)
        return short == model ? model : short
    }
}
