import Foundation
import DistillKit

// The Settings window's sections and its search index (canvas: SettingsNav).
// The index is data: a new setting becomes searchable by adding one entry to
// `SettingsIndex.fixed` (or, for action types, by the core listing the type).

enum SettingsGroup: String, CaseIterable {
    case general, ai, actions

    var title: String {
        switch self {
        case .general: return "General"
        case .ai: return "AI"
        case .actions: return "Actions and connections"
        }
    }

    var navTitle: String {
        switch self {
        case .general: return "GENERAL"
        case .ai: return "AI"
        case .actions: return "ACTIONS"
        }
    }

    var sections: [SettingsSection] { SettingsSection.allCases.filter { $0.group == self } }
}

/// One entry in the section list. The raw value is the id other screens open
/// (`AppModel.openSettings(section:)`, notification "distill.openSettingsSection").
enum SettingsSection: String, CaseIterable, Identifiable {
    case vaults, batching, sources, labels
    case askHistory = "ask-history"
    case shortcuts, runners, models, actions, todo, connections

    var id: String { rawValue }

    /// The page Advanced (model, paths, extra allowed tools) sits at the end of:
    /// AI runners, since most of it configures how the Claude Code runner and
    /// the core are started. Its search entry points here too.
    static let advancedHome = SettingsSection.runners

    var group: SettingsGroup {
        switch self {
        case .vaults, .batching, .sources, .labels, .askHistory, .shortcuts: return .general
        case .runners, .models: return .ai
        case .actions, .todo, .connections: return .actions
        }
    }

    var title: String {
        switch self {
        case .vaults: return "Vaults"
        case .batching: return "Batching"
        case .sources: return "Sources"
        case .labels: return "Labels"
        case .askHistory: return "Ask history"
        case .shortcuts: return "Keyboard shortcuts"
        case .runners: return "AI runners"
        case .models: return "Models for tasks"
        case .actions: return "Actions"
        case .todo: return "To-do defaults"
        case .connections: return "Connections"
        }
    }

    var systemImage: String {
        switch self {
        case .vaults: return "folder"
        case .batching: return "clock"
        case .sources: return "tray.full"
        case .labels: return "tag"
        case .askHistory: return "bubble.left"
        case .shortcuts: return "command"
        case .runners: return "cpu"
        case .models: return "slider.horizontal.3"
        case .actions: return "bolt"
        case .todo: return "checklist"
        case .connections: return "link"
        }
    }

    /// The line under the section's heading.
    var note: String {
        switch self {
        case .vaults: return "The vault Distill adds notes to, and where each one’s queue lives."
        case .batching: return "When queued notes go into the vault."
        case .sources: return "Where a note came from. Picking a group in Ask includes everything inside it."
        case .labels: return "Read from your vault’s tags. Rename or merge to keep suggestions tidy."
        case .askHistory: return "Past questions and answers, listed in History. Stored on this Mac only."
        case .shortcuts: return "Off until you record one. They work from any app."
        case .runners: return "Turn on the AI tools Distill may use."
        case .models: return "Runner, model and effort for each job. Ask can still change them per question."
        case .actions: return "Distill finds actions in processed notes and Ask answers. Each action type can do some for you; the rest become to-dos."
        case .todo: return "How To do opens. Changes you make on the To do screen are remembered there."
        case .connections: return "Sign-in happens in your browser. Distill keeps the access in your Keychain and never sees your password."
        }
    }
}

/// Where a nav selection or a search result leads.
struct SettingsTarget: Hashable {
    var section: SettingsSection
    /// An action type's own page (Actions › Slack message).
    var actionType: String?

    init(_ section: SettingsSection, actionType: String? = nil) {
        self.section = section
        self.actionType = actionType
    }

    /// "connections", "models", "actions/jira" (unknown ids → nil).
    init?(id: String) {
        let parts = id.split(separator: "/", maxSplits: 1).map(String.init)
        guard let first = parts.first, let section = SettingsSection(rawValue: first) else { return nil }
        self.init(section, actionType: parts.count > 1 && section == .actions ? parts[1] : nil)
    }

