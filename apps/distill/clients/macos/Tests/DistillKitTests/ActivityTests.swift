import XCTest
@testable import DistillKit

/// The activity log and trash: the routes, lenient decoding, the event, the
/// header that says who asked, the filter and the detail's words.
final class ActivityTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: String(repeating: "f", count: 64)), session: URLSession(configuration: config))
    }

    static let deleted = #"""
    {"id":"1791155040000-0001-a1b2c3","at":"2026-10-04T23:04:00.000Z","type":"collector.deleted","source":"app",
     "object":{"kind":"collector","id":"col-1","name":"Meeting notes"},"summary":"Deleted the script collector “Meeting notes”","outcome":"ok",
     "details":{"kind":"script","interpreter":"python3","scriptBytes":2140,"scriptLines":61,"schedule":"0 18 * * 1-5","vault":"/v/Research"},
     "recovery":{"kind":"trash","trashId":"trash-1","expiresAt":"2026-11-03T23:04:00.000Z"},"pid":4242}
    """#

    // MARK: Client

    func testEveryRequestSaysItIsTheApp() async throws {
        StubProtocol.handler = { _ in (200, Data(#"{"entries":[],"nextCursor":null}"#.utf8)) }
        _ = try await client.activity()
        XCTAssertEqual(StubProtocol.recorded.last?.headers["X-Distill-Client"], "app")
        // The event stream is built by the same function.
        XCTAssertEqual(client.makeRequest("GET", "/v1/events", body: nil, timeout: 1, accept: "text/event-stream")
            .value(forHTTPHeaderField: "X-Distill-Client"), "app")
    }

    func testActivitySendsTheCoreQueryNames() async throws {
        StubProtocol.handler = { _ in (200, Data("{\"entries\":[\(Self.deleted)],\"nextCursor\":\"1791155040000-0001-a1b2c3\"}".utf8)) }
        let since = Date(timeIntervalSince1970: 1_790_000_000)
        let page = try await client.activity(ActivityQuery(types: ["queue", "note"], objectID: "col 1", sources: [.scheduler], since: since,
                                                           text: "a+b", onlyFailures: true, limit: 50, cursor: "c1"))
        XCTAssertEqual(page.entries.count, 1)
        XCTAssertEqual(page.nextCursor, "1791155040000-0001-a1b2c3")
        let last = try XCTUnwrap(StubProtocol.recorded.last)
        XCTAssertEqual(last.path, "/v1/activity")
        let items = URLComponents(string: "x:/?" + (last.query ?? ""))?.queryItems ?? []
        let q = Dictionary(uniqueKeysWithValues: items.map { ($0.name, $0.value ?? "") })
        XCTAssertEqual(q["type"], "queue,note")
        XCTAssertEqual(q["object"], "col 1")
        XCTAssertEqual(q["source"], "scheduler")
        XCTAssertEqual(q["since"], CoreDate.format(since))
        XCTAssertEqual(q["q"], "a+b", "a plus survives (not read as a space)")
        XCTAssertEqual(q["outcome"], "failed")
        XCTAssertEqual(q["limit"], "50")
        XCTAssertEqual(q["cursor"], "c1")
    }

    func testTrashAndRestore() async throws {
        StubProtocol.handler = { req in
            if req.url?.path == "/v1/trash" {
                return (200, Data(#"{"items":[{"id":"trash-1","kind":"collector","objectID":"col-1","name":"Meeting notes","deletedAt":"2026-10-04T23:04:00Z","expiresAt":"2026-11-03T23:04:00Z","source":"app","sizeBytes":4100,"details":{"scriptLines":61}},{"bogus":true}]}"#.utf8))
            }
            return (200, Data(#"{"item":{"id":"trash-1","kind":"collector","objectID":"col-1","name":"Meeting notes"},"objectID":"col-2","note":"The script collector is off."}"#.utf8))
        }
        let items = try await client.trash()
        XCTAssertEqual(items.map(\.id), ["trash-1"], "an item of the wrong shape is skipped")
        XCTAssertEqual(items[0].sizeBytes, 4100)
        let r = try await client.restoreFromTrash("trash-1")
        XCTAssertEqual(r.objectID, "col-2")
        XCTAssertEqual(r.note, "The script collector is off.")
        XCTAssertEqual(StubProtocol.recorded.last?.method, "POST")
        XCTAssertEqual(StubProtocol.recorded.last?.path, "/v1/trash/trash-1/restore")
    }

    func testRestoreConflictAndOldCore() async {
        StubProtocol.handler = { _ in (409, Data(#"{"error":{"code":"conflict","message":"A chat with id c1 already exists."}}"#.utf8)) }
        do { _ = try await client.restoreFromTrash("trash-1"); XCTFail("expected 409") } catch let e as CoreClientError {
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.description, "A chat with id c1 already exists.")
        } catch { XCTFail("\(error)") }
        StubProtocol.handler = { _ in (501, Data(#"{"error":{"code":"not_implemented","message":"no activity"}}"#.utf8)) }
        do { _ = try await client.activity(); XCTFail("expected 501") } catch let e as CoreClientError {
            XCTAssertTrue(e.isNotAvailable)
        } catch { XCTFail("\(error)") }
    }

    // MARK: Decoding

    func testEntryDecodesLeniently() throws {
        let page = try JSONDecoder.core.decode(ActivityPage.self, from: Data(#"""
        {"entries":[
          {"id":"2","at":"2026-10-04T23:05:00Z","type":"widget.zapped","source":"robot","object":{"kind":"widget"},"summary":"Zapped",
           "outcome":"failed","error":"boom","details":{"nested":{"a":1},"list":["x","y"]},"recovery":{"kind":"cloud","url":"x"},"extra":1},
          {"id":"3","type":"no.time"},
          \#(Self.deleted)
        ],"nextCursor":"","more":true}
        """#.utf8))
        XCTAssertEqual(page.entries.map(\.id), ["2", "1791155040000-0001-a1b2c3"], "an entry without a time is skipped")
        XCTAssertNil(page.nextCursor)
        let odd = page.entries[0]
        XCTAssertEqual(odd.source.rawValue, "robot", "a newer source is kept")
        XCTAssertEqual(odd.family, "widget")
        XCTAssertTrue(odd.failed)
        XCTAssertEqual(odd.recovery, .unknown(kind: "cloud"))
        XCTAssertEqual(odd.strings("list"), ["x", "y"])
        let e = page.entries[1]
        XCTAssertEqual(e.recovery?.trashID, "trash-1")
        XCTAssertEqual(e.int("scriptLines"), 61)
        XCTAssertEqual(e.verb, "deleted")
        // A round trip keeps it.
        let again = try JSONDecoder.core.decode(ActivityEntry.self, from: JSONEncoder.core.encode(e))
        XCTAssertEqual(again, e)
    }

    func testActivityEvent() throws {
        let event = try CoreEvent.decode(Data("{\"type\":\"activity\",\"entry\":\(Self.deleted)}".utf8))
        guard case .activity(let e) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(e.type, "collector.deleted")
        // An entry this build can't read doesn't break the stream.
        XCTAssertEqual(try CoreEvent.decode(Data(#"{"type":"activity","entry":{"nope":1}}"#.utf8)), .unknown(type: "activity"))
    }

    // MARK: Filter

    func testFilterChipsAndQuery() {
        var f = ActivityFilter(text: " kettle ", what: .queue, from: .automatic, when: .today, onlyFailures: true)
        XCTAssertEqual(f.chips.map(\.text), ["Queue", "From: Automatic", "When: Today", "Only failures"])
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        let now = Date(timeIntervalSince1970: 1_791_155_040) // 2026-10-04 4:04 PM PDT
        let q = f.query(now: now, calendar: cal)
        XCTAssertEqual(q.types, ["queue", "note"])
        XCTAssertEqual(q.sources, [.scheduler])
        XCTAssertEqual(q.since, cal.startOfDay(for: now))
        XCTAssertEqual(q.text, "kettle")
        XCTAssertTrue(q.onlyFailures)
        f.remove(f.chips[1])
        XCTAssertEqual(f.from, .anywhere)
        f.object = .init(id: "col-1", name: "Meeting notes")
        XCTAssertEqual(f.chips.first?.text, "For: Meeting notes")
        f.clearChoices()
        XCTAssertTrue(f.chips.isEmpty)
        XCTAssertTrue(f.isActive, "the search stays after Clear")
    }

    func testLiveEntryMatching() throws {
        let e = try JSONDecoder.core.decode(ActivityEntry.self, from: Data(Self.deleted.utf8))
        let now = e.at.addingTimeInterval(60)
        XCTAssertEqual(ActivityFilter().matches(e, now: now), true)
        XCTAssertEqual(ActivityFilter(what: .collectors).matches(e, now: now), true)
        XCTAssertEqual(ActivityFilter(what: .chats).matches(e, now: now), false)
        XCTAssertEqual(ActivityFilter(from: .cli).matches(e, now: now), false)
        XCTAssertEqual(ActivityFilter(onlyFailures: true).matches(e, now: now), false)
        XCTAssertNil(ActivityFilter(text: "notes").matches(e, now: now), "search is the core's")
    }

    // MARK: Words

    func testRecoveryStates() throws {
        let e = try JSONDecoder.core.decode(ActivityEntry.self, from: Data(Self.deleted.utf8))
        let t = ActivityText()
        let item = TrashItem(id: "trash-1", kind: "collector", objectID: "col-1", name: "Meeting notes",
                             deletedAt: e.at, expiresAt: e.at.addingTimeInterval(30 * 86_400))
        guard case .inTrash(_, _, let hours)? = t.recovery(e, trash: ["trash-1": item], restores: [:]) else { return XCTFail() }
        XCTAssertEqual(t.kept(hours: hours), "Kept 30 days")
        XCTAssertEqual(t.kept(hours: 24), "Kept 24 hours")
        XCTAssertEqual(t.tag(t.recovery(e, trash: ["trash-1": item], restores: [:])), "In trash")
        // Gone from the trash and never restored: no Restore (it would 404).
        XCTAssertEqual(t.recovery(e, trash: [:], restores: [:]), .trashGone(expiresAt: item.expiresAt))
        XCTAssertEqual(t.tag(.trashGone(expiresAt: nil)), "")
        // A restore entry wins, after a relaunch too.
        let restored = ActivityEntry(id: "z", at: e.at.addingTimeInterval(480), type: "collector.restored", source: .app,
                                     object: ActivityObject(kind: "collector", id: "col-1", name: "Meeting notes"), summary: "Restored",
                                     details: ["trashId": .string("trash-1")])
        let index = ActivityRestore.index([restored])
        XCTAssertEqual(t.recovery(e, trash: [:], restores: index), .restored(at: restored.at, objectID: "col-1"))
    }

    func testFactsUseTheCoreKeys() throws {
        let e = try JSONDecoder.core.decode(ActivityEntry.self, from: Data(Self.deleted.utf8))
        let facts = ActivityText(home: "/Users/mei").facts(e, now: e.at, vaultName: { _ in "Research" })
        XCTAssertEqual(facts.heading, "WHAT WAS THERE")
        let rows = Dictionary(uniqueKeysWithValues: facts.rows.map { ($0.label, $0.value) })
        XCTAssertEqual(rows["What"], "Script collector “Meeting notes”")
        XCTAssertEqual(rows["Script"], "python3 · 61 lines · \(ActivityText.size(2140)), written in Distill")
        XCTAssertEqual(rows["Schedule"], "Weekdays at 6:00 PM")
        XCTAssertEqual(rows["Into"], "Research")
        XCTAssertEqual(facts.rows.last, ActivityText.Fact("Type", "collector.deleted", code: true))
        XCTAssertFalse(facts.rows.contains { $0.label == "Script bytes" }, "known keys aren't listed twice")
    }

    func testSettingsChangesAndUnknownKeys() {
        let t = ActivityText()
        XCTAssertEqual(t.settingsFact("askPreferences.keepHistory: true → false"), ActivityText.Fact("Keep history", "On → ", emphasis: "Off"))
        XCTAssertEqual(t.settingsFact("runners: changed"), ActivityText.Fact("Runners", "Changed"))
        let e = ActivityEntry(id: "1", at: Date(), type: "widget.zapped", source: .api, object: ActivityObject(kind: "widget"),
                              summary: "Zapped", details: ["zapCount": .number(3), "ok": .bool(true), "gone": .null])
        let rows = t.facts(e, now: Date()).rows
        XCTAssertEqual(rows.map(\.label), ["Ok", "Zap count", "Type"])
        XCTAssertEqual(rows.map(\.value), ["Yes", "3", "widget.zapped"])
    }

    func testSourcesAndGroups() {
        let t = ActivityText()
        XCTAssertEqual([ActivitySource.app, .cli, .agent, .scheduler, .api, .core, ActivitySource("robot")].map(t.source),
                       ["Mac app", "CLI", "Agent", "Automatic", "Other app", "Distill", "Other app"])
        let now = Date()
        let a = ActivityEntry(id: "2", at: now, type: "x.y", source: .app, object: ActivityObject(kind: "x"), summary: "a")
        let b = ActivityEntry(id: "1", at: now.addingTimeInterval(-86_400), type: "x.y", source: .app, object: ActivityObject(kind: "x"), summary: "b")
        XCTAssertEqual(t.groups([b, a], now: now).map(\.title), ["TODAY", "YESTERDAY"])
    }
}
