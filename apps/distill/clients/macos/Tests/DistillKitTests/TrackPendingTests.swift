import XCTest
@testable import DistillKit

/// Track as Pending from To confirm and Move to Pending for a to-do (actions-routing.md): prefill, who it can be,
/// what blocks it, the words, the key and the request.
final class TrackPendingTests: XCTestCase {
    let people = [
        ActionPerson(id: "you", name: "Jin Bin Liu", aliases: ["Jin"]),
        ActionPerson(id: "p-aditya", name: "Aditya Pradhan", aliases: ["A", "Aditya", "@aditya"]),
        ActionPerson(id: "p-tomasz", name: "Tomasz Kowal", aliases: ["@tomasz"]),
        ActionPerson(id: "p-mei", name: "Mei Tanaka", aliases: ["Mei"]),
    ]
    /// Tue Oct 6, 2026: Fri is Oct 9.
    let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 6; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func item(_ id: String = "c2", status: ActionStatus = .pending, type: String = "todo", owner: String? = "Aditya", ownerID: String? = "p-aditya",
              fields: [String: String] = ["due": "2026-10-09"], note: String = "Testing sync", quote: String? = nil) -> ActionItem {
        var i = ActionItem(id: id, type: type, status: status, title: "Write the migration guide", fields: fields,
                           source: .note(jobID: "j", notePath: "wiki/sources/\(note).md", pageTitle: note, quote: quote))
        i.route = .list; i.owner = owner; i.ownerID = ownerID
        return i
    }

    func testOrigin() {
        XCTAssertEqual(TrackPending.origin(item()), .confirm)
        XCTAssertEqual(TrackPending.origin(item(type: "slack")), .confirm, "any found type")
        XCTAssertEqual(TrackPending.origin(item(status: .open)), .todo)
        XCTAssertNil(TrackPending.origin(item(status: .open, type: "slack")), "an added message isn't moved")
        XCTAssertNil(TrackPending.origin(item(status: .done)))
        var waiting = item(status: .open); waiting.route = .waiting
        XCTAssertNil(TrackPending.origin(waiting))
    }

    func testPrefillFromTheOwnerAndDueDate() {
        let d = TrackPending.prefill(item(), people: people)
        XCTAssertEqual([d.personID, d.name, d.by], ["p-aditya", "Aditya Pradhan", "2026-10-09"])
        XCTAssertEqual(d.waitingOn, "p-aditya")
        XCTAssertNil(TrackPending.blockReason(d, people: people))
        XCTAssertEqual(TrackPending.noteLine(d, people: people), "Filled from its owner and due date. It leaves To confirm; nothing is sent to Aditya.")
        XCTAssertEqual(TrackPending.subtitle(item(), d, typeWords: "to-do"), "filled from the to-do")
        XCTAssertEqual(TrackPending.previewLine(item(), d, people: people, now: now), "from Aditya Pradhan · promised in Testing sync · by Fri")
        XCTAssertEqual(TrackPending.byLabel(d.by), "Fri, Oct 9")
        XCTAssertEqual(TrackPending.toast(d, people: people), "Tracked as Pending · waiting on Aditya")
    }

    func testTheOwnerIsYouStartsEmptyAndRequired() {
        let mine = item(owner: "me", ownerID: "you", quote: "me: migrate all existing tests\nnext line")
        XCTAssertTrue(TrackPending.ownerIsYou(mine))
        let d = TrackPending.prefill(mine, people: people)
        XCTAssertNil(d.waitingOn)
        XCTAssertEqual(TrackPending.blockReason(d, people: people), "Fill in who you’re waiting on")
        XCTAssertNil(TrackPending.noteLine(d, people: people))
        XCTAssertEqual(TrackPending.subtitle(mine, d, typeWords: "to-do"), "the owner is you")
        XCTAssertEqual(TrackPending.youNote(mine),
                       "The note says you would do this (“me: migrate all existing tests”), so there is no one to fill in. Pick who you are waiting on.")
        var typed = d
        typed.name = "  "
        XCTAssertEqual(TrackPending.blockReason(typed, people: people), "Fill in who you’re waiting on")
        typed.name = "Jin"
        XCTAssertEqual(TrackPending.blockReason(typed, people: people), "Pick someone other than you")
        typed.name = "The user" // the core reads it as you too (routing.ts ME_WORDS)
        XCTAssertEqual(TrackPending.blockReason(typed, people: people), "Pick someone other than you")
        typed.name = "Vladan  Dimitrijevic"
        XCTAssertNil(TrackPending.blockReason(typed, people: people))
        XCTAssertEqual(typed.waitingOn, "Vladan  Dimitrijevic", "a name not in People is kept as written (inner spaces too)")
    }