    var id: String { actionType.map { "\(section.rawValue)/\($0)" } ?? section.rawValue }
}

/// One searchable setting.
struct SettingsEntry: Hashable, Identifiable {
    var target: SettingsTarget
    var title: String
    var note: String
    /// Extra words that find it but are not shown.
    var keywords: String = ""
    /// The heading results are grouped under ("Actions › Slack message").
    var crumb: String

    var id: String { target.id + "|" + title }
}

enum SettingsIndex {
    private static func e(_ s: SettingsSection, _ title: String, _ note: String, _ keywords: String = "") -> SettingsEntry {
        SettingsEntry(target: SettingsTarget(s), title: title, note: note, keywords: keywords, crumb: s.title)
    }

    /// Every fixed setting, in window order.
    static let fixed: [SettingsEntry] = [
        e(.vaults, "Vaults", "Add a vault, pick the active one", "vault folder obsidian"),
        e(.vaults, "Queue folder", "Where each vault’s queue lives; use the vault’s inbox", "inbox"),
        e(.batching, "Batch every", "Automatic: runs on this schedule. Off: only when you press Process now.", "schedule interval automatic minutes hours days"),
        e(.batching, "Wait before picking up a file", "A file must stay unchanged this long before a batch takes it", "settle seconds"),
        e(.batching, "Check the queue folder for changes", "Finds files and folders added outside Distill (Finder, sync apps)", "queue check scan refresh sync interval every minutes off folder"),
        e(.sources, "Sources", "Where a note came from, in groups", "source group slack meeting"),
        e(.labels, "Labels", "Read from your vault’s tags", "tags"),
        e(.labels, "Suggest labels after a note is queued", "Uses the Label suggestions model"),
        e(.labels, "When Ask is limited to several labels, use notes with", "Any label or all labels"),
        e(.labels, "Include notes whose labels aren’t confirmed yet", "AI-applied labels still in Labels → To review", "unconfirmed"),
        e(.labels, "In Distill: ask me to confirm", "Notes written here show label suggestions after Add to queue"),
        e(.labels, "Queue folder: label automatically", "Files dropped straight into the folder get AI labels"),
        e(.labels, "CLI: use AI labels if none are sent back", "If no labels arrive before the batch runs"),
        e(.askHistory, "Keep Ask history", "Chats are deleted after a number of days; pinned chats are kept", "retention days"),
        e(.askHistory, "Clear now", "Delete every Ask chat that is not pinned"),
        e(.shortcuts, "Ask a question shortcut", "Opens the quick-ask window", "keyboard hotkey"),
        e(.shortcuts, "Add a note shortcut", "Opens the quick-note window", "keyboard hotkey"),
        e(.runners, "AI runners", "Claude Code, Codex, OpenRouter, OpenAI, Vercel AI SDK", "api key keychain"),
        e(.advancedHome, "Advanced", "Specific model, claude CLI, python3, node, product root, extra allowed tools", "path"),
        e(.models, "Adding notes", "Model and effort for batches into wiki pages", "ingest"),
        e(.models, "Ask a question", "Model and effort; the system prompt is fixed"),
        e(.models, "Label suggestions", "Model and effort after a note is queued"),
        e(.models, "Text from images", "Model and effort when you click Extract content", "image ocr"),
        e(.models, "Finding actions", "Model and effort after a batch is applied, and on Ask answers"),
        e(.actions, "Where actions come from", "Notes and Ask answers: detect to-dos and action types", "detect"),
        e(.actions, "Ask me to confirm before adding", "Found items wait in “To confirm”"),
        e(.actions, "Model for finding actions", "Also listed in Models for tasks"),
        e(.todo, "Default group", "How To do groups when it opens", "due date note"),
        e(.todo, "Default sort", "Inside each group", "order due date priority"),
        e(.todo, "Keep action history", "Removed, completed, sent and done items", "retention days forever"),
        e(.todo, "Remind me of overdue to-dos", "One macOS notification each morning", "notification"),
        e(.connections, "Atlassian", "Jira and Confluence: sign in with an API token", "jira confluence token sign in"),
        e(.connections, "Slack", "Not needed yet: Copy works without connecting"),
    ]

