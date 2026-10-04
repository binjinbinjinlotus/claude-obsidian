import AppKit
import SwiftUI
import XCTest
import DistillKit
@testable import Distill

/// The Actions redesign against a running throwaway core: `DISTILL_LIVE_STATE=<temp state dir>`
/// with seeded actions (never the real state dir). Drives the app's own store, so Complete,
/// Undo and bulk Complete go through the same calls the buttons make, and renders the real
/// Actions screen in an offscreen window at the minimum and the usual width
/// (`DISTILL_LIVE_OUT=<dir>` keeps the PNGs to look at; nothing here measures them). Skipped by default.
@MainActor
final class ActionsLiveTests: XCTestCase {
    /// One model for the whole run: ActionsStore.of(_:) keys stores by object identity, so a
    /// released model's address could hand a new one a store whose engine is gone.
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

    private func reload(_ store: ActionsStore) {
        store.phase = .idle
        store.load()
        wait("loaded") { store.phase == .loaded }
    }

    func testCompleteUndoAndBulkCompleteAgainstTheCore() throws {
        let e = try engine()
        let store = e.actions
        reload(store)
        guard let slack = store.items(type: "slack").first(where: { $0.status == .ready }) else { throw XCTSkip("seed a ready Slack message") }

        // Complete on a Slack message (no complete handler before this change).
        store.complete(slack)
        XCTAssertEqual(store.toast?.text, "Completed")
        wait("Slack message done") { store.items[slack.id]?.status == .done }
        XCTAssertEqual(store.items[slack.id]?.lastEvent("done")?.detail, "ready")
        store.toast?.undo?()
        wait("Undo puts it back where it was") { store.items[slack.id]?.status == .ready }

        // Bulk Complete: one toast; its Undo brings every one back (not only the last).
        let todos = Array(store.items(type: "todo").filter { $0.status == .open }.prefix(3))
        XCTAssertEqual(todos.count, 3)
        store.complete(todos)
        XCTAssertEqual(store.toast?.text, "Completed 3")
        wait("all three done") { todos.allSatisfy { store.items[$0.id]?.status == .done } }
        reload(store)
        XCTAssertTrue(todos.allSatisfy { store.items[$0.id]?.status == .done }, "the core has them as done")
        store.loadHistory()
        wait("History lists them as Completed") { todos.allSatisfy { store.items[$0.id].flatMap(ActionHistory.outcome) == .completed } }
        let undo = store.toast?.undo
        XCTAssertNotNil(undo)
        undo?()
        wait("Undo restored all three") { todos.allSatisfy { store.items[$0.id]?.status == .open } }
        reload(store)
        XCTAssertTrue(todos.allSatisfy { store.items[$0.id]?.status == .open }, "the core has them open again")

        // Jira: Complete from ready works too, and restores to ready.
        if let jira = store.items(type: "jira").first(where: { $0.status == .ready }) {
            store.complete(jira)
            wait("Jira draft done") { store.items[jira.id]?.status == .done }
            store.restoreAll([jira.id])
            wait("Jira draft back") { store.items[jira.id]?.status == .ready }
        }
    }

    func testConnectNowOpensSettingsAtConnections() throws {
        let e = try engine()
        var section: String?
        let token = NotificationCenter.default.addObserver(forName: .distillOpenSettingsSection, object: nil, queue: nil) { n in
            section = (n.object as? String) ?? (n.userInfo?["section"] as? String)
        }
        defer { NotificationCenter.default.removeObserver(token) }
        e.actions.openSettings("connections")
        wait("Settings asked to show Connections") { section == "connections" }
    }

    /// The real screen with core data in an offscreen window: To do with five filters at 900 and
    /// 1110 pt (window widths; the toolbar must stay one line), Jira not connected, Slack, History.
    func testRendersAtMinimumAndUsualWidth() throws {
        let e = try engine()
        let store = e.actions
        reload(store)
        store.loadHistory()
        wait("history") { store.historyLoaded }
        let out = ProcessInfo.processInfo.environment["DISTILL_LIVE_OUT"].map { URL(fileURLWithPath: $0) }
        var ui = TodoUI()
        ui.filter.status = .all
        ui.filter.due = [.thisWeek, .none]
        ui.filter.priorities = ["High"]
        ui.filter.addedBy = .you
        for (name, width) in [("todo-900", 900.0), ("todo-1110", 1110.0)] {
            render(name, width: width, e: e, out: out) { TodoScreen(store: store, ui: ui) }
        }
        for tab in ["slack", "jira", "confluence"] {
            guard let type = store.type(tab) else { continue }
            var tl = TypeListUI()
            // Filters on every tab: Jira and Confluence not connected is the tightest toolbar (status text + Connect now).
            if tab == "slack" { tl.filter.toggle("status", "Ready to paste"); tl.filter.toggle("label", "#none") }
            if tab == "jira" { tl.filter.toggle("status", "Draft"); tl.filter.toggle("project", "Operations"); tl.filter.toggle("assignee", "Priya Shah") }
            if tab == "confluence" { tl.filter.toggle("status", "Draft"); tl.filter.toggle("space", "Operations") }
            render("\(tab)-900", width: 900, e: e, out: out) { TypeListScreen(store: store, type: type) }
            render("\(tab)-900-filtered", width: 900, e: e, out: out) { TypeListScreen(store: store, type: type, ui: tl) }
        }
        render("history-900", width: 900, e: e, out: out) { ActionsHistoryContent(store: store) }
    }

    private func render<V: View>(_ name: String, width: CGFloat, e: AppModel, out: URL?, @ViewBuilder _ content: () -> V) {
        let size = CGSize(width: width, height: 628)
        let root = HStack(spacing: 0) {
            Sidebar(section: .constant(.actions), selectedJob: .constant(nil), historyPart: .constant(.actions), openSettings: {})
            content().frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity).clipped().background(Theme.window)
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
