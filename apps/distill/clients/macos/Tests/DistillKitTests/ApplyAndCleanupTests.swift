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
