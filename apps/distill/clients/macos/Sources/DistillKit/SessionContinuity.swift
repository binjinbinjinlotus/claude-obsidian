import Foundation

// Session continuity (docs/specs/session-continuity.md): the core never resumes into an AI
// session that is gone; it answers 409 `session_unavailable` and the app asks before the same
// call is sent again with `newSession`. Decoded leniently: unknown places and reasons from a
// newer core still show the confirmation with generic wording.

/// What the core reports when a session to resume is gone (`error` body fields, or `Job.sessionUnavailable`).
public struct SessionUnavailable: Codable, Equatable, Hashable, Sendable {
    /// batch | conversation | terminal (others: shown as a batch).
    public var place: String
    /// notFound | missing | neverStarted | runnerGone (others: generic reason).
    public var reason: String
    /// The core's plain sentence.
    public var message: String
    /// The technical reason (quiet line); never content.
    public var detail: String
    /// approve | reply | allow | ask | resume: the call to send again with newSession.
    public var action: String?
    /// The reply text / allow rules to send again (batches).
    public var text: String?
    public var rules: [String]?
    /// Approve options to send again (batches): "later", or the source pages picked for part of a batch.
    public var labels: String?
    public var pages: [String]?
    public var at: String?

    public init(place: String, reason: String, message: String = "", detail: String = "", action: String? = nil,
                text: String? = nil, rules: [String]? = nil, labels: String? = nil, pages: [String]? = nil, at: String? = nil) {
        self.place = place
        self.reason = reason
        self.message = message
        self.detail = detail
        self.action = action
        self.text = text
        self.rules = rules
        self.labels = labels
        self.pages = pages
        self.at = at
    }

    enum CodingKeys: String, CodingKey { case place, reason, message, detail, action, text, rules, labels, pages, at }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        place = c.lossy(String.self, .place) ?? "batch"
        reason = c.lossy(String.self, .reason) ?? ""
        message = c.lossy(String.self, .message) ?? ""
        detail = c.lossy(String.self, .detail) ?? ""
        action = c.lossy(String.self, .action)
        text = c.lossy(String.self, .text)
        rules = c.lossy([String].self, .rules)
        labels = c.lossy(String.self, .labels)
        pages = c.lossy([String].self, .pages)
        at = c.lossy(String.self, .at)
    }
}

/// The wording of SessionReplaceConfirm (mirrors design/components/SessionReplaceConfirm.dc.html).
public enum SessionReplaceText {
    public static func noun(_ place: String) -> String { place == "conversation" ? "conversation" : "batch" }

    public static func heading(place: String, reason: String = "") -> String {
        reason == "recovery" ? "Recovery suggests a new session" : "This \(noun(place))’s AI session isn’t available anymore"
    }

    public static func reason(_ reason: String, runner: String) -> String {
        switch reason {
        case "missing": return "its history is no longer on this Mac"
        case "notFound": return "\(runner) couldn’t find it"
        case "neverStarted": return "it never started: the batch stopped before \(runner) read the sources"
        case "runnerGone": return "\(runner) isn’t available anymore"
        case "recovery": return "a fresh session may get this batch going again"
        default: return "it can’t be resumed"
        }
    }

    public static func body(place: String, reason r: String, runner: String) -> String {
        let why = reason(r, runner: runner)
        let next = place == "terminal" ? "Distill will open a new session in Terminal instead." : "Distill will start a new session to continue."
        return why.prefix(1).uppercased() + why.dropFirst() + ". " + next
    }

    public static func carries(place: String) -> String {
        switch place {
        case "conversation": return "The new session starts with this conversation so far, so your follow-up keeps its context."
        case "terminal": return "It starts with this batch’s sources, labels and plan. The batch in Distill is not changed."
        default: return "The new session starts with this batch’s sources, your labels and the plan you are reviewing."
        }
    }

    public static func continueTitle(place: String) -> String { place == "terminal" ? "Open new session" : "Continue" }

    /// Display name of a runner id for the reason line.
    public static func runnerName(_ id: String?) -> String {
        switch id ?? "claude-code" {
        case "claude-code": return "Claude Code"
        case "codex": return "Codex"
        case let other: return other
        }
    }
}
