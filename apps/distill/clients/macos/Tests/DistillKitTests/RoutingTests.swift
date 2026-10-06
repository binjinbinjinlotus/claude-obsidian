import XCTest
@testable import DistillKit

/// Whose items, Pending and Highlights (actions-routing.md): the item's routing fields, People in
/// settings, the words the screens show, and the routes.
final class RoutingTests: XCTestCase {
    let people = [ActionPerson(id: "you", name: "Jin Bin Liu", aliases: ["Jin", "@jin"]),
                  ActionPerson(id: "p-aditya", name: "Aditya Pradhan", aliases: ["A", "@aditya"])]
    let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 6; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    func testItemDecodesItsRouteAndAnOlderItemIsInYourLists() throws {
        let json = #"{"id":"a","type":"todo","status":"open","title":"Aditya will send you the ticket links","fields":{},"source":{"kind":"note"},"createdAt":"2026-10-05T18:12:00Z","updatedAt":"2026-10-05T18:12:00Z","events":[],"owner":"Aditya","ownerID":"p-aditya","owedToID":"you","route":"waiting","what":"the ticket links","due":"2026-10-09","received":{"notePath":"wiki/sources/standup.md","pageTitle":"2026-10-06 Standup","at":"2026-10-06T09:00:00Z"}}"#
        let item = try JSONDecoder.core.decode(ActionItem.self, from: Data(json.utf8))
        XCTAssertEqual(item.route, .waiting)
        XCTAssertFalse(item.inLists)
        XCTAssertEqual(item.what, "the ticket links")
        XCTAssertEqual(item.received?.noteName, "2026-10-06 Standup")
        let back = try JSONDecoder.core.decode(ActionItem.self, from: JSONEncoder.core.encode(item))
        XCTAssertEqual(back.route, .waiting)
        XCTAssertEqual(back.ownerID, "p-aditya")
        let old = ActionItem(id: "o", title: "Old")
        XCTAssertNil(old.route)
        XCTAssertTrue(old.inLists, "items found before routing stay in your lists")
        XCTAssertEqual(ActionQuery(route: "waiting").queryItems.map(\.value), ["waiting"])
    }

    func testPeopleAndHandlesForInSettings() {
        var p = ActionPreferences()
        XCTAssertEqual(p.people.map(\.id), ["you"], "an empty you when Settings has none")
        XCTAssertFalse(p.routingOn)
        XCTAssertEqual(p.handlesFor("todo"), ["you"], "default: you")
        p.people = [people[1], people[0]]
        XCTAssertEqual(p.people.map(\.id), ["you", "p-aditya"], "you first")
        XCTAssertTrue(p.routingOn)
        p.setHandlesFor("todo", ["you", "p-aditya", "you", "gone"])
        XCTAssertEqual(p.handlesFor("todo"), ["you", "p-aditya"], "deduped; unknown ids dropped")
        p.removePerson("p-aditya", types: ["todo"])
        XCTAssertEqual(p.people.map(\.id), ["you"])
        XCTAssertEqual(p.handlesFor("todo"), ["you"])
        p.removePerson("you", types: ["todo"])
        XCTAssertEqual(p.people.map(\.id), ["you"], "you can't be removed")
    }

    func testNudgePrefill() {
        var item = ActionItem(id: "w", title: "Aditya will send you the ticket links")
        item.ownerID = "p-aditya"; item.owner = "Aditya"; item.what = "the ticket links"
        XCTAssertEqual(Routing.nudgeText(person: Routing.owner(item, people: people), what: Routing.what(item)), "Hi Aditya, any update on the ticket links?")
        XCTAssertEqual(Routing.nudgeTo(item, people: people), "Aditya Pradhan (@aditya)")
        var stranger = ActionItem(id: "v", title: "Vladan will share the numbers")
        stranger.owner = "Vladan Dimitrijevic"
        XCTAssertEqual(Routing.nudgeTo(stranger, people: people), "Vladan Dimitrijevic", "no handle: the name as written")
        XCTAssertEqual(Routing.nudgeText(person: "Vladan Dimitrijevic", what: Routing.what(stranger)), "Hi Vladan, any update on Vladan will share the numbers?")
    }