    /// Entries for each action type's page (types that aren't reserved).
    static func typeEntries(_ types: [SettingsActionType]) -> [SettingsEntry] {
        types.filter { !$0.reserved && $0.id != "todo" }.flatMap { t -> [SettingsEntry] in
            let target = SettingsTarget(.actions, actionType: t.id)
            let crumb = "Actions › \(t.label)"
            let thing = t.label
            var list = [
                SettingsEntry(target: target, title: "Create prompt", note: "How Distill drafts a \(thing)", keywords: "draft write", crumb: crumb),
                SettingsEntry(target: target, title: "Improve prompt", note: "Runs after you edit a \(thing)", keywords: "grammar edit", crumb: crumb),
                SettingsEntry(target: target, title: "When to write the draft", note: "When a note is processed, or only when you ask", crumb: crumb),
                SettingsEntry(target: target, title: "Models", note: "Writing and improving after an edit", keywords: "sonnet", crumb: crumb),
            ]
            for field in t.defaultFields {
                list.append(SettingsEntry(target: target, title: field.title, note: "Used for new \(t.pluralLabel)", crumb: crumb))
            }
            return list
        }
    }

    static func all(types: [SettingsActionType]) -> [SettingsEntry] {
        fixed + typeEntries(types)
    }

    /// Lowercased words of a query.
    static func words(_ query: String) -> [String] {
        query.lowercased().split(whereSeparator: { $0.isWhitespace }).map(String.init)
    }

    /// Entries where every word appears in the title, note or keywords.
    static func search(_ query: String, in entries: [SettingsEntry]) -> [SettingsEntry] {
        let w = words(query)
        guard !w.isEmpty else { return [] }
        return entries.filter { entry in
            let hay = (entry.title + " " + entry.note + " " + entry.keywords).lowercased()
            return w.allSatisfy { hay.contains($0) }
        }
    }

    static func counts(_ results: [SettingsEntry]) -> [SettingsSection: Int] {
        results.reduce(into: [:]) { $0[$1.target.section, default: 0] += 1 }
    }

    /// Ranges of `text` matching any query word, for highlighting.
    static func matches(_ text: String, _ query: String) -> [Range<String.Index>] {
        var out: [Range<String.Index>] = []
        for word in words(query) {
            var from = text.startIndex
            while let r = text.range(of: word, options: [.caseInsensitive, .diacriticInsensitive], range: from..<text.endIndex) {
                out.append(r)
                from = r.upperBound
            }
        }
        return out
    }
}

// MARK: - Action types (Settings' own view of GET /v1/action-types)

/// What Settings needs from an `ActionTypeInfo`. Decoded leniently from the
/// core's JSON; `builtIn` stands in when the core can't list types.
/// Settings uses the shared registry DTO (DistillKit `ActionTypeInfo`).
typealias SettingsActionType = ActionTypeInfo

extension ActionTypeInfo {
    typealias Handler = ActionHandlerInfo
    struct Field: Hashable { var key: String; var title: String }

    var fieldKeys: [String] { fields.map(\.key) }

    /// Field defaults Settings offers (Jira project and issue type, Confluence space and parent).
    var defaultFields: [Field] {
        let known: [(String, String)] = [("project", "Default project"), ("issueType", "Issue type"),
                                         ("space", "Default space"), ("parent", "Parent page")]
        return known.filter { fieldKeys.contains($0.0) }.map { Field(key: $0.0, title: $0.1) }
    }

    /// Items are created in another app only on your click (Jira, Confluence).
    var createsOnClick: Bool { handlers.contains { $0.id == "create" } }
    /// "Send in Slack": listed but not available yet.
    var laterHandler: Handler? { handlers.first { $0.id == "send" && !$0.available } }
    /// The app the item is created in ("Jira", "Confluence").
    var appName: String { label.split(separator: " ").first.map(String.init) ?? label }

