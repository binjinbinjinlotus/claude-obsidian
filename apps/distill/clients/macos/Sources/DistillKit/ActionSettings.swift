import Foundation

// v3 settings for Actions (`Settings.actionPreferences`, contracts.ts
// `ActionPreferences`) and Connections (`ConnectionInfo`, `ConnectRequest`).
//
// `actionPreferences` is kept as the raw JSON object it arrived as, with typed
// accessors on top. The core merges settings one top-level key at a time, so an
// edit sends the whole object: keeping the raw object means nested keys this
// build does not know (a newer core's flags) are sent back unchanged.

/// `Partial<ActionPreferences>` in settings.json. Missing values read as
/// `DEFAULT_ACTION_PREFERENCES`; setters write only what was edited.
public struct ActionPreferences: Codable, Equatable, Sendable {
    public var raw: [String: JSONValue]

    public init(raw: [String: JSONValue] = [:]) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        guard case .object(let o) = try JSONValue(from: decoder) else {
            throw DecodingError.typeMismatch([String: JSONValue].self, .init(codingPath: decoder.codingPath, debugDescription: "not an object"))
        }
        raw = o
    }

    public func encode(to encoder: Encoder) throws { try JSONValue.object(raw).encode(to: encoder) }

    // MARK: Paths

    /// The value at `path` (`["sources", "notes", "confirm"]`), or nil.
    public func value(_ path: [String]) -> JSONValue? {
        var node: JSONValue? = .object(raw)
        for key in path { node = node?[key] }
        return node
    }

    /// Sets (or, with nil, removes) the value at `path`, creating objects on the
    /// way and keeping every sibling key. A non-object on the way is replaced.
    public mutating func set(_ path: [String], _ value: JSONValue?) {
        guard let first = path.first else { return }
        raw[first] = Self.setting(raw[first], Array(path.dropFirst()), value)
        if raw[first] == nil { raw.removeValue(forKey: first) }
    }

    private static func setting(_ node: JSONValue?, _ path: [String], _ value: JSONValue?) -> JSONValue? {
        guard let key = path.first else { return value }
        var o: [String: JSONValue] = [:]
        if case .object(let existing)? = node { o = existing }
        o[key] = setting(o[key], Array(path.dropFirst()), value)
        if o[key] == nil { o.removeValue(forKey: key) }
        return .object(o)
    }

    // MARK: Sources

    public enum Source: String, CaseIterable, Sendable { case notes, ask }

    /// Detect to-dos (default on).
    public func detectTodos(_ s: Source) -> Bool { value(["sources", s.rawValue, "detectTodos"])?.boolValue ?? true }
    /// Detect Slack, Jira, Confluence items (default on).
    public func detectTypes(_ s: Source) -> Bool { value(["sources", s.rawValue, "detectTypes"])?.boolValue ?? true }
    /// Ask me to confirm before adding (default on).
    public func confirm(_ s: Source) -> Bool { value(["sources", s.rawValue, "confirm"])?.boolValue ?? true }
    /// Types not detected from this source even though detectTypes is on.
    public func disabledTypes(_ s: Source) -> [String] { value(["sources", s.rawValue, "disabledTypes"])?.stringArray ?? [] }

    public mutating func setDetectTodos(_ s: Source, _ on: Bool) { setSource(s, "detectTodos", .bool(on)) }
    public mutating func setDetectTypes(_ s: Source, _ on: Bool) { setSource(s, "detectTypes", .bool(on)) }
    public mutating func setConfirm(_ s: Source, _ on: Bool) { setSource(s, "confirm", .bool(on)) }

    public mutating func setType(_ typeID: String, detected: Bool, from s: Source) {
        var list = disabledTypes(s).filter { $0 != typeID }
        if !detected { list.append(typeID) }
        setSource(s, "disabledTypes", .array(list.map(JSONValue.string)))
    }

    /// The core reads each source as a whole object: the contract's required
    /// fields are written with their defaults the first time any is edited.
    private mutating func setSource(_ s: Source, _ key: String, _ v: JSONValue) {
        let base = ["sources", s.rawValue]
        for (k, d) in [("detectTodos", true), ("detectTypes", true), ("confirm", true)] where value(base + [k]) == nil {
            set(base + [k], .bool(d))
        }
        set(base + [key], v)
    }

    // MARK: Finding

    /// Model that finds actions (nil = the core's fallback: taskDefaults.actionFind, then Claude Code · Sonnet).
    public var findSelection: ModelSelection? {
        get { Self.selection(value(["findSelection"])) }
        set { set(["findSelection"], newValue.map(Self.json)) }
    }

    // MARK: Types

    public func typeValue(_ typeID: String, _ key: String) -> JSONValue? { value(["types", typeID, key]) }
    public mutating func setTypeValue(_ typeID: String, _ key: String, _ v: JSONValue?) { set(["types", typeID, key], v) }

    public func enabled(_ typeID: String) -> Bool? { typeValue(typeID, "enabled")?.boolValue }
    /// "onFind" or "onRequest"; nil = the type's built-in default.
    public func draftWhen(_ typeID: String) -> String? { typeValue(typeID, "draftWhen")?.stringValue }
    public func improveAfterEdit(_ typeID: String) -> Bool? { typeValue(typeID, "improveAfterEdit")?.boolValue }
    public func draftSelection(_ typeID: String) -> ModelSelection? { Self.selection(typeValue(typeID, "draftSelection")) }
    public func improveSelection(_ typeID: String) -> ModelSelection? { Self.selection(typeValue(typeID, "improveSelection")) }
    /// nil = the built-in default prompt.
    public func draftPrompt(_ typeID: String) -> String? { typeValue(typeID, "draftPrompt")?.stringValue }
    public func improvePrompt(_ typeID: String) -> String? { typeValue(typeID, "improvePrompt")?.stringValue }
    public func fieldDefault(_ typeID: String, _ field: String) -> String? { value(["types", typeID, "fieldDefaults", field])?.stringValue }

    public mutating func setFieldDefault(_ typeID: String, _ field: String, _ v: String?) {
        let trimmed = v?.trimmingCharacters(in: .whitespacesAndNewlines)
        set(["types", typeID, "fieldDefaults", field], (trimmed?.isEmpty ?? true) ? nil : .string(trimmed!))
    }

    // MARK: Automations

    /// The type's action buttons as saved (action-buttons.md); a button this build can't read is skipped.
    public func buttons(_ typeID: String) -> [AutomationButton] {
        guard case .array(let list)? = typeValue(typeID, "buttons") else { return [] }
        return list.compactMap { v in
            guard let data = try? JSONEncoder().encode(v), let b = try? JSONDecoder().decode(AutomationButton.self, from: data),
                  !b.id.isEmpty else { return nil }
            return b
        }
    }

    public mutating func setButtons(_ typeID: String, _ buttons: [AutomationButton]) {
        let values: [JSONValue] = buttons.compactMap { b in
            guard let data = try? JSONEncoder().encode(b) else { return nil }
            return try? JSONDecoder().decode(JSONValue.self, from: data)
        }
        setTypeValue(typeID, "buttons", values.isEmpty ? nil : .array(values))
    }

    // MARK: To-do defaults and History

    /// due | created | priority | note (default due).
    public var todoSort: String {
        get { value(["todo", "defaultSort"])?.stringValue ?? "due" }
        set { setTodo("defaultSort", .string(newValue)) }
    }
    /// due | note | none (default due).
    public var todoGroup: String {
        get { value(["todo", "defaultGroup"])?.stringValue ?? "due" }
        set { setTodo("defaultGroup", .string(newValue)) }
    }
    /// Default off.
    public var remindOverdue: Bool {
        get { value(["todo", "remindOverdue"])?.boolValue ?? false }
        set { setTodo("remindOverdue", .bool(newValue)) }
    }

    private mutating func setTodo(_ key: String, _ v: JSONValue) {
        // `todo` is one object in the contract: write all three the first time.
        if value(["todo", "defaultSort"]) == nil { set(["todo", "defaultSort"], .string("due")) }
        if value(["todo", "defaultGroup"]) == nil { set(["todo", "defaultGroup"], .string("due")) }
        if value(["todo", "remindOverdue"]) == nil { set(["todo", "remindOverdue"], .bool(false)) }
        set(["todo", key], v)
    }

    /// Removed / done / sent actions stay in History this many days. Default 90; 0 = forever.
    public var historyDays: Int {
        get {
            guard let d = value(["historyDays"])?.doubleValue else { return 90 }
            return d <= 0 ? 0 : Int(d)
        }
        set { set(["historyDays"], .number(Double(max(0, newValue)))) }
    }

    // MARK: Helpers

    static func selection(_ v: JSONValue?) -> ModelSelection? {
        guard let v, case .object = v, let data = try? JSONEncoder.core.encode(v) else { return nil }
        return try? JSONDecoder.core.decode(ModelSelection.self, from: data)
    }

    public static func json(_ s: ModelSelection) -> JSONValue {
        var o: [String: JSONValue] = ["runnerID": .string(s.runnerID), "model": .string(s.model)]
        if let e = s.effort { o["effort"] = .string(e) }
        return .object(o)
    }
}

