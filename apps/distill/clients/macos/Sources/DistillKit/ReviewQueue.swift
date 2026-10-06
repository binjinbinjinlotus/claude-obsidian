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
    /// new_session: recovery suggests something only the owner may do.
    public var proposal: String?
    /// A waiting attempt runs again at this time.
    public var waitUntil: Date?
    /// split_batch: the sources in groups; the first is rebuilt when the owner confirms.
    public var groups: [[String]]
    /// The hash the owner approved for the queued apply (a retry goes back only under it).
    public var approvedSha256: String?
    /// What a waiting recovery does next: agent (default) or retry (the queued apply).
    public var wake: String?

    public init(state: Phase, signature: String, attempts: [RecoveryAttempt] = [], denialAnswers: Int = 0, summary: String? = nil, proposal: String? = nil,
                waitUntil: Date? = nil, groups: [[String]] = [], approvedSha256: String? = nil, wake: String? = nil) {
        self.state = state; self.signature = signature; self.attempts = attempts; self.denialAnswers = denialAnswers
        self.summary = summary; self.proposal = proposal; self.waitUntil = waitUntil
        self.groups = groups; self.approvedSha256 = approvedSha256; self.wake = wake
    }
    enum Keys: String, CodingKey { case state, signature, attempts, denialAnswers, summary, proposal, waitUntil, groups, approvedSha256, wake }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        state = c.lossy(Phase.self, .state) ?? .gaveUp
        signature = c.lossy(String.self, .signature) ?? ""
        attempts = c.lossyArray(RecoveryAttempt.self, .attempts)
        denialAnswers = c.lossyInt(.denialAnswers) ?? 0
        summary = c.lossy(String.self, .summary)
        proposal = c.lossy(String.self, .proposal)
        waitUntil = c.lossyDate(.waitUntil)
        groups = (c.lossy([[String]].self, .groups) ?? []).filter { !$0.isEmpty }
        approvedSha256 = c.lossy(String.self, .approvedSha256)
        wake = c.lossy(String.self, .wake)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(state, forKey: .state)
        try c.encode(signature, forKey: .signature)
        try c.encode(attempts, forKey: .attempts)
        try c.encode(denialAnswers, forKey: .denialAnswers)
        try c.encodeIfPresent(summary, forKey: .summary)
        try c.encodeIfPresent(proposal, forKey: .proposal)
        if let waitUntil { try c.encode(CoreDate.format(waitUntil), forKey: .waitUntil) }
        if !groups.isEmpty { try c.encode(groups, forKey: .groups) }
        try c.encodeIfPresent(approvedSha256, forKey: .approvedSha256)
        try c.encodeIfPresent(wake, forKey: .wake)
    }

    public var costUSD: Double { attempts.reduce(0) { $0 + $1.costUSD } }
    /// Recovery suggests a new session (only the owner may start one).
    public var suggestsNewSession: Bool { proposal == "new_session" }
}

/// review-queue.md, Self-recovery: the Review words for a problem other than a blocked command (stale-again,
/// plan-error, runner-failed). The sentence of what's wrong is the core's; these only describe the state.
public enum RecoveryText {
    /// The card shows for these; blocked commands have their own card (BlockedText) while the turn still has
    /// blocked calls to show.
    public static func shows(_ job: Job) -> Bool {
        guard let r = job.recovery, r.state != .fixed else { return false }
        if r.signature == "denial", !(job.approval?.denials.isEmpty ?? true) { return false }
        return job.state == .awaitingApproval || job.state == .failed
    }

    /// Recovery is really working on the batch: a turn runs, an agent attempt runs, or the next try is scheduled.
    /// A recovery an older core left `running` with nothing in flight (the rule's turn ended with questions) is
    /// not: the batch needs the owner (2026-10-06).
    public static func isActive(_ job: Job) -> Bool {
        guard let r = job.recovery else { return false }
        switch r.state {
        case .waiting: return true
        case .running:
            return job.state == .running || r.attempts.last(where: { $0.result == "running" })?.by == "agent"
                || job.queuedApply?.waitingToApply == true // back in the queue under the approved hash: the pump has it
        case .gaveUp, .fixed: return false
        }
    }

