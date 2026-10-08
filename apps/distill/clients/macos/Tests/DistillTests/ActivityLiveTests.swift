import AppKit
import SwiftUI
import XCTest
import DistillKit
@testable import Distill

/// History → Activity against a running throwaway core: `DISTILL_LIVE_STATE=<temp state dir>`
/// with a deleted collector in its trash (never the real state dir). Drives the app's own
/// store (load, Restore) and renders the real screen offscreen in a 900 pt window, the app's
/// minimum (`DISTILL_LIVE_OUT=<dir>` keeps the PNGs). Skipped by default.
@MainActor
final class ActivityLiveTests: XCTestCase {
    private static var shared: AppModel?

    private func engine() throws -> AppModel {
        if let e = Self.shared { return e }
        guard let dir = ProcessInfo.processInfo.environment["DISTILL_LIVE_STATE"] else {
            throw XCTSkip("set DISTILL_LIVE_STATE to a temp core state dir")
        }
        let state = URL(fileURLWithPath: dir)
        struct Lock: Decodable { let port: Int }
        let lock = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: state.appendingPathComponent("server.json")))
        let token = try String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        e.useClientForTesting(CoreClient(endpoint: CoreEndpoint(port: lock.port, token: token)))
        Self.shared = e
        return e
    }

    private func wait(_ what: String, timeout: TimeInterval = 10, _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !ok() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(ok(), what)
    }

    func testRestoreAgainstTheCoreAndTheNarrowWindow() throws {
        let e = try engine()
        let out = ProcessInfo.processInfo.environment["DISTILL_LIVE_OUT"].map { URL(fileURLWithPath: $0) }
        let store = e.activity
        e.collectors.load()
        store.load()
        wait("loaded") { store.phase == .loaded }
        render("activity-900-list", e: e, out: out)

        guard let deleted = store.entries.first(where: { $0.type == "collector.deleted" && store.tag($0) == "In trash" }) else {
            throw XCTSkip("seed a deleted collector in the trash")
        }
        store.select(deleted, narrow: true)
        render("activity-900-detail", e: e, out: out)

        store.restore(deleted)
        wait("restored") { store.restoring.isEmpty && store.tag(deleted) == "Restored" }
        // The core logs the restore from the Mac app (X-Distill-Client: app).
        store.load()
        wait("reloaded") { store.entries.contains { $0.type == "collector.restored" } }
        let restoredEntry = try XCTUnwrap(store.entries.first { $0.type == "collector.restored" })
        XCTAssertEqual(restoredEntry.source, .app)
        XCTAssertEqual(store.tag(deleted), "Restored", "still Restored after a fresh load (from the restore entries)")
        e.collectors.load()
        wait("the collector is back") { e.collectors.collector(restoredEntry.object.id ?? "") != nil }
        XCTAssertTrue(store.canOpen(deleted, objectID: restoredEntry.object.id))
        store.selected = deleted.id
        store.pushed = true
        render("activity-900-restored", e: e, out: out)
    }

    private func render(_ name: String, e: AppModel, out: URL?) {
        let size = CGSize(width: 900, height: 628)
        let root = HStack(spacing: 0) {
            Sidebar(section: .constant(.history), selectedJob: .constant(nil), historyPart: .constant(.activity), openSettings: {})
            ActivityScreen().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped().background(Theme.window)
        }
        .environmentObject(e.ask).environmentObject(e).environment(\.colorScheme, .light)
        .frame(width: size.width, height: size.height)
        let host = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(x: -30000, y: -30000, width: size.width, height: size.height), styleMask: [.borderless], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = host
        for _ in 0..<10 { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        if let out, let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) {
            host.cacheDisplay(in: host.bounds, to: rep)
            try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)
            try? rep.representation(using: .png, properties: [:])?.write(to: out.appendingPathComponent("\(name).png"))
        }
        window.contentView = nil
    }
}