// MARK: - Connections

/// `ConnectionInfo` (contracts.ts): one sign-in, e.g. "atlassian" for Jira and
/// Confluence on one site. Never carries a secret.
public struct ConnectionInfo: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum Status: String, Codable, Sendable {
        case connected, notConnected = "not_connected", expired, signingIn = "signing_in", error
    }

    public var id: String
    public var label: String
    public var status: Status
    public var site: String?
    public var account: String?
    public var message: String?
    public var usedBy: [String]

    public init(id: String, label: String, status: Status, site: String? = nil, account: String? = nil,
                message: String? = nil, usedBy: [String] = []) {
        self.id = id; self.label = label; self.status = status
        self.site = site; self.account = account; self.message = message; self.usedBy = usedBy
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        label = c.lossy(String.self, .label) ?? id
        // An unknown status from a newer core reads as an error, never as connected.
        status = c.lossy(String.self, .status).map { Status(rawValue: $0) ?? .error } ?? .notConnected
        site = c.lossy(String.self, .site)
        account = c.lossy(String.self, .account)
        message = c.lossy(String.self, .message)
        usedBy = c.lossyArray(String.self, .usedBy)
    }
}

/// `ConnectRequest`: the core stores the token in the Keychain. Its description
/// never shows the token, so it cannot reach a log by accident.
public struct ConnectRequest: Encodable, Equatable, Sendable, CustomStringConvertible, CustomDebugStringConvertible {
    public var site: String?
    public var email: String?
    public var token: String?

    public init(site: String? = nil, email: String? = nil, token: String? = nil) {
        self.site = site; self.email = email; self.token = token
    }

    public var description: String { "ConnectRequest(site: \(site ?? "nil"), email: \(email ?? "nil"), token: \(token == nil ? "nil" : "•••"))" }
    public var debugDescription: String { description }
}

/// `GET /v1/connections/:id/sign-in-url`.
public struct SignInURL: Codable, Equatable, Sendable {
    public var url: String
}
