import Foundation

// v6 (2026-10-05): labels in the queue and in Review, picking and removing sources, approving in parts.
// Every type decodes leniently: a missing field takes its default and an unknown enum value its fallback,
// so an older or newer core never blanks a screen (contracts.ts is the source of truth).

/// A queue text file's labels, suggested in the background at most 3 files at a time (`QueueLabels`).
public struct QueueLabels: Codable, Equatable, Hashable, Sendable {
    /// waiting = behind the 3 running; own = the .md's own tags; skipped = sent without labels.
    public enum State: String, Codable, Sendable {
        case waiting, suggesting, suggested, confirmed, own, failed, skipped
    }

    public var state: State
    public var labels: [LabelSuggestion]
    public var error: String?
    /// Failed suggestions so far; Distill retries by itself until 3, then waits for the user.
    public var attempts: Int

    public init(state: State, labels: [LabelSuggestion] = [], error: String? = nil, attempts: Int = 0) {
        self.state = state
        self.labels = labels
        self.error = error
        self.attempts = attempts
    }

    enum CodingKeys: String, CodingKey { case state, labels, error, attempts }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // An unknown state from a newer core reads as waiting (labels not in yet), never as a failure.
        state = c.lossy(String.self, .state).flatMap(State.init(rawValue:)) ?? .waiting
        labels = c.lossyArray(LabelSuggestion.self, .labels)
        error = c.lossy(String.self, .error).flatMap { $0.isEmpty ? nil : $0 }
        attempts = max(0, c.lossyInt(.attempts) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(state, forKey: .state)
        try c.encode(labels, forKey: .labels)
        try c.encodeIfPresent(error, forKey: .error)
        if attempts > 0 { try c.encode(attempts, forKey: .attempts) }
    }

    /// After 3 failed tries the row offers Send without labels.
    public var allowsSkip: Bool { state == .failed && attempts >= 3 }
}

/// One input's source page in a pending batch (`ReviewSource`).
public struct ReviewSource: Codable, Equatable, Hashable, Sendable, Identifiable {
    public enum By: String, Codable, Sendable { case ai, user, none }
    public enum State: String, Codable, Sendable { case waiting, suggesting, failed }

    /// Vault-relative page the bundle writes ("wiki/sources/Foo.md").
    public var page: String
    public var title: String
    /// The input it was made from ("inbox/foo.md").
    public var source: String?
    public var labels: [String]
    public var by: By
    /// Only while labels are attached to a batch that reached Review without them.
    public var state: State?
    /// Taken out of the batch (Undo while the batch is in Review).
    public var removed: Bool

    public var id: String { page }

    public init(page: String, title: String, source: String? = nil, labels: [String] = [], by: By = .none,
                state: State? = nil, removed: Bool = false) {
        self.page = page
        self.title = title
        self.source = source
        self.labels = labels
        self.by = by
        self.state = state
        self.removed = removed
    }

    enum CodingKeys: String, CodingKey { case page, title, source, labels, by, state, removed }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        page = try c.decode(String.self, forKey: .page)
        let stem = ((page as NSString).lastPathComponent as NSString).deletingPathExtension
        title = c.lossy(String.self, .title).flatMap { $0.isEmpty ? nil : $0 } ?? stem
        source = c.lossy(String.self, .source).flatMap { $0.isEmpty ? nil : $0 }
        labels = c.lossyArray(String.self, .labels)
        by = c.lossy(String.self, .by).flatMap(By.init(rawValue:)) ?? (labels.isEmpty ? .none : .ai)
        state = c.lossy(String.self, .state).flatMap(State.init(rawValue:))
        removed = c.lossy(Bool.self, .removed) ?? false
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(page, forKey: .page)
        try c.encode(title, forKey: .title)
        try c.encodeIfPresent(source, forKey: .source)
        try c.encode(labels, forKey: .labels)
        try c.encode(by, forKey: .by)
        try c.encodeIfPresent(state, forKey: .state)
        if removed { try c.encode(true, forKey: .removed) }
    }
}

/// Where the labels shown in Review stand (`ReviewLabels`).
public struct ReviewLabels: Codable, Equatable, Sendable {
    public enum State: String, Codable, Sendable { case suggesting, confirming, confirmed, unconfirmed }

    public var state: State
    public var message: String?
    public var done: Int?
    public var total: Int?
    public var revision: Int?

    public init(state: State, message: String? = nil, done: Int? = nil, total: Int? = nil, revision: Int? = nil) {
        self.state = state
        self.message = message
        self.done = done
        self.total = total
        self.revision = revision
    }

