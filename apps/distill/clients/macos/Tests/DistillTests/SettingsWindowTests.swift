import AppKit
import SwiftUI
import XCTest
import DistillKit
@testable import Distill

/// Settings at narrow widths (every section fits the minimum window without the
/// clip guard), and the in-memory scroll position per section, driven through
/// the real Settings window and the same store calls the nav and search make.
@MainActor
final class SettingsWindowTests: XCTestCase {
    /// The page column at the minimum window: window − nav − the page's 36 pt side padding.
    private let pageWidth = SettingsWindowSize.minimum.width - SettingsWindowSize.nav - 72

    // MARK: Fit

    func testEverySectionFitsTheMinimumWindow() {
        let e = StatesSnapshot.engine { $0.enabledRunners = ["claude-code", "ai-sdk"] }
        e.notes.runnerBusy = ["openai": "Checking…"]
        let ui = e.settingsUI
        ui.connections = [ConnectionInfo(id: "atlassian", label: "Atlassian", status: .notConnected, site: nil, account: nil, message: nil,
                                         usedBy: ["jira", "confluence"])]
        ui.connectionsLoad = .loaded
        let views: [(String, AnyView)] = [
            ("vaults", AnyView(VaultsSettings(editingVault: .constant(nil)))),
            ("batching", AnyView(BatchingSettings())),
            ("sources", AnyView(SourcesSettings())),
            ("labels", AnyView(LabelsSettings(notes: e.notes))),
            ("ask-history", AnyView(AskHistorySettings(notes: e.notes))),
            ("shortcuts", AnyView(ShortcutsSettingsSection())),
            ("runners", AnyView(RunnersSettings(notes: e.notes))),
            ("models", AnyView(TaskDefaultsSettings(notes: e.notes))),
            ("actions", AnyView(ActionsSettings(ui: ui, notes: e.notes))),
            ("todo", AnyView(TodoDefaultsSettings())),
            ("connections", AnyView(ConnectionsSettings(ui: ui))),
            ("advanced", AnyView(AdvancedSettings())),
        ] + ["slack", "jira", "confluence"].map { ("actions/\($0)", AnyView(ActionTypeSettingsPage(ui: ui, typeID: $0))) }
        for width in [pageWidth, 890 - SettingsWindowSize.nav - 72] {
            for (name, view) in views {
                let host = NSHostingController(rootView: view.environmentObject(e).environment(\.colorScheme, .light))
                let size = host.sizeThatFits(in: CGSize(width: width, height: 5000))
                XCTAssertLessThanOrEqual(size.width, width + 0.5, "\(name) needs \(Int(size.width)) pt; the page has \(Int(width))")
            }
        }
    }

    func testWindowMinimumIsBelowTheUsualWidth() {
        XCTAssertLessThan(SettingsWindowSize.minimum.width, 890)
        let controller = SettingsWindowController(engine: StatesSnapshot.engine())
        controller.show()
        defer { controller.window?.close() }
        XCTAssertEqual(controller.window?.contentMinSize, SettingsWindowSize.minimum)
    }

    // MARK: Scroll memory

    private var controller: SettingsWindowController!
    private var ui: SettingsStore { controller.engine.settingsUI }

    /// Opens Settings at Vaults at the minimum size (offscreen). Not in setUp: an
    /// async setUp doesn't pump the run loop, so the page would land after the test scrolls.
    private func open() {
        controller = SettingsWindowController(engine: StatesSnapshot.engine())
        controller.engine.settingsUI.target = SettingsTarget(.vaults)
        controller.show()
        controller.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        controller.window?.setContentSize(SettingsWindowSize.minimum)
        settle()
    }

    override func tearDown() async throws {
        controller?.window?.close()
        controller = nil
    }

    private func settle(_ seconds: TimeInterval = 0.4) {
        let end = Date().addingTimeInterval(seconds)
        while Date() < end { RunLoop.main.run(until: Date().addingTimeInterval(0.02)) }
    }

