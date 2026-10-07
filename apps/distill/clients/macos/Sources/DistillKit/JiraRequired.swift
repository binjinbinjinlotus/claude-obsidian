import Foundation

/// Jira required fields (actions.md): the fields a project + type asks for beyond Project, Type and
/// Priority, shown by name with a control that follows Jira's field type. A value lives in the item's
/// fields under `jira.<fieldId>` (the core's encoding, `jira-required.ts`):
///   option, text, textarea, number, date (YYYY-MM-DD): the text   options: a JSON array of names
///   user: JSON {accountId, name}                                    cascading: a JSON array [parent, child]
/// `jira.<fieldId>:from` marks a value from the note: "note", or the names the note gave (several choices).
public struct JiraOption: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var children: [JiraOption]?
    public init(id: String, name: String, children: [JiraOption]? = nil) { self.id = id; self.name = name; self.children = children }
}

public enum JiraFieldKind: String, Codable, Sendable {
    case option, options, text, textarea, number, date, user, cascading, unsupported
}

public struct JiraField: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public var required: Bool
    public var kind: JiraFieldKind
    public var options: [JiraOption]
    /// Jira fills it when left empty.
    public var hasDefault: Bool

    public init(id: String, name: String, required: Bool = true, kind: JiraFieldKind, options: [JiraOption] = [], hasDefault: Bool = false) {
        self.id = id; self.name = name; self.required = required; self.kind = kind; self.options = options; self.hasDefault = hasDefault
    }

    enum Keys: String, CodingKey { case id, name, required, kind, options, hasDefault }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = c.lossy(String.self, .id) ?? ""
        name = c.lossy(String.self, .name) ?? ""
        required = c.lossy(Bool.self, .required) ?? false
        kind = c.lossy(String.self, .kind).flatMap(JiraFieldKind.init(rawValue:)) ?? .unsupported
        options = c.lossyArray(JiraOption.self, .options)
        hasDefault = c.lossy(Bool.self, .hasDefault) ?? false
    }

    /// Asked on every ticket: required and Jira has no default for it.
    public var asked: Bool { required && !hasDefault }
    public var key: String { JiraRequired.key(id) }
}

public struct JiraUser: Codable, Hashable, Sendable, Identifiable {
    public var accountId: String
    public var name: String
    public var id: String { accountId }
    public init(accountId: String, name: String) { self.accountId = accountId; self.name = name }
}

struct JiraUserList: Codable { var users: [JiraUser] }
struct JiraCreatePage: Codable { var url: String }

/// A saved value for a project + type (`actionPreferences.types.jira.requiredDefaults["TLS|Task"][fieldId]`).
public struct JiraRequiredDefault: Codable, Hashable, Sendable {
    public var name: String
    public var value: String
    public init(name: String, value: String) { self.name = name; self.value = value }
}

public enum JiraRequired {
    public static func key(_ id: String) -> String { "jira.\(id)" }
    public static func fromKey(_ id: String) -> String { "jira.\(id):from" }
    /// "TLS|Task".
    public static func defaultsKey(_ project: String, _ type: String) -> String {
        "\(project.trimmingCharacters(in: .whitespaces).uppercased())|\(type.trimmingCharacters(in: .whitespaces))"
    }

    public static func isEmpty(_ raw: String?) -> Bool {
        guard let t = raw?.trimmingCharacters(in: .whitespacesAndNewlines), !t.isEmpty else { return true }
        return t == "[]" || t == "{}"
    }

    /// The fields shown on a ticket: the asked ones, and an optional one only when a default is saved.
    public static func shown(_ extra: [JiraField], defaults: [String: JiraRequiredDefault]) -> [JiraField] {
        extra.filter { $0.asked || defaults[$0.id] != nil }
    }

    /// The value in force: the item's own, else the saved one.
    public static func value(_ f: JiraField, values: [String: String], defaults: [String: JiraRequiredDefault]) -> String? {
        if let own = values[f.key], !isEmpty(own) { return own }
        if let d = defaults[f.id]?.value, !isEmpty(d) { return d }
        return nil
    }

    /// The first asked field Create can't send: "Fill in Team first", or "Rollout plan can only be filled in Jira".
    public static func missing(_ extra: [JiraField], values: [String: String], defaults: [String: JiraRequiredDefault]) -> (field: String, message: String)? {
        for f in extra where f.asked {
            if f.kind == .unsupported { return (f.key, "\(f.name) can only be filled in Jira") }
            if value(f, values: values, defaults: defaults) == nil { return (f.key, "Fill in \(f.name) first") }
        }
        return nil
    }

    /// "Choose a team" / "Choose an environment".
    public static func placeholder(_ name: String) -> String {
        let n = name.lowercased()
        return "Choose \("aeiou".contains(n.first ?? "x") ? "an" : "a") \(n)"
    }

    /// "TEAMS IN TLS".
    public static func menuTitle(_ name: String, project: String) -> String {
        let n = name.uppercased()
        return "\(n.hasSuffix("S") ? n : n + "S") IN \(project)"
    }

