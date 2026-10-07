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

        func w(_ id: String, owner: String, ownerID: String? = nil, due: String?, daysAgo: Double) -> ActionItem {
            var i = ActionItem(id: id, title: id, createdAt: now.addingTimeInterval(-daysAgo * 86_400))
            i.route = .waiting; i.owner = owner; i.ownerID = ownerID; i.due = due; return i
        }
        let list = [w("n", owner: "Anant", due: nil, daysAgo: 1), w("v", owner: "Vladan", due: "2026-10-02", daysAgo: 6),
                    w("a", owner: "A", ownerID: "p-aditya", due: "2026-10-09", daysAgo: 1), w("v2", owner: "Vladan", due: nil, daysAgo: 0)]
        XCTAssertEqual(Routing.pendingGroups(list, byDate: false, people: people, now: now).map(\.title), ["Aditya Pradhan", "Vladan", "Anant"],
                       "People first in list order, then others in the order the notes first name them")
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

    // MARK: More words

    func testHighlightDecodesItsOptionalParts() throws {
        let json = #"{"notePath":"wiki/sources/s.md","duration":"30 min","wiki":{"path":"wiki/sources/s.md","summary":"They agreed."},"others":[{"person":"Vladan","items":[{"id":"x","title":"Benchmark","due":"2026-10-07","line":12,"onPage":true},{"id":"y"}]}]}"#
        let n = try JSONDecoder.core.decode(HighlightNote.self, from: Data(json.utf8))
        XCTAssertEqual(n.title, "wiki/sources/s.md", "no title: the path")
        XCTAssertEqual(n.kind, "note")
        XCTAssertFalse(n.isMeeting)
        XCTAssertEqual(n.duration, "30 min")
        XCTAssertEqual(n.id, "wiki/sources/s.md")
        XCTAssertEqual(n.wiki?.summary, "They agreed.")
        XCTAssertEqual(n.wiki?.title, "wiki/sources/s.md")
        let items = n.others.first?.items ?? []
        XCTAssertEqual(items.first, HighlightNote.Item(id: "x", title: "Benchmark", due: "2026-10-07", line: 12, onPage: true))
        XCTAssertEqual(items.last, HighlightNote.Item(id: "y", title: ""))
        XCTAssertFalse(items.last?.onPage ?? true, "not on the page unless the core says so")
        XCTAssertNil(items.last?.due)
        XCTAssertNil(items.last?.line)
    }

    func testRoutingIsOnWithANameOrARealAlias() {
        var p = ActionPreferences()
        p.people = [ActionPerson(id: "you", name: "  ", aliases: ["Jin"])]
        XCTAssertTrue(p.routingOn, "an alias alone is enough")
        p.people = [ActionPerson(id: "you", name: "", aliases: ["  ", ""])]
        XCTAssertFalse(p.routingOn, "blank aliases aren't")
        p.people = [ActionPerson(id: "you", name: "Jin", aliases: [])]
        XCTAssertTrue(p.routingOn)
    }

    func testRemovingAPersonLeavesTypesWithoutTheirOwnList() {
        var p = ActionPreferences()
        p.people = people
        p.setHandlesFor("todo", ["you", "p-aditya"])
        p.removePerson("p-aditya", types: ["todo", "slack"])
        XCTAssertEqual(p.handlesFor("todo"), ["you"])
        XCTAssertNil(p.typeValue("slack", "handlesFor"), "a type on the default stays on the default")
        // Duplicate or empty ids in Settings are skipped.
        p.set(["people"], .array([.object(["id": .string("you"), "name": .string("Jin")]), .object(["id": .string("you"), "name": .string("Other")]),
                                  .object(["id": .string(""), "name": .string("Nobody")]), .object(["name": .string("No id")])]))
        XCTAssertEqual(p.people.map(\.name), ["Jin"])
    }

    func testNamesAndInitials() {
        XCTAssertEqual(Routing.initials("Jin"), "J")
        XCTAssertEqual(Routing.initials("  "), "")
        XCTAssertEqual(Routing.initials("jin 2nd liu"), "JL")
        XCTAssertEqual(Routing.initials("Jin (Bin)"), "J", "only words that start with a letter")
        XCTAssertEqual(Routing.firstName(""), "")
        XCTAssertEqual(Routing.displayName(id: "you", written: "me", people: []), "You")
        XCTAssertEqual(Routing.displayName(id: "you", written: nil, people: [ActionPerson(id: "you", name: " ")]), "You")
        XCTAssertEqual(Routing.displayName(id: "p-x", written: "  ", people: people), "Someone")
        XCTAssertEqual(Routing.displayName(id: "p-aditya", written: "A", people: people), "Aditya Pradhan")
        XCTAssertEqual(Routing.nudgeText(person: "  ", what: " "), "Hi there, any update on this?")
        var item = ActionItem(id: "w", title: "Title")
        item.what = "  "
        XCTAssertEqual(Routing.what(item), "Title")
        XCTAssertEqual(Routing.pendingMeta(item, people: people), "from Someone · promised in")
        item.ownerID = "p-aditya"
        XCTAssertEqual(Routing.pendingMeta(item, people: people), "from Aditya Pradhan · promised in")
        var listed = ActionItem(id: "l", title: "x")
        listed.route = .waiting
        listed.ownerID = "p-aditya"
        XCTAssertNil(Routing.forWhom(listed, people: people), "only items in your lists say who they're for")
    }

    func testChipNamesShowAShortAliasOnly() {
        XCTAssertEqual(Routing.chipName(ActionPerson(id: "p", name: "Aditya Pradhan", aliases: ["Ad"])), "Aditya Pradhan (Ad)")
        XCTAssertEqual(Routing.chipName(ActionPerson(id: "p", name: "Aditya Pradhan", aliases: ["Aditya", "@a", "AP"])), "Aditya Pradhan (AP)")
        XCTAssertEqual(Routing.chipName(ActionPerson(id: "p", name: "Aditya Pradhan", aliases: ["Aditya"])), "Aditya Pradhan")
        XCTAssertEqual(Routing.chipName(ActionPerson(id: "you", name: "Jin", aliases: ["J"])), "Jin", "never on your own chip")
    }

    func testHandlesHintsForEveryType() {
        XCTAssertEqual(Routing.handlesHint(type: "jira", handles: ["you"], people: people), "Tickets Jin has to file.")
        XCTAssertEqual(Routing.handlesHint(type: "confluence", handles: ["you", "p-aditya"], people: people), "Pages Jin and Aditya have to write.")
        XCTAssertEqual(Routing.handlesHint(type: "webhook", handles: ["p-aditya"], people: people), "Items Aditya has to do.")
        XCTAssertEqual(Routing.handlesHint(type: "todo", handles: ["you"], people: people), "Your to-dos.")
        XCTAssertEqual(Routing.handlesHint(type: "todo", handles: ["p-aditya"], people: people), "The to-dos you do for Aditya.")
        let three = people + [ActionPerson(id: "p-mei", name: "Mei Tanaka")]
        XCTAssertEqual(Routing.handlesHint(type: "todo", handles: ["you", "p-aditya", "p-mei"], people: three), "Your to-dos, and the ones you do for Aditya and Mei.")
        XCTAssertEqual(Routing.handlesHint(type: "slack", handles: ["you", "p-aditya", "p-mei"], people: three), "Messages Jin, Aditya and Mei have to send.")
        XCTAssertEqual(Routing.handlesHint(type: "slack", handles: ["you"], people: [ActionPerson(id: "you", name: "")]), "Messages You has to send.")
    }

    func testByAndOverdueEdges() {
        XCTAssertEqual(Routing.by(nil, now: now), nil)
        XCTAssertEqual(Routing.by("not a date", now: now), nil)
        XCTAssertEqual(Routing.by("2026-10-06", now: now), "Tue", "today is this week")
        XCTAssertEqual(Routing.by("2026-10-12", now: now), "Mon", "six days on")
        XCTAssertEqual(Routing.by("2026-10-13", now: now), "Oct 13", "a week on: the date")
        XCTAssertEqual(Routing.by("2026-10-05", now: now), "Oct 5", "yesterday: the date")
        XCTAssertEqual(Routing.by("2026-10-09T18:00:00Z", now: now), "Fri", "a full time reads its day")
        XCTAssertFalse(Routing.overdue(nil, now: now))
        XCTAssertFalse(Routing.overdue("soon", now: now))
    }

    func testPendingByDateNewestFirstWithinADay() {
        func w(_ id: String, due: String?, minutesAgo: Double) -> ActionItem {
            var i = ActionItem(id: id, title: id, createdAt: now.addingTimeInterval(-minutesAgo * 60)); i.route = .waiting; i.due = due; return i
        }
        let groups = Routing.pendingGroups([w("old", due: "2026-10-09", minutesAgo: 30), w("new", due: "2026-10-09", minutesAgo: 1),
                                            w("mid", due: "2026-10-09", minutesAgo: 10), w("none", due: nil, minutesAgo: 0)], byDate: true, people: people, now: now)
        XCTAssertEqual(groups.map(\.title), ["Fri", "No date"])
        XCTAssertEqual(groups[0].items.map(\.id), ["new", "mid", "old"])
        // By person: newest first in a group; ties between people by when first named, then by name.
        let byPerson = Routing.pendingGroups([w("x", due: nil, minutesAgo: 5)].map { var i = $0; i.owner = "Zed"; return i }
                                              + [w("y", due: nil, minutesAgo: 5)].map { var i = $0; i.owner = "Amy"; return i }, byDate: false, people: people, now: now)
        XCTAssertEqual(byPerson.map(\.title), ["Amy", "Zed"])
        XCTAssertEqual(byPerson.map(\.id), ["name:amy", "name:zed"])
    }

    func testElsewhereCountsOnlyThisBatchsRoutedItems() {
        let pending = [ActionItem(id: "c", status: .pending, title: "x", source: .note(jobID: "j1", notePath: nil, pageTitle: nil, quote: nil))]
        var manual = ActionItem(id: "m", title: "m")
        manual.route = .others
        XCTAssertNil(Routing.elsewhereLine(pending: pending, routed: [manual]), "an item from no batch isn't this batch's")
        var listed = ActionItem(id: "l", title: "l", source: .note(jobID: "j1", notePath: nil, pageTitle: nil, quote: nil))
        listed.route = .list
        XCTAssertNil(Routing.elsewhereLine(pending: pending, routed: [listed]), "nothing went elsewhere")
        var other = listed
        other.route = .others
        XCTAssertEqual(Routing.elsewhereLine(pending: pending, routed: [other]), "1 item for other people went to Highlights")
    }

    func testHighlightCountsForEachMix() {
        func counts(_ lists: Int, _ waiting: Int) -> String {
            Routing.highlightCounts(HighlightNote(notePath: "n", title: "N", date: "", counts: .init(others: 1, decisions: 0, lists: lists, waiting: waiting)))
        }
        XCTAssertEqual(counts(0, 0), "Others’ actions 1 · Decisions 0 · Your items: none")
        XCTAssertEqual(counts(3, 0), "Others’ actions 1 · Decisions 0 · Your items: 3 in your lists")
        XCTAssertEqual(counts(0, 2), "Others’ actions 1 · Decisions 0 · Your items: 2 Pending")
        XCTAssertEqual(Routing.highlightWhen(HighlightNote(notePath: "n", title: "N", date: "someday")), "someday")
        XCTAssertEqual(Routing.highlightWhen(HighlightNote(notePath: "n", title: "N", date: "2026-10-05")), "Oct 5")
    }

    func testSummaryMarkdownSections() {
        let label: (String, Int) -> String = { t, n in "\(n) \(t)" }
        let bare = HighlightNote(notePath: "n", title: "Sync", date: "")
        XCTAssertEqual(Routing.summaryMarkdown(bare, typeLabel: label), "# Sync\n")
        let full = HighlightNote(notePath: "n", title: "Sync", date: "",
                                 wiki: .init(path: "n", title: "Sync", decisions: [.init(text: "Ship Friday", line: 4)]),
                                 others: [.init(person: "Vladan", items: [.init(id: "x", title: "Benchmark")])],
                                 yours: .init(lists: ["todo": 2, "jira": 1]))
        XCTAssertEqual(Routing.summaryMarkdown(full, typeLabel: label), """
        # Sync

        ## Decisions
        - Ship Friday

        ## Others’ actions
        - **Vladan**: Benchmark

        ## Your items
        - In your lists: 1 jira, 2 todo

        """)
        let waitingOnly = HighlightNote(notePath: "n", title: "Sync", date: "", yours: .init(waiting: [.init(id: "w", person: "Mei Tanaka", what: "slides")]))
        XCTAssertEqual(Routing.summaryMarkdown(waitingOnly, typeLabel: label), "# Sync\n\n## Your items\n- Pending: Mei: slides\n")
    }

    func testPreviewAndHighlightRoutes() async throws {
        StubProtocol.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
        defer { StubProtocol.handler = nil }
        StubProtocol.handler = { _ in (200, Data(#"{"days":7,"lists":1,"waiting":0,"others":0}"#.utf8)) }
        _ = try await client.routingPreview()
        XCTAssertEqual(try JSONDecoder.core.decode(JSONValue.self, from: StubProtocol.recorded.last?.body ?? Data()), .object([:]), "the saved settings")
        _ = try await client.routingPreview(people: [ActionPerson(id: "you", name: "Jin", aliases: ["J"])], handles: ["todo": ["you"]])
        let body = try JSONDecoder.core.decode(JSONValue.self, from: StubProtocol.recorded.last?.body ?? Data())
        XCTAssertEqual(body["people"], .array([.object(["id": .string("you"), "name": .string("Jin"), "aliases": .array([.string("J")])])]))
        XCTAssertEqual(body["types"], .object(["todo": .object(["handlesFor": .array([.string("you")])])]))
        StubProtocol.handler = { _ in (200, Data(#"{"notePath":"wiki/sources/a b.md","title":"A"}"#.utf8)) }
        let note = try await client.highlight("wiki/sources/a b.md")
        XCTAssertEqual(note.title, "A")
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/highlights/note")
        XCTAssertEqual(StubProtocol.recorded.last?.query, "path=wiki/sources/a%20b.md")
    }
}
