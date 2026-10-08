import AppKit
import SwiftUI
import XCTest
import DistillKit
@testable import Distill

/// The real DraftTextField hosted offscreen (actions.md, When field edits save): what is typed stays as
/// typed, and it saves after the pause, on focus loss, on a new key (to the old one), when it goes away
/// and on ⌘Q (PendingSaves). Nothing connects; `save` records.
@MainActor
final class DraftTextFieldViewTests: XCTestCase {
    private final class Props: ObservableObject {
        @Published var key = "a"
        @Published var value = ""
        @Published var shown = true
    }

    private struct Host: View {
        @ObservedObject var props: Props
        var autoFocus = false
        let save: (String, String) -> Void
        var body: some View {
            VStack {
                if props.shown && autoFocus {
                    DraftTextField(placeholder: "Person", key: props.key, value: props.value, autoFocus: true,
                                   normalize: FieldText.trimmed, save: save)
                } else if props.shown {
                    // The default, as the to-do detail uses it.
                    DraftTextField(placeholder: "Person", key: props.key, value: props.value, normalize: FieldText.trimmed, save: save)
                }
                TextField("Other", text: .constant(""))
            }
            .frame(width: 300, height: 80)
        }
    }

    private var saves: [String] = []
    private var window: NSWindow!
    private var props: Props!

    private func host(autoFocus: Bool = false) {
        saves = []
        props = Props()
        let view = NSHostingView(rootView: Host(props: props, autoFocus: autoFocus) { [weak self] key, value in self?.saves.append("\(key)=\(value)") })
        window = NSWindow(contentRect: CGRect(x: 0, y: 0, width: 300, height: 80), styleMask: [.titled], backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        window.contentView = view
        settle()
    }

    override func tearDown() {
        window?.orderOut(nil)
        window = nil
        super.tearDown()
    }

    private func settle(_ seconds: TimeInterval = 0.1) {
        window.contentView?.layoutSubtreeIfNeeded()
        RunLoop.main.run(until: Date().addingTimeInterval(seconds))
    }

    private func fields() -> [NSTextField] {
        func walk(_ v: NSView) -> [NSTextField] { ((v as? NSTextField).map { [$0] } ?? []) + v.subviews.flatMap(walk) }
        return walk(window.contentView!).filter { $0.isEditable }
    }

    private var field: NSTextField { fields().first { $0.placeholderString == "Person" }! }
    private var other: NSTextField { fields().first { $0.placeholderString == "Other" }! }

    private func type(_ text: String) throws {
        if window.firstResponder !== field.currentEditor() { XCTAssertTrue(window.makeFirstResponder(field)) }
        settle()
        let editor = try XCTUnwrap(field.currentEditor() as? NSTextView, "the field is being edited")
        editor.insertText(text, replacementRange: editor.selectedRange())
        settle()
    }

    func testTypedTextStaysAndTheTrimmedValueSavesAfterThePause() throws {
        host()
        try type("Linu ")
        XCTAssertEqual(saves, [], "not while typing")
        settle(1.0)
        XCTAssertEqual(saves, ["a=Linu"], "the pause saves the trimmed value")
        XCTAssertEqual(field.currentEditor()?.string, "Linu ", "the space stays while typing")
        PendingSaves.shared.flushAll()
        settle()
        XCTAssertEqual(saves, ["a=Linu"], "nothing new to save")
    }

    func testQuitFlushesBeforeThePause() throws {
        host()
        try type("Mei")
        PendingSaves.shared.flushAll()
        settle()
        XCTAssertEqual(saves, ["a=Mei"], "⌘Q saves the field without waiting")
    }

    func testFocusLossSavesAndShowsTheStoredForm() throws {
        host()
        try type(" Linu Chui ")
        XCTAssertTrue(window.makeFirstResponder(other))
        settle()
        XCTAssertEqual(saves, ["a=Linu Chui"])
        XCTAssertEqual(field.stringValue, "Linu Chui")
        settle(1.0)
        XCTAssertEqual(saves, ["a=Linu Chui"], "the pause doesn't save it again")
    }

    func testAnotherKeySavesToTheOldOneAndTypingGoesToTheNewOne() throws {
        host()
        try type("Linu")
        props.key = "b"
        props.value = "Mei"
        settle()
        XCTAssertEqual(saves, ["a=Linu"], "saved to the item it was typed for")
        settle(1.0)
        XCTAssertEqual(saves, ["a=Linu"], "the old pause was cancelled")
        try type("!")
        settle(1.0)
        XCTAssertEqual(saves.last?.hasPrefix("b="), true, "typing now saves to the new item: \(saves)")
    }

    /// The store changing under the field (another window saved) keeps the pause: what was typed still saves.
    func testAStoreChangeWhileTypingKeepsThePause() throws {
        host()
        try type("Linu")
        props.value = "Mei"
        settle()
        XCTAssertEqual(saves, [])
        settle(1.0)
        XCTAssertEqual(saves, ["a=Linu"], "the typed name still saves after the pause")
        XCTAssertEqual(field.currentEditor()?.string, "Linu", "and stays as typed")
    }

    func testGoingAwaySaves() throws {
        host()
        try type("Ana")
        props.shown = false
        settle()
        XCTAssertEqual(saves, ["a=Ana"])
    }

    /// A hosting view taken out of its window and put back keeps the field's state; it registers again,
    /// so ⌘Q still saves what is typed after.
    func testBackInItsWindowQuitStillSavesIt() throws {
        host()
        try type("Ana")
        let view = try XCTUnwrap(window.contentView)
        window.contentView = NSView()
        settle()
        XCTAssertEqual(saves, ["a=Ana"], "going away saved it")
        window.contentView = view
        settle()
        try type("Mei") // focusing selects all: it replaces "Ana"
        PendingSaves.shared.flushAll()
        settle()
        XCTAssertEqual(saves, ["a=Ana", "a=Mei"], "⌘Q after it came back")
    }

    func testFocusesOnlyWhenAsked() throws {
        host()
        XCTAssertFalse(window.firstResponder === field.currentEditor() && field.currentEditor() != nil, "not focused by default")
        host(autoFocus: true)
        settle()
        XCTAssertNotNil(field.currentEditor(), "a person just added: the name field has focus")
    }
}
