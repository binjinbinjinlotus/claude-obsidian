import AppKit
import SwiftUI
import XCTest
@testable import Distill

/// The live QuickShell (not the snapshot path) reports a desired height that
/// grows with content and comes back down when a slot empties.
@MainActor
final class QuickShellLiveTests: XCTestCase {
    final class Model: ObservableObject {
        @Published var lines = 2
        @Published var showError = false
        @Published var images = 0
    }

    struct Probe: View {
        @ObservedObject var model: Model
        let report: (CGFloat) -> Void

        var body: some View {
            QuickShell(title: "Quick note", close: {}, onDesiredHeight: report) {
                EmptyView()
            } top: {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(0..<model.lines, id: \.self) { i in Text("Line \(i)").frame(height: 18) }
                }
            } bottom: {
                if model.showError || model.images > 0 {
                    VStack(spacing: 8) {
                        ForEach(0..<model.images, id: \.self) { _ in Color.gray.frame(height: 60) }
                        if model.showError { Text("Couldn't queue the note.").frame(height: 30) }
                    }
                }
            } footer: {
                Text("footer").frame(height: 34)
            }
        }
    }

    private func pump() {
        for _ in 0..<6 { RunLoop.main.run(until: Date().addingTimeInterval(0.03)) }
    }

    func testDesiredHeightGrowsAndShrinksBack() {
        let model = Model()
        var last: CGFloat = 0
        let host = NSHostingView(rootView: Probe(model: model) { last = $0 })
        host.sizingOptions = []
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 300), styleMask: [.borderless],
                              backing: .buffered, defer: false)
        window.contentView = host
        host.frame = window.contentLayoutRect
        host.layoutSubtreeIfNeeded()
        pump()
        let start = last
        XCTAssertGreaterThan(start, 0)

        model.lines = 6
        pump()
        XCTAssertEqual(last - start, 4 * 22, accuracy: 1, "four more lines of 18 + 4")

        model.lines = 2
        pump()
        XCTAssertEqual(last, start, accuracy: 0.5)

        model.images = 1
        pump()
        let withImage = last
        XCTAssertGreaterThan(withImage, start + 60)
        model.images = 0
        pump()
        XCTAssertEqual(last, start, accuracy: 0.5, "removing the last image shrinks it back")

        model.showError = true
        pump()
        XCTAssertGreaterThan(last, start + 30)
        model.showError = false
        pump()
        XCTAssertEqual(last, start, accuracy: 0.5, "clearing the error shrinks it back")

        // The window's own height never feeds back into the desired height.
        window.setContentSize(NSSize(width: 420, height: 700))
        host.frame = window.contentLayoutRect
        pump()
        XCTAssertEqual(last, start, accuracy: 0.5)
    }
}
