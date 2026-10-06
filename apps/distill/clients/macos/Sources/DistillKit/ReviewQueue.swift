import Foundation

// Review queue (review-queue.md): an approval waiting for its turn to apply, a plan being rebuilt against
// the vault as it is now, and bounded self-recovery. Every type decodes leniently.

public struct QueuedApply: Codable, Equatable, Sendable {
    public var at: Date
    public var order: Double
    /// Present = waiting to apply; nil = rebuilt, needs the owner's OK again.
    public var planSha256: String?
    public var bundlePath: String

    public init(at: Date, order: Double, planSha256: String? = nil, bundlePath: String = "") {
        self.at = at; self.order = order; self.planSha256 = planSha256; self.bundlePath = bundlePath
    }
    enum Keys: String, CodingKey { case at, order, planSha256, bundlePath }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        at = c.lossyDate(.at) ?? .distantPast
        order = c.lossyDouble(.order) ?? 0
        planSha256 = c.lossy(String.self, .planSha256)
        bundlePath = c.lossy(String.self, .bundlePath) ?? ""
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(CoreDate.format(at), forKey: .at)
        try c.encode(order, forKey: .order)
        try c.encodeIfPresent(planSha256, forKey: .planSha256)
        try c.encode(bundlePath, forKey: .bundlePath)
    }
    public var waitingToApply: Bool { planSha256 != nil }
}

public struct RefreshState: Codable, Equatable, Sendable {
    public var since: Date
    public var stalePaths: [String]
    public var approved: Bool
    public init(since: Date, stalePaths: [String] = [], approved: Bool = false) {
        self.since = since; self.stalePaths = stalePaths; self.approved = approved
    }
    enum Keys: String, CodingKey { case since, stalePaths, approved }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        since = c.lossyDate(.since) ?? .distantPast
        stalePaths = c.lossyArray(String.self, .stalePaths)
        approved = c.lossy(Bool.self, .approved) ?? false
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(CoreDate.format(since), forKey: .since)
        try c.encode(stalePaths, forKey: .stalePaths)
        try c.encode(approved, forKey: .approved)
    }
}

public struct RecoveryAttempt: Codable, Equatable, Sendable {
    public var at: Date
    /// rule | agent
    public var by: String
    public var model: String?
    public var fix: String
    public var diagnosis: String?
    /// fixed | failed | running
    public var result: String
    public var error: String?
    public var costUSD: Double

    public init(at: Date, by: String = "rule", model: String? = nil, fix: String, diagnosis: String? = nil, result: String = "running",
                error: String? = nil, costUSD: Double = 0) {
        self.at = at; self.by = by; self.model = model; self.fix = fix; self.diagnosis = diagnosis; self.result = result
        self.error = error; self.costUSD = costUSD
    }
    enum Keys: String, CodingKey { case at, by, model, fix, diagnosis, result, error, costUSD }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        at = c.lossyDate(.at) ?? .distantPast
        by = c.lossy(String.self, .by) ?? "rule"
        model = c.lossy(String.self, .model)
        fix = c.lossy(String.self, .fix) ?? ""
        diagnosis = c.lossy(String.self, .diagnosis)
        result = c.lossy(String.self, .result) ?? "failed"
        error = c.lossy(String.self, .error)
        costUSD = c.lossyDouble(.costUSD) ?? 0
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(CoreDate.format(at), forKey: .at)
        try c.encode(by, forKey: .by)
        try c.encodeIfPresent(model, forKey: .model)
        try c.encode(fix, forKey: .fix)
        try c.encodeIfPresent(diagnosis, forKey: .diagnosis)
        try c.encode(result, forKey: .result)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encode(costUSD, forKey: .costUSD)
    }
}

public struct RecoveryState: Codable, Equatable, Sendable {
    public enum Phase: String, Codable, Sendable { case running, waiting, gaveUp, fixed }
    public var state: Phase
    /// denial | lock | stale-again | plan-error | not-recorded | full-read-stop | session-gone | runner-failed
    public var signature: String
    public var attempts: [RecoveryAttempt]
    public var denialAnswers: Int
    /// The owner's sentence when recovery gave up, written by the core (never built from a command here).
    public var summary: String?
    public var proposal: String?

    public init(state: Phase, signature: String, attempts: [RecoveryAttempt] = [], denialAnswers: Int = 0, summary: String? = nil, proposal: String? = nil) {
        self.state = state; self.signature = signature; self.attempts = attempts; self.denialAnswers = denialAnswers
        self.summary = summary; self.proposal = proposal
    }
    enum Keys: String, CodingKey { case state, signature, attempts, denialAnswers, summary, proposal }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = c.lossy(Phase.self, .state) ?? .gaveUp
        signature = c.lossy(String.self, .signature) ?? ""
        attempts = c.lossyArray(RecoveryAttempt.self, .attempts)
        denialAnswers = c.lossyInt(.denialAnswers) ?? 0
        summary = c.lossy(String.self, .summary)
        proposal = c.lossy(String.self, .proposal)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(state, forKey: .state)
        try c.encode(signature, forKey: .signature)
        try c.encode(attempts, forKey: .attempts)
        try c.encode(denialAnswers, forKey: .denialAnswers)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(proposal, forKey: .proposal)
    }

    public var costUSD: Double { attempts.reduce(0) { $0 + $1.costUSD } }
}

/// The blocked-command card's words (review-queue.md): the core's sentence, or a plain fallback for a batch
/// an older core left waiting. Never the command itself.
public enum BlockedText {
    public static func summary(_ job: Job) -> String {
        if let s = job.recovery?.summary, !s.isEmpty { return s }
        return "Claude was blocked from running a command it wanted, and stopped."
    }
    public static func heading(_ job: Job) -> String {
        job.recovery?.state == .running ? "Recovering" : "Claude got stuck"
    }
}
