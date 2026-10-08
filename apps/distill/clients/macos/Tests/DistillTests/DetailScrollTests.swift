import AppKit
import SwiftUI
import XCTest
import DistillKit
@testable import Distill

/// A to-do whose context runs past a short window: the detail's content scrolls and its footer
/// (Remove, Complete, Send to) stays inside the pane. Hosts the real TodoDetail offscreen with
/// fixture data; nothing connects.
@MainActor
final class DetailScrollTests: XCTestCase {
    private func longTodo() -> ActionItem {
        var item = ActionFixtures.live().first { $0.id == "t2" }!
        item.context = StatesSnapshot.ActionContextFixtures.items()[0].context
        item.body = (1...12).map { "Step \($0): confirm the room, the kettle and the tasting cups with Mei." }.joined(separator: "\n\n")
        return item
    }

    /// Lays out the detail at `size` in an offscreen window and returns the window's content view.
    private func host(_ item: ActionItem, size: CGSize, menu: String? = nil) -> NSView {
        let e = StatesSnapshot.engine()
        ActionFixtures.load(e, items: [item], select: item.id)
        let root = TodoDetail(store: e.actions, item: item, editing: .constant(false), menu: .constant(menu))
            .environmentObject(e)
            .frame(width: size.width, height: size.height)
        let view = NSHostingView(rootView: root)
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        view.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(0.2))
        view.layoutSubtreeIfNeeded()
        return view
    }

    private func scrollViews(in view: NSView) -> [NSScrollView] {
        view.subviews.flatMap { sub -> [NSScrollView] in (sub as? NSScrollView).map { [$0] } ?? scrollViews(in: sub) }
    }

    func testContentScrollsAboveAPinnedFooterWhenTheContextIsLong() throws {
        let size = CGSize(width: 440, height: 420)
        let view = host(longTodo(), size: size)
        let scroll = try XCTUnwrap(scrollViews(in: view).first, "the detail's content is in a scroll view")
        // Window coordinates, origin at the bottom: the footer's room is below the scroll view.
        let frame = scroll.convert(scroll.bounds, to: nil)
        XCTAssertEqual(frame.maxY, size.height, accuracy: 1, "the scroll starts at the top of the pane")
        XCTAssertGreaterThan(frame.minY, 50, "the footer (Remove, Complete, Send to) keeps its row below the scroll: \(frame)")
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertGreaterThan(document.frame.height, scroll.contentView.bounds.height + 50, "the long context runs past the viewport, so it scrolls")
    }

    /// Send to's panel opens upward from the pinned footer over the scrolling content: a click there
    /// reaches the panel, not the scroll view under it.
    func testSendToPanelOverTheScrollTakesTheClick() throws {
        let size = CGSize(width: 440, height: 420)
        let point = CGPoint(x: size.width - 80, y: 110)
        let closed = host(longTodo(), size: size)
        let under = try XCTUnwrap(closed.hitTest(point))
        XCTAssertNotNil(under.enclosingScrollView, "without the panel, this point is in the scrolling content")
        let open = host(longTodo(), size: size, menu: "sendto")
        let hit = try XCTUnwrap(open.hitTest(point))
        XCTAssertNil(hit.enclosingScrollView, "the panel, drawn over the scroll, gets the click: \(hit)")
    }

    func testShortContentFillsThePaneWithTheFooterAtTheBottom() throws {
        let size = CGSize(width: 440, height: 900)
        let item = ActionFixtures.live().first { $0.id == "t2" }!
        let view = host(item, size: size)
        let scroll = try XCTUnwrap(scrollViews(in: view).first)
        let frame = scroll.convert(scroll.bounds, to: nil)
        XCTAssertGreaterThan(frame.height, size.height - 120, "the scroll area takes the spare height, so the footer stays at the bottom: \(frame)")
        XCTAssertLessThan(frame.minY, 120)
        let document = try XCTUnwrap(scroll.documentView)
        XCTAssertLessThanOrEqual(document.frame.height, scroll.contentView.bounds.height + 1, "short content leaves nothing to scroll")
    }

    private final class Shown<T>: ObservableObject { @Published var item: T; init(_ i: T) { item = i } }
    private struct DetailHost<T, D: View>: View {
        @ObservedObject var shown: Shown<T>
        let detail: (T) -> D
        var body: some View { detail(shown.item) }
    }

    /// Scrolls the first item's detail down, selects `second`, and checks the next detail opens at the top.
    private func assertOpensAtTheTop<D: View>(_ first: ActionItem, _ second: ActionItem, file: StaticString = #filePath, line: UInt = #line,
                                              _ detail: @escaping (ActionsStore, ActionItem) -> D) throws {
        let e = StatesSnapshot.engine()
        ActionFixtures.load(e, items: [first, second], select: first.id)
        try assertOpensAtTheTop(first, second, engine: e, file: file, line: line, detail)
    }

    private func assertOpensAtTheTop<T, D: View>(_ first: T, _ second: T, engine e: AppModel, file: StaticString = #filePath, line: UInt = #line,
                                                 _ detail: @escaping (ActionsStore, T) -> D) throws {
        let shown = Shown(first)
        let size = CGSize(width: 440, height: 420)
        let store = e.actions
        let view = NSHostingView(rootView: DetailHost(shown: shown) { detail(store, $0) }.environmentObject(e).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func settle() { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)); view.layoutSubtreeIfNeeded() }
        settle()
        let scroll = try XCTUnwrap(scrollViews(in: view).first, file: file, line: line)
        let flipped = scroll.documentView?.isFlipped ?? true
        let top = flipped ? 0 : max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: flipped ? 200 : top - 200))
        XCTAssertNotEqual(scroll.contentView.bounds.origin.y, top, accuracy: 1, "scrolled down the first item", file: file, line: line)

        shown.item = second
        settle()
        let next = try XCTUnwrap(scrollViews(in: view).first, file: file, line: line)
        let nextTop = flipped ? 0 : max(0, (next.documentView?.frame.height ?? 0) - next.contentView.bounds.height)
        XCTAssertEqual(next.contentView.bounds.origin.y, nextTop, accuracy: 1, "the next item opens at the top", file: file, line: line)
    }

    func testPendingDetailOpensAtTheTopWhenAnotherItemIsSelected() throws {
        var first = longTodo(); first.id = "w1"; first.status = .open; first.route = .waiting; first.owner = "Mei"
        var second = first; second.id = "w2"
        try assertOpensAtTheTop(first, second) { PendingDetail(store: $0, item: $1) }
    }

    func testTodoDetailOpensAtTheTopWhenAnotherItemIsSelected() throws {
        let first = longTodo()
        var second = first; second.id = "t2-other"
        try assertOpensAtTheTop(first, second) { TodoDetail(store: $0, item: $1, editing: .constant(false), menu: .constant(nil)) }
    }

    func testConfirmDetailOpensAtTheTopWhenAnotherItemIsSelected() throws {
        var first = longTodo(); first.id = "c1"; first.status = .pending; first.summary = "A long one."
        var second = first; second.id = "c2"
        try assertOpensAtTheTop(first, second) { ConfirmDetail(store: $0, item: $1) }
    }

    /// Highlights' detail is keyed by the note, not an action item (HighlightsViews.swift's `.id(note.notePath)`).
    func testHighlightDetailOpensAtTheTopWhenAnotherNoteIsSelected() throws {
        let notes = RoutingFixtures.highlights()
        var first = notes[0]
        first.wiki?.summary = (1...12).map { "Point \($0): the shared Storybook, the mock server and the deploy migration." }.joined(separator: " ")
        var second = first; second.notePath = "wiki/sources/another.md"
        try assertOpensAtTheTop(first, second, engine: StatesSnapshot.engine()) { HighlightDetail(store: $0, note: $1) }
    }

    func testOverflowNeedsMoreThanRounding() {
        XCTAssertFalse(PinnedFooterLayout.overflows(content: 400, viewport: 400))
        XCTAssertFalse(PinnedFooterLayout.overflows(content: 400.4, viewport: 400))
        XCTAssertTrue(PinnedFooterLayout.overflows(content: 401, viewport: 400))
    }
}