    /// The page's scroll view (the nav doesn't scroll).
    private var scrollView: NSScrollView? {
        func find(_ v: NSView) -> NSScrollView? {
            if let s = v as? NSScrollView, (s.documentView?.frame.height ?? 0) > 0 { return s }
            for sub in v.subviews { if let s = find(sub) { return s } }
            return nil
        }
        return controller.window?.contentView.flatMap(find)
    }

    /// Distance from the top of the page.
    private var offset: CGFloat {
        guard let s = scrollView else { return -1 }
        return s.contentView.bounds.origin.y
    }

    /// Scrolls like the user does (the clip view moves; SwiftUI isn't told).
    private func userScroll(to y: CGFloat) {
        guard let s = scrollView else { return XCTFail("no scroll view") }
        XCTAssertTrue(s.documentView?.isFlipped ?? false, "SwiftUI pages grow downwards")
        s.contentView.scroll(to: NSPoint(x: 0, y: y))
        s.reflectScrolledClipView(s.contentView)
        settle(0.1)
    }

    private func pick(_ section: SettingsSection) {
        ui.select(SettingsTarget(section))
        settle()
    }

    func testANewSectionOpensAtTheTop() {
        open()
        userScroll(to: 300)
        XCTAssertEqual(offset, 300, accuracy: 1)
        // Another group, not visited yet: its page opens at the top.
        pick(.runners)
        XCTAssertEqual(offset, 0, accuracy: 1)
        // The same group as before, not visited: its own heading, not Vaults' leftover offset.
        pick(.vaults)
        pick(.labels)
        XCTAssertNotEqual(offset, 300, accuracy: 1)
        XCTAssertGreaterThan(offset, 0, "scrolled to the Labels heading")
    }

    func testGoingBackRestoresWhereYouLeftIt() {
        open()
        userScroll(to: 300)
        pick(.runners)
        userScroll(to: 120)
        pick(.vaults)
        XCTAssertEqual(offset, 300, accuracy: 1, "Vaults reopens where it was left")
        pick(.runners)
        XCTAssertEqual(offset, 120, accuracy: 1, "AI runners too")
        // A remembered offset past the end of a now shorter page is clamped.
        let max = (scrollView?.documentView?.frame.height ?? 0) - (scrollView?.contentView.bounds.height ?? 0)
        userScroll(to: max)
        pick(.vaults)
        pick(.runners)
        XCTAssertEqual(offset, max, accuracy: 1)
    }

    func testTypePageAndBackToActions() {
        open()
        pick(.actions)
        userScroll(to: 200)
        // An action type row opens its page at the top; "‹ Actions" goes back to where the list was.
        ui.select(SettingsTarget(.actions, actionType: "jira"))
        settle()
        XCTAssertEqual(offset, 0, accuracy: 1)
        ui.select(SettingsTarget(.actions))
        settle()
        XCTAssertEqual(offset, 200, accuracy: 1)
    }

    func testSearchResultsAndDeepLinksStillGoToTheSection() {
        open()
        userScroll(to: 300)
        pick(.runners)
        // A search result (and a deep link from another screen) for Vaults: its section, not the memory.
        ui.query = "vault"
        settle(0.1)
        ui.show(SettingsTarget(.vaults))
        settle()
        XCTAssertEqual(offset, 0, accuracy: 1)
        ui.open("runners")
        settle()
        XCTAssertEqual(offset, 0, accuracy: 1)
    }

    func testClosingSettingsForgetsPositions() {
        open()
        userScroll(to: 300)
        pick(.runners)
        XCTAssertFalse(ui.offsets.isEmpty)
        controller.window?.performClose(nil)
        settle(0.1)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        XCTAssertTrue(ui.offsets.isEmpty, "closing the window clears the memory")
        XCTAssertTrue(ui.promptUndo.isEmpty)

        controller.show()
        controller.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        settle()
        pick(.vaults)
        XCTAssertEqual(offset, 0, accuracy: 1, "a section visited before closing opens at the top again")
    }
}
