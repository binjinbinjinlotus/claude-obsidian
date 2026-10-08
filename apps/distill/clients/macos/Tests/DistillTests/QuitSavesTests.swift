import AppKit
import XCTest
import DistillKit
@testable import Distill

/// ⌘Q (actions.md, When field edits save): AppDelegate flushes the draft fields and the Settings save,
/// quits at once when nothing is saving, and otherwise waits for the saves before it replies.
@MainActor
final class QuitSavesTests: XCTestCase {
    func testNothingSavingQuitsNowAfterFlushingEverything() {
        let saves = PendingSaves()
        var flushed: [String] = []
        _ = saves.register { flushed.append("field") }
        var replies: [Bool] = []
        let reply = AppDelegate.terminate(saves: saves, saveSettingsNow: { flushed.append("settings") }) { replies.append($0) }
        XCTAssertEqual(reply, .terminateNow)
        XCTAssertEqual(flushed, ["field", "settings"])
        XCTAssertEqual(replies, [])
    }

    func testASaveInFlightIsWaitedForThenQuits() async {
        let saves = PendingSaves()
        var stored = false
        // The Settings save starts when flushed and takes 100 ms.
        let saveSettingsNow = {
            saves.began()
            Task { @MainActor in
                try? await Task.sleep(nanoseconds: 100_000_000)
                stored = true
                saves.ended()
            }
        }
        let replied = expectation(description: "reply")
        var replies: [Bool] = []
        let reply = AppDelegate.terminate(saves: saves, saveSettingsNow: saveSettingsNow) { replies.append($0); replied.fulfill() }
        XCTAssertEqual(reply, .terminateLater)
        XCTAssertFalse(stored)
        await fulfillment(of: [replied], timeout: 2)
        XCTAssertEqual(replies, [true], "quits once the save landed")
        XCTAssertTrue(stored)
    }
}
