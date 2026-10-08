import Foundation

// The activity log and Distill's trash (contracts.ts → "Activity log (v6)";
// spec activity-log.md). The core writes one entry per change: what changed,
// when, and from where. Everything decodes leniently: a newer core may add
// types, sources, object kinds, recovery kinds and detail keys, and an entry of
// the wrong shape is skipped instead of failing the page.

/// Who asked for a change: app, cli, agent, scheduler, api, core (or a newer one).
public struct ActivitySource: RawStringValue {
    public var rawValue: String
    public init(rawValue: String) { self.rawValue = rawValue }
    public static let fallback = "api"
    public static let app = ActivitySource("app")
    public static let cli = ActivitySource("cli")
    public static let agent = ActivitySource("agent")
    public static let scheduler = ActivitySource("scheduler")
    public static let api = ActivitySource("api")
    public static let core = ActivitySource("core")
}

public struct ActivityObject: Codable, Hashable, Sendable {
    /// chat, collector, action, batch, queue, note, connection, settings, runner, labels, core (or newer).
    public var kind: String
    public var id: String?
    /// The human name at the time of the change, so a deleted thing still has a name.
    public var name: String?

    public init(kind: String, id: String? = nil, name: String? = nil) { self.kind = kind; self.id = id; self.name = name }

    enum Keys: String, CodingKey { case kind, id, name }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        kind = c.lossy(String.self, .kind) ?? "core"
        id = c.lossy(String.self, .id).flatMap { $0.isEmpty ? nil : $0 }
        name = c.lossy(String.self, .name).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// Where a deleted thing can be got back from.
public enum ActivityRecovery: Hashable, Sendable {
    /// Distill's trash (deleted chats and collectors).
    case trash(id: String, expiresAt: Date?)
    /// Queue files moved to the macOS Trash (`~/.Trash/<name>`).
    case macosTrash(path: String)
    /// No copy, with the reason the core gave.
    case none(reason: String)
    /// A recovery kind this build doesn't know.
    case unknown(kind: String)

    public var trashID: String? { if case .trash(let id, _) = self { return id }; return nil }
}

extension ActivityRecovery: Codable {
    enum Keys: String, CodingKey { case kind, trashId, expiresAt, path, reason }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        let kind = c.lossy(String.self, .kind) ?? ""
        switch kind {
        case "trash":
            guard let id = c.lossy(String.self, .trashId), !id.isEmpty else { self = .unknown(kind: kind); return }
            self = .trash(id: id, expiresAt: c.lossyDate(.expiresAt))
        case "macosTrash": self = .macosTrash(path: c.lossy(String.self, .path) ?? "")
        case "none": self = .none(reason: c.lossy(String.self, .reason) ?? "")
        default: self = .unknown(kind: kind)
        }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        switch self {
        case .trash(let id, let expiresAt):
            try c.encode("trash", forKey: .kind)
            try c.encode(id, forKey: .trashId)
            try c.encodeIfPresent(expiresAt.map(CoreDate.format), forKey: .expiresAt)
        case .macosTrash(let path):
            try c.encode("macosTrash", forKey: .kind)
            try c.encode(path, forKey: .path)
        case .none(let reason):
            try c.encode("none", forKey: .kind)
            try c.encode(reason, forKey: .reason)
        case .unknown(let kind):
            try c.encode(kind, forKey: .kind)
        }
    }
}

/// One line of the activity log.
public struct ActivityEntry: Codable, Hashable, Sendable, Identifiable {
    /// Time-sortable; also the paging cursor.
    public var id: String
    public var at: Date
    /// "<family>.<verb>", e.g. "collector.deleted".
    public var type: String
    public var source: ActivitySource
    public var object: ActivityObject
    public var summary: String
    public var failed: Bool
    public var error: String?
    /// Small, flat, redacted facts (counts, sizes, paths, changed keys). Unknown keys are kept.
    public var details: [String: JSONValue]
    public var recovery: ActivityRecovery?

    public init(id: String, at: Date, type: String, source: ActivitySource, object: ActivityObject, summary: String,
                failed: Bool = false, error: String? = nil, details: [String: JSONValue] = [:], recovery: ActivityRecovery? = nil) {
        self.id = id; self.at = at; self.type = type; self.source = source; self.object = object; self.summary = summary
        self.failed = failed; self.error = error; self.details = details; self.recovery = recovery
    }

