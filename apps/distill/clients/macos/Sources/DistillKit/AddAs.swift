import Foundation

/// "Add as" at confirm time (actions.md): a found item comes in as another enabled type. The menu's
/// options, the panel's prefill and what blocks Add; the core maps and checks the same way
/// (`confirmActions(ids, {as})`).
public enum AddAs {
    /// "to-do", "Slack message", "Jira ticket" (a type in a sentence).
    public static func typeWords(_ id: String, types: [ActionTypeInfo]) -> String {
        if id == "todo" { return "to-do" }
        return types.first { $0.id == id }?.label ?? id
    }

    /// The split button's main part: "Add as to-do", "Add as Slack message".
    public static func mainTitle(_ item: ActionItem, types: [ActionTypeInfo]) -> String {
        "Add as " + typeWords(item.type, types: types)
    }

    public struct Option: Hashable, Sendable, Identifiable {
        public var id: String
        public var label: String
        /// What happens: "Ready to send with Send in Slack".
        public var detail: String
    }

    /// Every enabled type: To-do first, then the types with a handler or a button (Slack message, Jira
    /// ticket, …), in the core's order.
    public static func options(_ types: [ActionTypeInfo]) -> [Option] {
        let todo = types.first { $0.id == "todo" }
        let others = types.filter { t in
            t.id != "todo" && t.isUsable
                && (t.handlers.contains { !["complete", "markSent", "refresh"].contains($0.id) } || !t.buttons.isEmpty)
        }
        return ([todo].compactMap { $0 } + others).map { Option(id: $0.id, label: $0.id == "todo" ? "To-do" : $0.label, detail: detail($0)) }
    }

    /// The menu's line on what happens once it is added.
    public static func detail(_ t: ActionTypeInfo) -> String {
        if t.id == "todo" { return "Added to your to-dos" }
        if let send = t.buttons.first(where: { $0.button.slot == .send && $0.button.enabled }) { return "Ready to send with \(send.button.label)" }
        if let send = t.handler("send"), send.available { return "Ready to send with \(send.label)" }
        if let create = t.handler("create") { return "Written as a draft, then \(create.label)" }
        if t.handler("copy") != nil { return "Written for you to copy and paste" }
        if let b = t.buttons.first { return "Runs \(b.button.label)" }
        return "Added to \(t.pluralLabel)"
    }

    /// The panel's fields, prefilled from the found item.
    public struct Draft: Hashable, Sendable {
        public var type: String
        public var title: String
        public var body: String
        public var fields: [String: String]
        public init(type: String, title: String, body: String, fields: [String: String]) {
            self.type = type; self.title = title; self.body = body; self.fields = fields
        }
    }

    /// title → title; summary or body → body or text; people → to (and back); keys both types have kept.
    public static func prefill(_ item: ActionItem, as type: ActionTypeInfo) -> Draft {
        let keys = Set(type.fields.map(\.key))
        var fields: [String: String] = [:]
        for (k, v) in item.fields where keys.contains(k) { fields[k] = v }
        let person = item.field("person") ?? item.field("assignee")
        if keys.contains("to"), fields["to"] == nil, let person { fields["to"] = person }
        if keys.contains("assignee"), fields["assignee"] == nil, let p = item.field("person") ?? item.field("to") { fields["assignee"] = p }
        if keys.contains("person"), fields["person"] == nil, let p = item.field("to") ?? item.field("assignee") { fields["person"] = p }
        let body = [item.body, item.summary].compactMap { $0?.trimmingCharacters(in: .whitespacesAndNewlines) }.first { !$0.isEmpty } ?? ""
        return Draft(type: type.id, title: item.title, body: body, fields: fields)
    }

