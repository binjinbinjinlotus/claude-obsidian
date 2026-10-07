import XCTest
@testable import DistillKit

/// ⌘Q (actions.md, When field edits save): every registered draft is flushed, then quitting waits
/// for the saves to finish, or for the timeout, never longer.
@MainActor
final class PendingSavesTests: XCTestCase {
    func testFlushAllSavesEveryRegisteredDraftAndNotUnregisteredOnes() {
        let saves = PendingSaves()
        var flushed: [String] = []
        _ = saves.register { flushed.append("people") }
        let gone = saves.register { flushed.append("gone") }
        _ = saves.register { flushed.append("labels") }
        saves.unregister(gone)
        saves.flushAll()
        XCTAssertEqual(flushed.sorted(), ["labels", "people"])
    }

    func testQuitWaitsForTheSavesTheFlushStarted() async {
        let saves = PendingSaves()
        var stored: String?
        // A draft whose flush starts a save to the core that takes 100 ms.
        _ = saves.register {
            saves.began()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                stored = "Linu Chui"
                saves.ended()
            }
        }
        saves.flushAll()
        XCTAssertEqual(saves.running, 1)
        let done = await saves.waitForSaves(timeout: 2)
        XCTAssertTrue(done)
        XCTAssertEqual(stored, "Linu Chui", "the save landed before quit")
        XCTAssertEqual(saves.running, 0)
    }

    func testQuitNeverWaitsPastTheTimeout() async {
        let saves = PendingSaves()
        saves.began() // a save that never answers
        let start = Date()
        let done = await saves.waitForSaves(timeout: 0.2)
        XCTAssertFalse(done)
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testNothingRunningReturnsAtOnceAndEndedNeverGoesNegative() async {
        let saves = PendingSaves()
        saves.ended()
        XCTAssertEqual(saves.running, 0)
        let done = await saves.waitForSaves(timeout: 0)
        XCTAssertTrue(done)
    }
}