    func testWordsForToConfirmAndPending() {
        var mine = ActionItem(id: "c", status: .pending, title: "x", source: .note(jobID: "j1", notePath: nil, pageTitle: nil, quote: nil))
        mine.ownerID = "p-aditya"
        XCTAssertEqual(Routing.forWhom(mine, people: people), "for Aditya")
        mine.ownerID = "you"
        XCTAssertNil(Routing.forWhom(mine, people: people))
        func routed(_ id: String, _ r: ActionRoute, job: String) -> ActionItem {
            var i = ActionItem(id: id, title: id, source: .note(jobID: job, notePath: nil, pageTitle: nil, quote: nil)); i.route = r; return i
        }
        let elsewhere = [routed("a", .others, job: "j1"), routed("b", .others, job: "j1"), routed("c", .waiting, job: "j1"), routed("d", .others, job: "j9")]
        XCTAssertEqual(Routing.elsewhereLine(pending: [mine], routed: elsewhere), "2 items for other people went to Highlights · 1 to Pending")
        XCTAssertEqual(Routing.elsewhereLine(pending: [mine], routed: [routed("c", .waiting, job: "j1")]), "1 item for other people went to Pending")
        XCTAssertNil(Routing.elsewhereLine(pending: [], routed: elsewhere))

        XCTAssertEqual(Routing.by("2026-10-09", now: now), "Fri")
        XCTAssertEqual(Routing.by("2026-10-20", now: now), "Oct 20")
        XCTAssertTrue(Routing.overdue("2026-10-02", now: now))
        XCTAssertFalse(Routing.overdue("2026-10-06", now: now), "today isn't overdue")
        XCTAssertEqual(Routing.receivedLine(ActionReceived(notePath: "wiki/sources/2026-10-06 Standup.md")), "Looks received in 2026-10-06 Standup. Mark received?")

        func w(_ id: String, owner: String, ownerID: String? = nil, due: String?) -> ActionItem {
            var i = ActionItem(id: id, title: id); i.route = .waiting; i.owner = owner; i.ownerID = ownerID; i.due = due; return i
        }
        let list = [w("v", owner: "Vladan", due: "2026-10-02"), w("a", owner: "A", ownerID: "p-aditya", due: "2026-10-09"), w("n", owner: "Anant", due: nil)]
        XCTAssertEqual(Routing.pendingGroups(list, byDate: false, people: people, now: now).map(\.title), ["Aditya Pradhan", "Anant", "Vladan"], "People first, then by name")
        XCTAssertEqual(Routing.pendingGroups(list, byDate: true, people: people, now: now).map(\.title), ["Overdue", "Fri", "No date"])
    }

