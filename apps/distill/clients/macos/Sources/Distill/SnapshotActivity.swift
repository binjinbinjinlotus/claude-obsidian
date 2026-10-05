import AppKit
import SwiftUI
import DistillKit

/// History → Activity (canvas row 8, board Activity). Fixtures are core-shaped
/// JSON decoded through DistillKit, so the snapshots read entries the way the
/// app reads `GET /v1/activity`.
@MainActor
enum ActivityFixtures {
    /// Today at 7:20 PM: the board's clock.
    static var now: Date {
        let cal = Calendar.current
        return cal.date(bySettingHour: 19, minute: 20, second: 0, of: Date()) ?? Date()
    }

    static func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        let cal = Calendar.current
        let day = cal.date(byAdding: .day, value: -daysAgo, to: now) ?? now
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    static func iso(_ d: Date) -> JSONValue { .string(CoreDate.format(d)) }

    private static var seq = 0

    static func entry(_ type: String, _ when: Date, _ source: String, kind: String, id: String? = nil, name: String? = nil,
                      _ summary: String, failed: Bool = false, error: String? = nil, details: [String: JSONValue] = [:],
                      recovery: JSONValue? = nil) -> JSONValue {
        seq += 1
        let ms = Int(when.timeIntervalSince1970 * 1000)
        var object: [String: JSONValue] = ["kind": .string(kind)]
        if let id { object["id"] = .string(id) }
        if let name { object["name"] = .string(name) }
        var o: [String: JSONValue] = [
            "id": .string(String(format: "%013d-%04d-a1b2c3", ms, seq)), "at": iso(when), "type": .string(type),
            "source": .string(source), "object": .object(object), "summary": .string(summary),
            "outcome": .string(failed ? "failed" : "ok"), "details": .object(details), "pid": .number(4242),
        ]
        if let error { o["error"] = .string(error) }
        if let recovery { o["recovery"] = recovery }
        return .object(o)
    }

    static let trashMeeting = "trash-1791155040000-0a1b2c3d"
    static let trashChat = "trash-1791154920000-0e4f5a6b"

    static func trash(_ id: String, _ deleted: Date, days: Double = 30) -> JSONValue {
        .object(["kind": .string("trash"), "trashId": .string(id), "expiresAt": iso(deleted.addingTimeInterval(days * 86_400))])
    }

    static func meetingFacts(_ e: AppModel) -> [String: JSONValue] {
        ["kind": .string("script"), "interpreter": .string("python3"), "schedule": .string("0 18 * * 1-5"),
         "vault": .string(StatesSnapshot.vault(e)), "scriptBytes": .number(2140), "scriptLines": .number(61),
         "lastRunAt": iso(at(18, 0)), "collected": .number(2)]
    }

    static func deletedMeeting(_ e: AppModel) -> JSONValue {
        entry("collector.deleted", at(19, 4), "app", kind: "collector", id: "col-meeting-notes", name: "Meeting notes",
              "Deleted the script collector “Meeting notes”", details: meetingFacts(e), recovery: trash(trashMeeting, at(19, 4)))
    }

    static func failedRun() -> JSONValue {
        entry("collector.run", at(16, 30), "scheduler", kind: "collector", id: "col-slack-saved", name: "Slack saved items",
              "Slack saved items failed: exit 1", failed: true, error: "exit 1",
              details: ["runId": .string("run-1630"), "result": .string("failed"), "trigger": .string("schedule"),
                        "durationMs": .number(2400), "filesAdded": .array([]), "exitCode": .number(1)])
    }

    static let senchaDeleted = entry("chat.deleted", at(19, 1), "app", kind: "chat", id: "c-sencha", name: "Sencha water temperature",
                                     "Deleted the chat “Sencha water temperature”",
                                     details: ["turnCount": .number(3), "sizeBytes": .number(14_000), "createdAt": iso(at(18, 48)),
                                               "lastMessageAt": iso(at(18, 59)), "reason": .string("keep-history-off")],
                                     recovery: .object(["kind": .string("none"), "reason": .string("Keep Ask history is off, so closed chats are not kept.")]))

