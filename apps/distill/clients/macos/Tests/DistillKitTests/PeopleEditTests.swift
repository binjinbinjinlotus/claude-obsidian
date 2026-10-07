import XCTest
@testable import DistillKit

/// Settings → Whose items Distill handles (actions-routing.md): the controls that opened and closed at once.
final class PeopleEditTests: XCTestCase {
    private func jinOnly() -> ActionPreferences {
        var p = ActionPreferences()
        p.people = [ActionPerson(id: "you", name: "Jin")]
        return p
    }

    /// (a) The new row was saved with an empty name; the core drops those (decodePeople), and the
    /// reply removed the row half a second later. Now it stays on the page until named.
    func testANewPersonStaysUntilNamedAndNeverReachesSettingsBlank() {
        var p = jinOnly()
        var edit = PeopleEdit()
        edit.add(id: "p-1")
        XCTAssertEqual(edit.rows(p).map(\.id), ["you", "p-1"], "the row is there and editable")
        XCTAssertEqual(p.people.map(\.id), ["you"], "nothing blank is saved for the core to drop")
        XCTAssertFalse(p.people.contains { $0.name.isEmpty && !$0.isYou })
        // Settings comes back from the core (any save of another field): the row is still there.
        let fromCore = jinOnly()
        XCTAssertEqual(edit.rows(fromCore).map(\.id), ["you", "p-1"])
        edit.setAliases("p-1", ["Linu"], in: &p)
        XCTAssertEqual(p.people.map(\.id), ["you"], "an alias alone doesn't save them blank")
        edit.saveName("p-1", "Linu Chui", in: &p)
        XCTAssertNil(edit.newPerson)
        XCTAssertEqual(p.people.last, ActionPerson(id: "p-1", name: "Linu Chui", aliases: ["Linu"]))
        XCTAssertEqual(edit.rows(p).map(\.id), ["you", "p-1"], "one row, not two")
    }

    func testRemovingTheNewPersonOrARemovedOnesLateNameSaveChangesNothing() {
        var p = jinOnly()
        var edit = PeopleEdit()
        edit.add(id: "p-1")
        edit.remove("p-1", types: ["todo"], in: &p)
        XCTAssertNil(edit.newPerson)
        edit.saveName("p-1", "Mei", in: &p) // the field's pending save after Remove
        XCTAssertEqual(p.people.map(\.id), ["you"])
    }

    /// Typing a name, then ＋ Add a person (or a type's ＋) again before the pause saved it: the
    /// row was replaced, and its late save renamed nobody, so the typed name was lost.
    func testAddingAgainKeepsTheRowBeingNamed() {
        var p = jinOnly()
        var edit = PeopleEdit()
        XCTAssertEqual(edit.add(id: "p-1"), "p-1")
        XCTAssertEqual(edit.add(id: "p-2", forType: "todo"), "p-1", "the row being named stays")
        XCTAssertEqual(edit.rows(p).map(\.id), ["you", "p-1"])
        edit.saveName("p-1", "Linu", in: &p) // the field's save of the name typed before the second click
        XCTAssertEqual(p.people.map(\.id), ["you", "p-1"])
        XCTAssertEqual(p.handlesFor("todo"), ["you", "p-1"], "the type's ＋ still applies")
        XCTAssertEqual(edit.add(id: "p-3"), "p-3", "named: the next add is a new row")
    }

    /// (b) With only you, the ＋ menu had nothing to offer; the page now shows Add a person instead.
    func testHandlesForPlusHasNobodyToAddWhenOnlyYou() {
        var p = jinOnly()
        XCTAssertEqual(PeopleEdit.addable(p, type: "todo"), [])
        p.people.append(ActionPerson(id: "p-1", name: "Linu Chui"))
        p.people.append(ActionPerson(id: "p-2", name: ""))
        XCTAssertEqual(PeopleEdit.addable(p, type: "todo").map(\.id), ["p-1"], "named people not handled yet")
        p.setHandlesFor("todo", ["you", "p-1"])
        XCTAssertEqual(PeopleEdit.addable(p, type: "todo"), [])
    }

    /// A person added from a type's ＋ handles that type from their first name, in the same save.
    func testAPersonAddedFromATypesPlusHandlesThatType() {
        var p = jinOnly()
        var edit = PeopleEdit()
        edit.add(id: "p-1", forType: "todo")
        XCTAssertEqual(p.handlesFor("todo"), ["you"], "not before they're named")
        edit.saveName("p-1", "Linu Chui", in: &p)
        XCTAssertEqual(p.handlesFor("todo"), ["you", "p-1"])
        XCTAssertEqual(p.handlesFor("slack"), ["you"], "only that type")
        edit.add(id: "p-2")
        edit.saveName("p-2", "Mei", in: &p)
        XCTAssertEqual(p.handlesFor("todo"), ["you", "p-1"], "+ Add a person adds to no type")
        edit.add(id: "p-3", forType: "todo")
        edit.remove("p-3", types: ["todo"], in: &p)
        edit.add(id: "p-4")
        edit.saveName("p-4", "Ana", in: &p)
        XCTAssertEqual(p.handlesFor("todo"), ["you", "p-1"], "a removed draft's type doesn't carry over")
    }

    /// (c) The alias keeps inner spaces; it's trimmed, and a repeat in any case adds nothing.
    func testAliasKeepsTheSpace() {
        XCTAssertEqual(PeopleEdit.alias("  Linus Chui ", to: []), ["Linus Chui"])
        XCTAssertEqual(PeopleEdit.alias("@jin", to: ["Jin"]), ["Jin", "@jin"])
        XCTAssertNil(PeopleEdit.alias("jin", to: ["Jin"]))
        XCTAssertNil(PeopleEdit.alias("   ", to: []))
    }

    func testThePreviewNamesItemsFoundBeforeRouting() throws {
        let old = try JSONDecoder().decode(RoutingPreview.self, from: Data(#"{"days":7,"lists":1,"waiting":0,"others":2}"#.utf8))
        XCTAssertEqual(old, RoutingPreview(lists: 1, waiting: 0, others: 2), "an older core: none")
        XCTAssertNil(old.beforeRoutingNote)
        let p = try JSONDecoder().decode(RoutingPreview.self, from: Data(#"{"days":7,"lists":0,"waiting":0,"others":0,"beforeRouting":15}"#.utf8))
        XCTAssertEqual(p.beforeRoutingNote, "15 items found before routing aren’t counted: they have no owner.")
        XCTAssertEqual(RoutingPreview(lists: 0, waiting: 0, others: 0, beforeRouting: 1).beforeRoutingNote,
                       "1 item found before routing isn’t counted: it has no owner.")
    }
}