    /// "collector" for "collector.deleted"; the object kind when the type has no dot.
    public var family: String {
        if let dot = type.firstIndex(of: "."), dot != type.startIndex { return String(type[..<dot]) }
        return type.isEmpty ? object.kind : type
    }

    /// "deleted" for "collector.deleted".
    public var verb: String {
        guard let dot = type.firstIndex(of: ".") else { return "" }
        return String(type[type.index(after: dot)...])
    }

    enum Keys: String, CodingKey { case id, at, type, source, object, summary, outcome, error, details, recovery }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        // An entry needs an id (the cursor) and a time; everything else has a default.
        id = try c.decode(String.self, forKey: .id)
        guard let at = c.lossyDate(.at) else {
            throw DecodingError.dataCorruptedError(forKey: .at, in: c, debugDescription: "missing or unreadable time")
        }
        self.at = at
        type = c.lossy(String.self, .type) ?? ""
        source = c.lossy(ActivitySource.self, .source) ?? .api
        object = c.lossy(ActivityObject.self, .object) ?? ActivityObject(kind: "core")
        summary = c.lossy(String.self, .summary) ?? type
        failed = c.lossy(String.self, .outcome) == "failed"
        error = c.lossy(String.self, .error).flatMap { $0.isEmpty ? nil : $0 }
        details = c.lossy([String: JSONValue].self, .details) ?? [:]
        recovery = c.lossy(ActivityRecovery.self, .recovery)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(CoreDate.format(at), forKey: .at)
        try c.encode(type, forKey: .type)
        try c.encode(source, forKey: .source)
        try c.encode(object, forKey: .object)
        try c.encode(summary, forKey: .summary)
        try c.encode(failed ? "failed" : "ok", forKey: .outcome)
        try c.encodeIfPresent(error, forKey: .error)
        if !details.isEmpty { try c.encode(details, forKey: .details) }
        try c.encodeIfPresent(recovery, forKey: .recovery)
    }

    // Typed reads of `details` (absent or of another type: nil).
    public func string(_ key: String) -> String? { details[key]?.stringValue.flatMap { $0.isEmpty ? nil : $0 } }
    public func number(_ key: String) -> Double? { details[key]?.doubleValue }
    public func int(_ key: String) -> Int? { number(key).map { Int($0) } }
    public func strings(_ key: String) -> [String] { details[key]?.stringArray ?? [] }
    public func bool(_ key: String) -> Bool? { details[key]?.boolValue }
}

/// `GET /v1/activity`: newest first; `nextCursor` asks for the older page (nil at the end).
public struct ActivityPage: Decodable, Equatable, Sendable {
    public var entries: [ActivityEntry]
    public var nextCursor: String?

    public init(entries: [ActivityEntry], nextCursor: String? = nil) { self.entries = entries; self.nextCursor = nextCursor }

    enum Keys: String, CodingKey { case entries, nextCursor }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        entries = c.lossyArray(ActivityEntry.self, .entries)
        nextCursor = c.lossy(String.self, .nextCursor).flatMap { $0.isEmpty ? nil : $0 }
    }
}

/// The filters `GET /v1/activity` takes (all optional). Families match their types: "collector" is "collector.*".
public struct ActivityQuery: Equatable, Sendable {
    public var types: [String] = []
    public var objectKind: String?
    public var objectID: String?
    public var sources: [ActivitySource] = []
    /// Inclusive.
    public var since: Date?
    /// Exclusive.
    public var until: Date?
    public var text: String?
    public var onlyFailures = false
    public var limit: Int?
    public var cursor: String?

    public init(types: [String] = [], objectKind: String? = nil, objectID: String? = nil, sources: [ActivitySource] = [],
                since: Date? = nil, until: Date? = nil, text: String? = nil, onlyFailures: Bool = false,
                limit: Int? = nil, cursor: String? = nil) {
        self.types = types; self.objectKind = objectKind; self.objectID = objectID; self.sources = sources
        self.since = since; self.until = until; self.text = text; self.onlyFailures = onlyFailures
        self.limit = limit; self.cursor = cursor
    }