    static let queueRemoved = entry("queue.removed", at(21, 20, daysAgo: 1), "app", kind: "queue", id: "/Research/queue/export.zip", name: "export.zip",
                                    "Removed “export.zip” from the queue",
                                    details: ["path": .string("/Research/queue/export.zip"), "itemKind": .string("file"), "size": .number(4_200_000)],
                                    recovery: .object(["kind": .string("macosTrash"), "path": .string("~/.Trash/export.zip")]))

    static let settingsChanged = entry("settings.changed", at(14, 15), "app", kind: "settings", name: "Settings",
                                       "Changed settings: Ask history (Keep history off)",
                                       details: ["changes": .array([.string("askPreferences.keepHistory: true → false")])])

    static let kettleExpired = entry("chat.expired", at(3, 0, daysAgo: 1), "scheduler", kind: "chat", id: "c-kettle", name: "Kettle comparison",
                                     "Removed the chat “Kettle comparison”: older than 10 days",
                                     details: ["turnCount": .number(5), "lastMessageAt": iso(at(9, 30, daysAgo: 11)), "reason": .string("retention")],
                                     recovery: .object(["kind": .string("none"), "reason": .string("Ask history keeps unpinned chats for the days set in Settings → Ask; pin a chat to keep it.")]))

    static let batchApplied = entry("batch.applied", at(18, 41), "app", kind: "batch", id: "job-batch-4", name: "Batch · 4 files",
                                    "Batch · 4 files applied 6 page changes",
                                    details: ["changedPaths": .array(["wiki/sources/gyokuro.md", "wiki/tea/sencha.md", "wiki/tea/gyokuro.md",
                                                                      "wiki/index.md", "wiki/log.md", "wiki/hot.md"].map(JSONValue.string)),
                                              "operationID": .string("op-20261004-1841-7c2e")])

    static func all(_ e: AppModel) -> [JSONValue] {
        [
            deletedMeeting(e),
            entry("chat.deleted", at(19, 2), "app", kind: "chat", id: "c-q3", name: "Q3 tea club plan", "Deleted the chat “Q3 tea club plan”",
                  details: ["turnCount": .number(7), "sizeBytes": .number(38_000), "createdAt": iso(at(11, 5, daysAgo: 3)),
                            "lastMessageAt": iso(at(16, 40)), "reason": .string("deleted")],
                  recovery: trash(trashChat, at(19, 2))),
            senchaDeleted,
            entry("collector.run", at(19, 0), "scheduler", kind: "collector", id: "col-pocket", name: "Pocket export",
                  "Pocket export added 4 files to the queue",
                  details: ["runId": .string("run-1900"), "result": .string("success"), "trigger": .string("schedule"), "durationMs": .number(1800),
                            "filesAdded": .array(["pocket-1.html", "pocket-2.html", "pocket-3.html", "pocket-4.html"].map(JSONValue.string))]),
            batchApplied,
            entry("batch.approved", at(18, 40), "app", kind: "batch", id: "job-batch-4", name: "Batch · 4 files", "Approved Batch · 4 files"),
            entry("note.added", at(17, 12), "agent", kind: "note", id: "req-gyokuro", name: "Gyokuro tasting", "Added the note “Gyokuro tasting” to the queue",
                  details: ["notePath": .string("queue/Gyokuro tasting.md"), "files": .number(1), "images": .number(0), "labels": .array([.string("tea")])]),
            failedRun(),
            settingsChanged,
            queueRemoved,
            entry("action.confirmed", at(18, 5, daysAgo: 1), "app", kind: "action", id: "act-tasting", name: "Book the tea tasting",
                  "Confirmed “Book the tea tasting”", details: ["actionType": .string("todo"), "status": .string("open")]),
            entry("collector.consented", at(10, 12, daysAgo: 1), "app", kind: "collector", id: "col-meeting-notes", name: "Meeting notes",
                  "Allowed the script of “Meeting notes” and turned it on", details: ["sha256": .string("3f9a1c0be27d")]),
            kettleExpired,
        ]
    }