    public static func heading(_ r: RecoveryState, timeZone: TimeZone = .current) -> String {
        switch r.state {
        case .running: return "Recovering · \(doing(r))"
        case .waiting: return r.waitUntil.map { "Recovering · next try at \(clock($0, timeZone: timeZone))" } ?? "Recovering · waiting a minute"
        case .gaveUp: return "Distill couldn’t fix this"
        case .fixed: return "Fixed"
        }
    }

    /// What recovery is doing now, from the last attempt.
    public static func doing(_ r: RecoveryState) -> String {
        let last = r.attempts.last
        let who = last?.by == "agent" ? ModelChoice.shortName(last?.model ?? "the Recovery model") + " · " : ""
        switch (r.signature, last?.fix) {
        case ("stale-again", _): return who + "rebuilding against the latest pages"
        case ("runner-failed", "rebuild_in_session"): return who + "asking Claude to continue"
        case (_, "rebuild_in_session"): return who + "asking Claude to rebuild the plan"
        default: return who + "looking at the problem"
        }
    }

    /// The plain sentence: the core's when it gave up, else what this kind of problem is.
    public static func summary(_ r: RecoveryState) -> String {
        if let s = r.summary, !s.isEmpty { return s }
        switch r.signature {
        case "stale-again": return "Your vault keeps changing under this plan: it was rebuilt for the latest pages and is out of date again."
        case "plan-error": return "The vault core couldn’t check this plan."
        case "runner-failed": return "The AI run stopped with an error."
        case "denial": return "Distill answered Claude’s blocked command, but Claude stopped with questions instead of a plan."
        case "lock": return "Another app kept your vault locked, so your approved change couldn’t be applied yet."
        case "session-gone": return "This batch’s AI session isn’t available anymore, so your approved change can’t be applied in it."
        default: return "Distill couldn’t get this batch going again by itself."
        }
    }

    /// The quiet line under a running or waiting notice.
    public static func detail(_ r: RecoveryState) -> String {
        let base = summary(r)
        if r.state == .waiting { return base + " Distill waits a minute between tries, then looks again." }
        return base + " Nothing needs you while Distill works on it."
    }

    /// "Tried twice · last by Opus · $0.04."
    public static func tried(_ r: RecoveryState) -> String? {
        guard !r.attempts.isEmpty else { return nil }
        let n = r.attempts.count
        let cost = r.costUSD > 0 ? String(format: " · $%.2f", r.costUSD) : ""
        let agent = r.attempts.last(where: { $0.by == "agent" }).map { " · last by \(ModelChoice.shortName($0.model ?? "the Recovery model"))" } ?? ""
        return "Tried \(n == 1 ? "once" : n == 2 ? "twice" : "\(n) times")\(agent)\(cost)."
    }

    /// The card offers Continue in a new session: recovery suggested it and the job has no gone-session marker
    /// (that one already shows the confirmation under the batch).
    public static func offersNewSession(_ job: Job) -> Bool {
        guard let r = job.recovery, r.state == .gaveUp, r.suggestsNewSession else { return false }
        return job.sessionUnavailable == nil
    }

    /// What a fix did, in plain words (Review's attempt rows and Activity). Never an attempt's raw error.
    public static func fixWords(_ fix: String) -> String {
        switch fix {
        case "answer_denial": "told Claude to read the files instead"
        case "rebuild_in_session": "asked Claude to rebuild the plan"
        case "reinspect_same_bundle": "checked your approved plan again"
        case "wait_then_retry": "waited, then tried your approved plan again"
        case "split_batch": "suggested splitting the batch"
        case "discard_stale_part": "suggested discarding the rebuilt part"
        case "new_session": "suggested a new session"
        case "give_up": "handed it to you"
        default: "tried something Distill doesn’t know"
        }
    }

    public static func sentenceCase(_ s: String) -> String { s.prefix(1).uppercased() + s.dropFirst() }

