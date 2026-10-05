import XCTest
@testable import Distill

/// Resizable panes (docs/specs/resizable-panes.md): the width rules behind `.paneWidth`.
final class PaneLayoutTests: XCTestCase {
    func testMissingZeroOrNonFiniteIsAutomatic() {
        let s = PaneSpec.reviewConversation
        XCTAssertEqual(PaneLayout.width(saved: 0, automatic: 300, spec: s, container: 1400), 300)
        XCTAssertEqual(PaneLayout.width(saved: -5, automatic: 300, spec: s, container: 1400), 300)
        XCTAssertEqual(PaneLayout.width(saved: .nan, automatic: 300, spec: s, container: 1400), 300)
        XCTAssertEqual(PaneLayout.width(saved: .infinity, automatic: 300, spec: s, container: 1400), 300)
    }

    func testSavedWidthIsClampedToMinAndMax() {
        let s = PaneSpec.sidebar
        XCTAssertEqual(PaneLayout.width(saved: 260, automatic: 220, spec: s, container: 1400), 260)
        XCTAssertEqual(PaneLayout.width(saved: 100, automatic: 220, spec: s, container: 1400), 200)
        XCTAssertEqual(PaneLayout.width(saved: 900, automatic: 220, spec: s, container: 1400), 320)
    }

    func testOtherColumnKeepsItsMinimum() {
        // Review: details keep 360 + padding and gap (448 reserved). In a 900 pt detail the Conversation tops out at 452.
        let s = PaneSpec.reviewConversation
        XCTAssertEqual(PaneLayout.upper(s, automatic: 300, container: 900), 452)
        XCTAssertEqual(PaneLayout.width(saved: 520, automatic: 300, spec: s, container: 900), 452)
    }

    func testAutomaticWidthIsNeverSqueezedFurther() {
        // A narrow container leaves less than the automatic width: the automatic width still fits.
        let s = PaneSpec.reviewConversation
        XCTAssertEqual(PaneLayout.upper(s, automatic: 240, container: 600), 240)
        XCTAssertEqual(PaneLayout.upper(s, automatic: 240, container: nil), 520)
    }

    func testDragDirectionFollowsTheEdge() {
        XCTAssertEqual(PaneLayout.dragged(start: 220, translation: 30, edge: .trailing), 250)
        XCTAssertEqual(PaneLayout.dragged(start: 300, translation: 30, edge: .leading), 270)
    }

    func testDragReportsLimits() {
        let s = PaneSpec.sidebar
        let low = PaneLayout.drag(start: 220, translation: -80, spec: s, automatic: 220, container: 1400)
        XCTAssertEqual(low.width, 200); XCTAssertEqual(low.limit, .min)
        let high = PaneLayout.drag(start: 220, translation: 400, spec: s, automatic: 220, container: 1400)
        XCTAssertEqual(high.width, 320); XCTAssertEqual(high.limit, .max)
        let mid = PaneLayout.drag(start: 220, translation: 40, spec: s, automatic: 220, container: 1400)
        XCTAssertEqual(mid.width, 260); XCTAssertNil(mid.limit)
    }

    func testKeysAreDistinctAndPerType() {
        XCTAssertEqual(Set(PaneSpec.fixedKeys).count, PaneSpec.fixedKeys.count)
        XCTAssertNotEqual(PaneSpec.actionsList("jira").key, PaneSpec.actionsList("slack").key)
        XCTAssertTrue(PaneSpec.fixedKeys.allSatisfy { $0.hasPrefix("distill.pane.") })
    }
}
