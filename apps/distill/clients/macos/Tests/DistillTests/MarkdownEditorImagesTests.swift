import AppKit
import SwiftUI
import XCTest
import DistillKit
@testable import Distill

/// Images inside the text: `![[name]]` in the binding, an attachment in the text view.
@MainActor
final class MarkdownEditorImagesTests: XCTestCase {
    final class Box { var text: String; init(_ t: String) { text = t } }

    final class Fake {
        var states: [String: InlineImageState] = [:]
        var answer: Result<ExtractImageTextResult, Error> = .success(ExtractImageTextResult(text: "**Card**\n- 60 °C", model: "Haiku"))
        var gate: CheckedContinuation<Void, Never>?
        var waits = false
    }

    /// Windows stay open for the whole test (closing one dismantles the editor and cancels reads).
    var windows: [NSWindow] = []

    let card = DraftImage(url: URL(fileURLWithPath: "/nonexistent/brewing-card.png"), byteCount: 412_000)

    private func makeEditor(_ text: String, fake: Fake) -> (MarkdownEditorController, MarkdownTextView, Box, NSWindow) {
        let controller = MarkdownEditorController()
        let box = Box(text)
        let host = InlineImageHost(
            key: .quick,
            images: [card.name: card],
            states: fake.states,
            register: { $0 },
            extract: { _ in
                if fake.waits { await withCheckedContinuation { fake.gate = $0 } }
                try Task.checkCancellation()
                return try fake.answer.get()
            },
            setState: { name, state in fake.states[name] = state },
            readingModel: { "Haiku" },
            openSettings: {})
        let area = MarkdownTextArea(text: Binding(get: { box.text }, set: { box.text = $0 }), controller: controller, size: 13,
                                    placeholder: "", editable: true, scrolls: false, autoFocus: false, images: host)
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 500, height: 600), styleMask: [.titled], backing: .buffered, defer: true)
        window.contentView = NSHostingView(rootView: area.frame(width: 500, height: 600))
        window.contentView?.layoutSubtreeIfNeeded()
        let tv = controller.textView!
        window.makeFirstResponder(tv)
        windows.append(window)
        return (controller, tv, box, window)
    }

    private func attachment(_ tv: NSTextView) -> InlineImageAttachment? {
        var found: InlineImageAttachment?
        tv.textStorage!.enumerateAttribute(.attachment, in: NSRange(location: 0, length: tv.textStorage!.length)) { v, _, _ in
            if let a = v as? InlineImageAttachment { found = a }
        }
        return found
    }

    func testEmbedsBecomeAttachmentsAndRoundTrip() {
        let (controller, tv, box, _) = makeEditor("Their card:\n![[brewing-card.png]]\n![[unknown.png]]", fake: Fake())
        XCTAssertEqual(tv.string, "Their card:\n\u{FFFC}\n![[unknown.png]]", "only known images become attachments")
        XCTAssertEqual(controller.markdownText(), box.text)
        tv.setSelectedRange(NSRange(location: 0, length: 0))
        tv.insertText("Note. ", replacementRange: tv.selectedRange())
        XCTAssertEqual(box.text, "Note. Their card:\n![[brewing-card.png]]\n![[unknown.png]]")
        // A command over a range that holds the image keeps it.
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        controller.run(.quote)
        XCTAssertTrue(box.text.contains("![[brewing-card.png]]"), box.text)
        XCTAssertNotNil(attachment(tv))
    }

    func testInsertAtCursorOnItsOwnLineThenUndo() {
        let (controller, tv, box, _) = makeEditor("Before after", fake: Fake())
        tv.setSelectedRange(NSRange(location: 6, length: 0))
        XCTAssertTrue(controller.insertImages([card]))
        XCTAssertEqual(box.text, "Before\n![[brewing-card.png]]\n after")
        XCTAssertEqual(tv.selectedRange().location, 9, "typing carries on under the image")
        tv.undoManager?.undo()
        XCTAssertEqual(box.text, "Before after")
        tv.setSelectedRange(NSRange(location: 12, length: 0))
        controller.insertImages([card])
        XCTAssertEqual(box.text, "Before after\n![[brewing-card.png]]\n")
    }

    func testRemoveTakesTheImageLine() {
        let (controller, tv, box, _) = makeEditor("A\n![[brewing-card.png]]\nB", fake: Fake())
        controller.removeImage(attachment(tv)!)
        XCTAssertEqual(box.text, "A\nB")
        tv.undoManager?.undo()
        XCTAssertEqual(box.text, "A\n![[brewing-card.png]]\nB")
    }

    func testExtractReplacesInPlaceAndUndoBringsTheImageBack() async throws {
        let fake = Fake()
        let (controller, tv, box, _) = makeEditor("Card:\n![[brewing-card.png]]\nEnd", fake: fake)
        controller.extractImage(attachment(tv)!)
        XCTAssertEqual(fake.states["brewing-card.png"], .reading(model: "Haiku"))
        for _ in 0..<50 where box.text.contains("![[") { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(box.text, "Card:\n**Card**\n- 60 °C\nEnd")
        XCTAssertNil(fake.states["brewing-card.png"])
        XCTAssertNotNil(controller.extractedHighlight)
        tv.undoManager?.undo()
        XCTAssertEqual(box.text, "Card:\n![[brewing-card.png]]\nEnd", "⌘Z restores the image")
        XCTAssertNotNil(attachment(tv))
    }

    func testUndoLinkRestoresTheImage() async throws {
        let fake = Fake()
        let (controller, tv, box, _) = makeEditor("![[brewing-card.png]]", fake: fake)
        controller.extractImage(attachment(tv)!)
        for _ in 0..<50 where box.text.contains("![[") { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.restoreExtracted()
        XCTAssertEqual(box.text, "![[brewing-card.png]]")
        XCTAssertNil(controller.extractedHighlight)
    }

    func testNoTextAndFailureKeepTheImage() async throws {
        let fake = Fake()
        fake.answer = .success(ExtractImageTextResult(text: "  ", model: "Haiku"))
        let (controller, tv, box, _) = makeEditor("![[brewing-card.png]]", fake: fake)
        controller.extractImage(attachment(tv)!)
        for _ in 0..<50 where fake.states["brewing-card.png"] != .noText { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fake.states["brewing-card.png"], .noText)
        XCTAssertEqual(box.text, "![[brewing-card.png]]")
        fake.answer = .failure(CoreClientError.api(status: 400, code: "invalid_request", message: "Claude Code isn’t signed in."))
        controller.extractImage(attachment(tv)!)
        for _ in 0..<50 where fake.states["brewing-card.png"] == .reading(model: "Haiku") { try await Task.sleep(nanoseconds: 10_000_000) }
        XCTAssertEqual(fake.states["brewing-card.png"], .failed("Claude Code isn’t signed in."))
        XCTAssertEqual(box.text, "![[brewing-card.png]]")
    }

    func testCancelLeavesTheImageAndClearsReading() async throws {
        let fake = Fake()
        fake.waits = true
        let (controller, tv, box, _) = makeEditor("![[brewing-card.png]]", fake: fake)
        let att = attachment(tv)!
        controller.extractImage(att)
        for _ in 0..<50 where fake.gate == nil { try await Task.sleep(nanoseconds: 10_000_000) }
        controller.cancelRead(att)
        XCTAssertNil(fake.states["brewing-card.png"])
        fake.gate?.resume()
        try await Task.sleep(nanoseconds: 50_000_000)
        XCTAssertEqual(box.text, "![[brewing-card.png]]")
        XCTAssertNil(fake.states["brewing-card.png"])
    }

    func testCopyWritesMarkdown() {
        let (_, tv, _, _) = makeEditor("A\n![[brewing-card.png]]", fake: Fake())
        tv.setSelectedRange(NSRange(location: 0, length: (tv.string as NSString).length))
        let pb = NSPasteboard(name: NSPasteboard.Name("distill.test.\(UUID().uuidString)"))
        XCTAssertTrue(tv.writeSelection(to: pb, types: [.string]))
        XCTAssertEqual(pb.string(forType: .string), "A\n![[brewing-card.png]]")
        pb.releaseGlobally()
    }

    func testFitKeepsAspectWithinWidthAndHeight() {
        XCTAssertEqual(InlineImageLayout.fit(CGSize(width: 800, height: 400), maxWidth: 400), CGSize(width: 400, height: 200))
        XCTAssertEqual(InlineImageLayout.fit(CGSize(width: 300, height: 1200), maxWidth: 400), CGSize(width: 80, height: 320))
        XCTAssertEqual(InlineImageLayout.fit(CGSize(width: 100, height: 50), maxWidth: 400), CGSize(width: 100, height: 50))
    }
}