    /// review-queue.md, "What was tried": one row per attempt, oldest first. "Opus · asked Claude to rebuild the plan · didn’t help · $0.04".
    public static func attemptRows(_ r: RecoveryState) -> [String] {
        r.attempts.map { a in
            let who = a.by == "agent" ? ModelChoice.shortName(a.model ?? "the Recovery model") : "Distill"
            let result = switch a.result { case "fixed": "worked"; case "running": "in progress"; default: "didn’t help" }
            let cost = a.costUSD > 0 ? String(format: " · $%.2f", a.costUSD) : ""
            return "\(who) · \(fixWords(a.fix)) · \(result)\(cost)"
        }
    }

    /// What the card's Rebuild sends, as the owner's reply (a gone session asks first, as every reply does).
    public static let rebuildReply = "Rebuild this batch’s plan against the pages as they are now: write the bundle again in this job’s directory and finish with needs_approval. Distill runs inspect and the approved apply itself."

    /// Let recovery try again: not for session-gone (only the owner's new session goes on).
    public static func offersTryAgain(_ job: Job) -> Bool { job.recovery?.signature != "session-gone" }

    /// Rebuild against the latest pages is a reply to the batch's session: a labels confirmation has none.
    public static func offersRebuild(_ job: Job) -> Bool { job.kind != "labels" }

    /// split_batch: the owner's one click rebuilds the first group (Approve with those pages); the rest wait.
    public static func splitGroup(_ job: Job) -> [String]? {
        guard job.state == .awaitingApproval, let r = job.recovery, r.state == .gaveUp, r.proposal == "split_batch",
              let first = r.groups.first, !first.isEmpty else { return nil }
        return first
    }

    /// discard_stale_part: only while a rebuilt part waits (Reject the part, never the batch).
    public static func offersDiscard(_ job: Job) -> Bool {
        guard job.state == .awaitingApproval, let r = job.recovery, r.state == .gaveUp, r.proposal == "discard_stale_part" else { return false }
        return job.pendingPart != nil && job.approval?.rebuilt != nil && job.approval?.needsRebuild != true
    }

    /// What Continue in a new session sends, as the owner's reply (session continuity seeds the batch first).
    public static let newSessionReply = "Continue this batch in a new session: pick up where it stopped, using only the tools you have, and finish with the structured status."

    static func clock(_ d: Date, timeZone: TimeZone) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.timeZone = timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: d)
    }
}

/// The blocked-command card's words (review-queue.md): the core's sentence, or a plain fallback for a batch
/// an older core left waiting. Never the command itself.
public enum BlockedText {
    public static func summary(_ job: Job) -> String {
        if let s = job.recovery?.summary, !s.isEmpty { return s }
        return "Claude was blocked from running a command it wanted, and stopped."
    }
    public static func heading(_ job: Job) -> String {
        RecoveryText.isActive(job) ? "Recovering" : "Claude got stuck"
    }
}

/// review-queue.md: the Review words for the apply queue (the core decides; these only describe it).
public enum ReviewQueueText {
    /// The batch needs the owner: the same rule as the core's pendingApprovals (badges).
    public static func needsOwner(_ j: Job) -> Bool {
        // A stopped batch recovery gave up on is Couldn't fix, which needs the owner too.
        if j.state == .failed { return j.recovery?.state == .gaveUp }
        guard j.state == .awaitingApproval else { return false }
        if j.queuedApply?.waitingToApply == true || j.refresh != nil { return false }
        if RecoveryText.isActive(j) { return false }
        return true
    }

    /// A batch's short name: its first file without folder and extension, "+2" for the rest.
    public static func shortName(_ j: Job) -> String {
        guard let first = j.files.first else { return j.id }
        let file = (first as NSString).lastPathComponent
        let name = ReviewBatches.readableName(file) ?? (file as NSString).deletingPathExtension
        return "“\(name)”" + (j.files.count > 1 ? " +\(j.files.count - 1)" : "")
    }

