import XCTest
@testable import Distill
@testable import DistillKit

/// The to-do detail's free-text fields (actions.md, When field edits save), driven the way
/// DraftTextField drives them: a save after every key, the item read back while the field has focus.
@MainActor
final class FieldDraftAppTests: XCTestCase {
    private func store(_ items: [ActionItem]) -> ActionsStore {
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        e.actions.loadFixture(types: [], items: items)
        return e.actions
    }

    private func type(_ text: String, _ d: inout FieldDraft, _ s: ActionsStore, normalize: (String) -> String?,
                      save: (ActionsStore, String, String) -> Void, read: (ActionItem) -> String) {
        for ch in text {
            d.text += String(ch)
            if let v = d.save(normalize) { save(s, d.key, v) }
            XCTAssertNil(d.load(key: d.key, value: read(s.items[d.key]!), editing: true, normalize))
        }
    }

    private let person: (ActionItem) -> String = { $0.field("person") ?? "" }
    private let labels: (ActionItem) -> String = { $0.labels.joined(separator: ", ") }

    func testPeopleKeepsTheSpace() {
        let s = store([ActionItem(id: "a", title: "Plan")])
        var d = FieldDraft(key: "a", value: "")
        type("Linu ", &d, s, normalize: FieldText.trimmed, save: TodoDetail.savePerson, read: person)
        XCTAssertEqual(d.text, "Linu ")
        type("Chui", &d, s, normalize: FieldText.trimmed, save: TodoDetail.savePerson, read: person)
        XCTAssertEqual(d.text, "Linu Chui")
        XCTAssertEqual(s.items["a"]?.fields["person"], "Linu Chui")
    }

    func testTheSavedPersonIsTrimmedAndEmptyClearsIt() {
        let s = store([ActionItem(id: "a", title: "Plan", fields: ["person": "Mei"])])
        var d = FieldDraft(key: "a", value: "Mei")
        d.text = "  Linu Chui "
        if let v = d.finish(FieldText.trimmed) { TodoDetail.savePerson(s, d.key, v) }
        XCTAssertEqual(s.items["a"]?.fields["person"], "Linu Chui")
        XCTAssertEqual(d.text, "Linu Chui")
        d.text = "   "
        if let v = d.finish(FieldText.trimmed) { TodoDetail.savePerson(s, d.key, v) }
        XCTAssertNil(s.items["a"]?.fields["person"] ?? nil)
    }

    func testLabelsTypedAKeyAtATime() {
        let s = store([ActionItem(id: "a", title: "Plan")])
        var d = FieldDraft(key: "a", value: "")
        type("a,", &d, s, normalize: FieldText.labelText, save: TodoDetail.saveLabels, read: labels)
        XCTAssertEqual(d.text, "a,")
        type(" b", &d, s, normalize: FieldText.labelText, save: TodoDetail.saveLabels, read: labels)
        XCTAssertEqual(d.text, "a, b")
        XCTAssertEqual(s.items["a"]?.labels, ["a", "b"])
    }

    func testSwitchingItemsSavesTheDraftToTheOldItem() {
        let s = store([ActionItem(id: "a", title: "Plan"), ActionItem(id: "b", title: "Call", fields: ["person": "Mei"])])
        var d = FieldDraft(key: "a", value: "")
        d.text = "Linu Chui " // typed, no pause yet
        if let out = d.load(key: "b", value: person(s.items["b"]!), editing: true, FieldText.trimmed) {
            TodoDetail.savePerson(s, out.key, out.value)
        }
        XCTAssertEqual(s.items["a"]?.fields["person"], "Linu Chui")
        XCTAssertEqual(s.items["b"]?.fields["person"], "Mei", "the new item is untouched")
        XCTAssertEqual(d.text, "Mei")
    }

    func testANewPersonInSettingsIsAddedWithTheirFirstName() {
        var p = ActionPreferences()
        let new = ActionPerson(id: "p-1", name: "", aliases: ["Linu"])
        p.setName(new, "Linu Chui")
        XCTAssertEqual(p.people.last, ActionPerson(id: "p-1", name: "Linu Chui", aliases: ["Linu"]))
        p.setName(new, "Linu C")
        XCTAssertEqual(p.people.filter { $0.id == "p-1" }.map(\.name), ["Linu C"], "renamed, not added twice")
    }
}
