import AppKit
import XCTest
@testable import Distill
@testable import DistillKit

/// ⌘Q and the Settings save (actions.md, When field edits save): saveSettingsNow sends only a save that
/// is waiting out its pause, and a Settings save counts in PendingSaves while it is in flight.
@MainActor
final class SettingsSaveNowTests: XCTestCase {
    private func model() -> AppModel {
        SessionCoreProtocol.calls = []
        SessionCoreProtocol.answer = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionCoreProtocol.self]
        let app = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        app.useClientForTesting(CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config)))
        return app
    }

    private func edit(_ app: AppModel) {
        SettingsEdits.setActions(&app.settings) { $0.people = [ActionPerson(id: "you", name: "Jin Bin Liu"), ActionPerson(id: "p-1", name: "Mei")] }
    }

    func testNothingWaitingNothingSent() async throws {
        let app = model()
        edit(app) // no launcher: nothing is scheduled
        app.saveSettingsNow()
        try await Task.sleep(nanoseconds: 200_000_000)
        XCTAssertFalse(SessionCoreProtocol.calls.contains { $0.path == "/v1/settings" }, "no save was waiting: ⌘Q sends nothing")
    }

    func testASettingsSaveCountsWhileInFlight() async throws {
        let app = model()
        edit(app)
        let held = DispatchSemaphore(value: 0)
        SessionCoreProtocol.answer = { c in
            if c.path == "/v1/settings" { held.wait() }
            return (200, "{}")
        }
        let before = PendingSaves.shared.running
        let flush = Task { await app.flushSettings() }
        let end = Date().addingTimeInterval(3)
        while !SessionCoreProtocol.calls.contains(where: { $0.path == "/v1/settings" }) && Date() < end {
            try await Task.sleep(nanoseconds: 10_000_000)
        }
        XCTAssertTrue(SessionCoreProtocol.calls.contains { $0.method == "PUT" && $0.path == "/v1/settings" })
        XCTAssertEqual(PendingSaves.shared.running, before + 1, "⌘Q waits for it")
        held.signal()
        await flush.value
        XCTAssertEqual(PendingSaves.shared.running, before)
    }

    func testTheKeyIsOursWhenNoTextFieldIsBeingTyped() {
        _ = NSApplication.shared
        XCTAssertTrue(TrackPendingKey.allowed(), "no window typing: ⇧⌥Return opens Track as Pending")
    }
}
