import XCTest
@testable import DistillKit

final class ActionsLogicTests: XCTestCase {
    var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "America/Los_Angeles")!
        return c
    }()
    // Fri Oct 2 2026, 3:44 PM in Los Angeles.
    lazy var now = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 15, minute: 44))!
    let types = [ActionTypeInfo(id: "todo", label: "To-do", pluralLabel: "To do"),
                 ActionTypeInfo(id: "slack", label: "Slack message", pluralLabel: "Slack messages"),
                 ActionTypeInfo(id: "jira", label: "Jira ticket", pluralLabel: "Jira tickets"),
                 ActionTypeInfo(id: "confluence", label: "Confluence page", pluralLabel: "Confluence pages")]

    func item(_ id: String, _ type: String = "todo", _ status: ActionStatus = .open, due: String? = nil, priority: String? = nil,
              person: String? = nil, labels: [String] = [], note: String? = "Tea club planning", created: Double = 0) -> ActionItem {
        var f: [String: String] = [:]
        if let due { f["due"] = due }
        if let priority { f["priority"] = priority }
        if let person { f["person"] = person }
        return ActionItem(id: id, type: type, status: status, title: "Item \(id)", fields: f,
                          source: note.map { .note(jobID: "j1", notePath: nil, pageTitle: $0, quote: "bring the new tin.") } ?? .manual,
                          labels: labels, createdAt: now.addingTimeInterval(-created))
    }

    func testSidebarCountsMatchTheBoard() {
        // Canvas SidebarStates: To do 6, Slack 1, Jira 1, Confluence 1 → Actions 9.
        var items = (0..<6).map { item("t\($0)") } + [item("p", "todo", .pending)]
        items += [item("s1", "slack", .ready), item("s2", "slack", .open)]
        items += [item("j1", "jira", .ready), item("j2", "jira", .open), item("j3", "jira", .created)]
        items += [item("c1", "confluence", .ready), item("x", "todo", .done)]
        let ids = types.map(\.id)
        XCTAssertEqual(ActionCounts.byType(items, types: ids), ["todo": 6, "slack": 1, "jira": 1, "confluence": 1])
        XCTAssertEqual(ActionCounts.total(items, types: ids), 9)
        // A type that is off has no sub-item and adds nothing.
        XCTAssertEqual(ActionCounts.total(items, types: ["todo", "jira"]), 7)
    }

    func testOneRowIsSelectedWhenAToConfirmItemIsInThePane() {
        // A To-confirm item in the pane: no to-do row is drawn selected as well (the stand-in first row).
        XCTAssertFalse(ActionList.todoHighlighted("t1", selected: "p1", paneShowsSelection: true, first: "t1"))
        // Nothing selected: the first row stands in.
        XCTAssertTrue(ActionList.todoHighlighted("t1", selected: nil, paneShowsSelection: false, first: "t1"))
        XCTAssertFalse(ActionList.todoHighlighted("t2", selected: nil, paneShowsSelection: false, first: "t1"))
        // A to-do selected: only it.
        XCTAssertTrue(ActionList.todoHighlighted("t2", selected: "t2", paneShowsSelection: true, first: "t1"))
        XCTAssertFalse(ActionList.todoHighlighted("t1", selected: "t2", paneShowsSelection: true, first: "t1"))
    }

    func testPhrases() {
        XCTAssertEqual(ActionCounts.phrase(["jira": 1, "todo": 3, "slack": 1], types: types), "3 to-dos, 1 Slack message, 1 Jira ticket")
        XCTAssertEqual(ActionCounts.phrase(["email": 2], types: types), "2 emails")
        XCTAssertEqual(ActionCounts.addedPhrase(todos: 1, drafts: 3), "Added 1 to-do and created 3 drafts")
        XCTAssertEqual(ActionCounts.addedPhrase(todos: 0, drafts: 1), "Created 1 draft")
        XCTAssertEqual(ActionCounts.jobLine(JobActionsSummary(status: "done", found: 5, pending: 5)), "Found 5 actions to confirm")
        XCTAssertNil(ActionCounts.jobLine(JobActionsSummary(status: "done")))
        XCTAssertNil(ActionCounts.jobLine(JobActionsSummary(status: "finding")))
    }

    func testDueBucketsAndLabels() {
        let en = Locale(identifier: "en_US")
        XCTAssertEqual(ActionDue.bucket("2026-09-30", now: now, calendar: cal), .overdue)
        XCTAssertEqual(ActionDue.bucket("2026-10-02", now: now, calendar: cal), .today)
        XCTAssertEqual(ActionDue.bucket("2026-10-03", now: now, calendar: cal), .thisWeek)
        XCTAssertEqual(ActionDue.bucket("2026-11-03", now: now, calendar: cal), .later)
        XCTAssertEqual(ActionDue.bucket(nil, now: now, calendar: cal), .none)
        XCTAssertEqual(ActionDue.bucket("soon", now: now, calendar: cal), .none)
        XCTAssertEqual(ActionDue.short("2026-10-02", now: now, calendar: cal, locale: en), "Today")
        XCTAssertEqual(ActionDue.short("2026-10-03", now: now, calendar: cal, locale: en), "Sat")
        XCTAssertEqual(ActionDue.short("2026-09-30", now: now, calendar: cal, locale: en), "Sep 30")
        XCTAssertEqual(ActionDue.short("2026-10-03T00:00:00Z", now: now, calendar: cal, locale: en)?.replacingOccurrences(of: "\u{202F}", with: " "), "5:00 PM")
        XCTAssertEqual(ActionDue.long("2026-09-30", now: now, calendar: cal, locale: en), "Wed, Sep 30 · 2 days late")
        XCTAssertEqual(ActionDue.format(now, calendar: cal), "2026-10-02")
    }

    func testGroupingAndSorting() {
        let items = [item("a", due: "2026-10-03"), item("b", due: "2026-09-30", priority: "High"),
                     item("c", due: "2026-10-02", priority: "Medium"), item("d"), item("e", due: "2026-10-02", priority: "High", note: nil)]
        let groups = ActionList.grouped(items, by: .due, sort: .due, now: now, calendar: cal)
        XCTAssertEqual(groups.map(\.title), ["OVERDUE", "TODAY", "THIS WEEK", "NO DUE DATE"])
        XCTAssertEqual(groups[1].items.map(\.id), ["e", "c"])
        let byNote = ActionList.grouped(items, by: .note, sort: .title, now: now, calendar: cal)
        XCTAssertEqual(byNote.map(\.title), ["ADDED BY YOU", "TEA CLUB PLANNING"])
        XCTAssertEqual(ActionList.grouped(items, by: .priority, sort: .due, now: now).map(\.title), ["HIGH", "MEDIUM", "NONE"])
        XCTAssertEqual(ActionList.grouped([], by: .none, sort: .due).count, 0)
    }

    func testFiltersAndSearch() {
        let items = [item("a", person: "Mei, You", labels: ["tea"]), item("b", priority: "High", labels: ["project-x"], note: nil),
                     item("c", "todo", .done, labels: ["tea"])]
        var f = ActionFilter()
        XCTAssertFalse(f.isNarrowed)
        XCTAssertEqual(items.filter { f.matches($0, now: now) }.map(\.id), ["a", "b"])
        f.labels = ["tea"]
        XCTAssertEqual(items.filter { f.matches($0, now: now) }.map(\.id), ["a"])
        f.status = .all
        XCTAssertEqual(items.filter { f.matches($0, now: now) }.map(\.id), ["a", "c"])
        f = ActionFilter(); f.people = ["Mei"]
        XCTAssertEqual(items.filter { f.matches($0, now: now) }.map(\.id), ["a"])
        f = ActionFilter(); f.addedBy = .you
        XCTAssertEqual(items.filter { f.matches($0, now: now) }.map(\.id), ["b"])
        f = ActionFilter(); f.priorities = ["None"]
        XCTAssertEqual(items.filter { f.matches($0, now: now) }.map(\.id), ["a"])

        XCTAssertEqual(ActionSearch.match(items[0], "item"), .title)
        XCTAssertEqual(ActionSearch.match(items[0], "tin"), .context("bring the new tin."))
        XCTAssertNil(ActionSearch.match(items[0], "kettle"))
        XCTAssertEqual(ActionSearch.excerpt(String(repeating: "x", count: 50) + " tin", "tin", radius: 4), "…xxx tin")
    }

    func testHistory() {
        var done = item("d", "todo", .done); done.events = [ActionEvent(at: now.addingTimeInterval(-60), event: "done")]
        var sent = item("s", "todo", .sent); sent.events = [ActionEvent(at: now.addingTimeInterval(-600), event: "sent-to:jira")]
        var msg = item("m", "slack", .sent); msg.updatedAt = now.addingTimeInterval(-86400)
        var ticket = item("j", "jira", .done)
        ticket.external = ActionExternal(key: "PX-482", status: "Done", checkedAt: now.addingTimeInterval(-300))
        let removed = item("r", "slack", .removed)
        XCTAssertEqual(ActionHistory.what(done), .completed)
        XCTAssertEqual(ActionHistory.what(sent), .sent)
        XCTAssertEqual(ActionHistory.what(msg), .markedSent)
        XCTAssertEqual(ActionHistory.what(ticket), .done)
        XCTAssertEqual(ActionHistory.what(removed), .removed)
        XCTAssertNil(ActionHistory.what(item("o")))
        XCTAssertFalse(ActionHistory.canRestore(sent))
        XCTAssertTrue(ActionHistory.canRestore(removed))
        XCTAssertTrue(ActionHistory.detail(sent, types: types, now: now).hasPrefix("to Jira tickets today at "))
        XCTAssertTrue(ActionHistory.detail(ticket, types: types, now: now).hasPrefix("in Jira · checked today at "))
        XCTAssertEqual(ActionHistory.groups([msg, done, sent], now: now, calendar: cal).map(\.title), ["TODAY", "YESTERDAY"])
        XCTAssertEqual(ActionHistory.timeline(sent, types: types).map(\.title), ["Sent to Jira tickets"])
        XCTAssertEqual(HistoryDay.title(cal.date(from: DateComponents(year: 2025, month: 9, day: 30, hour: 9))!, now: now, calendar: cal), "SEP 30, 2025")
    }
}
