import XCTest
@testable import DistillKit

/// History → Activity's words (ActivityText.swift): the filter, times, recovery and
/// the detail's facts for each family, on a pinned clock and calendar.
final class ActivityTextTests: XCTestCase {
    static var utc: Calendar {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }
    let cal = ActivityTextTests.utc
    /// 2026-10-06 15:30 UTC.
    let now = Date(timeIntervalSince1970: 1_791_300_600)
    lazy var t = ActivityText(calendar: cal, home: "/Users/mei")

    func entry(_ type: String, name: String? = "Meeting notes", source: ActivitySource = .app, at: Date? = nil, failed: Bool = false,
               id: String = "1", objectID: String? = "obj-1", details: [String: JSONValue] = [:], recovery: ActivityRecovery? = nil) -> ActivityEntry {
        ActivityEntry(id: id, at: at ?? now, type: type, source: source, object: ActivityObject(kind: String(type.split(separator: ".").first ?? ""), id: objectID, name: name),
                      summary: "s", failed: failed, details: details, recovery: recovery)
    }

    func facts(_ type: String, _ details: [String: JSONValue], name: String? = "Meeting notes") -> ActivityText.Facts {
        t.facts(entry(type, name: name, details: details), now: now, vaultName: { ($0 as NSString).lastPathComponent })
    }

    func rows(_ f: ActivityText.Facts) -> [String: String] {
        Dictionary(f.rows.map { ($0.label, $0.value) }, uniquingKeysWith: { a, _ in a })
    }

    // MARK: Filter

