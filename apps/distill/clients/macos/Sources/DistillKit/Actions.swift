import Foundation

// Actions (contracts.ts → "Actions (actions.json)"): to-dos and the action
// types Distill can do for you (Slack message, Jira ticket, Confluence page, …).
// Types and handlers are registry data in the core, so every type id, status
// and handler id is kept as a raw string: a newer core's values decode and
// render generically from `ActionTypeInfo` instead of failing.

/// `ActionStatus`. A struct, not an enum, so unknown statuses survive.
public struct ActionStatus: RawRepresentable, Codable, Hashable, Sendable, CustomStringConvertible {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public init(_ raw: String) { rawValue = raw }

    public static let pending = ActionStatus("pending")
    public static let open = ActionStatus("open")
    public static let drafting = ActionStatus("drafting")
    public static let ready = ActionStatus("ready")
    public static let creating = ActionStatus("creating")
    public static let created = ActionStatus("created")
    public static let done = ActionStatus("done")
    public static let sent = ActionStatus("sent")
    public static let removed = ActionStatus("removed")
    public static let dismissed = ActionStatus("dismissed")

    /// Statuses History → Actions lists.
    public static let history: [ActionStatus] = [.done, .sent, .removed]
    public var isHistory: Bool { Self.history.contains(self) }

    public var description: String { rawValue }

    public init(from decoder: Decoder) throws {
        rawValue = (try? decoder.singleValueContainer().decode(String.self)) ?? "open"
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.singleValueContainer()
        try c.encode(rawValue)
    }
}

/// `ActionSource`: where an item was found.
public enum ActionSource: Codable, Hashable, Sendable {
    case note(jobID: String?, notePath: String?, pageTitle: String?, quote: String?)
    /// `turnIndex`: which answer (absent on older cores). `gap`: the item restates the
    /// answer's gap, so the Gap callout is hidden.
    case ask(conversationID: String, question: String?, quote: String?, citedPaths: [String], turnIndex: Int?, gap: Bool)
    /// Added by you (`by` absent or "user").
    case manual
    /// Added by an agent through the CLI (`kind: manual, by: agent`).
    case agent
    /// A kind this build does not know.
    case other(kind: String)

    enum Keys: String, CodingKey { case kind, jobID, notePath, pageTitle, quote, conversationID, question, citedPaths, turnIndex, gap, by }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: Keys.self) else { self = .manual; return }
        switch c.lossy(String.self, .kind) ?? "manual" {
        case "note":
            self = .note(jobID: c.lossy(String.self, .jobID), notePath: c.lossy(String.self, .notePath),
                         pageTitle: c.lossy(String.self, .pageTitle), quote: c.lossy(String.self, .quote))
        case "ask":
            self = .ask(conversationID: c.lossy(String.self, .conversationID) ?? "", question: c.lossy(String.self, .question),
                        quote: c.lossy(String.self, .quote), citedPaths: c.lossyArray(String.self, .citedPaths),
                        turnIndex: c.lossyInt(.turnIndex), gap: c.lossy(Bool.self, .gap) ?? false)
        case "manual": self = c.lossy(String.self, .by) == "agent" ? .agent : .manual
        case let kind: self = .other(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .note(let jobID, let notePath, let pageTitle, let quote):
            try c.encode("note", forKey: .kind)
            try c.encodeIfPresent(jobID, forKey: .jobID)
            try c.encodeIfPresent(notePath, forKey: .notePath)
            try c.encodeIfPresent(pageTitle, forKey: .pageTitle)
            try c.encodeIfPresent(quote, forKey: .quote)
        case .ask(let conversationID, let question, let quote, let citedPaths, let turnIndex, let gap):
            try c.encode("ask", forKey: .kind)
            try c.encode(conversationID, forKey: .conversationID)
            try c.encodeIfPresent(question, forKey: .question)
            try c.encodeIfPresent(quote, forKey: .quote)
            if !citedPaths.isEmpty { try c.encode(citedPaths, forKey: .citedPaths) }
            try c.encodeIfPresent(turnIndex, forKey: .turnIndex)
            if gap { try c.encode(true, forKey: .gap) }
        case .manual:
            try c.encode("manual", forKey: .kind)
        case .agent:
            try c.encode("manual", forKey: .kind)
            try c.encode("agent", forKey: .by)
        case .other(let kind):
            try c.encode(kind, forKey: .kind)
        }
    }

    public var quote: String? {
        switch self {
        case .note(_, _, _, let q), .ask(_, _, let q, _, _, _): return q
        default: return nil
        }
    }

    public var conversationID: String? { if case .ask(let id, _, _, _, _, _) = self { return id }; return nil }
    public var jobID: String? { if case .note(let id, _, _, _) = self { return id }; return nil }
    public var isManual: Bool { if case .manual = self { return true }; return false }
}