    /// What applies before this batch in its vault: the one applying now, or an earlier approval.
    public static func ahead(of job: Job, in jobs: [Job]) -> Job? {
        let others = jobs.filter { $0.id != job.id && $0.vaultPath == job.vaultPath }
        if let applying = others.first(where: { $0.state == .running && $0.approvedChange != nil && $0.refresh == nil && $0.pendingPart == nil
            && ApplyTimeline.approvalIsLatest($0) }) { return applying }
        let mine = job.queuedApply?.order ?? .infinity
        return others.filter { $0.queuedApply != nil && ($0.state == .awaitingApproval || $0.refresh != nil) && $0.queuedApply!.order < mine }
            .min { $0.queuedApply!.order < $1.queuedApply!.order }
    }

    /// "Queued · applies after “Product sync”" for a batch waiting to apply.
    public static func queuedLine(_ job: Job, in jobs: [Job]) -> String {
        if let a = ahead(of: job, in: jobs) { return "Queued · applies after \(shortName(a))" }
        return "Queued · applies next"
    }

    /// The footer note when Approve would queue: "Applies after “Product sync”".
    public static func approveNote(_ job: Job, in jobs: [Job]) -> String? {
        ahead(of: job, in: jobs).map { "Applies after \(shortName($0))" }
    }

    /// A rebuilt plan the owner had approved: it keeps its place and asks once more.
    public static func asksAgain(_ job: Job) -> Bool {
        job.state == .awaitingApproval && job.queuedApply != nil && job.queuedApply?.waitingToApply == false && job.approval?.canApplyPlan == true
    }

    /// "What changed since you approved" lines.
    public static func sinceLines(_ s: SinceApproved) -> [String] {
        var out = ["Your source pages: unchanged"]
        let pages = s.content + s.added
        if !pages.isEmpty {
            let names = pages.prefix(4).map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension.replacingOccurrences(of: "-", with: " ") }
            out.append("\(pages.count == 1 ? "1 page differs" : "\(pages.count) pages differ"): \(names.joined(separator: ", "))\(pages.count > 4 ? ", …" : "")")
        }
        if !s.dropped.isEmpty { out.append("\(s.dropped.count == 1 ? "1 page is" : "\(s.dropped.count) pages are") no longer changed") }
        if !s.bookkeeping.isEmpty {
            let names = s.bookkeeping.map { p -> String in
                switch (p as NSString).lastPathComponent {
                case "hot.md": return "hot cache"
                case "log.md": return "log"
                case "index.md": return "index"
                case "overview.md": return "overview"
                default: return "ledger"
                }
            }
            var counts: [String: Int] = [:]
            names.forEach { counts[$0, default: 0] += 1 }
            let order = ["log", "hot cache", "index", "overview", "ledger"].filter { counts[$0] != nil }
            out.append("Bookkeeping written again: " + order.map { counts[$0]! > 1 ? "\(counts[$0]!) \($0)s" : $0 }.joined(separator: ", "))
        }
        return out
    }
}

public struct SinceApproved: Codable, Equatable, Sendable {
    public var content: [String]
    public var added: [String]
    public var dropped: [String]
    public var bookkeeping: [String]
    public init(content: [String] = [], added: [String] = [], dropped: [String] = [], bookkeeping: [String] = []) {
        self.content = content; self.added = added; self.dropped = dropped; self.bookkeeping = bookkeeping
    }
    enum Keys: String, CodingKey { case content, added, dropped, bookkeeping }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        content = c.lossyArray(String.self, .content)
        added = c.lossyArray(String.self, .added)
        dropped = c.lossyArray(String.self, .dropped)
        bookkeeping = c.lossyArray(String.self, .bookkeeping)
    }
}

// MARK: - The batch list (review-queue.md, section 4)

public enum ReviewRowState: Equatable, Sendable {
    case ready, updating, queued(Int), applying, added, needsYou, recovering, couldntFix, notAdded, working

    public var label: String {
        switch self {
        case .ready: return "Ready"
        case .updating: return "Updating…"
        case .queued(let n): return n <= 1 ? "Queued · next" : "Queued · \(ReviewBatches.ordinal(n))"
        case .applying: return "Applying"
        case .added: return "Added"
        case .needsYou: return "Needs you"
        case .recovering: return "Recovering"
        case .couldntFix: return "Couldn't fix"
        case .notAdded: return "Not added"
        case .working: return "Working"
        }
    }
}

