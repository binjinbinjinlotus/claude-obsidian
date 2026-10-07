import XCTest
@testable import DistillKit

/// FieldDraft (actions.md, When field edits save): typed text stays as typed; the saved value is
/// normalised; another key saves the old draft first.
final class FieldDraftTests: XCTestCase {
    /// Types `text` a key at a time, saving after every key (a pause at the worst moment) and
    /// reading the stored value back as the view does while the field has focus.
    private func type(_ text: String, into d: inout FieldDraft, store: inout String,
                      normalize: (String) -> String?, read: (String) -> String = { $0 }) {
        for ch in text {
            d.text += String(ch)
            if let v = d.save(normalize) { store = v }
            XCTAssertNil(d.load(key: d.key, value: read(store), editing: true, normalize))
        }
    }

    func testASpaceSurvivesASaveMidName() {
        var stored = ""
        var d = FieldDraft(key: "a", value: stored)
        type("Linu ", into: &d, store: &stored, normalize: FieldText.trimmed)
        XCTAssertEqual(d.text, "Linu ", "the trailing space is still in the field")
        XCTAssertEqual(stored, "Linu", "what was saved is trimmed")
        type("Chui", into: &d, store: &stored, normalize: FieldText.trimmed)
        XCTAssertEqual(d.text, "Linu Chui")
        XCTAssertEqual(stored, "Linu Chui")
    }

    func testLabelsTypedAKeyAtATime() {
        var stored = ""
        var d = FieldDraft(key: "a", value: stored)
        type("a,", into: &d, store: &stored, normalize: FieldText.labelText)
        XCTAssertEqual(d.text, "a,", "the comma stays while you type")
        type(" b", into: &d, store: &stored, normalize: FieldText.labelText)
        XCTAssertEqual(d.text, "a, b")
        XCTAssertEqual(FieldText.labels(stored), ["a", "b"])
    }

    func testFinishShowsTheSavedForm() {
        var d = FieldDraft(key: "a", value: "")
        d.text = "  Linu Chui  "
        XCTAssertEqual(d.finish(FieldText.trimmed), "Linu Chui")
        XCTAssertEqual(d.text, "Linu Chui")
        XCTAssertNil(d.finish(FieldText.trimmed), "nothing new to save")
    }

    func testAnEmptyTitleIsNotSavedAndComesBack() {
        var d = FieldDraft(key: "a", value: "Buy milk")
        d.text = "  "
        XCTAssertNil(d.save(FieldText.nonEmpty), "a pause on an empty title saves nothing")
        XCTAssertEqual(d.text, "  ", "and doesn't put the old one back mid-edit")
        XCTAssertNil(d.finish(FieldText.nonEmpty))
        XCTAssertEqual(d.text, "Buy milk")
    }

    func testAnotherKeySavesTheOldDraftToTheOldKey() {
        var d = FieldDraft(key: "a", value: "")
        d.text = "Linu Chui "
        let out = d.load(key: "b", value: "Mei", editing: true, FieldText.trimmed)
        XCTAssertEqual(out?.key, "a")
        XCTAssertEqual(out?.value, "Linu Chui")
        XCTAssertEqual(d, FieldDraft(key: "b", value: "Mei"), "the field now shows b")
        XCTAssertNil(d.load(key: "c", value: "", editing: false, FieldText.trimmed), "no edit, nothing to save")
    }

    func testTheStoredValueShowsOnlyWhenNotTyping() {
        var d = FieldDraft(key: "a", value: "Linu")
        d.text = "Linu "
        _ = d.load(key: "a", value: "Mei", editing: true, FieldText.trimmed)
        XCTAssertEqual(d.text, "Linu ", "typing: kept")
        _ = d.load(key: "a", value: "Mei", editing: false, FieldText.trimmed)
        XCTAssertEqual(d.text, "Mei", "not typing: another change shows")
    }

    func testNormalisers() {
        XCTAssertEqual(FieldText.trimmed(" a b \n"), "a b")
        XCTAssertEqual(FieldText.trimmed("   "), "")
        XCTAssertNil(FieldText.nonEmpty(" \n"))
        XCTAssertEqual(FieldText.labels(" tea-club, #project-x,, "), ["tea-club", "project-x"])
        XCTAssertEqual(FieldText.labelText("a ,b,"), "a, b")
    }
}