    /// One registry entry from the core's JSON (nil without an id).
    init?(json: JSONValue) {
        guard let id = json["id"]?.stringValue, !id.isEmpty,
              let data = try? JSONEncoder.core.encode(json),
              let t = try? JSONDecoder.core.decode(ActionTypeInfo.self, from: data) else { return nil }
        self = t
    }

    init(settingsID id: String, label: String, pluralLabel: String, enabled: Bool = true, reserved: Bool = false,
         connectionID: String? = nil, improveAfterEdit: Bool = true, defaultDraftPrompt: String = "",
         defaultImprovePrompt: String = "", placeholders: [String] = [], handlers: [Handler] = [], fieldKeys: [String] = []) {
        self.init(id: id, label: label, pluralLabel: pluralLabel, enabled: enabled, reserved: reserved,
                  fields: fieldKeys.map { ActionFieldSpec(key: $0, label: $0) }, handlers: handlers, connectionID: connectionID,
                  improveAfterEdit: improveAfterEdit, defaultDraftPrompt: defaultDraftPrompt, defaultImprovePrompt: defaultImprovePrompt,
                  placeholders: placeholders)
    }

    /// The registry's types, for a core that can't list them yet (and snapshots).
    static let builtIn: [SettingsActionType] = [
        SettingsActionType(settingsID: "todo", label: "To do", pluralLabel: "To-dos", improveAfterEdit: false),
        SettingsActionType(
            settingsID: "slack", label: "Slack message", pluralLabel: "Slack messages",
            defaultDraftPrompt: "Write a short Slack message to {recipient} that does what the note asks.\nUse only facts from {excerpt} and {note_title}. Don’t invent times, names or numbers.\nFriendly and direct, under 80 words. Use Slack formatting: *bold*, bullet lists, @mentions.\nReturn only the message.",
            defaultImprovePrompt: "The user edited this Slack message. Fix grammar, spelling and punctuation only.\nKeep their words, tone, length and formatting. Don’t add or remove content.\nReturn only the message.",
            placeholders: ["{recipient}", "{excerpt}", "{note_title}", "{title}", "{why}"],
            handlers: [Handler(id: "copy", label: "Copy", available: true), Handler(id: "markSent", label: "Mark as sent", available: true),
                       Handler(id: "send", label: "Send in Slack", available: false, reason: "Copy only for now")],
            fieldKeys: ["to"]),
        SettingsActionType(
            settingsID: "jira", label: "Jira ticket", pluralLabel: "Jira tickets", connectionID: "atlassian",
            defaultDraftPrompt: "Draft a Jira ticket for project {project} from {excerpt}.\nSummary: one line, starts with a verb. Description sections: Context, Steps, Acceptance criteria.\nReturn the summary on the first line, then the description.",
            defaultImprovePrompt: "The user edited this Jira ticket. Fix grammar, spelling and punctuation only.\nKeep their words, structure and fields. Don’t add or remove content.\nReturn only the ticket.",
            placeholders: ["{project}", "{issue_type}", "{excerpt}", "{note_title}", "{labels}", "{title}"],
            handlers: [Handler(id: "create", label: "Create in Jira", available: true), Handler(id: "refresh", label: "Refresh", available: true)],
            fieldKeys: ["project", "issueType", "priority"]),
        SettingsActionType(
            settingsID: "confluence", label: "Confluence page", pluralLabel: "Confluence pages", connectionID: "atlassian",
            defaultDraftPrompt: "Draft a Confluence page for space {space} from {excerpt}.\nStart with a one-paragraph summary, then sections with headings. Link {note_title} as the source.\nReturn the title on the first line, then the page.",
            defaultImprovePrompt: "The user edited this Confluence page. Fix grammar, spelling and punctuation only.\nKeep their words, headings and structure. Don’t add or remove content.\nReturn only the page.",
            placeholders: ["{space}", "{parent}", "{excerpt}", "{note_title}", "{title}"],
            handlers: [Handler(id: "create", label: "Create in Confluence", available: true), Handler(id: "refresh", label: "Refresh", available: true)],
            fieldKeys: ["space", "parent"]),
        SettingsActionType(settingsID: "email", label: "Email", pluralLabel: "Emails", enabled: false, reserved: true),
    ]
}
