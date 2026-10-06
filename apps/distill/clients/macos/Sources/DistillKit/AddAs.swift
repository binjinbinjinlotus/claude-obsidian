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

    /// Why Add is off: "Fill in To first." (the core says the same).
    public static func blockReason(_ draft: Draft, type: ActionTypeInfo) -> String? {
        if draft.title.trimmingCharacters(in: .whitespaces).isEmpty { return "Give it a title first." }
        let names = missing(draft, type: type)
        return names.isEmpty ? nil : "Fill in \(names.joined(separator: " and ")) first."
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

    /// Keys while the To-confirm list has focus: Return adds as the found type; ⌥Return opens Add as….
    public enum Key: Equatable { case add, openMenu }
    public static func key(returnWithOption option: Bool) -> Key { option ? .openMenu : .add }
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
