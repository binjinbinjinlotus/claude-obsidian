import Foundation

// v8 (2026-10-05): Review after Approve (spec approval-and-review.md → "After you approve"). The
// steps until every approved file is in the knowledge base, read from the batch's live-log steps
// (start-k, apply-k, added-k, actions) with the job as the fallback. UI-free.

public struct ApplyTimeline: Equatable, Sendable {
    public enum Stage: String, Sendable, CaseIterable { case approved, starting, applying, applied, finding, done }

    /// The step running now (done = every step finished).
    public var stage: Stage
    /// The step that failed: starting, applying or finding (finding is a follow-up; the batch is still added).
    public var failedAt: Stage?
    /// The core applies it itself (labels, runners without tool permissions): no AI step.
    public var core: Bool
    public var runner: String
    public var vault: String
    public var sources: String
    public var changes: String
    public var added: String
    public var operation: String
    public var actions: String
    public var error: String
    public var help: String
    /// Time of each shown row, in order (approved, starting?, applying, applied, finding).
    public var times: [Date?]

    /// review-queue.md: another batch changed the same pages first; the plan is being rebuilt (never a failure).
    public var updating = false
    public var isFailed: Bool { !updating && failedAt != nil && failedAt != .finding }
    public var isAdded: Bool { !isFailed && [.applied, .finding, .done].contains(stage) }
    public var isRunning: Bool { !isFailed && [.approved, .starting, .applying].contains(stage) }