    /// The route's query parameters (core/src/server/http.ts → parseActivityQuery).
    public var queryItems: [URLQueryItem] {
        var out: [URLQueryItem] = []
        if !types.isEmpty { out.append(URLQueryItem(name: "type", value: types.joined(separator: ","))) }
        if let objectKind { out.append(URLQueryItem(name: "kind", value: objectKind)) }
        if let objectID { out.append(URLQueryItem(name: "object", value: objectID)) }
        if !sources.isEmpty { out.append(URLQueryItem(name: "source", value: sources.map(\.rawValue).joined(separator: ","))) }
        if let since { out.append(URLQueryItem(name: "since", value: CoreDate.format(since))) }
        if let until { out.append(URLQueryItem(name: "until", value: CoreDate.format(until))) }
        if let text = text?.trimmingCharacters(in: .whitespacesAndNewlines), !text.isEmpty { out.append(URLQueryItem(name: "q", value: text)) }
        if onlyFailures { out.append(URLQueryItem(name: "outcome", value: "failed")) }
        if let limit { out.append(URLQueryItem(name: "limit", value: String(limit))) }
        if let cursor { out.append(URLQueryItem(name: "cursor", value: cursor)) }
        return out
    }
}

/// A deleted chat or collector kept in Distill's trash. The payload stays on disk.
public struct TrashItem: Decodable, Hashable, Sendable, Identifiable {
    public var id: String
    /// chat or collector (or newer).
    public var kind: String
    public var objectID: String
    public var name: String
    public var deletedAt: Date?
    public var expiresAt: Date?
    public var source: ActivitySource
    public var sizeBytes: Int
    public var details: [String: JSONValue]

    public init(id: String, kind: String, objectID: String, name: String, deletedAt: Date? = nil, expiresAt: Date? = nil,
                source: ActivitySource = .app, sizeBytes: Int = 0, details: [String: JSONValue] = [:]) {
        self.id = id; self.kind = kind; self.objectID = objectID; self.name = name; self.deletedAt = deletedAt
        self.expiresAt = expiresAt; self.source = source; self.sizeBytes = sizeBytes; self.details = details
    }

    enum Keys: String, CodingKey { case id, kind, objectID, name, deletedAt, expiresAt, source, sizeBytes, details }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        id = try c.decode(String.self, forKey: .id)
        kind = c.lossy(String.self, .kind) ?? ""
        objectID = c.lossy(String.self, .objectID) ?? ""
        name = c.lossy(String.self, .name) ?? ""
        deletedAt = c.lossyDate(.deletedAt)
        expiresAt = c.lossyDate(.expiresAt)
        source = c.lossy(ActivitySource.self, .source) ?? .api
        sizeBytes = c.lossyInt(.sizeBytes) ?? 0
        details = c.lossy([String: JSONValue].self, .details) ?? [:]
    }
}

/// `POST /v1/trash/:id/restore`.
public struct RestoreResult: Decodable, Hashable, Sendable {
    public var item: TrashItem?
    /// The restored chat id or collector id (a collector gets a new id when its old one is taken).
    public var objectID: String
    /// A restored script collector comes back off and needs consent again.
    public var note: String?

    public init(item: TrashItem? = nil, objectID: String, note: String? = nil) { self.item = item; self.objectID = objectID; self.note = note }

    enum Keys: String, CodingKey { case item, objectID, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        item = c.lossy(TrashItem.self, .item)
        objectID = c.lossy(String.self, .objectID) ?? item?.objectID ?? ""
        note = c.lossy(String.self, .note).flatMap { $0.isEmpty ? nil : $0 }
    }
}

// MARK: - CoreClient

extension CoreClient {
    /// `GET /v1/activity`: newest first. A core without the log answers 501 (`isNotAvailable`).
    public func activity(_ query: ActivityQuery = ActivityQuery()) async throws -> ActivityPage {
        var c = URLComponents()
        c.queryItems = query.queryItems
        let q = (c.percentEncodedQuery ?? "").replacingOccurrences(of: "+", with: "%2B")
        return try await getPlain("/v1/activity" + (q.isEmpty ? "" : "?" + q))
    }

    /// `GET /v1/trash`: newest first, never the payloads.
    public func trash() async throws -> [TrashItem] {
        try await getWrapped("/v1/trash", LossyList<TrashItem>.self, key: "items").items
    }

    /// `POST /v1/trash/:id/restore`. 404: unknown or expired; 409: a chat with that id exists.
    public func restoreFromTrash(_ id: String) async throws -> RestoreResult {
        try await sendPlain("POST", "/v1/trash/\(Self.segment(id))/restore", body: JSONValue.object([:]))
    }
}
