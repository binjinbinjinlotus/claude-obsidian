import AppKit
import SwiftUI
import XCTest
@testable import Distill

/// The text view and controller together (offscreen window, no app run loop).
@MainActor
final class MarkdownEditorViewTests: XCTestCase {
    final class Box { var text: String; init(_ t: String) { text = t } }

    private func makeEditor(_ text: String = "", submit: MarkdownSubmitMode = .commandReturn)
        -> (MarkdownEditorController, MarkdownTextView, Box, NSWindow) {
        let controller = MarkdownEditorController()
        let box = Box(text)
        let area = MarkdownTextArea(text: Binding(get: { box.text }, set: { box.text = $0 }), controller: controller, size: 13,
                                    placeholder: "Write…", editable: true, scrolls: false, autoFocus: false)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 400, height: 300), styleMask: [.titled], backing: .buffered, defer: true)
        let host = NSHostingView(rootView: area.frame(width: 400, height: 300))
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        controller.submitMode = submit
        let tv = controller.textView!
        window.makeFirstResponder(tv)
        return (controller, tv, box, window)
    }

    private func key(_ chars: String, _ flags: NSEvent.ModifierFlags, code: UInt16) -> NSEvent {
        NSEvent.keyEvent(with: .keyDown, location: .zero, modifierFlags: flags, timestamp: 0, windowNumber: 0, context: nil,
                         characters: chars, charactersIgnoringModifiers: chars, isARepeat: false, keyCode: code)!
    }

    func testShortcutWrapsAndUndoRestores() {
        let (controller, tv, box, _) = makeEditor("Use 60 °C here")
        tv.setSelectedRange(NSRange(location: 4, length: 5))
        XCTAssertTrue(controller.handleKeyEquivalent(key("b", .command, code: 11)))
        XCTAssertEqual(box.text, "Use **60 °C** here")
        XCTAssertEqual(tv.selectedRange(), NSRange(location: 6, length: 5))
        tv.undoManager?.undo()
        XCTAssertEqual(tv.string, "Use 60 °C here")
        XCTAssertTrue(controller.handleKeyEquivalent(key("*", [.command, .shift], code: 28)))
        XCTAssertTrue(tv.string.hasPrefix("- "), tv.string)
        XCTAssertFalse(controller.handleKeyEquivalent(key("\r", .command, code: 36)), "⌘Return is left to buttons")
    }

    func testReturnContinuesListsAndSubmits() {
        var sent = 0
        let (controller, tv, box, _) = makeEditor("- tea", submit: .returnKey)
        controller.onSubmit = { sent += 1 }
        tv.setSelectedRange(NSRange(location: 5, length: 0))
        XCTAssertTrue(controller.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(box.text, "- tea\n- ")
        XCTAssertEqual(sent, 0)
        XCTAssertTrue(controller.textView(tv, doCommandBy: #selector(NSResponder.insertNewline(_:))))
        XCTAssertEqual(box.text, "- tea\n")
        XCTAssertEqual(sent, 1, "Return on an empty item sends in Ask")
    }

    func testTypingFormatsAndFadesMarks() {
        let (_, tv, box, _) = makeEditor()
        tv.insertText("[ ]", replacementRange: tv.selectedRange())
        tv.insertText(" ", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "- [ ] ")
        tv.insertText("see [", replacementRange: tv.selectedRange())
        tv.insertText("[", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "- [ ] see [[]]")
        let color = tv.textStorage!.attribute(.foregroundColor, at: 0, effectiveRange: nil) as? NSColor
        XCTAssertEqual(color, MarkdownTheme.mark, "the list marker is faded")
        tv.window?.childWindows?.forEach { $0.orderOut(nil) }
    }

    func testHeightGrowsWithLines() async throws {
        let (controller, tv, _, _) = makeEditor("one")
        try await Task.sleep(nanoseconds: 50_000_000)
        let one = controller.contentHeight
        XCTAssertGreaterThan(one, 10)
        tv.insertText("\ntwo\nthree", replacementRange: NSRange(location: 3, length: 0))
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertGreaterThan(controller.contentHeight, one + 20)
    }
}