public struct ActionError: Codable, Hashable, Sendable {
    /// not_connected / auth_expired / refused / unreachable / ai_failed / other (raw; unknown codes kept).
    public var code: String
    public var message: String
    public var field: String?

    public init(code: String, message: String, field: String? = nil) {
        self.code = code; self.message = message; self.field = field
    }

    enum CodingKeys: String, CodingKey { case code, message, field }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        code = c.lossy(String.self, .code) ?? "other"
        message = c.lossy(String.self, .message) ?? ""
        field = c.lossy(String.self, .field)
    }

    /// The fix is to sign in (not connected, or the sign-in expired).
    public var needsSignIn: Bool { code == "not_connected" || code == "auth_expired" }
}

public struct ActionEvent: Codable, Hashable, Sendable {
    public var at: Date
    /// found, confirmed, drafted, edited, improved, improve-undone, copied, sent-to:<type>, created, status, done, removed, restored …
    public var event: String
    public var detail: String?

    public init(at: Date, event: String, detail: String? = nil) {
        self.at = at; self.event = event; self.detail = detail
    }

    enum CodingKeys: String, CodingKey { case at, event, detail }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        at = c.lossyDate(.at) ?? .distantPast
        event = c.lossy(String.self, .event) ?? ""
        detail = c.lossy(String.self, .detail)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(CoreDate.format(at), forKey: .at)
        try c.encode(event, forKey: .event)
        try c.encodeIfPresent(detail, forKey: .detail)
    }
}

public struct ActionExternal: Codable, Hashable, Sendable {
    public var key: String?
    public var url: String?
    public var status: String?
    public var checkedAt: Date?

    public init(key: String? = nil, url: String? = nil, status: String? = nil, checkedAt: Date? = nil) {
        self.key = key; self.url = url; self.status = status; self.checkedAt = checkedAt
    }

    enum CodingKeys: String, CodingKey { case key, url, status, checkedAt }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = c.lossy(String.self, .key)
        url = c.lossy(String.self, .url)
        status = c.lossy(String.self, .status)
        checkedAt = c.lossyDate(.checkedAt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(key, forKey: .key)
        try c.encodeIfPresent(url, forKey: .url)
        try c.encodeIfPresent(status, forKey: .status)
        try c.encodeIfPresent(checkedAt.map(CoreDate.format), forKey: .checkedAt)
    }
}

