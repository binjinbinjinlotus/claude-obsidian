import XCTest
@testable import DistillKit

/// v8: Review after Approve (ApplyTimeline, the Review list) and Clean up inbox (DTOs, words, routes).
final class ApplyAndCleanupTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: String(repeating: "f", count: 64)), session: URLSession(configuration: config))
    }

    private let t0 = Date(timeIntervalSince1970: 1_790_000_000)

    private func approvedJob(state: JobState, op: String? = nil) -> Job {
        var j = Job(id: "job-1", vaultPath: "/v/Research", files: ["inbox/a.md"], state: state, operationID: op)
        j.approvedChange = ApprovedChange(at: t0, operationID: "op-1", changes: 31, sources: 22, concepts: 3, entities: 1, updated: 6, sourcesApproved: 22)
        j.turns = [TurnRecord(date: t0, author: .user, text: "Approved op-1 (abc…)")]
        return j
    }

    private func step(_ id: String, _ verb: String, _ state: String, _ text: String = "", at: Double = 1, hint: String? = nil) -> JobStep {
        JobStep(id: id, at: t0.addingTimeInterval(at), phase: "apply", state: state, verb: verb, text: text, hint: hint)
    }

    func testAddedWordsComeFromThePlanCounts() {
        XCTAssertEqual(approvedJob(state: .running).approvedChange?.addedWords, "22 source pages, 3 concepts, 1 entity added · 6 pages updated")
        XCTAssertEqual(ApprovedChange(operationID: "x", changes: 2, otherPages: 2).addedWords, "2 pages added")
        XCTAssertEqual(ApprovedChange(operationID: "x", changes: 4).addedWords, "4 changes applied")
    }

    func testTheStepsDriveTheStages() throws {
        var job = approvedJob(state: .running)
        var steps = [step("start-9", "start", "running", "Claude is starting: resuming this batch’s session"), step("apply-9", "apply", "waiting")]
        var t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps))
        XCTAssertEqual(t.stage, .starting)
        XCTAssertEqual(t.rows.map(\.state), ["done", "running", "waiting", "waiting", "waiting"])
        XCTAssertEqual(t.rows[0].count, "22 sources")
        XCTAssertEqual(t.heading, "Adding to Research…")

        steps = [step("start-9", "start", "done"), step("apply-9", "apply", "running", at: 30)]
        t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps))
        XCTAssertEqual(t.stage, .applying)
        XCTAssertEqual(t.rows[2].text, "Applying 31 changes through the vault core")

        job.state = .completed
        job.operationID = "op-1"
        job.actionsFound = JobActionsSummary(status: "finding")
        steps.append(step("added-9", "added", "done", at: 40))
        t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps))
        XCTAssertEqual(t.stage, .finding)
        XCTAssertTrue(t.isAdded)
        XCTAssertEqual(t.rows[3].text, "Added to Research: 22 source pages, 3 concepts, 1 entity added · 6 pages updated")

        job.actionsFound = JobActionsSummary(status: "failed")
        t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps))
        XCTAssertEqual(t.failedAt, .finding)
        XCTAssertFalse(t.isFailed, "finding actions is a follow-up: the batch is still added")
        XCTAssertEqual(t.heading, "Added to Research")
    }

    func testAFailedStepCarriesItsWordsAndWhatToDo() throws {
        var job = approvedJob(state: .awaitingApproval)
        job.turns.append(TurnRecord(date: t0.addingTimeInterval(20), author: .app, text: "Not applied: another process held the vault lock (LOCK_TIMEOUT)."))
        job.turns = [job.turns[0]] // the approval stays the latest user turn
        let steps = [step("start-3", "start", "done"), step("apply-3", "apply", "failed", "Not added: another app was changing your vault", hint: "Nothing was changed. Approve again to try again.")]
        let t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps))
        XCTAssertEqual(t.failedAt, .applying)
        XCTAssertTrue(t.isFailed)
        XCTAssertEqual(t.error, "Not added: another app was changing your vault")
        XCTAssertEqual(t.help, "Nothing was changed. Approve again to try again.")
        XCTAssertEqual(t.heading, "Not added to your vault")
        XCTAssertEqual(t.rows.map(\.state), ["done", "done", "failed", "waiting", "waiting"])
    }

    func testACoreApplyHasNoAIStep() throws {
        var job = approvedJob(state: .completed, op: "op-1")
        job.kind = "labels"
        let t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: [step("apply-2", "apply", "done"), step("added-2", "added", "done")]))
        XCTAssertTrue(t.core)
        XCTAssertEqual(t.rows.count, 4)
        XCTAssertEqual(t.stage, .done)
    }

    func testAStartThatFailedStopsAtStarting() throws {
        let job = approvedJob(state: .awaitingApproval)
        let steps = [step("start-4", "start", "failed", "Claude Code couldn’t start", hint: "Check Settings → Runners."), step("apply-4", "apply", "waiting")]
        let t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps))
        XCTAssertEqual(t.failedAt, .starting)
        XCTAssertEqual(t.stage, .starting)
        XCTAssertEqual(t.error, "Claude Code couldn’t start")
        XCTAssertEqual(t.help, "Check Settings → Runners.")
        XCTAssertTrue(t.isFailed)
        XCTAssertFalse(t.isRunning)
        XCTAssertFalse(t.isAdded)
        XCTAssertEqual(t.rows.map(\.state), ["done", "failed", "waiting", "waiting", "waiting"])
        XCTAssertEqual(t.rows[1].text, "Claude Code couldn’t start")
        // No hint: no help.
        let bare = try XCTUnwrap(ApplyTimeline.make(job: job, steps: [step("start-4", "start", "failed", "x"), step("apply-4", "apply", "waiting")]))
        XCTAssertEqual(bare.help, "")
    }

    func testWithoutStepsTheJobAloneSaysWhereItIs() throws {
        // Running, nothing loaded: an AI run is starting; a core apply is applying.
        let running = try XCTUnwrap(ApplyTimeline.make(job: approvedJob(state: .running), steps: []))
        XCTAssertEqual(running.stage, .starting)
        XCTAssertTrue(running.isRunning)
        XCTAssertEqual(running.heading, "Adding to Research…")
        var codexless = approvedJob(state: .running)
        codexless.runnerID = "openai"
        let core = try XCTUnwrap(ApplyTimeline.make(job: codexless, steps: []))
        XCTAssertTrue(core.core)
        XCTAssertEqual(core.stage, .applying)
        XCTAssertEqual(core.runner, "The AI")
        XCTAssertEqual(core.rows.map(\.stage), [.approved, .applying, .applied, .finding], "no AI step for a core apply")
        // Completed but not with the approved operation, and no steps: nothing is listed as added.
        let lost = try XCTUnwrap(ApplyTimeline.make(job: approvedJob(state: .completed, op: "other"), steps: []))
        XCTAssertEqual(lost.failedAt, .applying)
        XCTAssertEqual(lost.error, "Nothing recorded as applied: Claude didn’t report the approved change")
        XCTAssertEqual(lost.help, "Open Show steps to see what happened. Nothing is listed as added until the vault core confirms it.")
        XCTAssertEqual(lost.heading, "Not added to your vault")
        // Waiting again (awaitingApproval) with no steps: no timeline.
        XCTAssertNil(ApplyTimeline.make(job: approvedJob(state: .awaitingApproval), steps: []))
        // Never approved: no timeline.
        XCTAssertNil(ApplyTimeline.make(job: Job(id: "j", vaultPath: "/v", files: [], state: .running), steps: []))
    }

    func testAnApplyAfterADoneStartIsApplying() throws {
        let job = approvedJob(state: .awaitingApproval)
        let t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: [step("start-5", "start", "done"), step("apply-5", "apply", "waiting")]))
        XCTAssertEqual(t.stage, .applying)
        XCTAssertEqual(t.rows.map(\.state), ["done", "done", "running", "waiting", "waiting"])
        XCTAssertEqual(t.rows[1].text, "Claude resumed this batch’s session")
        XCTAssertEqual(t.rows[2].count, "", "the operation shows once it is done")
        // An apply step from before this approval doesn't count.
        let old = step("apply-1", "apply", "failed", "old failure", at: -60)
        let fresh = try XCTUnwrap(ApplyTimeline.make(job: approvedJob(state: .running), steps: [old]))
        XCTAssertNil(fresh.failedAt)
        XCTAssertEqual(fresh.stage, .starting)
        // Within 5 seconds before the approval still counts (clocks differ).
        let close = step("apply-1", "apply", "failed", "close failure", at: -4)
        XCTAssertEqual(try XCTUnwrap(ApplyTimeline.make(job: approvedJob(state: .running), steps: [close])).failedAt, .applying)
    }

    func testRunnerNameFromTheStartStep() throws {
        let job = approvedJob(state: .running)
        func runner(_ text: String) throws -> String {
            try XCTUnwrap(ApplyTimeline.make(job: job, steps: [step("start-1", "start", "running", text), step("apply-1", "apply", "waiting")])).runner
        }
        XCTAssertEqual(try runner("Codex is starting: resuming this batch’s session"), "Codex")
        XCTAssertEqual(try runner("The AI is starting: resuming"), "The AI")
        XCTAssertEqual(try runner("Some long name is starting"), "Claude", "a name with spaces isn't trusted")
        XCTAssertEqual(try runner(" is starting"), "Claude")
        XCTAssertEqual(try runner("Starting now"), "Claude")
        XCTAssertEqual(ApplyTimeline.runnerName(nil), "Claude")
        XCTAssertEqual(ApplyTimeline.runnerName("codex"), "Codex")
        XCTAssertEqual(ApplyTimeline.runnerName("openai"), "The AI")
    }

    func testFindingActionsWords() {
        XCTAssertEqual(ApplyTimeline.actionsWords(nil), "Finding actions in these notes")
        XCTAssertEqual(ApplyTimeline.actionsWords(JobActionsSummary(status: "done", found: 1)), "Found 1 action to confirm")
        XCTAssertEqual(ApplyTimeline.actionsWords(JobActionsSummary(status: "done", found: 5)), "Found 5 actions to confirm")
        XCTAssertEqual(ApplyTimeline.actionsWords(JobActionsSummary(status: "done", found: 0)), "Found no actions")
        XCTAssertEqual(ApplyTimeline.actionsWords(JobActionsSummary(status: "failed")), "Couldn’t look for actions this time · try again from Actions")
        XCTAssertEqual(ApplyTimeline.actionsWords(JobActionsSummary(status: "skipped")), "Didn’t look for actions")
        XCTAssertEqual(ApplyTimeline.actionsWords(JobActionsSummary(status: "finding")), "Finding actions in these notes")
    }

    func testAddedStagesWithoutAFindingResult() throws {
        // Added by the job's own operation, no added step: done (a labels batch never looks for actions).
        var labels = approvedJob(state: .completed, op: "op-1")
        labels.kind = "labels"
        let l = try XCTUnwrap(ApplyTimeline.make(job: labels, steps: []))
        XCTAssertEqual(l.stage, .done)
        XCTAssertEqual(l.actions, "Didn’t look for actions")
        XCTAssertEqual(l.heading, "Added to Research")
        // An ingest that changed nothing: applied, no finding.
        let ingest = try XCTUnwrap(ApplyTimeline.make(job: approvedJob(state: .completed, op: "op-1"), steps: []))
        XCTAssertEqual(ingest.stage, .applied)
        XCTAssertTrue(ingest.isAdded)
        var changed = approvedJob(state: .completed, op: "op-1")
        changed.changedPaths = ["wiki/a.md"]
        XCTAssertEqual(try XCTUnwrap(ApplyTimeline.make(job: changed, steps: [])).stage, .done)
        // Still running after the added step: finding.
        let finding = try XCTUnwrap(ApplyTimeline.make(job: approvedJob(state: .running), steps: [step("start-1", "start", "done"),
                                                                                                    step("apply-1", "apply", "done"), step("added-1", "added", "done")]))
        XCTAssertEqual(finding.stage, .finding)
        XCTAssertEqual(finding.rows.map(\.state), ["done", "done", "done", "done", "running"])
        var skipped = approvedJob(state: .completed, op: "op-1")
        skipped.actionsFound = JobActionsSummary(status: "skipped")
        XCTAssertEqual(try XCTUnwrap(ApplyTimeline.make(job: skipped, steps: [])).stage, .done)
        // Done: every row done, each with its done words.
        let done = try XCTUnwrap(ApplyTimeline.make(job: skipped, steps: []))
        XCTAssertEqual(done.rows.map(\.state), ["done", "done", "done", "done", "done"])
        XCTAssertEqual(done.rows[2].text, "Applied through the vault core")
        XCTAssertEqual(done.rows[2].count, "op-1")
        XCTAssertEqual(done.rows[4].text, "Didn’t look for actions")
    }

    func testAppliedInTerminalAfterAFailureHereCountsAsAdded() throws {
        var job = approvedJob(state: .completed, op: "op-1")
        job.approvedChange?.appliedOutside = true
        job.actionsFound = JobActionsSummary(status: "done", found: 0)
        let steps = [step("start-1", "start", "failed", "x"), step("apply-1", "apply", "failed", "y")]
        let t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps))
        XCTAssertNil(t.failedAt)
        XCTAssertEqual(t.stage, .done)
        // Outside only counts with the approved operation on a completed job.
        job.operationID = "other"
        XCTAssertEqual(try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps)).failedAt, .starting)
    }

    func testSourcesCountFallsBackToTheApprovalThenTheJob() throws {
        var job = approvedJob(state: .running)
        job.approvedChange?.sourcesApproved = nil
        job.approval = ApprovalRequest(summary: "", sources: [ReviewSource(page: "a.md", title: "A"), ReviewSource(page: "b.md", title: "B", removed: true),
                                                              ReviewSource(page: "c.md", title: "C")])
        XCTAssertEqual(try XCTUnwrap(ApplyTimeline.make(job: job, steps: [])).sources, "2 sources", "removed sources don't count")
        job.approval = nil
        XCTAssertEqual(try XCTUnwrap(ApplyTimeline.make(job: job, steps: [])).sources, "1 source", "the job's own sources")
        job.files = []
        XCTAssertEqual(try XCTUnwrap(ApplyTimeline.make(job: job, steps: [])).sources, "")
        job.approvedChange?.sourcesApproved = 0
        XCTAssertEqual(try XCTUnwrap(ApplyTimeline.make(job: job, steps: [])).rows[0].count, "")
    }

    func testRefreshTimesAndRows() throws {
        var job = approvedJob(state: .running)
        job.refresh = RefreshState(since: t0)
        let t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: [step("apply-1", "apply", "failed", "x")]))
        XCTAssertTrue(t.updating)
        XCTAssertEqual(t.stage, .applying)
        XCTAssertFalse(t.isFailed)
        XCTAssertTrue(t.isRunning)
        XCTAssertEqual(t.help, "Another batch changed the same pages first. This batch’s session is rebuilding the plan against the pages as they are now.")
        // Times: approved, (start), apply, added, actions.
        let steps = [step("start-2", "start", "done", at: 2), step("apply-2", "apply", "running", at: 3)]
        let timed = try XCTUnwrap(ApplyTimeline.make(job: approvedJob(state: .running), steps: steps))
        XCTAssertEqual(timed.times, [t0, t0.addingTimeInterval(2), t0.addingTimeInterval(3), nil, nil])
    }

    func testPlanReplacedComparesTheApprovedHash() {
        let plan = TransactionPlan(operationID: "op", operationType: "ingest", valid: true, changedPaths: [], approvalSHA256: "abcdef0123456789")
        var job = approvedJob(state: .awaitingApproval)
        job.approval = ApprovalRequest(summary: "", bundlePath: "/b", plan: plan)
        job.turns = [TurnRecord(date: t0, author: .user, text: "Approved op-1 (abcdef012345…)")]
        XCTAssertFalse(ApplyTimeline.planReplaced(job), "the turn's prefix matches")
        job.turns = [TurnRecord(date: t0, author: .user, text: "Approved op-1 (ffffff012345…)")]
        XCTAssertTrue(ApplyTimeline.planReplaced(job))
        job.turns = [TurnRecord(date: t0, author: .user, text: "Approved op-1 (abc…)")]
        XCTAssertFalse(ApplyTimeline.planReplaced(job), "too short a prefix to tell")
        job.turns = [TurnRecord(date: t0, author: .user, text: "Approved op-1")]
        XCTAssertFalse(ApplyTimeline.planReplaced(job))
        job.approvedChange?.approvalSha256 = "abcdef0123456789"
        XCTAssertFalse(ApplyTimeline.planReplaced(job), "a stored hash decides")
        job.approvedChange?.approvalSha256 = "0000"
        XCTAssertTrue(ApplyTimeline.planReplaced(job))
        job.state = .running
        XCTAssertFalse(ApplyTimeline.planReplaced(job))
    }

    func testShowsInReviewPerState() {
        var job = approvedJob(state: .failed)
        XCTAssertTrue(ApplyTimeline.showsInReview(job))
        XCTAssertEqual(ApplyTimeline.tabSubtitle(job), "not added")
        job.state = .cancelled
        XCTAssertTrue(ApplyTimeline.showsInReview(job))
        job.state = .awaitingApproval
        XCTAssertFalse(ApplyTimeline.showsInReview(job))
        XCTAssertNil(ApplyTimeline.tabSubtitle(job))
        job.state = .running
        job.pendingPart = PendingPart(reason: .partial)
        XCTAssertFalse(ApplyTimeline.showsInReview(job), "a part being rebuilt is waiting, not applying")
        var labels = approvedJob(state: .completed, op: "op-1")
        labels.kind = "labels"
        XCTAssertFalse(ApplyTimeline.showsInReview(labels))
        XCTAssertTrue(ApplyTimeline.approvalIsLatest(Job(id: "x", vaultPath: "/v", files: [])) == false)
        var noTurns = approvedJob(state: .running)
        noTurns.turns = []
        XCTAssertTrue(ApplyTimeline.approvalIsLatest(noTurns), "no turns kept: the approval stands")
    }

    func testOnlyApplySteps() throws {
        let job = approvedJob(state: .running)
        // Another step in the apply phase, or one named like an apply, is never the apply.
        let steps = [step("start-1", "start", "done"), step("apply-1", "apply", "running", at: 2),
                     JobStep(id: "x-1", at: t0.addingTimeInterval(3), phase: "apply", state: "failed", verb: "tool", text: "other"),
                     JobStep(id: "apply-note", at: t0.addingTimeInterval(4), phase: "agent", state: "failed", verb: "tool", text: "note")]
        let t = try XCTUnwrap(ApplyTimeline.make(job: job, steps: steps))
        XCTAssertNil(t.failedAt)
        XCTAssertEqual(t.stage, .applying)
        // Exactly 5 seconds before the approval still counts.
        let edge = try XCTUnwrap(ApplyTimeline.make(job: job, steps: [step("apply-1", "apply", "failed", "edge", at: -5)]))
        XCTAssertEqual(edge.failedAt, .applying)
        XCTAssertEqual(edge.error, "edge")
    }

    func testTheApprovedRowTimeIsTheApprovalStep() throws {
        let approved = t0.addingTimeInterval(-30)
        let steps = [JobStep(id: "a1", at: approved, endedAt: approved, phase: "agent", verb: "answer", text: "You approved"),
                     JobStep(id: "a2", at: t0, endedAt: t0.addingTimeInterval(1), phase: "agent", verb: "answer", text: "You replied"),
                     JobStep(id: "a3", at: t0, endedAt: t0.addingTimeInterval(2), phase: "agent", verb: "tool", text: "You approved")]
        let t = try XCTUnwrap(ApplyTimeline.make(job: approvedJob(state: .running), steps: steps))
        XCTAssertEqual(t.times.first, approved)
        XCTAssertFalse(ApplyTimeline(stage: .done).core, "an AI apply unless told")
    }

    func testPlanReplacedReadsTheApprovalTurnOnly() {
        let plan = TransactionPlan(operationID: "op", operationType: "ingest", valid: true, changedPaths: [], approvalSHA256: "abcdef0123456789")
        var job = approvedJob(state: .awaitingApproval)
        job.approval = ApprovalRequest(summary: "", bundlePath: "/b", plan: plan)
        job.turns = [TurnRecord(date: t0, author: .user, text: "Approved op-1 (ffffff01…)"), TurnRecord(date: t0, author: .user, text: "Thanks")]
        XCTAssertTrue(ApplyTimeline.planReplaced(job), "an 8-character prefix is enough; a later reply isn't the approval")
        job.turns = [TurnRecord(date: t0, author: .user, text: "Approved op-1 (abcdef01…)"), TurnRecord(date: t0, author: .app, text: "Approved (zzzzzzzzzz…)")]
        XCTAssertFalse(ApplyTimeline.planReplaced(job), "the app's own turn isn't the approval")
    }

    func testReviewListsRunningPartsAndRebuildsOnly() {
        var refreshing = Job(id: "r", vaultPath: "/v", files: [], state: .running)
        refreshing.refresh = RefreshState(since: t0)
        var part = Job(id: "p", vaultPath: "/v", files: [], state: .running)
        part.pendingPart = PendingPart(reason: .partial)
        var finished = Job(id: "f", vaultPath: "/v", files: [], state: .completed)
        finished.pendingPart = PendingPart(reason: .partial)
        let plain = Job(id: "x", vaultPath: "/v", files: [], state: .running)
        XCTAssertEqual(Set(ApplyTimeline.reviewList([refreshing, part, finished, plain]).map(\.id)), ["r", "p"])
        var failed = approvedJob(state: .failed, op: "op-1")
        XCTAssertEqual(ApplyTimeline.tabSubtitle(failed), "not added", "the approved operation on a failed job isn't added")
        failed.state = .completed
        failed.operationID = "other"
        XCTAssertEqual(ApplyTimeline.tabSubtitle(failed), "not added")
    }

    func testReviewKeepsAnApprovedBatchUntilDoneAndNeverCountsIt() {
        var waiting = Job(id: "job-2", vaultPath: "/v", files: [], state: .awaitingApproval, createdAt: t0.addingTimeInterval(100))
        waiting.turns = []
        let applying = approvedJob(state: .running)
        var done = approvedJob(state: .completed, op: "op-1")
        done.id = "job-3"
        done.reviewDoneAt = t0
        var replied = approvedJob(state: .running)
        replied.id = "job-4"
        replied.turns.append(TurnRecord(date: t0.addingTimeInterval(5), author: .user, text: "Put it on the Gyokuro page"))
        let list = ApplyTimeline.reviewList([applying, waiting, done, replied])
        XCTAssertEqual(list.map(\.id), ["job-2", "job-1"], "waiting first; Done and a later reply leave Review")
        XCTAssertEqual(ReviewBatches.tabSubtitle(applying), "adding…")
        XCTAssertEqual(ReviewBatches.tabSubtitle(approvedJob(state: .completed, op: "op-1")), "added")
        XCTAssertTrue(ApplyTimeline.isApplying(applying))
        XCTAssertFalse(ApplyTimeline.isApplying(replied))
    }

    func testOlderCoresDecodeWithoutTheNewFields() throws {
        let job = try JSONDecoder.core.decode(Job.self, from: Data(#"{"id":"job-1","state":"completed"}"#.utf8))
        XCTAssertNil(job.approvedChange)
        XCTAssertNil(job.reviewDoneAt)
        XCTAssertFalse(ApplyTimeline.showsInReview(job))
        let step = try JSONDecoder.core.decode(JobStep.self, from: Data(#"{"id":"apply-1","text":"x","hint":"Approve again"}"#.utf8))
        XCTAssertEqual(step.hint, "Approve again")
    }

    func testPreviewDecodesAndSaysWhatStays() async throws {
        StubProtocol.handler = { _ in (200, Data(#"""
        {"vaultPath":"/v","jobId":"job-1","checkedAt":"2026-10-05T09:00:00Z",
         "items":[{"path":"inbox/a.md","kind":"note","members":["inbox/a.distill.json"],"fileCount":2,"size":10,"pages":["wiki/sources/a.md"]},
                  {"path":"inbox/2026-10-04/Trip","kind":"folder","fileCount":12,"size":99,"pages":[]}],
         "stays":[{"path":"inbox/k.md","kind":"file","reason":"changed","fileCount":1},{"path":"inbox/n.md","reason":"notAdded","fileCount":1},
                  {"path":"inbox/x.md","reason":"somethingNew","fileCount":1}]}
        """#.utf8)) }
        let p = try await client.inboxCleanup(jobID: "job-1")
        XCTAssertEqual(p.fileCount, 14)
        XCTAssertEqual(InboxCleanupWords.button(p), "Clear inbox · 14 files")
        XCTAssertEqual(p.stays[0].reasonWords, "changed since it was added")
        XCTAssertTrue(p.stays[0].isWarning)
        XCTAssertEqual(p.staysByReason.map(\.reason), ["notAdded", "changed"])
        let last = try XCTUnwrap(StubProtocol.recorded.last)
        XCTAssertEqual(last.method, "GET")
        XCTAssertEqual(last.path, "/v1/inbox/cleanup")
        XCTAssertEqual(InboxCleanupWords.nothingLine(InboxCleanupPreview(stays: [InboxCleanupStay(path: "inbox/n.md", reason: "notAdded")])), "1 file stays in inbox/")
        XCTAssertEqual(InboxCleanupWords.nothingLine(InboxCleanupPreview()), "No inbox files left")
    }

    func testCleanUpSendsThePathsAndReportsWhatStayed() async throws {
        StubProtocol.handler = { _ in (200, Data(#"""
        {"moved":[{"path":"inbox/a.md","fileCount":2}],"stayed":[{"path":"inbox/b.md","reason":"changed","fileCount":1}],"failed":[],"method":"finder"}
        """#.utf8)) }
        let r = try await client.cleanUpInbox(paths: ["inbox/a.md", "inbox/b.md"], jobID: "job-1")
        XCTAssertEqual(r.movedFiles, 2)
        XCTAssertEqual(InboxCleanupWords.resultTitle(r), "Cleared 2 files from inbox")
        XCTAssertEqual(InboxCleanupWords.resultText(r), "1 stayed in inbox/: b.md changed, so it was left alone. Put Back in the Trash returns a file to inbox/.")
        let last = try XCTUnwrap(StubProtocol.recorded.last)
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data()),
                       .object(["paths": .array([.string("inbox/a.md"), .string("inbox/b.md")]), "jobId": .string("job-1")]))
    }

    func testDoneRoute() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"id":"job-1","state":"completed","reviewDoneAt":"2026-10-05T09:00:00Z"}"#.utf8)) }
        let job = try await client.finishReview("job-1")
        XCTAssertNotNil(job.reviewDoneAt)
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/jobs/job-1/done")
    }
}