    func testFilterTitlesTypesAndSources() {
        XCTAssertEqual(ActivityWhat.allCases.map(\.title), ["All", "Chats", "Collectors", "Actions", "Batches", "Queue", "Settings"])
        XCTAssertEqual(ActivityWhat.allCases.map(\.types), [[], ["chat"], ["collector"], ["action"], ["batch", "labels"], ["queue", "note"],
                                                           ["settings", "runner", "connection"]])
        XCTAssertEqual(ActivityFrom.allCases.map(\.title), ["Anywhere", "Mac app", "CLI", "Agent", "Automatic"])
        XCTAssertEqual(ActivityFrom.allCases.map(\.source), [nil, .app, .cli, .agent, .scheduler])
        XCTAssertEqual(ActivityWhen.allCases.map(\.title), ["Any time", "Today", "7 days", "30 days"])
        XCTAssertNil(ActivityWhen.any.since(now: now, calendar: cal))
        XCTAssertEqual(ActivityWhen.today.since(now: now, calendar: cal), cal.startOfDay(for: now))
        XCTAssertEqual(ActivityWhen.week.since(now: now, calendar: cal), now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(ActivityWhen.month.since(now: now, calendar: cal), now.addingTimeInterval(-30 * 86_400))
    }

    func testQueryDefaultsAndBlankSearch() {
        let q = ActivityFilter(text: "  \n").query(now: now, calendar: cal, limit: 20, cursor: "c9")
        XCTAssertEqual(q, ActivityQuery(types: [], objectID: nil, sources: [], since: nil, text: nil, onlyFailures: false, limit: 20, cursor: "c9"))
        XCTAssertFalse(ActivityFilter(text: "  ").isActive)
        XCTAssertTrue(ActivityFilter(what: .chats).isActive)
        XCTAssertTrue(ActivityFilter(object: .init(id: "c", name: "C")).isActive)
        let scoped = ActivityFilter(object: .init(id: "col-1", name: "Meeting notes")).query(now: now)
        XCTAssertEqual(scoped.objectID, "col-1")
        XCTAssertEqual(scoped.limit, 50)
        XCTAssertNil(scoped.cursor)
    }

    func testEveryChipRemovesOnlyItsOwnChoice() {
        var f = ActivityFilter(text: "kettle", what: .batches, from: .cli, when: .month, onlyFailures: true, object: .init(id: "b-1", name: "Batch"))
        XCTAssertEqual(f.chips.map(\.text), ["For: Batch", "Batches", "From: CLI", "When: 30 days", "Only failures"])
        XCTAssertEqual(f.chips.map(\.section), ["object", "what", "from", "when", "failed"])
        XCTAssertEqual(f.chips.map(\.value), ["b-1", "batches", "cli", "month", "1"])
        f.remove(FacetChip(section: "nowhere", value: "x", text: "x"))
        XCTAssertEqual(f.chips.count, 5)
        f.remove(f.chips[0])
        XCTAssertNil(f.object)
        XCTAssertEqual(f.what, .batches)
        f.remove(f.chips[0])
        XCTAssertEqual(f.what, .all)
        XCTAssertEqual(f.from, .cli)
        f.remove(f.chips[0])
        XCTAssertEqual(f.from, .anywhere)
        f.remove(f.chips[0])
        XCTAssertEqual(f.when, .any)
        XCTAssertTrue(f.onlyFailures)
        f.remove(f.chips[0])
        XCTAssertFalse(f.onlyFailures)
        XCTAssertEqual(f.chips, [])
        XCTAssertEqual(f.text, "kettle")
    }

    func testClearChoicesResetsEveryChoice() {
        var f = ActivityFilter(text: "x", what: .queue, from: .agent, when: .week, onlyFailures: true, object: .init(id: "a", name: "A"))
        f.clearChoices()
        XCTAssertEqual(f, ActivityFilter(text: "x"))
    }

    func testLiveMatchingEachChoice() {
        let e = entry("note.added", source: .agent, at: now.addingTimeInterval(-3 * 86_400), failed: true, objectID: "n-1")
        // Queue includes notes by family; a family-less type matches by its whole name.
        XCTAssertEqual(ActivityFilter(what: .queue).matches(e, now: now, calendar: cal), true)
        XCTAssertEqual(ActivityFilter(what: .settings).matches(e, now: now, calendar: cal), false)
        let bare = ActivityEntry(id: "2", at: now, type: "runner", source: .app, object: ActivityObject(kind: "x"), summary: "s")
        XCTAssertEqual(ActivityFilter(what: .settings).matches(bare, now: now, calendar: cal), true)
        XCTAssertEqual(ActivityFilter(from: .agent).matches(e, now: now, calendar: cal), true)
        XCTAssertEqual(ActivityFilter(from: .app).matches(e, now: now, calendar: cal), false)
        XCTAssertEqual(ActivityFilter(when: .week).matches(e, now: now, calendar: cal), true)
        XCTAssertEqual(ActivityFilter(when: .today).matches(e, now: now, calendar: cal), false)
        // Exactly at the start counts (inclusive).
        let edge = entry("note.added", at: now.addingTimeInterval(-7 * 86_400))
        XCTAssertEqual(ActivityFilter(when: .week).matches(edge, now: now, calendar: cal), true)
        XCTAssertEqual(ActivityFilter(when: .week).matches(entry("note.added", at: now.addingTimeInterval(-7 * 86_400 - 1)), now: now, calendar: cal), false)
        XCTAssertEqual(ActivityFilter(onlyFailures: true).matches(e, now: now, calendar: cal), true)
        XCTAssertEqual(ActivityFilter(object: .init(id: "n-1", name: "N")).matches(e, now: now, calendar: cal), true)
        XCTAssertEqual(ActivityFilter(object: .init(id: "n-2", name: "N")).matches(e, now: now, calendar: cal), false)
        XCTAssertEqual(ActivityFilter(text: "   ").matches(e, now: now, calendar: cal), true, "a blank search is no search")
    }

    // MARK: Times and sources

    func testDaysAndDatesOnAPinnedCalendar() {
        XCTAssertEqual(t.day(now.addingTimeInterval(-3600), now: now), "Today")
        XCTAssertEqual(t.day(now.addingTimeInterval(-86_400), now: now), "Yesterday")
        XCTAssertEqual(t.day(now.addingTimeInterval(-2 * 86_400), now: now), "Oct 4")
        XCTAssertEqual(t.day(now.addingTimeInterval(-400 * 86_400), now: now), "Sep 1, 2025")
        XCTAssertEqual(t.date(now, now: now), "Oct 6")
        XCTAssertEqual(t.date(now.addingTimeInterval(-400 * 86_400), now: now), "Sep 1, 2025")
        XCTAssertEqual(t.date(now.addingTimeInterval(400 * 86_400), now: now), "Nov 10, 2027")
        XCTAssertEqual(t.clock(now), "3:30 PM")
        XCTAssertEqual(t.when(now.addingTimeInterval(-86_400), now: now), "Yesterday 3:30 PM")
    }

    func testDetailLineSaysWhoAsked() {
        let sources: [ActivitySource] = [.app, .cli, .agent, .scheduler, .core, .api, ActivitySource("robot")]
        XCTAssertEqual(sources.map(t.fromPhrase), ["from the Mac app", "from the CLI", "from an agent (the CLI in Claude Code or Codex)",
                                                   "Automatic", "from Distill itself", "from another app", "from another app"])
        XCTAssertEqual(t.detailLine(entry("chat.deleted", source: .cli), now: now), "Today 3:30 PM · from the CLI")
    }

    func testGroupsAreNewestFirstAndOnePerDay() {
        let a = entry("x.y", at: now, id: "3")
        let b = entry("x.y", at: now.addingTimeInterval(-60), id: "2")
        let c = entry("x.y", at: now.addingTimeInterval(-3 * 86_400), id: "1")
        let groups = t.groups([c, a, b], now: now)
        XCTAssertEqual(groups.map(\.title), ["TODAY", "OCT 3"])
        XCTAssertEqual(groups.map(\.id), ["TODAY", "OCT 3"])
        XCTAssertEqual(groups[0].entries.map(\.id), ["3", "2"])
        XCTAssertEqual(groups[1].entries.map(\.id), ["1"])
        XCTAssertEqual(t.groups([], now: now), [])
    }

    // MARK: Recovery

    func testRecoveryKeepsTheTrashCopysOwnDates() {
        let deleted = now.addingTimeInterval(-86_400)
        let e = entry("chat.deleted", at: deleted, recovery: .trash(id: "t1", expiresAt: deleted.addingTimeInterval(10 * 86_400)))
        // The trash listing's expiry wins over the entry's.
        let item = TrashItem(id: "t1", kind: "chat", objectID: "c", name: "C", deletedAt: deleted, expiresAt: deleted.addingTimeInterval(24 * 3600))
        XCTAssertEqual(t.recovery(e, trash: ["t1": item], restores: [:]),
                       .inTrash(trashID: "t1", expiresAt: deleted.addingTimeInterval(24 * 3600), keptHours: 24))
        // No expiry in the listing: the entry's; no deletedAt: the entry's time.
        let bare = TrashItem(id: "t1", kind: "chat", objectID: "c", name: "C")
        XCTAssertEqual(t.recovery(e, trash: ["t1": bare], restores: [:]),
                       .inTrash(trashID: "t1", expiresAt: deleted.addingTimeInterval(10 * 86_400), keptHours: 240))
        // No expiry anywhere: 30 days.
        let open = entry("chat.deleted", recovery: .trash(id: "t1", expiresAt: nil))
        XCTAssertEqual(t.recovery(open, trash: ["t1": bare], restores: [:]), .inTrash(trashID: "t1", expiresAt: nil, keptHours: 720))
        // An expiry within the hour still says at least 1 hour.
        let soon = TrashItem(id: "t1", kind: "chat", objectID: "c", name: "C", deletedAt: deleted, expiresAt: deleted.addingTimeInterval(60))
        XCTAssertEqual(t.recovery(e, trash: ["t1": soon], restores: [:]), .inTrash(trashID: "t1", expiresAt: deleted.addingTimeInterval(60), keptHours: 1))
        // A restore wins over a trash copy.
        XCTAssertEqual(t.recovery(e, trash: ["t1": item], restores: ["t1": ActivityRestore(at: now, objectID: nil)]), .restored(at: now, objectID: nil))
        XCTAssertEqual(t.tag(.restored(at: now, objectID: nil)), "Restored")
    }

    func testOtherRecoveryKinds() {
        XCTAssertEqual(t.recovery(entry("queue.removed", recovery: .macosTrash(path: "~/.Trash/a.md")), trash: [:], restores: [:]), .macosTrash(path: "~/.Trash/a.md"))
        XCTAssertEqual(t.recovery(entry("queue.removed", recovery: .none(reason: "too big")), trash: [:], restores: [:]), .none(reason: "too big"))
        XCTAssertNil(t.recovery(entry("queue.removed", recovery: .unknown(kind: "cloud")), trash: [:], restores: [:]))
        XCTAssertNil(t.recovery(entry("queue.removed"), trash: [:], restores: [:]))
        XCTAssertEqual(t.tag(nil), "")
        XCTAssertEqual(t.tag(.macosTrash(path: "x")), "")
        XCTAssertEqual(t.tag(.inTrash(trashID: "t", expiresAt: nil, keptHours: 1)), "In trash")
    }

    func testKeptWordsSwitchToDaysAtTwoDays() {
        XCTAssertEqual(t.kept(hours: 1), "Kept 1 hours")
        XCTAssertEqual(t.kept(hours: 47), "Kept 47 hours")
        XCTAssertEqual(t.kept(hours: 48), "Kept 2 days")
        XCTAssertEqual(t.kept(hours: 60), "Kept 3 days")
        XCTAssertEqual(t.kept(hours: 59), "Kept 2 days")
        XCTAssertEqual(t.kept(hours: 720), "Kept 30 days")
    }

    func testRestoreIndexKeepsTheLatestSuccessfulRestore() {
        let early = entry("chat.restored", at: now.addingTimeInterval(-60), objectID: "c-1", details: ["trashId": .string("t1")])
        let late = entry("chat.restored", at: now, objectID: "c-2", details: ["trashId": .string("t1")])
        let failed = entry("chat.restored", at: now.addingTimeInterval(60), failed: true, objectID: "c-3", details: ["trashId": .string("t1")])
        let other = entry("chat.deleted", at: now.addingTimeInterval(120), objectID: "c-4", details: ["trashId": .string("t1")])
        let noID = entry("collector.restored", at: now, objectID: "c-5")
        XCTAssertEqual(ActivityRestore.index([early, late, failed, other, noID]), ["t1": ActivityRestore(at: now, objectID: "c-2")])
        XCTAssertEqual(ActivityRestore.index([late, early]), ["t1": ActivityRestore(at: now, objectID: "c-2")], "order doesn't matter")
    }

    // MARK: Facts: collectors

    func testCollectorRunFacts() {
        let f = facts("collector.run", ["trigger": .string("schedule"), "durationMs": .number(1530), "exitCode": .number(0), "runId": .string("r1"),
                                        "filesAdded": .array(["a.md", "b.md", "c.md", "d.md", "e.md"].map(JSONValue.string)), "result": .string("ok")])
        XCTAssertEqual(f.heading, "DETAILS")
        XCTAssertEqual(f.rows.map(\.label), ["Collector", "Run", "Added", "Type"])
        XCTAssertEqual(rows(f)["Collector"], "Meeting notes")
        XCTAssertEqual(rows(f)["Run"], "Scheduled · 1.5 s · exit 0")
        XCTAssertEqual(rows(f)["Added"], "a.md, b.md, c.md, +2 more")
        XCTAssertEqual(rows(facts("collector.run", ["trigger": .string("catch-up")]))["Run"], "Catch-up after sleep")
        XCTAssertEqual(rows(facts("collector.run", ["trigger": .string("now"), "exitCode": .number(2)]))["Run"], "Run now · exit 2")
        XCTAssertEqual(rows(facts("collector.run", ["trigger": .string("webhook")]))["Run"], "webhook")
        // Nothing to say about the run: no Run row; nothing added says so.
        let empty = facts("collector.run", [:], name: nil)
        XCTAssertEqual(empty.rows.map(\.label), ["Added", "Type"])
        XCTAssertEqual(rows(empty)["Added"], "Nothing")
        XCTAssertEqual(rows(facts("collector.run", ["filesAdded": .array(["a.md", "b.md", "c.md"].map(JSONValue.string))]))["Added"], "a.md, b.md, c.md")
    }

    func testRunDurations() {
        XCTAssertEqual(t.seconds(0), "0 ms")
        XCTAssertEqual(t.seconds(999), "999 ms")
        XCTAssertEqual(t.seconds(1000), "1.0 s")
        XCTAssertEqual(t.seconds(9_949), "9.9 s")
        XCTAssertEqual(t.seconds(10_000), "10 s")
        XCTAssertEqual(t.seconds(125_400), "125 s")
    }

    func testListShowsAFewThenCounts() {
        XCTAssertEqual(t.list([]), "")
        XCTAssertEqual(t.list(["a"]), "a")
        XCTAssertEqual(t.list(["a", "b", "c"]), "a, b, c")
        XCTAssertEqual(t.list(["a", "b", "c", "d"]), "a, b, c, +1 more")
        XCTAssertEqual(t.list(["a", "b", "c"], show: 2), "a, b, +1 more")
        XCTAssertEqual(t.list(["a", "b"], show: 2), "a, b")
    }

    func testFolderCollectorFacts() {
        let f = facts("collector.created", ["kind": .string("folder"), "folder": .string("/Users/mei/Notes/Inbox"), "afterCollect": .string("move"),
                                            "schedule": .string("*/15 * * * *"), "vault": .string("/v/Research"),
                                            "lastRunAt": .string("2026-10-06T14:00:00.000Z"), "collected": .number(1)])
        XCTAssertEqual(f.heading, "DETAILS")
        XCTAssertEqual(f.rows.map(\.label), ["What", "Folder", "After", "Schedule", "Into", "Last run", "Type"])
        XCTAssertEqual(rows(f)["What"], "Folder collector “Meeting notes”")
        XCTAssertEqual(rows(f)["Folder"], "~/Notes/Inbox")
        XCTAssertEqual(rows(f)["After"], "Moves files into the queue")
        XCTAssertEqual(rows(f)["Schedule"], "Every 15 minutes")
        XCTAssertEqual(rows(f)["Into"], "Research")
        XCTAssertEqual(rows(f)["Last run"], "Today 2:00 PM · 1 file collected")
        XCTAssertEqual(rows(facts("collector.updated", ["afterCollect": .string("copy")]))["After"], "Copies files into the queue")
        XCTAssertEqual(rows(facts("collector.updated", ["afterCollect": .string("link")]))["After"], "link")
        XCTAssertEqual(rows(facts("collector.updated", ["lastRunAt": .string("2026-10-05T14:00:00.000Z"), "collected": .number(4)]))["Last run"],
                       "Yesterday 2:00 PM · 4 files collected")
        XCTAssertEqual(rows(facts("collector.updated", ["lastRunAt": .string("2026-10-05T14:00:00.000Z")]))["Last run"], "Yesterday 2:00 PM")
        // Without a last run, the count isn't listed on its own either.
        XCTAssertEqual(facts("collector.updated", ["collected": .number(4)]).rows.map(\.label), ["Type"])
        // A kind Distill doesn't know is capitalized.
        XCTAssertEqual(rows(facts("collector.updated", ["kind": .string("webhook")]))["What"], "Webhook collector “Meeting notes”")
    }

    func testCollectorHeadingsAndRestoreFacts() {
        XCTAssertEqual(facts("collector.deleted", [:]).heading, "WHAT WAS THERE")
        XCTAssertEqual(facts("collector.updated", [:]).heading, "DETAILS")
        let restored = facts("collector.restored", ["deletedAt": .string("2026-10-05T09:15:00.000Z"), "trashId": .string("t1"), "previousID": .string("col-0"),
                                                    "renamedFrom": .string("Old notes")])
        XCTAssertEqual(restored.heading, "DETAILS")
        XCTAssertEqual(restored.rows.map(\.label), ["Was", "Deleted", "Old id", "Type"])
        XCTAssertEqual(rows(restored)["Was"], "“Old notes”")
        XCTAssertEqual(rows(restored)["Deleted"], "Yesterday 9:15 AM")
        XCTAssertEqual(rows(restored)["Old id"], "col-0")
        // Deleted and Old id only belong to a restore; elsewhere they're listed as they are.
        let other = facts("collector.updated", ["previousID": .string("col-0")])
        XCTAssertEqual(other.rows.map(\.label), ["Previous id", "Type"])
        // A consent hides the script hash; elsewhere it shows.
        XCTAssertEqual(facts("collector.consented", ["sha256": .string("abc")]).rows.map(\.label), ["Type"])
        XCTAssertEqual(facts("collector.updated", ["sha256": .string("abc")]).rows.map(\.label), ["Sha256", "Type"])
    }

    func testScriptRemovedOutsideDistill() {
        // Saved elsewhere and now gone: no size, the change says the script went.
        let f = facts("collector.script_changed_outside", ["interpreter": .string("python3"), "changedOutside": .bool(true),
                                                           "changes": .array([.string("script")]), "file": .string("/x/collector.py")])
        XCTAssertEqual(rows(f)["Script"], "python3 · removed outside Distill")
        XCTAssertEqual(f.rows.map(\.label), ["Script", "Type"], "file and change list aren't repeated; no modified time, no Saved row")
        // Changed outside but not the script: nothing about the script file.
        let settings = facts("collector.script_changed_outside", ["interpreter": .string("python3"), "changedOutside": .bool(true),
                                                                  "changes": .array([.string("schedule")])])
        XCTAssertEqual(rows(settings)["Script"], "python3")
        // A script collector with nothing known about its script: no Script row.
        XCTAssertEqual(facts("collector.updated", ["kind": .string("script")]).rows.map(\.label), ["What", "Type"])
        XCTAssertEqual(rows(facts("collector.updated", ["kind": .string("script"), "scriptLines": .number(1)]))["Script"], "1 line")
        // Not a script and no interpreter: script keys are listed as they are.
        XCTAssertEqual(facts("collector.updated", ["kind": .string("folder"), "scriptLines": .number(3)]).rows.map(\.label), ["What", "Script lines", "Type"])
    }

    // MARK: Facts: chats

    func testChatFacts() {
        let f = facts("chat.deleted", ["turnCount": .number(3), "sizeBytes": .number(2048), "createdAt": .string("2026-10-05T08:00:00.000Z"),
                                       "lastMessageAt": .string("2026-10-04T08:00:00.000Z"), "reason": .string("keep-history-off")],
                      name: "Kettle prices")
        XCTAssertEqual(f.heading, "WHAT WAS THERE")
        XCTAssertEqual(f.rows.map(\.label), ["What", "Size", "Started", "Last message", "Why", "Type"])
        XCTAssertEqual(rows(f)["What"], "Ask chat “Kettle prices”")
        XCTAssertEqual(rows(f)["Size"], "3 questions · \(ActivityText.size(2048))")
        XCTAssertEqual(rows(f)["Started"], "Yesterday 8:00 AM")
        XCTAssertEqual(rows(f)["Last message"], "Oct 4")
        XCTAssertEqual(rows(f)["Why"], "Closed with Keep history off")
        XCTAssertEqual(facts("chat.expired", [:]).heading, "WHAT WAS THERE")
        XCTAssertEqual(rows(facts("chat.expired", ["reason": .string("retention")]))["Why"], "Older than Ask history keeps chats")
        // An unknown reason: no Why row, and the key isn't repeated raw.
        XCTAssertEqual(facts("chat.expired", ["reason": .string("disk-full")], name: nil).rows.map(\.label), ["Type"])
        XCTAssertEqual(rows(facts("chat.created", ["turnCount": .number(1)]))["Size"], "1 question")
        XCTAssertEqual(facts("chat.created", [:]).heading, "DETAILS")
        let restored = facts("chat.restored", ["deletedAt": .string("2026-10-06T10:00:00.000Z"), "trashId": .string("t1")])
        XCTAssertEqual(restored.rows.map(\.label), ["What", "Deleted", "Type"])
        XCTAssertEqual(rows(restored)["Deleted"], "Today 10:00 AM")
        // Deleted belongs to a restore; a deletion lists the dates it has.
        XCTAssertEqual(facts("chat.deleted", ["trashId": .string("t1")], name: nil).rows.map(\.label), ["Trash id", "Type"])
    }

    // MARK: Facts: batches and queue

    func testAppliedBatchFacts() {
        let f = facts("batch.applied", ["changedPaths": .array(["wiki/a.md", "wiki/b.md", "wiki/c.md"].map(JSONValue.string)), "operationID": .string("op-7")])
        XCTAssertEqual(f.heading, "PAGES")
        XCTAssertEqual(f.rows.map(\.label), ["Changed", "Operation", "Type"])
        XCTAssertEqual(rows(f)["Changed"], "wiki/a.md, wiki/b.md, +1 more")
        XCTAssertEqual(rows(f)["Operation"], "op-7")
        let ready = facts("batch.ready", [:])
        XCTAssertEqual(ready.heading, "PAGES")
        XCTAssertEqual(rows(ready)["Changed"], "Nothing")
        // Another batch verb: details as they are.
        let other = facts("batch.started", ["changedPaths": .array([.string("wiki/a.md")])])
        XCTAssertEqual(other.heading, "DETAILS")
        XCTAssertEqual(other.rows.map(\.label), ["Changed paths", "Type"])
    }

    func testRecoveryFacts() {
        let f = facts("batch.recovery", ["kind": .string("denial"), "fix": .string("answer_denial"), "by": .string("agent"),
                                         "model": .string("claude-opus-5-5"), "attempts": .number(2), "costUSD": .number(0.0412),
                                         "summary": .string("Claude tried to run cat")])
        XCTAssertEqual(f.heading, "RECOVERY")
        XCTAssertEqual(f.rows.map(\.label), ["Problem", "Fix", "By", "Tried", "Cost", "What's wrong", "Type"])
        XCTAssertEqual(rows(f)["Problem"], "A blocked command")
        XCTAssertEqual(rows(f)["Fix"], "Told Claude to read the files instead")
        XCTAssertEqual(rows(f)["By"], "Opus")
        XCTAssertEqual(rows(f)["Tried"], "2 times")
        XCTAssertEqual(rows(f)["Cost"], "$0.04")
        XCTAssertEqual(rows(f)["What's wrong"], "Claude tried to run cat")
        let problems = ["stale-again": "The plan went stale again", "lock": "The vault was locked", "plan-error": "The plan couldn't be checked",
                        "runner-failed": "The AI run failed", "brand-new": "brand-new"]
        for (kind, words) in problems { XCTAssertEqual(rows(facts("batch.recovery", ["kind": .string(kind)]))["Problem"], words, kind) }
        XCTAssertEqual(rows(facts("batch.recovery", ["by": .string("agent")]))["By"], "Recovery model")
        XCTAssertEqual(rows(facts("batch.recovery", ["by": .string("rule"), "attempts": .number(1)]))["By"], "Distill (a rule)")
        XCTAssertEqual(rows(facts("batch.recovery", ["attempts": .number(1)]))["Tried"], "once")
        // Someone else (or nobody): no By row, and the raw keys aren't listed either.
        XCTAssertEqual(facts("batch.recovery", ["by": .string("user"), "model": .string("x")]).rows.map(\.label), ["Type"])
    }

    func testRefreshFacts() {
        let f = facts("batch.refresh", ["stalePaths": .array(["a.md", "b.md", "c.md", "d.md"].map(JSONValue.string)), "approved": .bool(true)])
        XCTAssertEqual(f.rows.map(\.label), ["Changed first", "You had approved it", "Type"])
        XCTAssertEqual(rows(f)["Changed first"], "a.md, b.md, c.md, +1 more")
        XCTAssertEqual(rows(f)["You had approved it"], "Yes: it asks once more")
        let plain = facts("batch.refresh", ["approved": .bool(false)])
        XCTAssertEqual(plain.rows.map(\.label), ["You had approved it", "Type"])
        XCTAssertEqual(rows(plain)["You had approved it"], "No")
    }

    func testQueueFacts() {
        let f = facts("queue.removed", ["size": .number(4096), "fileCount": .number(1), "path": .string("/q/a.md"), "itemKind": .string("file")])
        XCTAssertEqual(f.heading, "WHAT WAS THERE")
        XCTAssertEqual(f.rows.map(\.label), ["Size", "Files", "Type"])
        XCTAssertEqual(rows(f)["Size"], ActivityText.size(4096))
        XCTAssertEqual(rows(f)["Files"], "1 file")
        let added = facts("queue.added", ["size": .number(0), "fileCount": .number(3)])
        XCTAssertEqual(added.heading, "DETAILS")
        XCTAssertEqual(added.rows.map(\.label), ["Files", "Type"], "an empty size isn't shown")
        XCTAssertEqual(rows(added)["Files"], "3 files")
    }

    func testButtonFactsForAnOwnType() {
        let f = facts("action.button_run", ["buttonId": .string("post"), "actionType": .string("webhook")])
        XCTAssertEqual(rows(f)["Action type"], "webhook")
        XCTAssertEqual(["todo", "slack", "jira", "confluence", "x"].map(ActivityText.actionTypeName),
                       ["To do", "Slack message", "Jira ticket", "Confluence page", "x"])
        // Another action verb: details as they are.
        XCTAssertEqual(facts("action.created", ["buttonId": .string("post")]).rows.map(\.label), ["Button id", "Type"])
    }

    // MARK: Facts: settings and other keys

    func testSettingsFootnoteAndRawChanges() {
        let f = facts("settings.changed", ["changes": .array([.string("vaults: changed"), .string("askPreferences.keepHistory: — → true")])])
        XCTAssertEqual(f.heading, "CHANGES")
        XCTAssertEqual(f.rows, [ActivityText.Fact("Vaults", "Changed"), ActivityText.Fact("Keep history", "— → ", emphasis: "On"),
                                ActivityText.Fact("Type", "settings.changed", code: true)])
        XCTAssertEqual(f.footnote, "Only what changed is listed. Keys and tokens are never shown, only that they changed.")
        XCTAssertNil(facts("chat.deleted", [:]).footnote)
    }

    func testSettingsFactShapes() {
        XCTAssertEqual(t.settingsFact("no colon here"), ActivityText.Fact("Setting", "no colon here"))
        XCTAssertEqual(t.settingsFact("theme: dark"), ActivityText.Fact("Theme", "dark"))
        XCTAssertEqual(t.settingsFact("a.b.defaultModel: x → y"), ActivityText.Fact("Default model", "x → ", emphasis: "y"))
        XCTAssertEqual(t.settingsFact("flag: false → true"), ActivityText.Fact("Flag", "Off → ", emphasis: "On"))
        XCTAssertEqual(t.readableSettingsFact("Nothing to split"), ActivityText.Fact("Setting", "Nothing to split"))
        XCTAssertEqual(t.readableSettingsFact("Theme: Dark"), ActivityText.Fact("Theme", "Dark"))
        XCTAssertEqual(t.readableSettingsFact("Runners: changed"), ActivityText.Fact("Runners", "Changed"))
        // The arrow's right side may hold ": " without moving the label.
        XCTAssertEqual(t.readableSettingsFact("Model: a → b: c"), ActivityText.Fact("Model", "a → ", emphasis: "b: c"))
    }

    func testOtherKeysInPlainWords() {
        XCTAssertEqual(t.plain(.string("")), nil)
        XCTAssertEqual(t.plain(.string("x")), "x")
        XCTAssertEqual(t.plain(.number(3)), "3")
        XCTAssertEqual(t.plain(.number(-2)), "-2")
        XCTAssertEqual(t.plain(.number(2.5)), "2.5")
        XCTAssertEqual(t.plain(.number(1e16)), "1e+16")
        XCTAssertEqual(t.plain(.bool(false)), "No")
        XCTAssertEqual(t.plain(.bool(true)), "Yes")
        XCTAssertEqual(t.plain(.array([.string("a"), .null, .number(1), .string("")])), "a, 1")
        XCTAssertNil(t.plain(.array([.null])))
        XCTAssertNil(t.plain(.object(["a": .string("b")])))
        XCTAssertNil(t.plain(.null))
        // Keys are listed alphabetically after the known ones, empty values skipped.
        let f = facts("widget.zapped", ["zeta": .string("z"), "alpha": .string("a"), "empty": .string(""), "nested": .object([:])])
        XCTAssertEqual(f.rows.map(\.label), ["Alpha", "Zeta", "Type"])
    }

    func testLabelsFromKeys() {
        XCTAssertEqual(ActivityText.label("keepHistory"), "Keep history")
        XCTAssertEqual(ActivityText.label("operationID"), "Operation id")
        XCTAssertEqual(ActivityText.label("snake_case_key"), "Snake case key")
        XCTAssertEqual(ActivityText.label("kebab-case"), "Kebab case")
        XCTAssertEqual(ActivityText.label("two  spaces"), "Two spaces")
        XCTAssertEqual(ActivityText.label("_leading"), "Leading")
        XCTAssertEqual(ActivityText.label("trailing_"), "Trailing")
        XCTAssertEqual(ActivityText.label(""), "")
        XCTAssertEqual(ActivityText.word("true"), "On")
        XCTAssertEqual(ActivityText.word("false"), "Off")
        XCTAssertEqual(ActivityText.word("—"), "—")
    }

    func testFactIDs() {
        XCTAssertEqual(ActivityText.Fact("A", "b").id, "A\u{1F}b")
        XCTAssertFalse(ActivityText.Fact("A", "b").code)
    }

    func testDatesUseTheTextsOwnCalendarAndLocale() {
        // UTC+14: the date can be a day ahead of the Mac's own zone, and French words: never the Mac's settings.
        var kiritimati = Calendar(identifier: .gregorian)
        kiritimati.timeZone = TimeZone(identifier: "Pacific/Kiritimati")!
        let fr = ActivityText(calendar: kiritimati, locale: Locale(identifier: "fr_FR"))
        let date = Date(timeIntervalSince1970: 1_791_028_800) // 2026-10-03 12:00 UTC = Oct 4 02:00 in Kiritimati
        let later = date.addingTimeInterval(5 * 86_400)
        XCTAssertEqual(fr.day(date, now: later), "oct. 4")
        XCTAssertEqual(fr.date(date, now: later), "oct. 4")
        XCTAssertEqual(fr.day(date, now: later.addingTimeInterval(400 * 86_400)), "oct. 4, 2026")
    }

    func testTheFirstOfTwoRestoresAtTheSameTimeStays() {
        let a = entry("chat.restored", at: now, objectID: "c-1", details: ["trashId": .string("t1")])
        let b = entry("chat.restored", at: now, objectID: "c-2", details: ["trashId": .string("t1")])
        XCTAssertEqual(ActivityRestore.index([a, b])["t1"]?.objectID, "c-1")
    }

    func testVeryLargeNumbersAreNotRoundedToInts() {
        XCTAssertEqual(t.plain(.number(1e15)), "1000000000000000.0", "from 1e15 on, the number as Swift writes it")
        XCTAssertEqual(t.plain(.number(999_999_999_999_999)), "999999999999999")
    }
}