    enum CodingKeys: String, CodingKey { case state, message, done, total, revision }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        // Unknown = confirmed: approving confirms what is shown (the core refuses with a message if it is not ready).
        state = c.lossy(String.self, .state).flatMap(State.init(rawValue:)) ?? .confirmed
        message = c.lossy(String.self, .message).flatMap { $0.isEmpty ? nil : $0 }
        done = c.lossyInt(.done)
        total = c.lossyInt(.total)
        revision = c.lossyInt(.revision)
    }

    /// Approve waits while labels are being suggested or written into the change.
    public var blocksApprove: Bool { state == .suggesting || state == .confirming }
}

/// The same change with labels left unconfirmed (Approve, review labels later).
public struct UnconfirmedPlan: Codable, Equatable, Sendable {
    public var bundlePath: String
    public var plan: TransactionPlan?

    public init(bundlePath: String, plan: TransactionPlan? = nil) { self.bundlePath = bundlePath; self.plan = plan }

    enum CodingKeys: String, CodingKey { case bundlePath, plan }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        bundlePath = c.lossy(String.self, .bundlePath) ?? ""
        plan = c.lossy(TransactionPlan.self, .plan)
    }
}

/// partial = the user approved some sources; remaining = what is left after a part applied; stale = the vault changed.
public enum PartReason: String, Codable, Sendable { case partial, remaining, stale }

/// confirm = approving confirms the labels shown; later = apply them unconfirmed (Labels → To review).
public enum ApproveLabels: String, Codable, Sendable { case confirm, later }

/// The plan was rebuilt in the batch's session and checked against what the user approved.
public struct RebuiltPlan: Codable, Equatable, Sendable {
    public var reason: PartReason
    public var pages: [String]
    public var labels: ApproveLabels

    public init(reason: PartReason, pages: [String] = [], labels: ApproveLabels = .confirm) {
        self.reason = reason; self.pages = pages; self.labels = labels
    }

    enum CodingKeys: String, CodingKey { case reason, pages, labels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = c.lossy(String.self, .reason).flatMap(PartReason.init(rawValue:)) ?? .partial
        pages = c.lossyArray(String.self, .pages)
        labels = c.lossy(String.self, .labels).flatMap(ApproveLabels.init(rawValue:)) ?? .confirm
    }
}

/// A part of a batch already applied (approving only some sources).
public struct JobPart: Codable, Equatable, Sendable {
    public var operationID: String
    public var pages: [String]
    public var labels: ApproveLabels
    public var at: Date

    public init(operationID: String, pages: [String], labels: ApproveLabels = .confirm, at: Date) {
        self.operationID = operationID; self.pages = pages; self.labels = labels; self.at = at
    }

    enum CodingKeys: String, CodingKey { case operationID, pages, labels, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        operationID = c.lossy(String.self, .operationID) ?? ""
        pages = c.lossyArray(String.self, .pages)
        labels = c.lossy(String.self, .labels).flatMap(ApproveLabels.init(rawValue:)) ?? .confirm
        at = c.lossyDate(.at) ?? .distantPast
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(operationID, forKey: .operationID)
        try c.encode(pages, forKey: .pages)
        try c.encode(labels, forKey: .labels)
        try c.encode(CoreDate.format(at), forKey: .at)
    }
}

/// The part being rebuilt in the batch's session, until its change comes back.
public struct PendingPart: Codable, Equatable, Sendable {
    public var reason: PartReason
    /// Source pages the rebuilt change must hold, with the sha256 of what the user saw.
    public var expected: [String: String]
    public var excluded: [String]
    public var labels: ApproveLabels

    public init(reason: PartReason, expected: [String: String] = [:], excluded: [String] = [], labels: ApproveLabels = .confirm) {
        self.reason = reason; self.expected = expected; self.excluded = excluded; self.labels = labels
    }

    enum CodingKeys: String, CodingKey { case reason, expected, excluded, labels }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        reason = c.lossy(String.self, .reason).flatMap(PartReason.init(rawValue:)) ?? .partial
        expected = c.lossy([String: String].self, .expected) ?? [:]
        excluded = c.lossyArray(String.self, .excluded)
        labels = c.lossy(String.self, .labels).flatMap(ApproveLabels.init(rawValue:)) ?? .confirm
    }
}

/// `POST /v1/jobs/:id/approve` body (v6). Both nil = approve everything, confirming the labels (as before).
public struct ApproveOptions: Equatable, Sendable {
    public var labels: ApproveLabels?
    /// The picked source pages; nil when every source not removed is picked.
    public var pages: [String]?

    public init(labels: ApproveLabels? = nil, pages: [String]? = nil) { self.labels = labels; self.pages = pages }

    public var isEmpty: Bool { labels == nil && pages == nil }

    var body: [String: JSONValue] {
        var out: [String: JSONValue] = [:]
        if let labels { out["labels"] = .string(labels.rawValue) }
        if let pages { out["pages"] = .array(pages.map(JSONValue.string)) }
        return out
    }
}