public struct ActionItem: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var type: String
    public var status: ActionStatus
    public var title: String
    public var body: String?
    /// Type-specific fields (to, due, priority, person, project, issueType, space, parent, labels…). Nulls are dropped.
    public var fields: [String: String]
    public var why: String?
    /// What the action is about, 2–4 plain sentences (action-summary.md). Nil on older items until summarized.
    public var summary: String?
    public var source: ActionSource
    /// v11: the original's lines and the wiki refs, read from the same `source` object (action-context.md).
    public var context: ActionContextRefs = .none
    public var vaultPath: String?
    public var labels: [String]
    public var createdAt: Date
    public var updatedAt: Date
    public var draftModel: String?
    public var previousBody: String?
    public var external: ActionExternal?
    public var error: ActionError?
    public var fromActionID: String?
    public var events: [ActionEvent]
    /// Automations: this item's button runs, newest last (action-buttons.md).
    public var runs: [ActionButtonRun] = []
    /// The button run in progress, if any.
    public var activeRun: ActiveButtonRun?

    public init(id: String, type: String = "todo", status: ActionStatus = .open, title: String, body: String? = nil,
                fields: [String: String] = [:], why: String? = nil, source: ActionSource = .manual, vaultPath: String? = nil,
                labels: [String] = [], createdAt: Date = Date(), updatedAt: Date? = nil, draftModel: String? = nil,
                previousBody: String? = nil, external: ActionExternal? = nil, error: ActionError? = nil,
                fromActionID: String? = nil, events: [ActionEvent] = [], context: ActionContextRefs = .none,
                summary: String? = nil) {
        self.id = id; self.type = type; self.status = status; self.title = title; self.body = body; self.fields = fields
        self.why = why; self.source = source; self.vaultPath = vaultPath; self.labels = labels; self.createdAt = createdAt
        self.updatedAt = updatedAt ?? createdAt; self.draftModel = draftModel; self.previousBody = previousBody
        self.external = external; self.error = error; self.fromActionID = fromActionID; self.events = events
        self.context = context; self.summary = summary
    }

    enum CodingKeys: String, CodingKey {
        case id, type, status, title, body, fields, why, summary, source, vaultPath, labels, createdAt, updatedAt, draftModel
        case previousBody, external, error, fromActionID, events, runs, activeRun
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        type = c.lossy(String.self, .type) ?? "todo"
        status = c.lossy(ActionStatus.self, .status) ?? .open
        title = c.lossy(String.self, .title) ?? ""
        body = c.lossy(String.self, .body)
        fields = Self.decodeFields(c.lossy(JSONValue.self, .fields))
        why = c.lossy(String.self, .why)
        summary = c.lossy(String.self, .summary).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
        source = c.lossy(ActionSource.self, .source) ?? .manual
        context = c.lossy(ActionContextRefs.self, .source) ?? .none
        vaultPath = c.lossy(String.self, .vaultPath)
        labels = c.lossyArray(String.self, .labels)
        createdAt = c.lossyDate(.createdAt) ?? .distantPast
        updatedAt = c.lossyDate(.updatedAt) ?? createdAt
        draftModel = c.lossy(String.self, .draftModel)
        previousBody = c.lossy(String.self, .previousBody)
        external = c.lossy(ActionExternal.self, .external)
        error = c.lossy(ActionError.self, .error)
        fromActionID = c.lossy(String.self, .fromActionID)
        events = c.lossyArray(ActionEvent.self, .events)
        runs = c.lossyArray(ActionButtonRun.self, .runs)
        activeRun = c.lossy(ActiveButtonRun.self, .activeRun)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(id, forKey: .id)
        try c.encode(type, forKey: .type)
        try c.encode(status, forKey: .status)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(body, forKey: .body)
        try c.encode(fields, forKey: .fields)
        try c.encodeIfPresent(why, forKey: .why)
        try c.encodeIfPresent(summary, forKey: .summary)
        // The source's own keys and the context keys share one object.
        let sourceEncoder = c.superEncoder(forKey: .source)
        try source.encode(to: sourceEncoder)
        if !context.isEmpty { try context.encode(to: sourceEncoder) }
        try c.encodeIfPresent(vaultPath, forKey: .vaultPath)
        if !labels.isEmpty { try c.encode(labels, forKey: .labels) }
        try c.encode(CoreDate.format(createdAt), forKey: .createdAt)
        try c.encode(CoreDate.format(updatedAt), forKey: .updatedAt)
        try c.encodeIfPresent(draftModel, forKey: .draftModel)
        try c.encodeIfPresent(previousBody, forKey: .previousBody)
        try c.encodeIfPresent(external, forKey: .external)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(fromActionID, forKey: .fromActionID)
        try c.encode(events, forKey: .events)
        if !runs.isEmpty { try c.encode(runs, forKey: .runs) }
        try c.encodeIfPresent(activeRun, forKey: .activeRun)
    }

    /// Strings stay; numbers and bools become text; nulls and nested values are dropped.
    static func decodeFields(_ json: JSONValue?) -> [String: String] {
        guard case .object(let o)? = json else { return [:] }
        var out: [String: String] = [:]
        for (k, v) in o {
            switch v {
            case .string(let s): out[k] = s
            case .number(let n): out[k] = n.rounded() == n ? String(Int(n)) : String(n)
            case .bool(let b): out[k] = b ? "true" : "false"
            case .array(let a): let s = a.compactMap(\.stringValue); if !s.isEmpty { out[k] = s.joined(separator: ", ") }
            default: break
            }
        }
        return out
    }

    public func field(_ key: String) -> String? {
        guard let v = fields[key]?.trimmingCharacters(in: .whitespacesAndNewlines), !v.isEmpty else { return nil }
        return v
    }

    /// The time of the last event with this name.
    public func lastEvent(_ name: String) -> ActionEvent? { events.last { $0.event == name } }
}

public struct ActionFieldSpec: Codable, Hashable, Sendable {
    public var key: String
    public var label: String
    /// text | person | date | choice | markdown (raw).
    public var kind: String
    public var choices: [String]
    public var required: Bool

    public init(key: String, label: String, kind: String = "text", choices: [String] = [], required: Bool = false) {
        self.key = key; self.label = label; self.kind = kind; self.choices = choices; self.required = required
    }

    enum CodingKeys: String, CodingKey { case key, label, kind, choices, required }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        label = c.lossy(String.self, .label) ?? key
        kind = c.lossy(String.self, .kind) ?? "text"
        choices = c.lossyArray(String.self, .choices)
        required = c.lossy(Bool.self, .required) ?? false
    }
}

