import Foundation

/// `Progress` in contracts.ts: live progress for long AI work (loading states).
/// Named `CoreProgress` because Foundation already has `Progress`.
/// One event per change; the last one for a key has `finished: true`.
public struct CoreProgress: Codable, Equatable, Sendable, Identifiable {
    /// A job id, `ask:<conversationID>`, or `note:<requestID>`.
    public var key: String
    /// batch | labelSuggest | labelPages | ask | apply (raw; unknown kinds are kept).
    public var kind: String
    public var message: String
    /// Ordered steps for batches, e.g. ["Moved to inbox", "Read sources", "Drafting page changes", "Ready for review"].
    public var steps: [String]
    public var stepIndex: Int?
    public var done: Int?
    public var total: Int?
    public var startedAt: Date
    public var runnerID: String?
    public var model: String?
    public var finished: Bool
    public var error: String?
    /// v7, batches: the file being worked on now (labels being suggested).
    public var current: String?

    public var id: String { key }

    enum CodingKeys: String, CodingKey {
        case key, kind, message, steps, stepIndex, done, total, startedAt, runnerID, model, finished, error, current
    }

    public init(key: String, kind: String, message: String, steps: [String] = [], stepIndex: Int? = nil, done: Int? = nil,
                total: Int? = nil, startedAt: Date = Date(), runnerID: String? = nil, model: String? = nil,
                finished: Bool = false, error: String? = nil, current: String? = nil) {
        self.key = key; self.kind = kind; self.message = message; self.steps = steps; self.stepIndex = stepIndex
        self.done = done; self.total = total; self.startedAt = startedAt; self.runnerID = runnerID; self.model = model
        self.finished = finished; self.error = error; self.current = current
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        key = try c.decode(String.self, forKey: .key)
        kind = c.lossy(String.self, .kind) ?? ""
        message = c.lossy(String.self, .message) ?? ""
        steps = c.lossyArray(String.self, .steps)
        stepIndex = c.lossyInt(.stepIndex)
        done = c.lossyInt(.done)
        total = c.lossyInt(.total)
        startedAt = c.lossyDate(.startedAt) ?? Date()
        runnerID = c.lossy(String.self, .runnerID)
        model = c.lossy(String.self, .model)
        finished = c.lossy(Bool.self, .finished) ?? false
        error = c.lossy(String.self, .error)
        current = c.lossy(String.self, .current)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(key, forKey: .key)
        try c.encode(kind, forKey: .kind)
        try c.encode(message, forKey: .message)
        if !steps.isEmpty { try c.encode(steps, forKey: .steps) }
        try c.encodeIfPresent(stepIndex, forKey: .stepIndex)
        try c.encodeIfPresent(done, forKey: .done)
        try c.encodeIfPresent(total, forKey: .total)
        try c.encode(CoreDate.format(startedAt), forKey: .startedAt)
        try c.encodeIfPresent(runnerID, forKey: .runnerID)
        try c.encodeIfPresent(model, forKey: .model)
        if finished { try c.encode(true, forKey: .finished) }
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(current, forKey: .current)
    }

    /// Progress key for an Ask turn.
    public static func askKey(_ conversationID: String) -> String { "ask:\(conversationID)" }
    /// Progress key for a queued note's label suggestion.
    public static func noteKey(_ requestID: String) -> String { "note:\(requestID)" }
}

/// `GET /v1/jobs/:id/resume`: the argv that reopens a job's session interactively.
public struct ResumeCommand: Codable, Equatable, Sendable {
    public var argv: [String]
    /// Working directory to run it in, when the core says.
    public var cwd: String?

    public init(argv: [String], cwd: String? = nil) { self.argv = argv; self.cwd = cwd }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        argv = c.lossyArray(String.self, .argv)
        cwd = c.lossy(String.self, .cwd)
    }
}