    static func collectors(_ e: AppModel) -> [JSONValue] {
        [
            deletedMeeting(e),
            entry("collector.run", at(19, 0), "scheduler", kind: "collector", id: "col-pocket", name: "Pocket export",
                  "Pocket export added 4 files to the queue",
                  details: ["result": .string("success"), "trigger": .string("schedule"), "durationMs": .number(1800),
                            "filesAdded": .array(["pocket-1.html", "pocket-2.html", "pocket-3.html", "pocket-4.html"].map(JSONValue.string))]),
            entry("collector.run", at(18, 0), "scheduler", kind: "collector", id: "col-meeting-notes", name: "Meeting notes",
                  "Meeting notes added 2 files to the queue",
                  details: ["result": .string("success"), "trigger": .string("schedule"), "durationMs": .number(3100),
                            "filesAdded": .array(["standup-2026-10-04.md", "design-review.md"].map(JSONValue.string))]),
            failedRun(),
            entry("collector.disabled", at(20, 41, daysAgo: 1), "app", kind: "collector", id: "col-scans", name: "Scans", "Turned off “Scans”"),
            entry("collector.consented", at(10, 12, daysAgo: 1), "app", kind: "collector", id: "col-meeting-notes", name: "Meeting notes",
                  "Allowed the script of “Meeting notes” and turned it on", details: ["sha256": .string("3f9a1c0be27d")]),
            entry("collector.created", at(10, 9, daysAgo: 1), "app", kind: "collector", id: "col-meeting-notes", name: "Meeting notes",
                  "Added the script collector “Meeting notes” (off until you allow it)", details: meetingFacts(e)),
        ]
    }

    static func restored(_ e: AppModel) -> [JSONValue] {
        [entry("collector.restored", at(19, 12), "app", kind: "collector", id: "col-meeting-notes", name: "Meeting notes",
               "Restored the collector “Meeting notes” from Distill’s trash",
               details: ["trashId": .string(trashMeeting), "deletedAt": iso(at(19, 4))])] + all(e)
    }

    static func decode(_ list: [JSONValue]) -> [ActivityEntry] {
        let page: ActivityPage? = DTO.make(.object(["entries": .array(list), "nextCursor": .null]))
        return page?.entries ?? []
    }

    static func trashItems(_ e: AppModel, restored: Bool = false) -> [String: TrashItem] {
        var items: [JSONValue] = [
            .object(["id": .string(trashChat), "kind": .string("chat"), "objectID": .string("c-q3"), "name": .string("Q3 tea club plan"),
                     "deletedAt": iso(at(19, 2)), "expiresAt": iso(at(19, 2).addingTimeInterval(30 * 86_400)), "source": .string("app"),
                     "sizeBytes": .number(38_000), "details": .object(["turnCount": .number(7)])]),
        ]
        if !restored {
            items.append(.object(["id": .string(trashMeeting), "kind": .string("collector"), "objectID": .string("col-meeting-notes"),
                                  "name": .string("Meeting notes"), "deletedAt": iso(at(19, 4)),
                                  "expiresAt": iso(at(19, 4).addingTimeInterval(30 * 86_400)), "source": .string("app"),
                                  "sizeBytes": .number(4100), "details": .object(meetingFacts(e))]))
        }
        let list: [TrashItem] = DTO.make(.array(items)) ?? []
        return Dictionary(uniqueKeysWithValues: list.map { ($0.id, $0) })
    }

    /// A loaded store on the board's clock.
    @discardableResult
    static func load(_ e: AppModel, _ list: [JSONValue], restored: Bool = false, selected: Int? = 0) -> ActivityStore {
        let s = e.activity
        s.fixtureNow = now
        let entries = decode(list)
        s.entries = entries
        s.nextCursor = nil
        s.trash = trashItems(e, restored: restored)
        s.restores = ActivityRestore.index(entries)
        s.selected = selected.flatMap { $0 < entries.count ? entries[$0].id : nil }
        s.phase = .loaded
        return s
    }
}