    func testSettingsAndHighlightsWords() {
        XCTAssertEqual(Routing.handlesHint(type: "todo", handles: ["you", "p-aditya"], people: people), "Your to-dos, and the ones you do for Aditya.")
        XCTAssertEqual(Routing.handlesHint(type: "slack", handles: ["you"], people: people), "Messages Jin has to send.")
        XCTAssertEqual(Routing.handlesHint(type: "jira", handles: [], people: people), "Nobody’s: these go to Pending or Highlights.")
        XCTAssertEqual(Routing.chipName(people[1]), "Aditya Pradhan (A)")
        XCTAssertEqual(Routing.initials("Jin Bin Liu"), "JL")
        let note = HighlightNote(notePath: "wiki/sources/s.md", title: "Sync", date: "2026-10-05", kind: "meeting", duration: "45 min",
                                 wiki: .init(path: "wiki/sources/s.md", title: "Sync", summary: "They agreed.", keyPoints: [.init(text: "One Storybook", line: 17)]),
                                 others: [.init(person: "Vladan", items: [.init(id: "x", title: "Benchmark", due: "2026-10-07")])],
                                 yours: .init(lists: ["todo": 2], waiting: [.init(id: "w", person: "Aditya Pradhan", what: "the ticket links")]),
                                 counts: .init(others: 5, decisions: 2, lists: 3, waiting: 2))
        XCTAssertEqual(Routing.highlightCounts(note), "Others’ actions 5 · Decisions 2 · Your items: 3 in your lists, 2 Pending")
        XCTAssertEqual(Routing.highlightWhen(note), "Oct 5 · 45 min")
        let md = Routing.summaryMarkdown(note) { t, n in "\(t == "todo" ? "To do" : t) \(n)" }
        XCTAssertTrue(md.contains("## Key points\n- One Storybook"))
        XCTAssertTrue(md.contains("- **Vladan**: Benchmark (by 2026-10-07)"))
        XCTAssertTrue(md.contains("- Pending: Aditya: the ticket links"))
    }

    func testRoutes() async throws {
        StubProtocol.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
        defer { StubProtocol.handler = nil }
        let item = #"{"id":"a","type":"todo","status":"open","title":"t","fields":{},"source":{"kind":"manual"},"createdAt":"2026-10-05T18:12:00Z","updatedAt":"2026-10-05T18:12:00Z","events":[]}"#
        StubProtocol.handler = { _ in (200, Data(item.utf8)) }
        _ = try await client.assignActionOwner("a", owner: nil)
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/actions/a/owner")
        XCTAssertEqual(String(data: StubProtocol.recorded.last?.body ?? Data(), encoding: .utf8), #"{"owner":null}"#, "Not mine is null")
        for (call, path) in [("track", "track-pending"), ("claim", "claim"), ("received", "received"), ("stop", "stop-waiting")] {
            switch call {
            case "track": _ = try await client.trackAsPending("a")
            case "claim": _ = try await client.claimAction("a")
            case "received": _ = try await client.markReceived("a")
            default: _ = try await client.stopWaiting("a")
            }
            XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/actions/a/\(path)")
        }
        StubProtocol.handler = { _ in (200, Data(#"{"item":\#(item),"message":\#(item.replacingOccurrences(of: "\"a\"", with: "\"m\""))}"#.utf8)) }
        let nudge = try await client.nudgeAction("a", to: "Aditya Pradhan (@aditya)", text: "Hi Aditya, any update on the ticket links?")
        XCTAssertEqual(nudge.message.id, "m")
        let sent = try JSONDecoder().decode([String: String].self, from: StubProtocol.recorded.last?.body ?? Data())
        XCTAssertEqual(sent, ["to": "Aditya Pradhan (@aditya)", "text": "Hi Aditya, any update on the ticket links?"])
        StubProtocol.handler = { _ in (200, Data(#"{"days":7,"lists":14,"waiting":6,"others":31}"#.utf8)) }
        let preview = try await client.routingPreview(people: people, handles: ["todo": ["you", "p-aditya"]])
        XCTAssertEqual(preview, RoutingPreview(lists: 14, waiting: 6, others: 31))
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/actions/routing-preview")
        StubProtocol.handler = { _ in (200, Data(#"{"notes":[{"notePath":"wiki/sources/s.md","title":"Sync","date":"2026-10-05","kind":"meeting","people":["Jin"],"wiki":{"path":"wiki/sources/s.md","title":"Sync","keyPoints":[{"text":"One","line":3}],"decisions":[]},"others":[],"yours":{"lists":{},"waiting":[]},"counts":{"others":0,"decisions":0,"lists":0,"waiting":0},"foundAt":"x"}]}"#.utf8)) }
        let notes = try await client.highlights()
        XCTAssertEqual(notes.first?.wiki?.keyPoints.first?.line, 3)
        XCTAssertTrue(notes.first?.isMeeting ?? false)
    }
}
