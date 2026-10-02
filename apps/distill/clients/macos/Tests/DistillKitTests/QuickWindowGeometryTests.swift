import CoreGraphics
import XCTest
@testable import DistillKit

/// Quick note / quick ask window frames: centering, growth, clamping to the visible frame, the remembered floor.
final class QuickWindowGeometryTests: XCTestCase {
    typealias G = QuickWindowGeometry
    /// A 1440×900 screen with a 25 pt menu bar and no Dock (AppKit: y up).
    let visible = CGRect(x: 0, y: 0, width: 1440, height: 875)
    /// A second screen to the right, lower and smaller.
    let second = CGRect(x: 1440, y: -200, width: 1280, height: 775)
    let floor = CGSize(width: 420, height: 160)

    func testOpensCenteredWithTopAt30Percent() {
        let f = G.openFrame(desired: 200, floor: floor, visible: visible)
        XCTAssertEqual(f.width, 420)
        XCTAssertEqual(f.height, 200)
        XCTAssertEqual(f.midX, visible.midX)
        XCTAssertEqual(f.maxY, visible.maxY - (875 * 0.3).rounded(), "top edge 30 % down the visible frame")
        // Same rule on another screen (the one with the pointer or the flask).
        let g = G.openFrame(desired: 200, floor: floor, visible: second)
        XCTAssertEqual(g.midX, second.midX)
        XCTAssertEqual(g.maxY, second.maxY - (775 * 0.3).rounded())
        XCTAssertTrue(second.contains(g))
    }

    func testOpensWhereTheUserDraggedIt() {
        let f = G.openFrame(desired: 200, floor: floor, visible: visible, remembered: CGPoint(x: 100, y: 700))
        XCTAssertEqual(f.minX, 100)
        XCTAssertEqual(f.maxY, 700)
        // A remembered spot off the screen is pulled back onto it.
        let g = G.openFrame(desired: 200, floor: floor, visible: visible, remembered: CGPoint(x: 1400, y: 2000))
        XCTAssertEqual(g.maxX, visible.maxX - G.sideMargin)
        XCTAssertEqual(g.maxY, visible.maxY)
    }

    func testMinimumAndFloor() {
        XCTAssertEqual(G.fittedHeight(desired: 90, floor: 0, top: 600, visible: visible), 160, "never below 160")
        XCTAssertEqual(G.fittedHeight(desired: 200, floor: 300, top: 600, visible: visible), 300, "the dragged size is a floor")
        XCTAssertEqual(G.fittedHeight(desired: 380, floor: 300, top: 600, visible: visible), 380, "content above the floor grows it")
        let narrow = G.openFrame(desired: 200, floor: CGSize(width: 200, height: 100), visible: visible)
        XCTAssertEqual(narrow.size, CGSize(width: 360, height: 200), "minimum width 360")
    }

    func testGrowsDownwardAndStopsAboveTheBottom() {
        let start = G.openFrame(desired: 180, floor: floor, visible: visible)
        let grown = G.grownFrame(start, desired: 260, floor: 160, hiddenOverflow: 0, visible: visible)
        XCTAssertEqual(grown.maxY, start.maxY, "top edge stays")
        XCTAssertEqual(grown.height, 260)
        let huge = G.grownFrame(start, desired: 5000, floor: 160, hiddenOverflow: 0, visible: visible)
        XCTAssertEqual(huge.maxY, start.maxY)
        XCTAssertEqual(huge.minY, visible.minY + 8, "stops 8 pt above the bottom of the visible frame")
        let back = G.grownFrame(huge, desired: 180, floor: 160, hiddenOverflow: 0, visible: visible)
        XCTAssertEqual(back, start, "shrinks back as content shrinks")
        let floorStop = G.grownFrame(huge, desired: 120, floor: 240, hiddenOverflow: 0, visible: visible)
        XCTAssertEqual(floorStop.height, 240, "never below the floor")
    }

    func testResizeCorner() {
        let start = CGRect(x: 500, y: 300, width: 420, height: 300)
        let bigger = G.resized(start, dx: 80, dy: -100, visible: visible)
        XCTAssertEqual(bigger, CGRect(x: 500, y: 200, width: 500, height: 400), "top-left stays; pointer down = taller")
        let tiny = G.resized(start, dx: -400, dy: 400, visible: visible)
        XCTAssertEqual(tiny.size, G.minSize)
        XCTAssertEqual(tiny.maxY, start.maxY)
        let past = G.resized(start, dx: 5000, dy: -5000, visible: visible)
        XCTAssertEqual(past.maxX, visible.maxX - 8)
        XCTAssertEqual(past.minY, visible.minY + 8)
    }

    func testDraggedSmallerThanContentKeepsItsSize() {
        // Content wants 400; the user drags to 250: 150 stays hidden (the middle scrolls).
        let top: CGFloat = 600
        var hidden = G.hiddenOverflow(desired: 400, height: 250)
        XCTAssertEqual(hidden, 150)
        let floorH: CGFloat = 250
        XCTAssertEqual(G.fittedHeight(desired: 400, floor: floorH, hiddenOverflow: hidden, top: top, visible: visible), 250)
        // Typing a line (+18) grows it by that line, not back to full height.
        hidden = G.updatedHiddenOverflow(hidden, desired: 418, floor: floorH)
        XCTAssertEqual(G.fittedHeight(desired: 418, floor: floorH, hiddenOverflow: hidden, top: top, visible: visible), 268)
        // Deleting until everything fits clears the hidden part; it stays at the floor.
        hidden = G.updatedHiddenOverflow(hidden, desired: 200, floor: floorH)
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(G.fittedHeight(desired: 200, floor: floorH, hiddenOverflow: hidden, top: top, visible: visible), 250)
        // Growing again from there grows the window normally.
        hidden = G.updatedHiddenOverflow(hidden, desired: 320, floor: floorH)
        XCTAssertEqual(G.fittedHeight(desired: 320, floor: floorH, hiddenOverflow: hidden, top: top, visible: visible), 320)
    }

    func testDraggedBiggerFillsAndNeverShrinksBelow() {
        let hidden = G.hiddenOverflow(desired: 200, height: 420)
        XCTAssertEqual(hidden, 0)
        XCTAssertEqual(G.fittedHeight(desired: 200, floor: 420, hiddenOverflow: hidden, top: 600, visible: visible), 420)
    }
}
