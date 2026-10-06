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
        XCTAssertEqual(BlockedText.heading(job), "Recovering")
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
        c.recovery = RecoveryState(state: .running, signature: "denial")
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
}
