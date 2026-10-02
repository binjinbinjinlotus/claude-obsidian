import AppKit
import SwiftUI
import XCTest
@testable import Distill

/// The live Review reply box (not the snapshot path) draws its placeholder.
@MainActor
final class ReplyPlaceholderLiveTests: XCTestCase {
    private func pump() {
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    /// Pixels close to the placeholder gray (#9B978F) in the hosted view.
    private func placeholderPixels(_ view: NSView) -> Int {
        let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds)!
        view.cacheDisplay(in: view.bounds, to: rep)
        var count = 0
        for x in 0..<rep.pixelsWide {
            for y in 0..<rep.pixelsHigh {
                guard let c = rep.colorAt(x: x, y: y)?.usingColorSpace(.sRGB) else { continue }
                if abs(c.redComponent - 0x9B / 255) < 0.12, abs(c.greenComponent - 0x97 / 255) < 0.12,
                   abs(c.blueComponent - 0x8F / 255) < 0.12, c.alphaComponent > 0.5 { count += 1 }
            }
        }
        return count
    }

    func testEmptyReplyShowsPlaceholder() {
        var text = ""
        let host = NSHostingView(rootView: ReplyEditor(text: Binding(get: { text }, set: { text = $0 }))
            .frame(width: 290).padding(10).background(Color.white))
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 310, height: 260), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        pump()
        host.layoutSubtreeIfNeeded()
        let empty = placeholderPixels(host)
        XCTAssertGreaterThan(empty, 1000, "the placeholder text is drawn")

        guard let tv = textView(in: host) else { return XCTFail("no text view") }
        tv.insertText("Use the Gyokuro page", replacementRange: tv.selectedRange())
        pump()
        XCTAssertEqual(text, "Use the Gyokuro page")
        XCTAssertLessThan(placeholderPixels(host), empty / 2, "typed text hides the placeholder")

        tv.selectAll(nil)
        tv.insertText("", replacementRange: tv.selectedRange())
        pump()
        XCTAssertEqual(text, "")
        XCTAssertGreaterThan(placeholderPixels(host), empty / 2, "clearing the reply brings the placeholder back")
    }

    private func textView(in view: NSView) -> MarkdownTextView? {
        if let tv = view as? MarkdownTextView { return tv }
        for sub in view.subviews { if let tv = textView(in: sub) { return tv } }
        return nil
    }
}