extension StatesSnapshot {
    static func activityStates() {
        let f = Flow.activity
        let narrow = CGSize(width: 890, height: 760)
        typealias F = ActivityFixtures
        func shot(_ file: String, _ state: String, _ desc: String, _ e: AppModel, size: CGSize = CGSize(width: 1200, height: 820),
                  ui: ActivityScreenUI = ActivityScreenUI()) {
            main(file, f, "History · Activity", state, desc, e, section: .history, historyPart: .activity, size: size) {
                ActivityScreenContent(store: e.activity, ui: ui)
            }
        }

        var e = engine()
        F.load(e, F.all(e))
        shot("activity", "A · A delete kept in Distill’s trash, with Restore",
             "History → Activity: day-grouped lines; the selected delete shows what was there and Restore.", e)

        e = engine()
        var s = F.load(e, F.all(e))
        s.filter.what = .collectors
        s.panel = ""
        shot("activity-filters", "B · Filter: What, From, When, Only failures",
             "Three short choices and one switch; Collectors picked.", e, ui: ActivityScreenUI(inlinePanel: true))

        e = engine()
        s = F.load(e, F.collectors(e), selected: 3)
        s.filter.what = .collectors
        s.selected = s.entries.first { $0.failed }?.id
        shot("activity-filtered", "C · Filtered to Collectors; a failed run opened",
             "The failed run: exit code, time, nothing added, Open run log.", e)

        e = engine()
        s = F.load(e, F.restored(e), restored: true, selected: 1)
        shot("activity-restored", "D · After Restore",
             "Back in Collectors, off until you allow its script; a Restored line at the top.", e)

        e = engine()
        F.load(e, [])
        shot("activity-empty", "E · Nothing yet", "No entries and no filters.", e)

        e = engine()
        s = F.load(e, [])
        s.filter = ActivityFilter(text: "kettle", what: .chats, from: .cli)
        shot("activity-no-matches", "F · No matches for the filters", "Says what the filters were, and Clear filters.", e)

        e = engine()
        s = F.load(e, F.all(e), selected: nil)
        s.filter = ActivityFilter(what: .collectors, from: .app, when: .week)
        shot("activity-narrow", "G · Narrow window (890 pt)", "The list takes the width; chips collapse into +N.", e, size: narrow,
             ui: ActivityScreenUI(visibleChips: 1))

        e = engine()
        s = F.load(e, F.all(e), selected: 2)
        s.pushed = true
        shot("activity-narrow-detail", "H · Narrow: an entry opens in place",
             "‹ Activity goes back; a delete with no copy says why.", e, size: narrow)

        // The detail for other kinds of entries, as cards.
        func card(_ file: String, _ state: String, _ desc: String, _ entry: JSONValue) {
            let e = engine()
            let s = F.load(e, [entry])
            if file == "activity-card-batch" {
                e.jobs = [job(e, "job-batch-4", .completed, files: ["inbox/a.md"], minutesAgo: 40)]
            }
            natural(file, f, "History · Activity", state, desc, e) {
                ActivityDetail(store: s, entry: s.entries[0])
                    .frame(width: 336)
                    .padding(.horizontal, 22).padding(.vertical, 20)
                    .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
            }
        }
        card("activity-card-queue", "A queue file removed", "Queue files go to the macOS Trash; the entry says where.", F.queueRemoved)
        card("activity-card-settings", "Settings changed", "Each change as old → new; secrets only as “changed”.", F.settingsChanged)
        card("activity-card-expired", "Removed by Ask history", "Retention is Distill acting on your setting: Automatic, not kept in the trash.", F.kettleExpired)
        card("activity-card-batch", "A batch applied", "The pages it changed and the vault operation.", F.batchApplied)
    }
}
