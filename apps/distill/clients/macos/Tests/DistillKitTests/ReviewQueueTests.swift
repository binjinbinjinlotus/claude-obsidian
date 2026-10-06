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
}
