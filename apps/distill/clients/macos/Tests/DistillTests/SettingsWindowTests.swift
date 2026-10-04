import AppKit
import SwiftUI
import XCTest
import DistillKit
@testable import Distill

/// Settings shows one page per section (and per action type). Each page fits the
/// minimum window and the usual ~890 pt without the clip guard; each keeps its
/// own scroll position for the Settings session; search results and deep links
/// land on the page's top or the matched row. Driven through the real Settings
/// window and the same store calls the nav, links and search make.
@MainActor
final class SettingsWindowTests: XCTestCase {
    /// Every page: each section, then each action type's page.
    private static let pages: [SettingsTarget] = SettingsSection.allCases.map { SettingsTarget($0) }
        + SettingsActionType.builtIn.filter { !$0.reserved && $0.id != "todo" }.map { SettingsTarget(.actions, actionType: $0.id) }

    private static func fixtureEngine() -> AppModel {
        let e = StatesSnapshot.engine { $0.enabledRunners = ["claude-code", "ai-sdk"] }
        e.notes.runnerBusy = ["openai": "Checking…"]
        e.settingsUI.connections = [ConnectionInfo(id: "atlassian", label: "Atlassian", status: .notConnected, site: nil, account: nil, message: nil,
                                                   usedBy: ["jira", "confluence"])]
        e.settingsUI.connectionsLoad = .loaded
        return e
    }

    // MARK: Fit

    func testEveryPageFitsTheMinimumAndTheUsualWidth() {
        let e = Self.fixtureEngine()
        for window in [SettingsWindowSize.minimum.width, 890] {
            let width = window - SettingsWindowSize.nav - 2 * SettingsPage.sidePadding
            for target in Self.pages {
                // The page as shown (header, content, Advanced expanded), without the clip guard.
                let page = SettingsPage(ui: e.settingsUI, target: target, editingVault: .constant(nil), showAdvanced: .constant(true))
                let host = NSHostingController(rootView: page.environmentObject(e).environment(\.colorScheme, .light))
                let size = host.sizeThatFits(in: CGSize(width: width, height: 5000))
                XCTAssertLessThanOrEqual(size.width, width + 0.5,
                                         "\(target.id) needs \(Int(size.width)) pt at a \(Int(window)) pt window; the page has \(Int(width))")
            }
        }
    }

    func testWindowMinimumIsBelowTheUsualWidth() {
        XCTAssertLessThan(SettingsWindowSize.minimum.width, 890)
        let controller = SettingsWindowController(engine: StatesSnapshot.engine())
        controller.show()
        defer { controller.window?.close() }
        XCTAssertEqual(controller.window?.contentMinSize, SettingsWindowSize.minimum)
        // Nothing in the page pushes the window's minimum up: a smaller size stops at 820.
        controller.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        controller.window?.setContentSize(NSSize(width: 500, height: 500))
        RunLoop.main.run(until: Date().addingTimeInterval(0.3))
        XCTAssertEqual(controller.window?.minSize.width, SettingsWindowSize.minimum.width)
        let host = NSHostingController(rootView: SettingsView().environmentObject(controller.engine))
        XCTAssertEqual(host.sizeThatFits(in: CGSize(width: 100, height: 100)).width, SettingsWindowSize.minimum.width,
                       "the Settings view asks for no more than the window minimum")
    }

    /// In the real window, at 820 and 890: every page starts right of the full-width
    /// nav and never scrolls sideways.
    func testEveryPageInTheWindowKeepsTheNavWhole() {
        controller = SettingsWindowController(engine: Self.fixtureEngine())
        controller.show()
        controller.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        for width in [SettingsWindowSize.minimum.width, 890] {
            controller.window?.setContentSize(NSSize(width: width, height: SettingsWindowSize.minimum.height))
            for target in Self.pages {
                ui.select(target)
                settle(0.3)
                guard let scroll = scrollView else { XCTFail("\(target.id): no page"); continue }
                let frame = scroll.convert(scroll.bounds, to: nil)
                XCTAssertEqual(frame.minX, SettingsWindowSize.nav, accuracy: 0.5, "\(target.id) at \(Int(width)): the nav keeps its 236 pt")
                XCTAssertEqual(frame.maxX, width, accuracy: 0.5, "\(target.id) at \(Int(width)): the page ends at the window's edge")
                XCTAssertLessThanOrEqual(scroll.documentView?.frame.width ?? 0, scroll.contentView.bounds.width + 0.5,
                                         "\(target.id) at \(Int(width)) is wider than its column")
            }
        }
    }