public struct ActionHandlerInfo: Codable, Hashable, Sendable {
    /// copy | markSent | create | complete | refresh | send …
    public var id: String
    public var label: String
    public var available: Bool
    public var reason: String?

    public init(id: String, label: String, available: Bool = true, reason: String? = nil) {
        self.id = id; self.label = label; self.available = available; self.reason = reason
    }

    enum CodingKeys: String, CodingKey { case id, label, available, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.lossy(String.self, .label) ?? id
        available = c.lossy(Bool.self, .available) ?? true
        reason = c.lossy(String.self, .reason)
    }
}

public struct ActionTypeInfo: Codable, Hashable, Identifiable, Sendable {
    public var id: String
    public var label: String
    public var pluralLabel: String
    public var enabled: Bool
    public var reserved: Bool
    public var fields: [ActionFieldSpec]
    public var handlers: [ActionHandlerInfo]
    public var connectionID: String?
    /// onFind | onRequest
    public var draftWhen: String
    public var improveAfterEdit: Bool
    public var defaultDraftPrompt: String?
    public var defaultImprovePrompt: String?
    public var placeholders: [String]
    /// Automations: the type's action buttons, as the core reports them.
    public var buttons: [ActionButtonInfo] = []

    public init(id: String, label: String, pluralLabel: String? = nil, enabled: Bool = true, reserved: Bool = false,
                fields: [ActionFieldSpec] = [], handlers: [ActionHandlerInfo] = [], connectionID: String? = nil,
                draftWhen: String = "onFind", improveAfterEdit: Bool = false, defaultDraftPrompt: String? = nil,
                defaultImprovePrompt: String? = nil, placeholders: [String] = []) {
        self.id = id; self.label = label; self.pluralLabel = pluralLabel ?? label + "s"; self.enabled = enabled
        self.reserved = reserved; self.fields = fields; self.handlers = handlers; self.connectionID = connectionID
        self.draftWhen = draftWhen; self.improveAfterEdit = improveAfterEdit; self.defaultDraftPrompt = defaultDraftPrompt
        self.defaultImprovePrompt = defaultImprovePrompt; self.placeholders = placeholders
    }

    enum CodingKeys: String, CodingKey {
        case id, label, pluralLabel, enabled, reserved, fields, handlers, connectionID, draftWhen, improveAfterEdit
        case defaultDraftPrompt, defaultImprovePrompt, placeholders, buttons
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.lossy(String.self, .label) ?? id
        pluralLabel = c.lossy(String.self, .pluralLabel) ?? label
        enabled = c.lossy(Bool.self, .enabled) ?? true
        reserved = c.lossy(Bool.self, .reserved) ?? false
        fields = c.lossyArray(ActionFieldSpec.self, .fields)
        handlers = c.lossyArray(ActionHandlerInfo.self, .handlers)
        connectionID = c.lossy(String.self, .connectionID)
        draftWhen = c.lossy(String.self, .draftWhen) ?? "onFind"
        improveAfterEdit = c.lossy(Bool.self, .improveAfterEdit) ?? false
        defaultDraftPrompt = c.lossy(String.self, .defaultDraftPrompt)
        defaultImprovePrompt = c.lossy(String.self, .defaultImprovePrompt)
        placeholders = c.lossyArray(String.self, .placeholders)
        buttons = c.lossyArray(ActionButtonInfo.self, .buttons)
    }

    public func handler(_ id: String) -> ActionHandlerInfo? { handlers.first { $0.id == id } }
    /// Usable now: on, and not a reserved slot (Email).
    public var isUsable: Bool { enabled && !reserved }
}

/// `JobActionsSummary` (Job.actionsFound): what the batch's "Finding actions" step found.
public struct JobActionsSummary: Codable, Hashable, Sendable {
    /// finding | done | failed | skipped (raw).
    public var status: String
    public var found: Int
    public var pending: Int
    public var added: Int
    public var byType: [String: Int]
    public var error: String?
    public var model: String?
    /// v11: review = found while the batch was read (they wait until their source's pages apply); applied = in Actions.
    public var stage: String?
    /// v11: found before apply, not added yet.
    public var proposed: Int?
    /// v11: lines looked through, of how many.
    public var lines: Int?
    public var linesOf: Int?
    public var sources: Int?
    /// v11: found again (re-read, repair) and already in Actions.
    public var duplicates: Int?