    func testMoveToPendingFillsFromTheToDosPerson() {
        let todo = item(status: .open, owner: nil, ownerID: nil, fields: ["due": "2026-10-02", "person": "Mei Tanaka"])
        let d = TrackPending.prefill(todo, people: people)
        XCTAssertEqual(d.origin, .todo)
        XCTAssertEqual([d.personID, d.name, d.by], ["p-mei", "Mei Tanaka", "2026-10-02"])
        XCTAssertEqual(TrackPending.title(d), "Move to Pending")
        XCTAssertNil(TrackPending.subtitle(todo, d, typeWords: "to-do"))
        XCTAssertNil(TrackPending.noteLine(d, people: people), "the To confirm line isn't shown for a to-do")
        let yours = item(status: .open, owner: nil, ownerID: nil, fields: ["person": "You (Jin Liu)"])
        XCTAssertNil(TrackPending.prefill(yours, people: people).personID)
        let noDate = item(status: .open, fields: [:])
        XCTAssertNil(TrackPending.prefill(noDate, people: people).by, "no date: it never turns Overdue")
    }

    func testChoicesInThisNoteThenPeople() {
        let mine = item(owner: "me", ownerID: "you")
        var tomasz = item("x1", status: .open, owner: "Tomasz", ownerID: "p-tomasz"); tomasz.route = .others
        let aditya = item("c9", owner: "A", ownerID: "p-aditya")
        let elsewhere = item("z1", owner: "Mei", ownerID: "p-mei", note: "Planning")
        let named = item("x2", status: .open, owner: "Vladan", ownerID: nil)
        let c = TrackPending.choices(for: mine, all: [tomasz, named, aditya, elsewhere], people: people)
        XCTAssertEqual(c.note.map(\.name), ["Aditya Pradhan", "Tomasz Kowal", "Vladan"], "People order first, never you")
        XCTAssertEqual(c.note.first?.handle, "@aditya")
        XCTAssertEqual(c.people.map(\.name), ["Mei Tanaka"])
        let typed = TrackPending.choices(for: mine, all: [tomasz, aditya], people: people, typed: "tom")
        XCTAssertEqual(typed.note.map(\.name), ["Tomasz Kowal"])
        XCTAssertTrue(typed.people.isEmpty)
    }

    func testShiftOptionReturnTracks() {
        XCTAssertEqual(AddAs.key(option: true, command: false, shift: true), .trackPending)
        XCTAssertNil(AddAs.key(option: false, command: false, shift: true), "⇧Return isn't ours")
        XCTAssertNil(AddAs.key(option: true, command: true, shift: true))
        XCTAssertNil(AddAs.key(option: true, command: false, shift: true, other: true))
        XCTAssertEqual(AddAs.key(option: false, command: false), .add, "Return is unchanged")
        XCTAssertEqual(AddAs.key(option: true, command: false), .openMenu, "⌥Return is unchanged")
    }

    func testRequestBody() async throws {
        StubProtocol.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
        defer { StubProtocol.handler = nil }
        let json = #"{"id":"a","type":"todo","status":"open","title":"t","fields":{},"source":{"kind":"manual"},"createdAt":"2026-10-05T18:12:00Z","updatedAt":"2026-10-05T18:12:00Z","events":[],"route":"waiting","trackedFrom":{"route":"list","status":"pending"}}"#
        StubProtocol.handler = { _ in (200, Data(json.utf8)) }
        let out = try await client.trackAsPending("a", waitingOn: "p-aditya", by: "2026-10-09")
        XCTAssertEqual(out.route, .waiting, "an unknown trackedFrom decodes leniently")
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/actions/a/track-pending")
        var sent = try JSONSerialization.jsonObject(with: StubProtocol.recorded.last?.body ?? Data()) as? [String: Any]
        XCTAssertEqual(sent?["waitingOn"] as? String, "p-aditya")
        XCTAssertEqual(sent?["by"] as? String, "2026-10-09")
        _ = try await client.trackAsPending("a", waitingOn: "Mei", by: nil)
        sent = try JSONSerialization.jsonObject(with: StubProtocol.recorded.last?.body ?? Data()) as? [String: Any]
        XCTAssertTrue(sent?["by"] is NSNull, "no date is null")
    }
}
