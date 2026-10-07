import XCTest
@testable import DistillKit

/// Review queue (review-queue.md): the job fields decode leniently, and the blocked card's words never show a command.
final class ReviewQueueTests: XCTestCase {
    func testJobFieldsDecodeLenientlyAndRoundTrip() throws {
        let json = #"""
        {"id":"j1","vaultPath":"/v","files":[],"state":"awaitingApproval","createdAt":"2026-10-05T10:00:00Z",
         "queuedApply":{"at":"2026-10-05T10:01:00Z","order":1759658460000,"planSha256":"abc","bundlePath":"/v/b.json","labels":"confirm","carries":"confirm"},
         "refresh":{"since":"2026-10-05T10:02:00Z","reason":"stale","stalePaths":["wiki/log.md"],"approved":true,"attempt":1},
         "recovery":{"state":"gaveUp","signature":"denial","denialAnswers":2,"summary":"Claude wanted to compare the claim ledger with this batch's copy.",
                     "attempts":[{"at":"2026-10-05T10:03:00Z","by":"rule","fix":"answer_denial","result":"failed","costUSD":0},{"at":"bad"}]}}
        """#
        let job = try JSONDecoder.core.decode(Job.self, from: Data(json.utf8))
        XCTAssertTrue(job.queuedApply?.waitingToApply ?? false)
        XCTAssertEqual(job.refresh?.stalePaths, ["wiki/log.md"])
        XCTAssertEqual(job.recovery?.state, .gaveUp)
        XCTAssertEqual(job.recovery?.denialAnswers, 2)
        XCTAssertEqual(job.recovery?.attempts.count, 2)
        let again = try JSONDecoder.core.decode(Job.self, from: JSONEncoder.core.encode(job))
        XCTAssertEqual(again.recovery, job.recovery)
        XCTAssertEqual(again.queuedApply, job.queuedApply)

        let old = try JSONDecoder.core.decode(Job.self, from: Data(#"{"id":"j0","vaultPath":"/v","recovery":"nope","queuedApply":{"order":"x"}}"#.utf8))
        XCTAssertNil(old.recovery)
        XCTAssertNotNil(old.queuedApply, "a wrong field inside takes its default")
    }

    func testBlockedWordsAreTheCoresSentenceOrAPlainFallback() throws {
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .awaitingApproval)
        XCTAssertEqual(BlockedText.summary(job), "Claude was blocked from running a command it wanted, and stopped.")
        XCTAssertEqual(BlockedText.heading(job), "Claude got stuck")
        job.recovery = RecoveryState(state: .gaveUp, signature: "denial", summary: "Claude wanted to read the vault log.")
        XCTAssertEqual(BlockedText.summary(job), "Claude wanted to read the vault log.")
        job.recovery?.state = .running
        XCTAssertEqual(BlockedText.heading(job), "Claude got stuck", "nothing works on it: never Recovering")
        job.state = .running
        XCTAssertEqual(BlockedText.heading(job), "Recovering", "the rule's turn runs")
    }

    func testRecoveryWordsForOtherProblems() throws {
        let json = #"{"state":"waiting","signature":"plan-error","waitUntil":"2026-10-06T14:05:00Z","attempts":[{"at":"2026-10-06T14:03:00Z","by":"rule","fix":"rebuild_in_session","result":"failed","costUSD":0},{"at":"2026-10-06T14:04:00Z","by":"agent","model":"opus","fix":"rebuild_in_session","result":"failed","costUSD":0.04}]}"#
        var r = try JSONDecoder.core.decode(RecoveryState.self, from: Data(json.utf8))
        XCTAssertEqual(r.waitUntil, CoreDate.parse("2026-10-06T14:05:00Z"))
        XCTAssertEqual(try JSONDecoder.core.decode(RecoveryState.self, from: JSONEncoder.core.encode(r)), r)
        XCTAssertEqual(RecoveryText.heading(r, timeZone: TimeZone(identifier: "UTC")!), "Recovering · next try at 2:05 PM")
        XCTAssertEqual(RecoveryText.summary(r), "The vault core couldn’t check this plan.")
        XCTAssertEqual(RecoveryText.tried(r), "Tried twice · last by Opus · $0.04.")
        r.state = .running
        XCTAssertEqual(RecoveryText.heading(r), "Recovering · Opus · asking Claude to rebuild the plan")
        r.state = .gaveUp
        r.summary = "The AI run stopped with an error: the AI service was busy."
        XCTAssertEqual(RecoveryText.heading(r), "Distill couldn’t fix this")
        XCTAssertEqual(RecoveryText.summary(r), "The AI run stopped with an error: the AI service was busy.")

        var job = Job(id: "j", vaultPath: "/v", files: [], state: .failed)
        job.recovery = r
        XCTAssertTrue(RecoveryText.shows(job), "a batch whose run stopped shows its recovery")
        XCTAssertTrue(ReviewQueueText.needsOwner(job), "Couldn't fix needs the owner")
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .couldntFix)
        XCTAssertEqual(ApplyTimeline.reviewList([job]).map(\.id), ["j"])
        XCTAssertFalse(RecoveryText.offersNewSession(job))
        job.recovery?.proposal = "new_session"
        XCTAssertTrue(RecoveryText.offersNewSession(job), "recovery suggests it; the owner still confirms")
        XCTAssertEqual(SessionReplaceText.heading(place: "batch", reason: "recovery"), "Recovery suggests a new session")
        job.sessionUnavailable = SessionUnavailable(place: "batch", reason: "missing")
        XCTAssertFalse(RecoveryText.offersNewSession(job), "the gone-session confirmation already shows")
        job.sessionUnavailable = nil
        job.recovery?.signature = "denial"
        XCTAssertTrue(RecoveryText.shows(job), "no blocked calls left to show: this card")
        job.approval = ApprovalRequest(summary: "", denials: [PermissionDenial(toolName: "Bash", input: ["command": .string("ls")])])
        XCTAssertFalse(RecoveryText.shows(job), "blocked commands have their own card")
        job.recovery = nil
        XCTAssertTrue(ApplyTimeline.reviewList([job]).isEmpty)
    }

    /// 2026-10-06, the owner's stuck batch: a rule's recovery left `running` after its turn ended with questions.
    func testRecoveringOnlyWhileSomethingWorksOnIt() {
        var job = Job(id: "j", vaultPath: "/v", files: ["inbox/Sync.md"], state: .awaitingApproval)
        job.approval = ApprovalRequest(summary: "Still blocked.", questions: ["Can you clear the lock?"])
        job.recovery = RecoveryState(state: .running, signature: "denial", attempts: [RecoveryAttempt(at: Date(), fix: "answer_denial")], denialAnswers: 1)
        XCTAssertFalse(RecoveryText.isActive(job), "nothing in flight")
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .needsYou)
        XCTAssertTrue(ReviewQueueText.needsOwner(job))
        XCTAssertEqual(BlockedText.heading(job), "Claude got stuck")
        XCTAssertTrue(RecoveryText.shows(job), "no blocked calls left: the recovery card shows")

        job.state = .running
        XCTAssertTrue(RecoveryText.isActive(job), "the rule's turn runs")
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .recovering)
        job.state = .awaitingApproval
        job.recovery?.attempts.append(RecoveryAttempt(at: Date(), by: "agent", model: "opus", fix: "give_up"))
        XCTAssertTrue(RecoveryText.isActive(job), "an agent attempt runs")
        XCTAssertFalse(ReviewQueueText.needsOwner(job))
        job.recovery = RecoveryState(state: .waiting, signature: "plan-error", waitUntil: Date())
        XCTAssertTrue(RecoveryText.isActive(job))
        job.recovery?.state = .gaveUp
        XCTAssertFalse(RecoveryText.isActive(job))
    }

    func testRecoveryProposalsAndTheirFields() throws {
        let json = #"{"state":"gaveUp","signature":"stale-again","proposal":"split_batch","groups":[["wiki/sources/a.md"],["wiki/sources/b.md"],[]],"approvedSha256":"abc","wake":"retry","attempts":[]}"#
        let r = try JSONDecoder.core.decode(RecoveryState.self, from: Data(json.utf8))
        XCTAssertEqual(r.groups, [["wiki/sources/a.md"], ["wiki/sources/b.md"]], "an empty group is dropped")
        XCTAssertEqual(r.approvedSha256, "abc")
        XCTAssertEqual(try JSONDecoder.core.decode(RecoveryState.self, from: JSONEncoder.core.encode(r)), r)
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .awaitingApproval)
        job.recovery = r
        XCTAssertEqual(RecoveryText.splitGroup(job), ["wiki/sources/a.md"])
        job.recovery?.proposal = "discard_stale_part"
        XCTAssertNil(RecoveryText.splitGroup(job))
        XCTAssertFalse(RecoveryText.offersDiscard(job), "no rebuilt part waits: never offered (it would reject the batch)")
        job.recovery = RecoveryState(state: .running, signature: "lock", approvedSha256: "abc")
        job.queuedApply = QueuedApply(at: Date(), order: 1, planSha256: "abc")
        XCTAssertTrue(RecoveryText.isActive(job), "back in the queue under the approved hash")
    }

    func testAttemptRowsArePlainWordsNeverTheRawError() {
        let r = RecoveryState(state: .gaveUp, signature: "runner-failed", attempts: [
            RecoveryAttempt(at: Date(), fix: "rebuild_in_session", result: "failed", error: "Exited 1: API Error: 529 {\"type\":\"overloaded_error\"}"),
            RecoveryAttempt(at: Date(), by: "agent", model: "opus", fix: "wait_then_retry", result: "fixed", costUSD: 0.04),
            RecoveryAttempt(at: Date(), by: "agent", model: "claude-opus-4-1", fix: "made_up", result: "failed", error: "/Users/me/x.py"),
        ])
        let rows = RecoveryText.attemptRows(r)
        XCTAssertEqual(rows, ["Distill · asked Claude to rebuild the plan · didn’t help",
                              "Opus · waited, then tried your approved plan again · worked · $0.04",
                              "\(ModelChoice.shortName("claude-opus-4-1")) · tried something Distill doesn’t know · didn’t help"])
        XCTAssertFalse(rows.joined().contains("529") || rows.joined().contains("/Users"), "never the raw error")
        XCTAssertTrue(RecoveryText.rebuildReply.contains("needs_approval"))
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .awaitingApproval)
        job.recovery = RecoveryState(state: .gaveUp, signature: "session-gone", proposal: "new_session")
        XCTAssertFalse(RecoveryText.offersTryAgain(job), "session-gone goes on only through a new session")
        job.recovery?.signature = "lock"
        XCTAssertTrue(RecoveryText.offersTryAgain(job))
        XCTAssertTrue(RecoveryText.offersRebuild(job))
        job.kind = "labels"
        XCTAssertFalse(RecoveryText.offersRebuild(job), "a labels confirmation has no session to reply to")
    }

    func testQueueWordsAndTheBadgeRule() {
        let now = Date()
        var a = Job(id: "a", vaultPath: "/v", files: ["inbox/Product sync.md"], state: .running)
        a.approvedChange = try? JSONDecoder.core.decode(ApprovedChange.self, from: Data(#"{"at":"2026-10-05T10:00:00Z","operationID":"op-a","changes":3}"#.utf8))
        a.turns = [TurnRecord(date: now, author: .user, text: "Approved op-a (abc…)")]
        var b = Job(id: "b", vaultPath: "/v", files: ["inbox/Telus stand-up.md", "inbox/x.md"], state: .awaitingApproval)
        b.queuedApply = QueuedApply(at: now, order: 2, planSha256: "h")
        var c = Job(id: "c", vaultPath: "/v", files: ["inbox/c.md"], state: .awaitingApproval)
        XCTAssertEqual(ReviewQueueText.queuedLine(b, in: [a, b, c]), "Queued · applies after “Product sync”")
        XCTAssertEqual(ReviewQueueText.approveNote(c, in: [a, b, c]), "Applies after “Product sync”")
        XCTAssertEqual(ReviewQueueText.approveNote(c, in: [b, c]), "Applies after “Telus stand-up” +1", "an earlier approval goes first")
        XCTAssertNil(ReviewQueueText.approveNote(c, in: [c]))
        XCTAssertFalse(ReviewQueueText.needsOwner(b), "waiting to apply")
        XCTAssertTrue(ReviewQueueText.needsOwner(c))
        b.queuedApply?.planSha256 = nil
        XCTAssertTrue(ReviewQueueText.needsOwner(b), "rebuilt: needs the owner once more")
        c.refresh = RefreshState(since: now)
        XCTAssertFalse(ReviewQueueText.needsOwner(c), "being rebuilt")
        c.refresh = nil
        c.recovery = RecoveryState(state: .running, signature: "denial", attempts: [RecoveryAttempt(at: now, by: "agent", fix: "give_up")])
        XCTAssertFalse(ReviewQueueText.needsOwner(c), "recovering")
    }

    func testSinceApprovedLines() {
        let s = SinceApproved(content: ["wiki/concepts/retry-policy.md"], added: ["wiki/entities/auth.md"], dropped: [],
                              bookkeeping: ["wiki/log.md", "wiki/hot.md", "wiki/meta/ledgers/claim-ledger.json", "wiki/meta/ledgers/source-ledger.json"])
        XCTAssertEqual(ReviewQueueText.sinceLines(s), ["Your source pages: unchanged", "2 pages differ: retry policy, auth",
                                                        "Bookkeeping written again: log, hot cache, 2 ledgers"])
    }

    func testARefreshIsUpdatingNeverAFailure() throws {
        var job = Job(id: "j", vaultPath: "/v/Research", files: [], state: .running)
        job.approvedChange = try JSONDecoder.core.decode(ApprovedChange.self, from: Data(#"{"at":"2026-10-05T10:00:00Z","operationID":"op","changes":3}"#.utf8))
        job.turns = [TurnRecord(date: Date(), author: .user, text: "Approved op (abc…)")]
        job.refresh = RefreshState(since: Date(), stalePaths: ["wiki/log.md"], approved: true)
        let failed = JobStep(id: "apply-1", at: Date(), phase: "apply", state: "failed", verb: "apply", text: "Not applied")
        let t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: [failed]))
        XCTAssertFalse(t.isFailed)
        XCTAssertEqual(t.heading, "Updating against the latest pages")
    }

    func testEachProblemHasItsOwnSentence() {
        let words = [
            "stale-again": "Your vault keeps changing under this plan: it was rebuilt for the latest pages and is out of date again.",
            "plan-error": "The vault core couldn’t check this plan.",
            "runner-failed": "The AI run stopped with an error.",
            "denial": "Distill answered Claude’s blocked command, but Claude stopped with questions instead of a plan.",
            "lock": "Another app kept your vault locked, so your approved change couldn’t be applied yet. Approve again when it is closed.",
            "session-gone": "This batch’s AI session isn’t available anymore, so your approved change can’t be applied in it.",
            "brand-new": "Distill couldn’t get this batch going again by itself.",
        ]
        for (signature, sentence) in words {
            XCTAssertEqual(RecoveryText.summary(RecoveryState(state: .running, signature: signature)), sentence, signature)
            // An empty core sentence is no sentence.
            XCTAssertEqual(RecoveryText.summary(RecoveryState(state: .running, signature: signature, summary: "")), sentence, signature)
        }
    }

    func testDetailLineUnderTheNotice() {
        var r = RecoveryState(state: .waiting, signature: "plan-error")
        XCTAssertEqual(RecoveryText.detail(r), "The vault core couldn’t check this plan. Distill waits a minute between tries, then looks again.")
        r.state = .running
        XCTAssertEqual(RecoveryText.detail(r), "The vault core couldn’t check this plan. Nothing needs you while Distill works on it.")
        r.summary = "The lock is held by Obsidian."
        XCTAssertEqual(RecoveryText.detail(r), "The lock is held by Obsidian. Nothing needs you while Distill works on it.")
    }

    func testHeadingsAndWhatRecoveryIsDoing() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(RecoveryText.heading(RecoveryState(state: .waiting, signature: "lock"), timeZone: utc), "Recovering · waiting a minute")
        XCTAssertEqual(RecoveryText.heading(RecoveryState(state: .fixed, signature: "lock")), "Fixed")
        XCTAssertEqual(RecoveryText.heading(RecoveryState(state: .gaveUp, signature: "lock")), "Distill couldn’t fix this")
        XCTAssertEqual(RecoveryText.heading(RecoveryState(state: .waiting, signature: "lock", waitUntil: Date(timeIntervalSince1970: 1_791_300_600)),
                                            timeZone: TimeZone(identifier: "America/Los_Angeles")!), "Recovering · next try at 8:30 AM")
        func doing(_ signature: String, _ attempts: [RecoveryAttempt]) -> String {
            RecoveryText.doing(RecoveryState(state: .running, signature: signature, attempts: attempts))
        }
        let rule = RecoveryAttempt(at: Date(), fix: "rebuild_in_session")
        let agent = RecoveryAttempt(at: Date(), by: "agent", model: "claude-sonnet-5-5", fix: "rebuild_in_session")
        let anonymous = RecoveryAttempt(at: Date(), by: "agent", fix: "answer_denial")
        XCTAssertEqual(doing("stale-again", []), "rebuilding against the latest pages")
        XCTAssertEqual(doing("stale-again", [agent]), "Sonnet · rebuilding against the latest pages")
        XCTAssertEqual(doing("runner-failed", [rule]), "asking Claude to continue")
        XCTAssertEqual(doing("plan-error", [rule]), "asking Claude to rebuild the plan")
        XCTAssertEqual(doing("plan-error", [agent]), "Sonnet · asking Claude to rebuild the plan")
        XCTAssertEqual(doing("denial", [anonymous]), "the Recovery model · looking at the problem")
        XCTAssertEqual(doing("runner-failed", []), "looking at the problem")
        XCTAssertEqual(RecoveryText.heading(RecoveryState(state: .running, signature: "lock")), "Recovering · looking at the problem")
    }

    func testTriedCountsAndCost() {
        XCTAssertNil(RecoveryText.tried(RecoveryState(state: .running, signature: "lock")))
        let rule = RecoveryAttempt(at: Date(), fix: "wait_then_retry")
        XCTAssertEqual(RecoveryText.tried(RecoveryState(state: .running, signature: "lock", attempts: [rule])), "Tried once.")
        let three = [rule, RecoveryAttempt(at: Date(), by: "agent", model: "opus", fix: "x", costUSD: 0.5),
                     RecoveryAttempt(at: Date(), by: "rule", fix: "y", costUSD: 0.25)]
        // The last agent attempt names the model, even when a rule tried after it; costs add up.
        XCTAssertEqual(RecoveryText.tried(RecoveryState(state: .running, signature: "lock", attempts: three)), "Tried 3 times · last by Opus · $0.75.")
        XCTAssertEqual(RecoveryState(state: .running, signature: "lock", attempts: three).costUSD, 0.75)
        let unnamed = [RecoveryAttempt(at: Date(), by: "agent", fix: "x"), rule]
        XCTAssertEqual(RecoveryText.tried(RecoveryState(state: .running, signature: "lock", attempts: unnamed)), "Tried twice · last by the Recovery model.")
        XCTAssertEqual(RecoveryText.attemptRows(RecoveryState(state: .running, signature: "lock", attempts: [RecoveryAttempt(at: Date(), by: "agent", fix: "give_up", result: "running")])),
                       ["the Recovery model · handed it to you · in progress"])
    }

    func testEveryFixHasPlainWords() {
        let fixes = ["answer_denial": "told Claude to read the files instead", "rebuild_in_session": "asked Claude to rebuild the plan",
                     "reinspect_same_bundle": "checked your approved plan again", "wait_then_retry": "waited, then tried your approved plan again",
                     "split_batch": "suggested splitting the batch", "discard_stale_part": "suggested discarding the rebuilt part",
                     "new_session": "suggested a new session", "give_up": "handed it to you", "": "tried something Distill doesn’t know"]
        for (fix, words) in fixes { XCTAssertEqual(RecoveryText.fixWords(fix), words, fix) }
        XCTAssertEqual(RecoveryText.sentenceCase("handed it to you"), "Handed it to you")
        XCTAssertEqual(RecoveryText.sentenceCase(""), "")
        XCTAssertTrue(RecoveryText.newSessionReply.hasPrefix("Continue this batch in a new session"))
    }

    func testTheCardShowsOnlyForAStoppedOrWaitingBatch() {
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .running)
        XCTAssertFalse(RecoveryText.shows(job), "no recovery")
        job.recovery = RecoveryState(state: .gaveUp, signature: "lock")
        XCTAssertFalse(RecoveryText.shows(job), "a running batch")
        job.state = .awaitingApproval
        XCTAssertTrue(RecoveryText.shows(job))
        job.recovery?.state = .fixed
        XCTAssertFalse(RecoveryText.shows(job), "fixed: nothing to show")
        job.recovery?.state = .gaveUp
        job.state = .completed
        XCTAssertFalse(RecoveryText.shows(job))
        // A denial with no blocked calls left shows here; other signatures ignore the calls.
        job.state = .awaitingApproval
        job.approval = ApprovalRequest(summary: "", denials: [PermissionDenial(toolName: "Bash", input: [:])])
        XCTAssertTrue(RecoveryText.shows(job))
        XCTAssertFalse(RecoveryText.isActive(Job(id: "n", vaultPath: "/v", files: [])), "no recovery: not active")
        job.recovery?.state = .fixed
        XCTAssertFalse(RecoveryText.isActive(job))
    }

    func testANewSessionIsOfferedOnlyWhenRecoveryGaveUpAndSuggestsIt() {
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .awaitingApproval)
        XCTAssertFalse(RecoveryText.offersNewSession(job))
        job.recovery = RecoveryState(state: .running, signature: "session-gone", proposal: "new_session")
        XCTAssertFalse(RecoveryText.offersNewSession(job), "still working")
        XCTAssertTrue(job.recovery!.suggestsNewSession)
        job.recovery?.state = .gaveUp
        XCTAssertTrue(RecoveryText.offersNewSession(job))
        job.recovery?.proposal = "split_batch"
        XCTAssertFalse(job.recovery!.suggestsNewSession)
        XCTAssertFalse(RecoveryText.offersNewSession(job))
        XCTAssertTrue(RecoveryText.offersTryAgain(Job(id: "x", vaultPath: "/v", files: [])), "no recovery: Try again stays")
    }

    func testSplitAndDiscardNeedTheirExactState() {
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .awaitingApproval)
        XCTAssertNil(RecoveryText.splitGroup(job))
        job.recovery = RecoveryState(state: .gaveUp, signature: "stale-again", proposal: "split_batch", groups: [["a.md", "b.md"], ["c.md"]])
        XCTAssertEqual(RecoveryText.splitGroup(job), ["a.md", "b.md"])
        job.recovery?.groups = []
        XCTAssertNil(RecoveryText.splitGroup(job), "no groups")
        job.recovery?.groups = [[], ["c.md"]]
        XCTAssertNil(RecoveryText.splitGroup(job), "an empty first group")
        job.recovery?.groups = [["a.md"]]
        job.recovery?.state = .running
        XCTAssertNil(RecoveryText.splitGroup(job), "still working")
        job.recovery?.state = .gaveUp
        job.state = .failed
        XCTAssertNil(RecoveryText.splitGroup(job), "only while it waits for the owner")

        var part = Job(id: "p", vaultPath: "/v", files: [], state: .awaitingApproval)
        part.recovery = RecoveryState(state: .gaveUp, signature: "stale-again", proposal: "discard_stale_part")
        part.pendingPart = PendingPart(reason: .stale)
        part.approval = ApprovalRequest(summary: "", rebuilt: RebuiltPlan(reason: .stale))
        XCTAssertTrue(RecoveryText.offersDiscard(part))
        part.approval?.needsRebuild = true
        XCTAssertFalse(RecoveryText.offersDiscard(part), "the part still needs rebuilding")
        part.approval?.needsRebuild = false
        XCTAssertTrue(RecoveryText.offersDiscard(part))
        part.approval?.rebuilt = nil
        XCTAssertFalse(RecoveryText.offersDiscard(part), "no rebuilt part")
        part.approval?.rebuilt = RebuiltPlan(reason: .stale)
        part.pendingPart = nil
        XCTAssertFalse(RecoveryText.offersDiscard(part), "no pending part")
        part.pendingPart = PendingPart(reason: .stale)
        part.recovery?.state = .running
        XCTAssertFalse(RecoveryText.offersDiscard(part))
        part.recovery?.state = .gaveUp
        part.recovery?.proposal = "split_batch"
        XCTAssertFalse(RecoveryText.offersDiscard(part))
        part.recovery?.proposal = "discard_stale_part"
        part.state = .running
        XCTAssertFalse(RecoveryText.offersDiscard(part))
    }

    func testRecoveryFieldsDecodeWithDefaults() throws {
        let r = try JSONDecoder.core.decode(RecoveryState.self, from: Data(#"{"attempts":[{}],"groups":"x","denialAnswers":"two"}"#.utf8))
        XCTAssertEqual(r.state, .gaveUp, "an unreadable state never claims to be working")
        XCTAssertEqual(r.signature, "")
        XCTAssertEqual(r.denialAnswers, 0)
        XCTAssertEqual(r.groups, [])
        XCTAssertNil(r.waitUntil)
        let a = try XCTUnwrap(r.attempts.first)
        XCTAssertEqual(a.by, "rule")
        XCTAssertEqual(a.fix, "")
        XCTAssertEqual(a.result, "failed", "an attempt of unknown result didn't help")
        XCTAssertEqual(a.costUSD, 0)
        XCTAssertEqual(a.at, .distantPast)
        // Encoding leaves out what isn't there.
        let json = try XCTUnwrap(String(data: JSONEncoder.core.encode(RecoveryState(state: .running, signature: "lock")), encoding: .utf8))
        XCTAssertFalse(json.contains("waitUntil") || json.contains("groups") || json.contains("summary") || json.contains("wake"), json)
        let attempt = RecoveryAttempt(at: Date(timeIntervalSince1970: 0), by: "agent", model: "opus", fix: "x", diagnosis: "d", result: "fixed", error: "e", costUSD: 0.1)
        XCTAssertEqual(try JSONDecoder.core.decode(RecoveryAttempt.self, from: JSONEncoder.core.encode(attempt)), attempt)
    }

    func testQueueAndRefreshDecodeWithDefaults() throws {
        let q = try JSONDecoder.core.decode(QueuedApply.self, from: Data(#"{"order":"x","planSha256":7}"#.utf8))
        XCTAssertEqual(q, QueuedApply(at: .distantPast, order: 0, planSha256: nil, bundlePath: ""))
        XCTAssertFalse(q.waitingToApply)
        let full = QueuedApply(at: Date(timeIntervalSince1970: 100), order: 2.5, planSha256: "h", bundlePath: "/b.json")
        XCTAssertEqual(try JSONDecoder.core.decode(QueuedApply.self, from: JSONEncoder.core.encode(full)), full)
        XCTAssertFalse(try XCTUnwrap(String(data: JSONEncoder.core.encode(q), encoding: .utf8)).contains("planSha256"))
        let r = try JSONDecoder.core.decode(RefreshState.self, from: Data(#"{"stalePaths":"wiki/a.md","approved":"yes"}"#.utf8))
        XCTAssertEqual(r, RefreshState(since: .distantPast, stalePaths: [], approved: false))
        let refresh = RefreshState(since: Date(timeIntervalSince1970: 100), stalePaths: ["a.md"], approved: true)
        XCTAssertEqual(try JSONDecoder.core.decode(RefreshState.self, from: JSONEncoder.core.encode(refresh)), refresh)
    }

    func testSinceApprovedDecodesLeniently() throws {
        let s = try JSONDecoder.core.decode(SinceApproved.self, from: Data(#"{"content":["a.md",3],"added":"b.md","bookkeeping":["wiki/log.md"],"extra":1}"#.utf8))
        XCTAssertEqual(s, SinceApproved(content: ["a.md"], added: [], dropped: [], bookkeeping: ["wiki/log.md"]))
        XCTAssertEqual(try JSONDecoder.core.decode(SinceApproved.self, from: Data("{}".utf8)), SinceApproved())
    }

    func testSinceApprovedLineShapes() {
        XCTAssertEqual(ReviewQueueText.sinceLines(SinceApproved()), ["Your source pages: unchanged"])
        XCTAssertEqual(ReviewQueueText.sinceLines(SinceApproved(added: ["wiki/entities/tea-club.md"], dropped: ["x.md"])),
                       ["Your source pages: unchanged", "1 page differs: tea club", "1 page is no longer changed"])
        let five = SinceApproved(content: ["a.md", "b.md", "c.md"], added: ["d.md", "e.md"], dropped: ["x.md", "y.md"])
        XCTAssertEqual(ReviewQueueText.sinceLines(five), ["Your source pages: unchanged", "5 pages differ: a, b, c, d, …", "2 pages are no longer changed"])
        let four = SinceApproved(content: ["a.md", "b.md", "c.md", "d.md"])
        XCTAssertEqual(ReviewQueueText.sinceLines(four)[1], "4 pages differ: a, b, c, d")
        let books = SinceApproved(bookkeeping: ["wiki/meta/x.json", "wiki/overview.md", "wiki/index.md", "wiki/hot.md", "wiki/hot.md", "wiki/log.md"])
        XCTAssertEqual(ReviewQueueText.sinceLines(books), ["Your source pages: unchanged", "Bookkeeping written again: log, 2 hot caches, index, overview, ledger"])
    }

    func testRecoveryPreferencesDefaultsAndBounds() throws {
        let none = RecoveryPreferences()
        XCTAssertTrue(none.resolvedAutomatic)
        XCTAssertEqual(none.resolvedMaxAttempts, 2)
        XCTAssertEqual(none.resolvedMaxCostUSD, 1)
        XCTAssertEqual(RecoveryPreferences(maxAttempts: 0).resolvedMaxAttempts, 1)
        XCTAssertEqual(RecoveryPreferences(maxAttempts: 9).resolvedMaxAttempts, 5)
        XCTAssertEqual(RecoveryPreferences(maxAttempts: 5).resolvedMaxAttempts, 5)
        XCTAssertEqual(RecoveryPreferences(maxAttempts: 1).resolvedMaxAttempts, 1)
        XCTAssertEqual(RecoveryPreferences(maxAttempts: 3).resolvedMaxAttempts, 3)
        XCTAssertFalse(RecoveryPreferences(automatic: false).resolvedAutomatic)
        XCTAssertEqual(RecoveryPreferences(maxCostUSD: 0.25).resolvedMaxCostUSD, 0.25)
        let p = try JSONDecoder.core.decode(RecoveryPreferences.self, from: Data(#"{"automatic":"no","maxAttempts":"3","maxCostUSD":2}"#.utf8))
        XCTAssertNil(p.automatic, "a wrong type is unset, never a guess")
        XCTAssertEqual(p.maxCostUSD, 2)
        // Only what the owner set is written.
        XCTAssertEqual(String(data: try JSONEncoder.core.encode(RecoveryPreferences()), encoding: .utf8), "{}")
        let set = RecoveryPreferences(automatic: false, maxAttempts: 4, maxCostUSD: 0.5)
        XCTAssertEqual(try JSONDecoder.core.decode(RecoveryPreferences.self, from: JSONEncoder.core.encode(set)), set)
    }

    func testAheadOnlyCountsTheSameVaultAndEarlierApprovals() {
        let now = Date()
        var mine = Job(id: "m", vaultPath: "/v", files: ["inbox/Mine.md"], state: .awaitingApproval)
        mine.queuedApply = QueuedApply(at: now, order: 5, planSha256: "h")
        var otherVault = Job(id: "o", vaultPath: "/w", files: ["inbox/Other.md"], state: .awaitingApproval)
        otherVault.queuedApply = QueuedApply(at: now, order: 1, planSha256: "h")
        var later = Job(id: "l", vaultPath: "/v", files: ["inbox/Later.md"], state: .awaitingApproval)
        later.queuedApply = QueuedApply(at: now, order: 9, planSha256: "h")
        var first = Job(id: "f", vaultPath: "/v", files: ["inbox/First.md"], state: .awaitingApproval)
        first.queuedApply = QueuedApply(at: now, order: 2, planSha256: "h")
        var second = Job(id: "s", vaultPath: "/v", files: ["inbox/Second.md"], state: .awaitingApproval)
        second.queuedApply = QueuedApply(at: now, order: 3, planSha256: "h")
        var rebuilding = Job(id: "r", vaultPath: "/v", files: ["inbox/Rebuilding.md"], state: .running)
        rebuilding.queuedApply = QueuedApply(at: now, order: 1)
        rebuilding.refresh = RefreshState(since: now)
        var done = Job(id: "d", vaultPath: "/v", files: ["inbox/Done.md"], state: .completed)
        done.queuedApply = QueuedApply(at: now, order: 0, planSha256: "h")
        XCTAssertEqual(ReviewQueueText.ahead(of: mine, in: [mine, otherVault, later, second, first])?.id, "f", "the earliest earlier approval")
        XCTAssertEqual(ReviewQueueText.ahead(of: mine, in: [mine, first, rebuilding])?.id, "r", "a plan being rebuilt keeps its place")
        XCTAssertNil(ReviewQueueText.ahead(of: mine, in: [mine, otherVault, later, done]))
        XCTAssertEqual(ReviewQueueText.queuedLine(mine, in: [mine, later]), "Queued · applies next")
        // Not queued at all: every queued approval in the vault goes first.
        let unqueued = Job(id: "u", vaultPath: "/v", files: [], state: .awaitingApproval)
        XCTAssertEqual(ReviewQueueText.ahead(of: unqueued, in: [unqueued, later, second])?.id, "s")
        XCTAssertEqual(ReviewQueueText.shortName(unqueued), "u", "no files: the id")
        XCTAssertEqual(ReviewQueueText.shortName(Job(id: "x", vaultPath: "/v", files: ["inbox/2026-10-05.md"])), "“2026-10-05”", "nothing readable: the plain name")
    }

    func testABatchApplyingNowGoesFirstOnlyWhileItsApprovalIsLatest() throws {
        var applying = Job(id: "a", vaultPath: "/v", files: ["inbox/Applying.md"], state: .running)
        applying.approvedChange = ApprovedChange(operationID: "op", changes: 1)
        applying.turns = [TurnRecord(date: Date(), author: .user, text: "Approved op (abc…)")]
        var earlier = Job(id: "e", vaultPath: "/v", files: ["inbox/Earlier.md"], state: .awaitingApproval)
        earlier.queuedApply = QueuedApply(at: Date(), order: 1, planSha256: "h")
        let mine = Job(id: "m", vaultPath: "/v", files: [], state: .awaitingApproval)
        XCTAssertEqual(ReviewQueueText.ahead(of: mine, in: [earlier, applying, mine])?.id, "a")
        var replied = applying
        replied.turns.append(TurnRecord(date: Date(), author: .user, text: "Also add the tea club page"))
        XCTAssertEqual(ReviewQueueText.ahead(of: mine, in: [earlier, replied, mine])?.id, "e", "a reply after the approval runs something else")
        var part = applying; part.pendingPart = PendingPart(reason: .partial)
        XCTAssertEqual(ReviewQueueText.ahead(of: mine, in: [earlier, part, mine])?.id, "e")
        var refreshing = applying; refreshing.refresh = RefreshState(since: Date())
        XCTAssertEqual(ReviewQueueText.ahead(of: mine, in: [earlier, refreshing, mine])?.id, "e")
        var unapproved = applying; unapproved.approvedChange = nil
        XCTAssertEqual(ReviewQueueText.ahead(of: mine, in: [earlier, unapproved, mine])?.id, "e")
        var elsewhere = applying; elsewhere.vaultPath = "/w"
        XCTAssertEqual(ReviewQueueText.ahead(of: mine, in: [earlier, elsewhere, mine])?.id, "e")
        // The batch itself never counts.
        XCTAssertNil(ReviewQueueText.ahead(of: applying, in: [applying]))
    }

    func testAsksAgainOnlyForARebuiltPlanTheOwnerHadQueued() {
        let plan = TransactionPlan(operationID: "op", operationType: "ingest", valid: true, changedPaths: [], approvalSHA256: "h")
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .awaitingApproval)
        job.approval = ApprovalRequest(summary: "", bundlePath: "/b", plan: plan)
        XCTAssertFalse(ReviewQueueText.asksAgain(job), "never queued")
        job.queuedApply = QueuedApply(at: Date(), order: 1)
        XCTAssertTrue(ReviewQueueText.asksAgain(job))
        job.queuedApply?.planSha256 = "h"
        XCTAssertFalse(ReviewQueueText.asksAgain(job), "still waiting to apply")
        job.queuedApply?.planSha256 = nil
        job.approval?.bundlePath = nil
        XCTAssertFalse(ReviewQueueText.asksAgain(job), "nothing to apply")
        job.approval?.bundlePath = "/b"
        job.state = .running
        XCTAssertFalse(ReviewQueueText.asksAgain(job))
    }

    func testNeedsOwnerForEachState() {
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .running)
        XCTAssertFalse(ReviewQueueText.needsOwner(job))
        job.state = .completed
        XCTAssertFalse(ReviewQueueText.needsOwner(job))
        job.state = .failed
        XCTAssertFalse(ReviewQueueText.needsOwner(job), "a plain failure isn't a badge")
        job.recovery = RecoveryState(state: .running, signature: "runner-failed")
        XCTAssertFalse(ReviewQueueText.needsOwner(job))
        job.recovery = RecoveryState(state: .waiting, signature: "lock")
        job.state = .awaitingApproval
        XCTAssertFalse(ReviewQueueText.needsOwner(job), "recovery waits to try again")
    }
}

final class ReviewBatchListTests: XCTestCase {
    func testReadableNames() {
        let cases: [(String, String?)] = [
            ("2026-10-05 Telus Daily Stand-up - 2026_10_05 19_00 IST - Notes by Gemini.gdoc", "Telus Daily Stand-up"),
            ("2026-10-05-Telus-Daily-Stand-up-2026-10-05-19-00-IST-Notes-by-Gemini", "Telus Daily Stand-up"),
            ("Product sync - 2026_10_04 09_30 PDT - Notes by Gemini.gdoc", "Product sync"),
            ("Weekly sync – 2026-10-03 14.00 GMT+5:30.md", "Weekly sync"),
            ("2026-10-05.md", nil),
            ("tea-club-notes.md", "Tea club notes"),
            ("Design review Transcript 3:15 PM.txt", "Design review"),
        ]
        for (file, name) in cases { XCTAssertEqual(ReviewBatches.readableName(file), name, file) }
    }

    func testRowStatesOrderAndNextSelection() throws {
        var ready = Job(id: "r", vaultPath: "/v", files: [], state: .awaitingApproval)
        ready.approval = ApprovalRequest(summary: "", questions: [], bundlePath: "/b",
                                         plan: TransactionPlan(operationID: "op", operationType: "ingest", valid: true, changedPaths: [], approvalSHA256: "h"),
                                         planError: nil, denials: [])
        var queued = ready; queued.id = "q"; queued.queuedApply = QueuedApply(at: Date(), order: 1, planSha256: "h")
        var later = ready; later.id = "q2"; later.queuedApply = QueuedApply(at: Date(), order: 2, planSha256: "h")
        var again = ready; again.id = "a"; again.queuedApply = QueuedApply(at: Date(), order: 3)
        var gave = ready; gave.id = "g"; gave.recovery = RecoveryState(state: .gaveUp, signature: "denial")
        var upd = ready; upd.id = "u"; upd.state = .running; upd.refresh = RefreshState(since: Date())
        let all = [ready, queued, later, again, gave, upd]
        XCTAssertEqual(ReviewBatches.rowState(ready, in: all), .ready)
        XCTAssertEqual(ReviewBatches.rowState(queued, in: all).label, "Queued · next")
        XCTAssertEqual(ReviewBatches.rowState(later, in: all).label, "Queued · 2nd")
        XCTAssertEqual(ReviewBatches.rowState(again, in: all), .needsYou)
        XCTAssertEqual(ReviewBatches.rowState(gave, in: all), .couldntFix)
        XCTAssertEqual(ReviewBatches.rowState(upd, in: all), .updating)
        XCTAssertEqual(ReviewBatches.nextSelection(after: "b", in: ["a", "b", "c"], now: ["a", "c"]), "c")
        XCTAssertEqual(ReviewBatches.nextSelection(after: "c", in: ["a", "b", "c"], now: ["a", "b"]), "b")
        XCTAssertEqual(ReviewBatches.ordinal(3), "3rd")
        XCTAssertEqual(ReviewBatches.ordinal(11), "11th")
        let named = Job(id: "n", vaultPath: "/v", files: ["inbox/2026-10-04 Product sync.md"], createdAt: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ReviewBatches.batchDate(named, locale: Locale(identifier: "en_US"), timeZone: TimeZone(identifier: "UTC")!), "Oct 4")
    }

    func testOrdinals() {
        XCTAssertEqual([1, 2, 3, 4, 11, 12, 13, 21, 22, 23, 101, 111, 112, 113, 0].map(ReviewBatches.ordinal),
                       ["1st", "2nd", "3rd", "4th", "11th", "12th", "13th", "21st", "22nd", "23rd", "101st", "111th", "112th", "113th", "0th"])
        XCTAssertEqual(ReviewRowState.queued(0).label, "Queued · next")
        XCTAssertEqual(ReviewRowState.queued(1).label, "Queued · next")
        XCTAssertEqual(ReviewRowState.queued(3).label, "Queued · 3rd")
        let labels = [ReviewRowState.ready, .updating, .applying, .added, .needsYou, .recovering, .couldntFix, .notAdded, .working].map(\.label)
        XCTAssertEqual(labels, ["Ready", "Updating…", "Applying", "Added", "Needs you", "Recovering", "Couldn't fix", "Not added", "Working"])
    }

    func testNextSelectionFallbacks() {
        XCTAssertEqual(ReviewBatches.nextSelection(after: "z", in: ["a", "b"], now: ["b"]), "b", "not in the list: the first")
        XCTAssertNil(ReviewBatches.nextSelection(after: "a", in: ["a"], now: []))
        XCTAssertEqual(ReviewBatches.nextSelection(after: "b", in: ["a", "b", "c", "d"], now: ["a", "d"]), "d", "skips rows that are gone")
        XCTAssertEqual(ReviewBatches.nextSelection(after: "c", in: ["a", "b", "c"], now: ["a"]), "a", "the nearest earlier row")
        XCTAssertEqual(ReviewBatches.nextSelection(after: "a", in: ["a", "b"], now: ["x"]), "x", "nothing near: the first")
    }

    func testRowStatesForRunningAndFinishedBatches() {
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .running)
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .working)
        job.approvedChange = ApprovedChange(operationID: "op", changes: 1)
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .applying, "no turns: the approval is the latest")
        job.pendingPart = PendingPart(reason: .partial)
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .updating)
        job.pendingPart = nil
        job.state = .completed
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .notAdded, "no operation recorded")
        job.operationID = "other"
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .notAdded)
        job.operationID = "op"
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .added)
        job.approvedChange = nil
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .notAdded)
        for state in [JobState.failed, .cancelled, .rejected] {
            job.state = state
            XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .notAdded, "\(state)")
        }
        job.state = .failed
        job.recovery = RecoveryState(state: .gaveUp, signature: "x")
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .couldntFix)
        job.recovery = RecoveryState(state: .waiting, signature: "x")
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .recovering)
    }

    func testWaitingRowsThatNeedTheOwner() {
        let plan = TransactionPlan(operationID: "op", operationType: "ingest", valid: true, changedPaths: [], approvalSHA256: "h")
        var job = Job(id: "j", vaultPath: "/v", files: [], state: .awaitingApproval)
        job.approval = ApprovalRequest(summary: "", bundlePath: "/b", plan: plan)
        XCTAssertEqual(ReviewBatches.rowState(job, in: [job]), .ready)
        var q = job; q.approval?.questions = ["Which page?"]
        XCTAssertEqual(ReviewBatches.rowState(q, in: [q]), .needsYou)
        var e = job; e.approval?.planError = "bad"
        XCTAssertEqual(ReviewBatches.rowState(e, in: [e]), .needsYou)
        var d = job; d.approval?.denials = [PermissionDenial(toolName: "Bash", input: [:])]
        XCTAssertEqual(ReviewBatches.rowState(d, in: [d]), .needsYou)
        var noPlan = job; noPlan.approval?.bundlePath = nil
        XCTAssertEqual(ReviewBatches.rowState(noPlan, in: [noPlan]), .needsYou)
        noPlan.approval?.needsRebuild = true
        XCTAssertEqual(ReviewBatches.rowState(noPlan, in: [noPlan]), .ready, "a part waiting to be rebuilt is still ready to approve")
        var gone = job; gone.sessionUnavailable = SessionUnavailable(place: "batch", reason: "missing")
        XCTAssertEqual(ReviewBatches.rowState(gone, in: [gone]), .needsYou)
        let bare = Job(id: "b", vaultPath: "/v", files: [], state: .awaitingApproval)
        XCTAssertEqual(ReviewBatches.rowState(bare, in: [bare]), .ready, "no approval yet: nothing to say")
    }

    func testQueuePositionCountsTheBatchApplyingNow() {
        var first = Job(id: "q1", vaultPath: "/v", files: [], state: .awaitingApproval)
        first.queuedApply = QueuedApply(at: Date(), order: 1, planSha256: "h")
        var second = first; second.id = "q2"; second.queuedApply?.order = 2
        var elsewhere = first; elsewhere.id = "w"; elsewhere.vaultPath = "/w"; elsewhere.queuedApply?.order = 0
        XCTAssertEqual(ReviewBatches.rowState(second, in: [second, first, elsewhere]), .queued(2))
        var applying = Job(id: "a", vaultPath: "/v", files: [], state: .running)
        applying.approvedChange = ApprovedChange(operationID: "op", changes: 1)
        XCTAssertEqual(ReviewBatches.rowState(first, in: [first, second, applying]), .queued(2))
        XCTAssertEqual(ReviewBatches.rowState(second, in: [first, second, applying]), .queued(3))
        applying.vaultPath = "/w"
        XCTAssertEqual(ReviewBatches.rowState(first, in: [first, second, applying]), .queued(1))
        // Queued but recovery gave up: Couldn't fix wins.
        var gave = first; gave.recovery = RecoveryState(state: .gaveUp, signature: "lock")
        XCTAssertEqual(ReviewBatches.rowState(gave, in: [gave]), .couldntFix)
    }

    func testBatchDateFallsBackToWhenItStarted() {
        let utc = TimeZone(identifier: "UTC")!
        let en = Locale(identifier: "en_US")
        let started = Date(timeIntervalSince1970: 1_791_300_600)
        XCTAssertEqual(ReviewBatches.batchDate(Job(id: "a", vaultPath: "/v", files: ["inbox/Notes.md"], createdAt: started), locale: en, timeZone: utc), "Oct 6")
        XCTAssertEqual(ReviewBatches.batchDate(Job(id: "b", vaultPath: "/v", files: [], createdAt: started), locale: en, timeZone: utc), "Oct 6")
        XCTAssertEqual(ReviewBatches.batchDate(Job(id: "c", vaultPath: "/v", files: ["x/2025_3_9 Retro.md"], createdAt: started), locale: en, timeZone: utc), "Mar 9")
        // Only the first file's name counts, never its folder.
        XCTAssertEqual(ReviewBatches.batchDate(Job(id: "d", vaultPath: "/v", files: ["2024-01-02/Retro.md", "2025-05-05 x.md"], createdAt: started),
                                               locale: en, timeZone: utc), "Oct 6")
    }

    func testMoreReadableNames() {
        let cases: [(String, String?)] = [
            ("follow-up-with-design.md", "Follow-up with design"),
            ("Weekly Kick off.md", "Weekly Kick off"),
            ("kick-off_notes", "Kick-off notes"),
            ("one-on-one-mei.md", "One-on-one mei"),
            ("Report.final draft.md", "Report.final draft"),
            ("notes.longextension", "Notes.longextension"),
            ("2026_10_05 19_00.md", nil),
            ("Sync 10/05/2026 9:30 am.md", "Sync"),
            ("  .md", nil),
            ("Daily check in.md", "Daily check in"),
            ("daily-check-in-Check-In.md", "Daily check-in Check-in"),
        ]
        for (file, name) in cases { XCTAssertEqual(ReviewBatches.readableName(file), name, file) }
    }
}