    public init(status: String, found: Int = 0, pending: Int = 0, added: Int = 0, byType: [String: Int] = [:],
                error: String? = nil, model: String? = nil, stage: String? = nil, proposed: Int? = nil,
                lines: Int? = nil, linesOf: Int? = nil, sources: Int? = nil, duplicates: Int? = nil) {
        self.status = status; self.found = found; self.pending = pending; self.added = added
        self.byType = byType; self.error = error; self.model = model
        self.stage = stage; self.proposed = proposed; self.lines = lines; self.linesOf = linesOf
        self.sources = sources; self.duplicates = duplicates
    }

    enum CodingKeys: String, CodingKey { case status, found, pending, added, byType, error, model, stage, proposed, lines, linesOf, sources, duplicates }

    /// Found while the batch was read (before Review), not after it applied.
    public var foundInBatch: Bool { stage != nil }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        status = c.lossy(String.self, .status) ?? "done"
        found = c.lossyInt(.found) ?? 0
        pending = c.lossyInt(.pending) ?? 0
        added = c.lossyInt(.added) ?? 0
        var by: [String: Int] = [:]
        if case .object(let o)? = c.lossy(JSONValue.self, .byType) {
            for (k, v) in o { if let n = v.doubleValue { by[k] = Int(n) } }
        }
        byType = by
        error = c.lossy(String.self, .error)
        model = c.lossy(String.self, .model)
        stage = c.lossy(String.self, .stage)
        proposed = c.lossyInt(.proposed)
        lines = c.lossyInt(.lines)
        linesOf = c.lossyInt(.linesOf)
        sources = c.lossyInt(.sources)
        duplicates = c.lossyInt(.duplicates)
    }
}

/// `NewActionInput` (POST /v1/actions).
public struct NewActionInput: Codable, Hashable, Sendable {
    public var type: String
    public var title: String
    public var body: String?
    public var fields: [String: String]?
    public var why: String?
    public var source: ActionSource?
    public var vaultPath: String?
    /// Labels for the new item (sent only when set; requested from the core).
    public var labels: [String]?

    public init(type: String = "todo", title: String, body: String? = nil, fields: [String: String]? = nil, why: String? = nil,
                source: ActionSource? = nil, vaultPath: String? = nil, labels: [String]? = nil) {
        self.type = type; self.title = title; self.body = body; self.fields = fields; self.why = why
        self.source = source; self.vaultPath = vaultPath; self.labels = labels
    }
}

/// `ActionPatch` (PATCH /v1/actions/:id). Only set keys are sent; a field set to nil is sent as null (cleared).
public struct ActionPatch: Encodable, Hashable, Sendable {
    public var title: String?
    /// `.some(nil)` clears the body.
    public var body: String??
    public var fields: [String: String?]?
    public var type: String?
    /// Replaces the item's labels (sent only when set; requested from the core).
    public var labels: [String]?

    public init(title: String? = nil, body: String?? = nil, fields: [String: String?]? = nil, type: String? = nil, labels: [String]? = nil) {
        self.title = title; self.body = body; self.fields = fields; self.type = type; self.labels = labels
    }

    enum CodingKeys: String, CodingKey { case title, body, fields, type, labels }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(title, forKey: .title)
        if let body { if let b = body { try c.encode(b, forKey: .body) } else { try c.encodeNil(forKey: .body) } }
        if let fields {
            var o: [String: JSONValue] = [:]
            for (k, v) in fields { o[k] = v.map(JSONValue.string) ?? .null }
            try c.encode(o, forKey: .fields)
        }
        try c.encodeIfPresent(type, forKey: .type)
        try c.encodeIfPresent(labels, forKey: .labels)
    }

    public var isEmpty: Bool { title == nil && body == nil && fields == nil && type == nil && labels == nil }
}

/// `ActionQuery` (GET /v1/actions?type=&status=&history=1&vault=&q=).
public struct ActionQuery: Hashable, Sendable {
    public var type: String?
    public var status: [ActionStatus]
    public var history: Bool
    public var vaultPath: String?
    public var text: String?

    public init(type: String? = nil, status: [ActionStatus] = [], history: Bool = false, vaultPath: String? = nil, text: String? = nil) {
        self.type = type; self.status = status; self.history = history; self.vaultPath = vaultPath; self.text = text
    }

    public var queryItems: [URLQueryItem] {
        var items: [URLQueryItem] = []
        if let type { items.append(URLQueryItem(name: "type", value: type)) }
        if !status.isEmpty { items.append(URLQueryItem(name: "status", value: status.map(\.rawValue).joined(separator: ","))) }
        if history { items.append(URLQueryItem(name: "history", value: "1")) }
        if let vaultPath { items.append(URLQueryItem(name: "vault", value: vaultPath)) }
        if let text, !text.isEmpty { items.append(URLQueryItem(name: "q", value: text)) }
        return items
    }
}
