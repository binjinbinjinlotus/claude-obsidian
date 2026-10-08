import XCTest
@testable import Distill
@testable import DistillKit

/// review-queue.md: Recovery defaults to Opus ("we default use the opus") and can be changed in Settings.
final class RecoverySettingsTests: XCTestCase {
    func testRecoveryFallsBackToOpusAndHonoursTaskDefaults() {
        var s = Settings()
        let fallback = SettingsEdits.selection(.recovery, settings: s)
        XCTAssertEqual(fallback.model, "opus")
        XCTAssertEqual(fallback.effort, "medium")
        XCTAssertEqual(SettingsEdits.taskTitle(.recovery).0, "Recovery")
        s.taskDefaults["recovery"] = ModelSelection(runnerID: "claude-code", model: "sonnet")
        XCTAssertEqual(SettingsEdits.selection(.recovery, settings: s).model, "sonnet")
    }

    func testRecoveryPreferencesStoreOnlyWhatWasSet() throws {
        var s = Settings()
        XCTAssertNil(s.jsonObject()["recovery"])
        s.recovery = RecoveryPreferences(automatic: false)
        XCTAssertEqual(s.jsonObject()["recovery"], .object(["automatic": .bool(false)]))
        let p = RecoveryPreferences()
        XCTAssertTrue(p.resolvedAutomatic)
        XCTAssertEqual(p.resolvedMaxAttempts, 2)
        XCTAssertEqual(p.resolvedMaxCostUSD, 1)
    }
}