    /// Labels of required fields left empty, in the type's order.
    public static func missing(_ draft: Draft, type: ActionTypeInfo) -> [String] {
        type.fields.filter { $0.required && (draft.fields[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty }.map(\.label)
    }

    /// Why Add is off, between Cancel and Add: "Fill in who it goes to", "Fill in Project and Type".
    /// `unknownName`: a Slack To that is a name Distill doesn't know while a button sends to it ("Who is
    /// X in Slack?" is open), so who it goes to isn't filled in yet.
    public static func blockReason(_ draft: Draft, type: ActionTypeInfo, unknownName: Bool = false) -> String? {
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a title" }
        let keys = type.fields.filter {
            ($0.required && (draft.fields[$0.key] ?? "").trimmingCharacters(in: .whitespaces).isEmpty) || ($0.key == "to" && unknownName)
        }
        guard !keys.isEmpty else { return nil }
        let names = keys.map { $0.key == "to" ? "who it goes to" : $0.label }
        return "Fill in " + names.joined(separator: " and ")
    }

    /// The menu row's line for the found type: "Found as a to-do".
    public static func foundLine(_ id: String, types: [ActionTypeInfo]) -> String {
        let words = typeWords(id, types: types)
        let article = words.first.map { "aeiouAEIOU".contains($0) } == true ? "an" : "a"
        return "Found as \(article) \(words)"
    }

    /// The menu's last line: "Return adds as to-do · ⌥Return opens Add as…".
    public static func keysHint(_ item: ActionItem, types: [ActionTypeInfo]) -> String {
        "Return adds as \(typeWords(item.type, types: types)) · ⌥Return opens Add as…"
    }

    /// The body's label in the panel.
    public static func bodyLabel(_ type: ActionTypeInfo) -> String {
        switch type.id {
        case "todo": return "Note"
        case "slack": return "Text"
        case "jira": return "Description"
        default: return "Body"
        }
    }

    /// Keys in the To-confirm list and its detail: Return adds as the found type (⌘Return too); ⌥Return
    /// opens Add as…. Never while typing in a text field, and not while the panel is open (its own
    /// ⌘Return adds it).
    public enum Key: Equatable { case add, openMenu }
    public static func key(returnWithOption option: Bool) -> Key { option ? .openMenu : .add }
    /// Return (⌘Return as an alias) adds as the found type; ⌥Return opens Add as…; any other modifier is not ours.
    public static func key(option: Bool, command: Bool, other: Bool = false) -> Key? {
        if other || (option && command) { return nil }
        return option ? .openMenu : .add
    }
    public static func detailKey(returnWithOption option: Bool, typing: Bool, panelOpen: Bool) -> Key? {
        typing || panelOpen ? nil : key(returnWithOption: option)
    }
}

/// `as` in `POST /v1/actions/confirm`.
public struct ConfirmAs: Encodable, Equatable, Sendable {
    public var type: String
    public var title: String?
    public var body: String?
    public var fields: [String: String?]?

    public init(_ d: AddAs.Draft) {
        type = d.type
        title = d.title.trimmingCharacters(in: .whitespaces)
        body = d.body
        fields = d.fields.mapValues { v in
            let t = v.trimmingCharacters(in: .whitespaces)
            return t.isEmpty ? nil : t
        }
    }

    enum CodingKeys: String, CodingKey { case type, title, body, fields }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(body, forKey: .body)
        if let fields {
            var f = c.nestedContainer(keyedBy: AnyKey.self, forKey: .fields)
            for (k, v) in fields { if let v { try f.encode(v, forKey: AnyKey(k)) } else { try f.encodeNil(forKey: AnyKey(k)) } }
        }
    }

    struct AnyKey: CodingKey {
        var stringValue: String
        var intValue: Int? { nil }
        init(_ s: String) { stringValue = s }
        init?(stringValue: String) { self.stringValue = stringValue }
        init?(intValue: Int) { nil }
    }
}

private struct ConfirmAsBody: Encodable { let ids: [String]; let `as`: ConfirmAs }

extension CoreClient {
    /// Add as (actions.md): one pending item comes in as `as.type`, with the owner's edits.
    public func confirmAction(_ id: String, as target: ConfirmAs) async throws -> ActionItem? {
        try await sendPlainList("POST", "/v1/actions/confirm", body: ConfirmAsBody(ids: [id], as: target)).first
    }

    private func sendPlainList(_ method: String, _ path: String, body: ConfirmAsBody) async throws -> [ActionItem] {
        struct Out: Decodable { let actions: LossyList<ActionItem> }
        let out: Out = try await sendPlain(method, path, body: body)
        return out.actions.items
    }
}