    public init(stage: Stage, failedAt: Stage? = nil, core: Bool = false, runner: String = "Claude", vault: String = "",
                sources: String = "", changes: String = "", added: String = "", operation: String = "", actions: String = "",
                error: String = "", help: String = "", times: [Date?] = []) {
        self.stage = stage; self.failedAt = failedAt; self.core = core; self.runner = runner; self.vault = vault
        self.sources = sources; self.changes = changes; self.added = added; self.operation = operation; self.actions = actions
        self.error = error; self.help = help; self.times = times
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String { n == 1 ? "1 \(one)" : "\(n) \(many ?? one + "s")" }

    public static func runnerName(_ id: String?) -> String {
        switch id ?? "claude-code" {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        default: return "The AI"
        }
    }

    /// "Found 5 actions to confirm", from the job's Finding actions result.
    public static func actionsWords(_ a: JobActionsSummary?) -> String {
        guard let a else { return "Finding actions in these notes" }
        switch a.status {
        case "done": return a.found > 0 ? "Found \(plural(a.found, "action")) to confirm" : "Found no actions"
        case "failed": return "Couldn’t look for actions this time · try again from Actions"
        case "skipped": return "Didn’t look for actions"
        default: return "Finding actions in these notes"
        }
    }

    /// The timeline of the latest approval, or nil when the job was not approved (or Done was pressed).
    public static func make(job: Job, steps: [JobStep]) -> ApplyTimeline? {
        guard let change = job.approvedChange else { return nil }
        let vault = URL(fileURLWithPath: job.vaultPath).lastPathComponent
        let applies = steps.filter { $0.phase == "apply" && $0.verb == "apply" && $0.id.hasPrefix("apply-") }
        let apply = applies.last(where: { $0.at.addingTimeInterval(5) >= change.at })
        let k = apply.map { String($0.id.dropFirst("apply-".count)) }
        let start = k.flatMap { key in steps.first { $0.id == "start-\(key)" } }
        let addedStep = k.flatMap { key in steps.first { $0.id == "added-\(key)" } }
        let approvedStep = steps.last { $0.verb == "answer" && $0.text == "You approved" }
        let actionsStep = steps.first { $0.id == "actions" }
        let core = apply != nil ? start == nil : !(job.runnerID == nil || job.runnerID == "claude-code" || job.runnerID == "codex") || job.kind == "labels"
        let named = start?.text.range(of: " is starting").map { String(start!.text[..<$0.lowerBound]) }
        let runner = named.flatMap { $0.isEmpty || $0.contains(" ") && $0 != "The AI" ? nil : $0 } ?? runnerName(job.runnerID)
        let n = change.sourcesApproved ?? job.approval?.sources?.filter { !$0.removed }.count ?? job.sources.count
        var t = ApplyTimeline(stage: .starting, core: core, runner: runner, vault: vault,
                              sources: n > 0 ? plural(n, "source") : "",
                              changes: plural(change.changes, "change"), added: change.addedWords,
                              operation: change.operationID, actions: actionsWords(job.actionsFound))
        let actionsTime = actionsStep?.endedAt ?? actionsStep?.at
        t.times = [approvedStep?.endedAt ?? change.at] + (core ? [] : [start?.at]) + [apply?.at, addedStep?.at, actionsTime]
        if job.refresh != nil {
            t.updating = true
            t.stage = .applying
            t.help = "Another batch changed the same pages first. This batch’s session is rebuilding the plan against the pages as they are now."
            return t
        }
        // Applied in Terminal after an attempt here failed: the vault's journal is the evidence, not the old steps.
        let outside = change.appliedOutside && job.state == .completed && job.operationID == change.operationID
        let addedNow = outside || addedStep != nil || (job.state == .completed && job.operationID == change.operationID && apply == nil)
        if !outside, let start, start.state == "failed" {
            t.failedAt = .starting; t.stage = .starting; t.error = start.text; t.help = start.hint ?? ""
            return t
        }
        if !outside, let apply, apply.state == "failed" {
            t.failedAt = .applying; t.stage = .applying; t.error = apply.text; t.help = apply.hint ?? ""
            return t
        }
        if addedNow {
            switch job.actionsFound?.status {
            case "finding"?: t.stage = .finding
            case "failed"?: t.stage = .finding; t.failedAt = .finding; t.error = t.actions
            case "done"?, "skipped"?: t.stage = .done
            default: t.stage = job.kind == "ingest" && job.state == .running ? .finding : (job.kind == "ingest" && job.changedPaths.isEmpty ? .applied : .done)
                if job.kind != "ingest" { t.actions = "Didn’t look for actions" }
            }
            return t
        }
        if let apply, apply.state == "running" { t.stage = .applying; return t }
        if let start, start.state == "running" { t.stage = .starting; return t }
        if apply != nil, start?.state == "done" { t.stage = .applying; return t }
        if job.state == .running { t.stage = core ? .applying : .starting; return t }
        // Steps not loaded yet (or not kept): the job alone.
        if job.state == .completed {
            t.failedAt = .applying; t.stage = .applying
            t.error = "Nothing recorded as applied: \(runner) didn’t report the approved change"
            t.help = "Open Show steps to see what happened. Nothing is listed as added until the vault core confirms it."
            return t
        }
        return nil
    }

    /// Review shows a plan other than the one approved: Claude rebuilt it after the apply didn't go in
    /// (exit 75), or the owner fixed it in the conversation. The old "Not added" card is history then.
    /// Older jobs have no stored hash: the "Approved <op> (<first 12>…)" turn gives it.
    public static func planReplaced(_ job: Job) -> Bool {
        guard job.state == .awaitingApproval, let current = job.approval?.plan?.approvalSHA256, !current.isEmpty,
              let change = job.approvedChange else { return false }
        if let approved = change.approvalSha256, !approved.isEmpty { return approved != current }
        guard let turn = job.turns.last(where: { $0.author == .user && $0.text.hasPrefix("Approved ") })?.text,
              let open = turn.firstIndex(of: "("), let close = turn[open...].firstIndex(of: "…") else { return false }
        let prefix = String(turn[turn.index(after: open)..<close])
        return prefix.count >= 8 && !current.hasPrefix(prefix)
    }

    /// The job's latest user turn was the approval (a reply after it starts something else).
    public static func approvalIsLatest(_ job: Job) -> Bool {
        guard job.approvedChange != nil else { return false }
        return job.turns.last(where: { $0.author == .user })?.text.hasPrefix("Approved") ?? true
    }

    /// The approved change is being added right now (Approve and Reject are gone; nothing needs the user).
    public static func isApplying(_ job: Job) -> Bool {
        job.state == .running && job.pendingPart == nil && approvalIsLatest(job)
    }

    /// Review keeps an approved batch until Done: while it is added, once it is, and when adding it failed.
    /// It never counts as needing the user (badges count awaitingApproval only) and never blocks a batch.
    public static func showsInReview(_ job: Job) -> Bool {
        // Batches only (decision 2026-10-05): a label confirmation leaves Review once applied, as before.
        guard job.kind == "ingest", job.approvedChange != nil, job.reviewDoneAt == nil, approvalIsLatest(job) else { return false }
        switch job.state {
        case .running: return job.pendingPart == nil
        case .completed, .failed, .cancelled: return true
        default: return false
        }
    }

    /// Review lists the batches waiting for the user (oldest first), then the approved ones not yet Done.
    public static func reviewList(_ jobs: [Job]) -> [Job] {
        let waiting = ReviewBatches.ordered(jobs.filter {
            $0.state == .awaitingApproval || ($0.state == .running && ($0.pendingPart != nil || $0.refresh != nil))
                // review-queue.md: a batch whose run stopped stays here while recovery works on it, or gave up.
                || ($0.state == .failed && RecoveryText.shows($0) && !showsInReview($0))
        })
        let approved = jobs.filter(showsInReview).sorted { ($0.approvedChange?.at ?? $0.updatedAt, $0.id) < ($1.approvedChange?.at ?? $1.updatedAt, $1.id) }
        return waiting + approved
    }

    /// A tab's subtitle for an approved batch: "adding…", "added", "not added".
    public static func tabSubtitle(_ job: Job) -> String? {
        guard showsInReview(job) else { return nil }
        if job.state == .running { return "adding…" }
        return job.state == .completed && job.operationID == job.approvedChange?.operationID ? "added" : "not added"
    }

    /// Row title as drawn: "Claude is starting: resuming this batch’s session", "Added to Research: …".
    public var rows: [(stage: Stage, state: String, text: String, count: String)] {
        let order: [Stage] = [.approved, .starting, .applying, .applied, .finding, .done]
        let at = order.firstIndex(of: failedAt ?? stage) ?? 0
        let words: [Stage: (String, String, String)] = [
            .approved: ("You approved", "You approved", sources),
            .starting: ("\(runner) is starting: resuming this batch’s session", "\(runner) resumed this batch’s session", ""),
            .applying: ("Applying \(changes) through the vault core", "Applied through the vault core", operation),
            .applied: ("Add to \(vault)", "Added to \(vault): \(added)", ""),
            .finding: ("Finding actions in these notes", actions, ""),
        ]
        let shown: [Stage] = [.approved, .starting, .applying, .applied, .finding].filter { !(core && $0 == .starting) }
        return shown.map { k in
            let n = order.firstIndex(of: k)!
            let failed = failedAt == k
            let state: String = failed ? (k == .finding ? "waiting" : "failed")
                : (n < at || stage == .done) ? "done" : n == at ? (k == .applied ? "done" : "running") : "waiting"
            let w = words[k]!
            let text = failed ? error : (state == "done" ? w.1 : w.0)
            return (k, state, text, (state == "done" || k == .approved) ? w.2 : "")
        }
    }

    public var heading: String {
        updating ? "Updating against the latest pages" : isFailed ? "Not added to your vault" : isAdded ? "Added to \(vault)" : "Adding to \(vault)…"
    }
}