extension ReviewBatches {
    static let timeZones: Set<String> = ["IST", "PST", "PDT", "EST", "EDT", "CST", "CDT", "MST", "MDT", "UTC", "GMT", "CET", "CEST", "BST", "JST",
                                         "AEST", "AEDT", "SGT", "HKT"]

    private static func replacing(_ s: String, _ pattern: String, with: String = " ", options: NSRegularExpression.Options = []) -> String {
        guard let re = try? NSRegularExpression(pattern: pattern, options: options) else { return s }
        return re.stringByReplacingMatches(in: s, range: NSRange(s.startIndex..., in: s), withTemplate: with)
    }

    /// "Telus Daily Stand-up" from "2026-10-05 Telus Daily Stand-up - 2026_10_05 19_00 IST - Notes by Gemini.gdoc";
    /// nil when nothing readable is left (the caller falls back to the plain title).
    public static func readableName(_ fileName: String) -> String? {
        var s = fileName
        // 1. The extension (a short one without spaces), then a slugged name's dashes and underscores become spaces.
        if let dot = s.lastIndex(of: "."), s.distance(from: dot, to: s.endIndex) <= 6, !s[dot...].contains(" "),
           s[s.index(after: dot)...].allSatisfy({ $0.isLetter || $0.isNumber }), s[s.index(after: dot)...].contains(where: \.isLetter) {
            s = String(s[..<dot])
        }
        let slugged = !s.contains(" ")
        if slugged { s = s.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ") }
        // 2. Notes by Gemini, Transcript.
        s = replacing(s, #"notes[\s_-]+by[\s_-]+gemini"#, options: .caseInsensitive)
        s = replacing(s, #"\btranscript\b"#, options: .caseInsensitive)
        // 5 first (GMT+5:30 has a time in it), then 3 dates and 4 times.
        s = replacing(s, #"\bGMT\s?[+\-−]\s?\d{1,2}(:\d{2})?"#)
        s = replacing(s, #"\b\d{4}[-_ /.]\d{1,2}[-_ /.]\d{1,2}\b"#)
        s = replacing(s, #"\b\d{1,2}[_/]\d{1,2}[_/]\d{4}\b"#)
        s = replacing(s, #"\b\d{1,2}[:_.\- ]\d{2}([:_.]\d{2})?(\s?[AaPp][Mm])?\b"#)
        let words = s.split(separator: " ", omittingEmptySubsequences: true).filter { !timeZones.contains(String($0)) }
        s = words.joined(separator: " ")
        // 6. Leftover separators.
        s = replacing(s, #"(\s+[-–—]+)+\s+"#)
        s = replacing(s, #"\s{2,}"#)
        s = s.trimmingCharacters(in: CharacterSet(charactersIn: " -–—_.,:;"))
        // 7. A slugged name gets its hyphens back in a few common words.
        if slugged {
            for (plain, joined) in [("stand up", "stand-up"), ("check in", "check-in"), ("follow up", "follow-up"), ("kick off", "kick-off"),
                                    ("sync up", "sync-up"), ("one on one", "one-on-one")] {
                while let r = s.range(of: "\\b\(plain)\\b", options: [.regularExpression, .caseInsensitive]) {
                    let upper = s[r].first?.isUppercase == true
                    s.replaceSubrange(r, with: upper ? joined.prefix(1).uppercased() + joined.dropFirst() : joined)
                }
            }
        }
        guard !s.isEmpty, s.contains(where: \.isLetter) else { return nil }
        return s.prefix(1).uppercased() + s.dropFirst()
    }

    public static func ordinal(_ n: Int) -> String {
        let suffix: String
        switch (n % 10, n % 100) {
        case (1, let t) where t != 11: suffix = "st"
        case (2, let t) where t != 12: suffix = "nd"
        case (3, let t) where t != 13: suffix = "rd"
        default: suffix = "th"
        }
        return "\(n)\(suffix)"
    }

    /// "Oct 5": the date in the first source's name, otherwise when the batch started.
    public static func batchDate(_ job: Job, locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let f = DateFormatter()
        f.locale = locale
        f.timeZone = timeZone
        f.setLocalizedDateFormatFromTemplate("MMMd")
        if let name = job.files.first.map({ ($0 as NSString).lastPathComponent }),
           let re = try? NSRegularExpression(pattern: #"(\d{4})[-_ /.](\d{1,2})[-_ /.](\d{1,2})"#),
           let m = re.firstMatch(in: name, range: NSRange(name.startIndex..., in: name)),
           let y = Int((name as NSString).substring(with: m.range(at: 1))), let mo = Int((name as NSString).substring(with: m.range(at: 2))),
           let d = Int((name as NSString).substring(with: m.range(at: 3))) {
            var c = Calendar(identifier: .gregorian)
            c.timeZone = timeZone
            if let date = c.date(from: DateComponents(year: y, month: mo, day: d, hour: 12)) { return f.string(from: date) }
        }
        return f.string(from: job.createdAt)
    }

    /// The row's one state, from the same facts as the apply card.
    public static func rowState(_ job: Job, in jobs: [Job]) -> ReviewRowState {
        if job.refresh != nil { return .updating }
        if RecoveryText.isActive(job) { return .recovering }
        switch job.state {
        case .awaitingApproval:
            if job.recovery?.state == .gaveUp { return .couldntFix }
            if job.queuedApply?.waitingToApply == true {
                let queue = jobs.filter { $0.vaultPath == job.vaultPath && $0.state == .awaitingApproval && $0.queuedApply?.waitingToApply == true }
                    .sorted { $0.queuedApply!.order < $1.queuedApply!.order }
                let applying = jobs.contains { $0.vaultPath == job.vaultPath && ApplyTimeline.isApplying($0) }
                return .queued((queue.firstIndex { $0.id == job.id } ?? 0) + (applying ? 2 : 1))
            }
            if ReviewQueueText.asksAgain(job) || job.sessionUnavailable != nil { return .needsYou }
            if let a = job.approval, a.planError != nil || !a.questions.isEmpty || !a.denials.isEmpty || !a.canApplyPlan && a.needsRebuild != true {
                return .needsYou
            }
            return .ready
        case .running:
            if job.pendingPart != nil { return .updating }
            return ApplyTimeline.isApplying(job) ? .applying : .working
        case .completed:
            return job.operationID != nil && job.operationID == job.approvedChange?.operationID ? .added : .notAdded
        case .failed where job.recovery?.state == .gaveUp:
            return .couldntFix
        case .failed, .cancelled, .rejected:
            return .notAdded
        }
    }

    /// The row to select when `leaving` goes (Done or Reject): the next one, or the previous at the end.
    public static func nextSelection(after leaving: String, in before: [String], now: [String]) -> String? {
        guard let i = before.firstIndex(of: leaving) else { return now.first }
        for id in before[(i + 1)...] where now.contains(id) { return id }
        for id in before[..<i].reversed() where now.contains(id) { return id }
        return now.first
    }
}

/// review-queue.md: Settings → Recovery. Only what the owner set is stored (nil = default).
public struct RecoveryPreferences: Codable, Equatable, Sendable {
    public var automatic: Bool?
    public var maxAttempts: Int?
    public var maxCostUSD: Double?
    public init(automatic: Bool? = nil, maxAttempts: Int? = nil, maxCostUSD: Double? = nil) {
        self.automatic = automatic; self.maxAttempts = maxAttempts; self.maxCostUSD = maxCostUSD
    }
    enum Keys: String, CodingKey { case automatic, maxAttempts, maxCostUSD }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        automatic = c.lossy(Bool.self, .automatic)
        maxAttempts = c.lossyInt(.maxAttempts)
        maxCostUSD = c.lossyDouble(.maxCostUSD)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(automatic, forKey: .automatic)
        try c.encodeIfPresent(maxAttempts, forKey: .maxAttempts)
        try c.encodeIfPresent(maxCostUSD, forKey: .maxCostUSD)
    }
    public var resolvedAutomatic: Bool { automatic ?? true }
    public var resolvedMaxAttempts: Int { min(5, max(1, maxAttempts ?? 2)) }
    public var resolvedMaxCostUSD: Double { maxCostUSD ?? 1 }
}
