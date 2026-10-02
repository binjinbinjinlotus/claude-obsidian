import AppKit
import XCTest
@testable import Distill

/// Quick windows are non-activating, so they route ⌘X/C/V/A/Z themselves.
@MainActor
final class QuickWindowEditKeysTests: XCTestCase {
    private func key(_ chars: String, _ flags: NSEvent.ModifierFlags) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0,
                         context: nil, characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: 0)!
    }

    func testMapsStandardEditKeys() {
        XCTAssertEqual(QuickWindow.editAction(for: key("c", .command)), #selector(NSText.copy(_:)))
        XCTAssertEqual(QuickWindow.editAction(for: key("v", .command)), #selector(NSText.paste(_:)))
        XCTAssertEqual(QuickWindow.editAction(for: key("x", .command)), #selector(NSText.cut(_:)))
        XCTAssertEqual(QuickWindow.editAction(for: key("a", .command)), #selector(NSText.selectAll(_:)))
        XCTAssertEqual(QuickWindow.editAction(for: key("z", .command)), Selector(("undo:")))
        XCTAssertEqual(QuickWindow.editAction(for: key("Z", [.command, .shift])), Selector(("redo:")))
        XCTAssertNil(QuickWindow.editAction(for: key("v", [.command, .option])))
        XCTAssertNil(QuickWindow.editAction(for: key("v", [])))
    }

    func testSelectAllReachesTheFocusedTextView() {
        let window = QuickWindow(width: 420)
        let text = NSTextView(frame: NSRect(x: 0, y: 0, width: 300, height: 100))
        text.string = "hello quick ask"
        window.contentView = text
        XCTAssertTrue(window.makeFirstResponder(text))
        text.setSelectedRange(NSRange(location: 0, length: 0))
        XCTAssertTrue(window.performKeyEquivalent(with: key("a", .command)))
        XCTAssertEqual(text.selectedRange(), NSRange(location: 0, length: 15))
    }
}
