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
    private func host(_ item: ActionItem, size: CGSize) -> NSView {
        let e = StatesSnapshot.engine()
        ActionFixtures.load(e, items: [item], select: item.id)
        let root = TodoDetail(store: e.actions, item: item, editing: .constant(false), menu: .constant(nil))
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

    func testShortContentFillsThePaneWithTheFooterAtTheBottom() throws {
        let size = CGSize(width: 440, height: 900)
        let item = ActionFixtures.live().first { $0.id == "t2" }!
        let view = host(item, size: size)
        let scroll = try XCTUnwrap(scrollViews(in: view).first)
        let frame = scroll.convert(scroll.bounds, to: nil)
        XCTAssertGreaterThan(frame.height, size.height - 120, "the scroll area takes the spare height, so the footer stays at the bottom: \(frame)")
        XCTAssertLessThan(frame.minY, 120)
    }

    private final class Shown: ObservableObject { @Published var item: ActionItem; init(_ i: ActionItem) { item = i } }
    private struct PendingHost: View {
        @ObservedObject var store: ActionsStore
        @ObservedObject var shown: Shown
        var body: some View { PendingDetail(store: store, item: shown.item) }
    }

    func testPendingDetailOpensAtTheTopWhenAnotherItemIsSelected() throws {
        var first = longTodo(); first.id = "w1"; first.status = .open; first.route = .waiting; first.owner = "Mei"
        var second = first; second.id = "w2"
        let e = StatesSnapshot.engine()
        ActionFixtures.load(e, items: [first, second], select: first.id)
        let shown = Shown(first)
        let size = CGSize(width: 440, height: 420)
        let view = NSHostingView(rootView: PendingHost(store: e.actions, shown: shown).environmentObject(e).frame(width: size.width, height: size.height))
        let window = NSWindow(contentRect: CGRect(origin: .zero, size: size), styleMask: [.borderless], backing: .buffered, defer: false)
        window.contentView = view
        func settle() { view.layoutSubtreeIfNeeded(); RunLoop.main.run(until: Date().addingTimeInterval(0.2)); view.layoutSubtreeIfNeeded() }
        settle()
        let scroll = try XCTUnwrap(scrollViews(in: view).first)
        let flipped = scroll.documentView?.isFlipped ?? true
        let top = flipped ? 0 : max(0, (scroll.documentView?.frame.height ?? 0) - scroll.contentView.bounds.height)
        scroll.contentView.scroll(to: CGPoint(x: 0, y: flipped ? 200 : top - 200))
        XCTAssertNotEqual(scroll.contentView.bounds.origin.y, top, accuracy: 1, "scrolled down the first item")

        shown.item = second
        settle()
        let next = try XCTUnwrap(scrollViews(in: view).first)
        let nextTop = flipped ? 0 : max(0, (next.documentView?.frame.height ?? 0) - next.contentView.bounds.height)
        XCTAssertEqual(next.contentView.bounds.origin.y, nextTop, accuracy: 1, "the next item opens at the top")
    }

    func testOverflowNeedsMoreThanRounding() {
        XCTAssertFalse(PinnedFooterLayout.overflows(content: 400, viewport: 400))
        XCTAssertFalse(PinnedFooterLayout.overflows(content: 400.4, viewport: 400))
        XCTAssertTrue(PinnedFooterLayout.overflows(content: 401, viewport: 400))
    }
}