    /// "Use for future TLS Tasks".
    public static func useForFuture(project: String, type: String) -> String {
        let t = type.trimmingCharacters(in: .whitespaces)
        return "Use for future \(project) \(t.hasSuffix("s") ? t : t + "s")"
    }

    // MARK: Values

    public static func names(_ raw: String?) -> [String] {
        guard let raw, let data = raw.data(using: .utf8), let list = try? JSONDecoder().decode([String].self, from: data) else {
            return (raw ?? "").split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        return list
    }

    public static func encode(_ names: [String]) -> String {
        (try? String(data: JSONEncoder().encode(names), encoding: .utf8)) ?? "[]"
    }

    public static func user(_ raw: String?) -> JiraUser? {
        guard let data = raw?.data(using: .utf8) else { return nil }
        return try? JSONDecoder().decode(JiraUser.self, from: data)
    }

    public static func encode(_ user: JiraUser) -> String {
        (try? String(data: JSONEncoder().encode(user), encoding: .utf8)) ?? ""
    }

    /// [parent, child] of a cascading value.
    public static func pair(_ raw: String?) -> (String?, String?) {
        let n = names(raw)
        return (n.first, n.count > 1 ? n[1] : nil)
    }

    /// The names a note gave for this field ("note" means the whole value).
    public static func fromNote(_ f: JiraField, values: [String: String]) -> [String] {
        guard let tag = values[fromKey(f.id)], !tag.isEmpty else { return [] }
        if tag == "note" { return f.kind == .options ? names(values[f.key]) : [values[f.key] ?? ""] }
        return names(tag)
    }

    /// "2026-10-16" ↔ a date (UTC noon, so the day never shifts).
    public static func date(_ raw: String?) -> Date? {
        guard let raw, raw.count == 10 else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.date(from: raw).map { $0.addingTimeInterval(12 * 3600) }
    }

    public static func dayString(_ d: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "yyyy-MM-dd"
        return f.string(from: d)
    }

    /// "Oct 16, 2026".
    public static func dayLabel(_ raw: String?) -> String? {
        guard let d = date(raw) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US"); f.timeZone = TimeZone(identifier: "UTC"); f.dateFormat = "MMM d, yyyy"
        return f.string(from: d)
    }

    /// What a value reads as in a line ("Staging › us-east-1", "API, Gateway", "Aditya Pradhan").
    public static func display(_ f: JiraField, _ raw: String?) -> String? {
        guard let raw, !isEmpty(raw) else { return nil }
        switch f.kind {
        case .options: return names(raw).joined(separator: ", ")
        case .user: return user(raw)?.name ?? raw
        case .cascading: let (p, c) = pair(raw); return [p, c].compactMap { $0 }.joined(separator: " › ")
        case .date: return dayLabel(raw) ?? raw
        default: return raw
        }
    }

    /// Copy the ticket text: the title and description, then each filled field by name ("Team: Platform").
    public static func ticketText(title: String, body: String?, fields: [JiraField], values: [String: String],
                                  defaults: [String: JiraRequiredDefault]) -> String {
        let lines = fields.compactMap { f in display(f, value(f, values: values, defaults: defaults)).map { "\(f.name): \($0)" } }
        return ([title, body ?? ""] + (lines.isEmpty ? [] : [lines.joined(separator: "\n")])).filter { !$0.isEmpty }.joined(separator: "\n\n")
    }

    /// "AP" for Aditya Pradhan.
    public static func initials(_ name: String) -> String {
        String(name.split(separator: " ").prefix(2).compactMap(\.first)).uppercased()
    }
}

extension ActionPreferences {
    /// Saved required-field values per "PROJECT|Type".
    public var jiraRequiredDefaults: [String: [String: JiraRequiredDefault]] {
        guard case .object(let byKey)? = typeValue("jira", "requiredDefaults") else { return [:] }
        var out: [String: [String: JiraRequiredDefault]] = [:]
        for (k, v) in byKey {
            guard case .object(let fields) = v else { continue }
            var m: [String: JiraRequiredDefault] = [:]
            for (id, d) in fields {
                guard let value = d["value"]?.stringValue, !JiraRequired.isEmpty(value) else { continue }
                m[id] = JiraRequiredDefault(name: d["name"]?.stringValue ?? id, value: value)
            }
            if !m.isEmpty { out[k] = m }
        }
        return out
    }

    /// Saves (or, with nil, removes) a project + type's value for a field.
    public mutating func setJiraRequiredDefault(_ key: String, field: String, _ d: JiraRequiredDefault?) {
        set(["types", "jira", "requiredDefaults", key, field], d.map { .object(["name": .string($0.name), "value": .string($0.value)]) })
        if case .object(let o)? = value(["types", "jira", "requiredDefaults", key]), o.isEmpty {
            set(["types", "jira", "requiredDefaults", key], nil)
        }
    }
}
