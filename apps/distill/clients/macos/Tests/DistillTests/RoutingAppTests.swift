import XCTest
@testable import Distill
@testable import DistillKit

/// actions-routing.md in the app: Pending and Highlights items never reach your lists; Nudge's panel opens prefilled.
@MainActor
final class RoutingAppTests: XCTestCase {
    func testRoutedItemsStayOutOfYourListsAndNudgeIsPrefilled() {
        var settings = Settings()
        SettingsEdits.setActions(&settings) { $0.people = [ActionPerson(id: "you", name: "Jin Bin Liu"), ActionPerson(id: "p-aditya", name: "Aditya Pradhan", aliases: ["@aditya"])] }
        let e = AppModel(fixtureSettings: settings, jobs: [], queue: [], status: nil)
        let store = e.actions
        store.loadFixture(types: [], items: [])
        var w = ActionItem(id: "w1", title: "Aditya will send you the ticket links")
        w.route = .waiting; w.ownerID = "p-aditya"; w.owner = "Aditya"; w.what = "the ticket links"
        var x = ActionItem(id: "x1", title: "Benchmark the cache"); x.route = .others; x.owner = "Vladan"
        let mine = ActionItem(id: "t1", title: "Book the room")
        for i in [w, x, mine] { store.apply(i, deleted: false) }
        XCTAssertEqual(Set(store.items.keys), ["t1"], "your lists hold only your items")
        XCTAssertEqual(store.waiting.map(\.id), ["w1"])
        XCTAssertEqual(store.others.map(\.id), ["x1"])

        store.startNudge(w)
        XCTAssertEqual(store.nudging["w1"], NudgeDraft(to: "Aditya Pradhan (@aditya)", text: "Hi Aditya, any update on the ticket links?"))

        // It's mine (the core answers with route list): it moves into your lists.
        var claimed = x; claimed.route = .list
        store.apply(claimed, deleted: false)
        XCTAssertNotNil(store.items["x1"])
        XCTAssertNil(store.routed["x1"])
        // Received: done items go to History (your items map), out of Pending.
        var done = w; done.status = .done
        store.apply(done, deleted: false)
        XCTAssertTrue(store.waiting.isEmpty)
        XCTAssertEqual(store.items["w1"]?.status, .done)
    }

    func testPeoplePageIsInTheSettingsIndex() {
        let hit = SettingsIndex.search("whose", in: SettingsIndex.all(types: []))
        XCTAssertTrue(hit.contains { $0.target.id == "actions/people" && $0.title == "Whose items Distill handles" })
    }
}