    // MARK: Scroll memory

    private var controller: SettingsWindowController!
    private var ui: SettingsStore { controller.engine.settingsUI }

    /// Opens Settings at `target` at the minimum size (offscreen). Not in setUp: an
    /// async setUp doesn't pump the run loop, so the page would land after the test scrolls.
    private func open(_ target: SettingsTarget = SettingsTarget(.labels)) {
        controller = SettingsWindowController(engine: Self.fixtureEngine())
        controller.engine.settingsUI.target = target
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

    /// How far the current page can scroll.
    private var maxOffset: CGFloat {
        guard let s = scrollView else { return 0 }
        return (s.documentView?.frame.height ?? 0) - s.contentView.bounds.height
    }

    /// Scrolls like the user does (the clip view moves; SwiftUI isn't told).
    private func userScroll(to y: CGFloat, file: StaticString = #filePath, line: UInt = #line) {
        guard let s = scrollView else { return XCTFail("no scroll view", file: file, line: line) }
        XCTAssertTrue(s.documentView?.isFlipped ?? false, "SwiftUI pages grow downwards", file: file, line: line)
        XCTAssertGreaterThan(maxOffset, y, "\(ui.target.id) must be taller than the window for this test", file: file, line: line)
        s.contentView.scroll(to: NSPoint(x: 0, y: y))
        s.reflectScrolledClipView(s.contentView)
        settle(0.1)
    }

    private func pick(_ section: SettingsSection) {
        ui.select(SettingsTarget(section))
        settle()
    }

    // At 820×600 with the fixtures, Actions, Models for tasks and the action type
    // pages scroll; the other pages fit the window (offset 0 is all they have).

    func testFirstVisitOpensAtTheTop() {
        open(SettingsTarget(.actions))
        userScroll(to: 200)
        // Unvisited pages, of the same nav group and of others: each at its top,
        // not at Actions' offset and not at a heading further down a shared page.
        for section in [SettingsSection.todo, .connections, .models, .labels, .runners] {
            pick(section)
            XCTAssertEqual(offset, 0, accuracy: 1, "\(section.rawValue) opens at its top")
        }
        ui.select(SettingsTarget(.actions, actionType: "jira"))
        settle()
        XCTAssertEqual(offset, 0, accuracy: 1, "an action type's page opens at its top")
    }

    func testGoingBackRestoresWhereYouLeftIt() {
        open(SettingsTarget(.actions))
        userScroll(to: 200)
        pick(.models)
        userScroll(to: 100)
        pick(.todo)
        pick(.actions)
        XCTAssertEqual(offset, 200, accuracy: 1, "Actions reopens where it was left")
        pick(.models)
        XCTAssertEqual(offset, 100, accuracy: 1, "Models for tasks too, separately from Actions")
        // Runners shares the AI nav group with Models, but not its position.
        pick(.runners)
        XCTAssertEqual(offset, 0, accuracy: 1)
    }

    func testARememberedOffsetIsClampedWhenThePageGotShorter() {
        open(SettingsTarget(.models))
        let bottom = maxOffset
        XCTAssertGreaterThan(bottom, 40, "Models for tasks scrolls at 820×600")
        userScroll(to: bottom - 1)
        pick(.labels)
        // A taller window: the same page has less to scroll.
        controller.window?.setContentSize(NSSize(width: SettingsWindowSize.minimum.width, height: SettingsWindowSize.minimum.height + 30))
        settle(0.2)
        pick(.models)
        XCTAssertLessThan(maxOffset, bottom - 1)
        XCTAssertEqual(offset, maxOffset, accuracy: 1, "clamped to the end of the page")
    }

    func testTypePageAndBackToActions() {
        open(SettingsTarget(.actions))
        userScroll(to: 150)
        // An action type row opens its page at the top; "‹ Actions" goes back to where the list was.
        ui.select(SettingsTarget(.actions, actionType: "jira"))
        settle()
        XCTAssertEqual(offset, 0, accuracy: 1)
        userScroll(to: 120)
        ui.select(SettingsTarget(.actions))
        settle()
        XCTAssertEqual(offset, 150, accuracy: 1)
        ui.select(SettingsTarget(.actions, actionType: "jira"))
        settle()
        XCTAssertEqual(offset, 120, accuracy: 1, "the type page keeps its own position")
    }

    func testSearchResultsAndDeepLinksOpenAtTheTop() {
        open(SettingsTarget(.actions))
        userScroll(to: 200)
        pick(.models)
        userScroll(to: 100)
        ui.select(SettingsTarget(.actions, actionType: "jira"))
        settle()
        userScroll(to: 120)
        pick(.todo)
        // A search result for the section itself (“Models for tasks” isn't an entry; use the
        // page's own deep link id): its top, not the memory.
        ui.query = "model"
        settle(0.1)
        ui.show(SettingsTarget(.models))
        settle()
        XCTAssertEqual(ui.target, SettingsTarget(.models))
        XCTAssertEqual(offset, 0, accuracy: 1)
        // Deep links from other screens (`openSettings(section:)` → AppDelegate → open).
        pick(.todo)
        ui.open("actions")
        settle()
        XCTAssertEqual(ui.target, SettingsTarget(.actions))
        XCTAssertEqual(offset, 0, accuracy: 1)
        ui.open("actions/jira")
        settle()
        XCTAssertEqual(ui.target, SettingsTarget(.actions, actionType: "jira"))
        XCTAssertEqual(offset, 0, accuracy: 1)
        // "Open Actions ›" on Models for tasks is a link to Actions' top too.
        pick(.actions)
        userScroll(to: 200)
        pick(.models)
        ui.show(SettingsTarget(.actions))
        settle()
        XCTAssertEqual(offset, 0, accuracy: 1)
    }

    /// The anchor of `title` on the shown page, and whether it is in view.
    private func rowInView(_ title: String) -> (y: CGFloat, visible: Bool)? {
        guard let y = ui.anchors[ui.target]?[SettingsAnchor.key(title)], let s = scrollView else { return nil }
        let top = s.contentView.bounds.origin.y
        return (y, y >= top - 0.5 && y + 20 <= top + s.contentView.bounds.height)
    }

    func testASearchResultLandsOnItsRow() {
        open(SettingsTarget(.vaults))
        let height = SettingsWindowSize.minimum.height
        for (target, title) in [(SettingsTarget(.models), "Finding actions"),
                                (SettingsTarget(.actions, actionType: "jira"), "Improve prompt"),
                                (SettingsTarget(.actions, actionType: "confluence"), "Create prompt"),
                                (SettingsTarget(.labels), "CLI: use AI labels if none are sent back")] {
            ui.query = title
            settle(0.1)
            ui.show(target, row: title)
            settle()
            guard let row = rowInView(title) else { XCTFail("\(target.id): no row “\(title)”"); continue }
            if row.y + 20 > height {
                XCTAssertGreaterThan(offset, 0, "\(target.id): scrolled down to “\(title)”")
            }
            XCTAssertTrue(row.visible, "\(target.id): “\(title)” at \(Int(row.y)) is in view (offset \(Int(offset)))")
        }
    }

    /// Every search entry lands on its own row, except those that are the section
    /// itself (its top) and Queue folder (inside the vault editor sheet). Catches a
    /// row renamed without its anchor.
    func testEverySearchEntryHasItsRow() {
        open(SettingsTarget(.vaults))
        let atTop: Set<String> = ["Queue folder"]
        for entry in SettingsIndex.all(types: SettingsActionType.builtIn) {
            if entry.title == entry.target.section.title || atTop.contains(entry.title) { continue }
            ui.query = entry.title
            settle(0.05)
            ui.show(entry)
            settle(0.35)
            guard let row = rowInView(entry.title) else {
                XCTFail("\(entry.crumb) › \(entry.title): no row on \(entry.target.id) reports this anchor")
                continue
            }
            XCTAssertTrue(row.visible, "\(entry.crumb) › \(entry.title) is in view")
        }
    }

    func testClosingSettingsForgetsPositions() {
        open(SettingsTarget(.actions))
        userScroll(to: 200)
        pick(.models)
        XCTAssertEqual(ui.offsets[SettingsTarget(.actions)] ?? -1, 200, accuracy: 1)
        controller.window?.performClose(nil)
        settle(0.1)
        XCTAssertFalse(controller.window?.isVisible ?? true)
        XCTAssertTrue(ui.offsets.isEmpty, "closing the window clears the memory")
        XCTAssertTrue(ui.anchors.isEmpty)
        XCTAssertTrue(ui.promptUndo.isEmpty)

        controller.show()
        controller.window?.setFrameOrigin(NSPoint(x: -30000, y: -30000))
        settle()
        pick(.actions)
        XCTAssertGreaterThan(maxOffset, 200)
        XCTAssertEqual(offset, 0, accuracy: 1, "a page visited before closing opens at the top again")
    }
}
