import XCTest
@testable import Distill
@testable import DistillKit

/// Track as Pending in the app (actions-routing.md), against a scripted core: the panel opens filled,
/// Track as Pending posts who and by when, the item leaves To confirm for Pending, the next row is
/// selected and the toast's Undo restores it; Cancel changes nothing.
@MainActor
final class TrackPendingAppTests: XCTestCase {
    static func json(_ id: String, status: String, route: String, owner: String? = nil) -> String {
        #"{"id":"\#(id)","type":"todo","status":"\#(status)","title":"Write the migration guide","fields":{"due":"2026-10-09"},"source":{"kind":"manual"},"createdAt":"2026-10-05T18:12:00Z","updatedAt":"2026-10-05T18:12:00Z","events":[],"route":"\#(route)"\#(owner.map { #","owner":"\#($0)","ownerID":"p-aditya","owedToID":"you","due":"2026-10-09""# } ?? "")}"#
    }

    private func model() -> AppModel {
        SessionCoreProtocol.calls = []
        SessionCoreProtocol.answer = nil
        var settings = Settings()
        SettingsEdits.setActions(&settings) {
            $0.people = [ActionPerson(id: "you", name: "Jin Bin Liu"), ActionPerson(id: "p-aditya", name: "Aditya Pradhan", aliases: ["@aditya"])]
        }
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [SessionCoreProtocol.self]
        let app = AppModel(fixtureSettings: settings, jobs: [], queue: [], status: nil)
        app.useClientForTesting(CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config)))
        return app
    }

    private func waitUntil(_ condition: @escaping () -> Bool, timeout: TimeInterval = 3) async {
        let end = Date().addingTimeInterval(timeout)
        while !condition() && Date() < end { try? await Task.sleep(nanoseconds: 20_000_000) }
    }

    private func found(_ id: String) -> ActionItem {
        var i = ActionItem(id: id, status: .pending, title: "Write the migration guide", fields: ["due": "2026-10-09"])
        i.route = .list; i.owner = "Aditya"; i.ownerID = "p-aditya"
        return i
    }

    func testTrackFromToConfirmThenUndo() async {
        let app = model()
        let store = app.actions
        store.loadFixture(types: [], items: [found("c1"), found("c2"), found("c3")])
        store.tab = "todo"
        store.selected["todo"] = "c2"
        store.addingAs["c2"] = AddAs.Draft(type: "slack", title: "x", body: "", fields: [:])
        store.startTrack(found("c2"))
        XCTAssertNil(store.addingAs["c2"], "one panel at a time")
        XCTAssertEqual(store.tracking["c2"]?.personID, "p-aditya")
        XCTAssertNil(store.trackPicker, "filled: the list stays closed")

        SessionCoreProtocol.answer = { c in
            c.path.hasSuffix("/track-pending") ? (200, Self.json("c2", status: "open", route: "waiting", owner: "Aditya Pradhan"))
                : (200, Self.json("c2", status: "pending", route: "list"))
        }
        var moved = false
        store.finishTrack(found("c2")) { store.selected["todo"] = "c3"; moved = true }
        store.finishTrack(found("c2")) // a double click: one request, no "already in Pending" error
        await waitUntil { store.routed["c2"] != nil }
        XCTAssertEqual(SessionCoreProtocol.calls.filter { $0.path.hasSuffix("/track-pending") }.count, 1)
        XCTAssertTrue(store.trackSending.isEmpty)
        XCTAssertNil(store.items["c2"], "it leaves To confirm")
        XCTAssertEqual(store.waiting.map(\.id), ["c2"], "Pending's count goes up")
        XCTAssertTrue(moved)
        XCTAssertEqual(store.selected["todo"], "c3", "the next row is selected")
        XCTAssertNil(store.tracking["c2"])
        XCTAssertEqual(store.toast?.text, "Tracked as Pending · waiting on Aditya")
        let sent = SessionCoreProtocol.calls.last { $0.path.hasSuffix("/track-pending") }
        XCTAssertEqual(sent?.path, "/v1/actions/c2/track-pending")
        XCTAssertEqual(sent?.body["waitingOn"] as? String, "p-aditya")
        XCTAssertEqual(sent?.body["by"] as? String, "2026-10-09")

        store.toast?.undo?()
        await waitUntil { store.items["c2"] != nil }
        XCTAssertEqual(SessionCoreProtocol.calls.last?.path, "/v1/actions/c2/restore")
        XCTAssertEqual(store.items["c2"]?.status, .pending, "back in To confirm")
        XCTAssertTrue(store.waiting.isEmpty)
        XCTAssertEqual(store.selected["todo"], "c2", "and selected again")
    }

    func testEmptyWaitingOnBlocksAndCancelChangesNothing() async {
        let app = model()
        let store = app.actions
        var mine = found("c1"); mine.owner = "me"; mine.ownerID = "you"
        store.loadFixture(types: [], items: [mine])
        store.startTrack(mine)
        XCTAssertEqual(store.trackPicker, "c1", "no one to fill in: the list opens")
        XCTAssertEqual(store.trackBlock(mine), "Fill in who you’re waiting on")
        store.finishTrack(mine)
        try? await Task.sleep(nanoseconds: 150_000_000)
        XCTAssertTrue(SessionCoreProtocol.calls.isEmpty, "nothing is sent while it's empty")
        store.tracking["c1"]?.name = "Mei  Tanaka"
        XCTAssertNil(store.trackBlock(mine))
        store.cancelTrack(mine)
        XCTAssertNil(store.tracking["c1"])
        XCTAssertNil(store.trackPicker)
        XCTAssertEqual(store.items["c1"]?.status, .pending)
    }

    func testMoveToPendingOnlyForOpenToDos() {
        let app = model()
        let store = app.actions
        let todo = ActionItem(id: "t1", status: .open, title: "Book the room", fields: ["person": "Aditya Pradhan"])
        let slack = ActionItem(id: "s1", type: "slack", status: .ready, title: "Tell Mei")
        store.loadFixture(types: [], items: [todo, slack])
        store.startTrack(slack)
        XCTAssertNil(store.tracking["s1"], "an added message is something you send")
        store.startTrack(todo)
        XCTAssertEqual(store.tracking["t1"]?.origin, .todo)
        XCTAssertEqual(store.tracking["t1"]?.personID, "p-aditya")
    }

    func testATypedNameIsSentAtOnce() async {
        let app = model()
        let store = app.actions
        var mine = found("c1"); mine.owner = "me"; mine.ownerID = "you"
        store.loadFixture(types: [], items: [mine])
        store.startTrack(mine)
        SessionCoreProtocol.answer = { _ in (200, Self.json("c1", status: "open", route: "waiting", owner: "Linus Chui")) }
        // Typed and submitted at once: no pause before ⌘Return or the button.
        store.typeWaitingOn("c1", "Linus Chui")
        XCTAssertNil(store.trackBlock(mine), "the button is on as soon as the name is typed")
        store.finishTrack(mine)
        await waitUntil { SessionCoreProtocol.calls.contains { $0.path.hasSuffix("/track-pending") } }
        XCTAssertEqual(SessionCoreProtocol.calls.last { $0.path.hasSuffix("/track-pending") }?.body["waitingOn"] as? String, "Linus Chui")
    }

    func testMoveToPendingSelectsTheNextToDoAsTheListShowsIt() {
        let day = { (n: Int) in "2026-10-0\(n)" }
        let now = Calendar(identifier: .gregorian).date(from: DateComponents(year: 2026, month: 10, day: 1, hour: 12))!
        let a = ActionItem(id: "a", status: .open, title: "A", fields: ["due": day(3)])
        let b = ActionItem(id: "b", status: .open, title: "B", fields: ["due": day(5)])
        let c = ActionItem(id: "c", status: .open, title: "C", fields: ["due": day(4)])
        let visible = [a, b, c]
        XCTAssertEqual(TodoScreen.afterMove("a", visible: visible, grouping: .none, sort: .due, now: now), "c", "the next row by due date")
        XCTAssertEqual(TodoScreen.afterMove("b", visible: visible, grouping: .none, sort: .due, now: now), "c", "the last row: the one before")
        XCTAssertNil(TodoScreen.afterMove("a", visible: [a], grouping: .none, sort: .due, now: now))
    }
}
