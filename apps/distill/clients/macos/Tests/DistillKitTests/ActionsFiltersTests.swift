import XCTest
@testable import DistillKit

/// The v57 Actions toolbar and Filter panel rules (ActionsFilters.swift).
final class ActionsFiltersTests: XCTestCase {
    let now = Date(timeIntervalSince1970: 1_790_000_000)
    let types = [ActionTypeInfo(id: "todo", label: "To-do", pluralLabel: "To do"),
                 ActionTypeInfo(id: "slack", label: "Slack message", pluralLabel: "Slack messages"),
                 ActionTypeInfo(id: "jira", label: "Jira ticket", pluralLabel: "Jira tickets")]

    func item(_ id: String, _ type: String, _ status: ActionStatus, body: String? = nil, fields: [String: String] = [:],
              labels: [String] = [], note: String? = "Tea club planning", events: [ActionEvent] = []) -> ActionItem {
        ActionItem(id: id, type: type, status: status, title: "Item \(id)", body: body, fields: fields,
                   source: note.map { .note(jobID: "j", notePath: nil, pageTitle: $0, quote: nil) } ?? .manual,
                   labels: labels, createdAt: now, events: events)
    }

    // MARK: Toolbar fit

    func testEverythingFitsAtFullWidth() {
        let fit = ToolbarFit.plan(total: 820, search: 190, filter: 96, right: 110, rightCompact: 110, chips: [110, 90], plus: { _ in 40 })
        XCTAssertEqual(fit, ToolbarFit(searchWidth: 190, compactRight: false, visibleChips: 2))
    }

    func testNarrowWindowCollapsesChipsIntoPlusN() {
        // The canvas "Narrow (890 pt window)": five chips, 566 pt, one shown and +4.
        let chips: [Double] = [118, 140, 125, 108, 70]
        let fit = ToolbarFit.plan(total: 566, search: 190, filter: 96, right: 110, rightCompact: 110, chips: chips, plus: { _ in 40 })
        XCTAssertEqual(fit.searchWidth, 160)
        XCTAssertEqual(fit.visibleChips, 1)
        XCTAssertFalse(fit.compactRight)
        // Never wider than the bar.
        let used = fit.searchWidth + 6 + 96 + chips.prefix(fit.visibleChips).reduce(0) { $0 + $1 + 6 } + 40 + 6 + 8 + 6 + 110
        XCTAssertLessThanOrEqual(used, 566)
    }

    func testDisconnectedRightSlotDropsItsTextLast() {
        // Jira at the minimum window: "Atlassian · not connected" + Connect now is about 290 pt.
        let fit = ToolbarFit.plan(total: 600, search: 180, filter: 90, right: 290, rightCompact: 110, chips: [80], plus: { _ in 40 })
        XCTAssertEqual(fit.searchWidth, 140)
        // 600 - (140+6+90+6+8+6+290) = 54: no room for the chip, but "+1" fits; the text stays.
        XCTAssertFalse(fit.compactRight)
        XCTAssertEqual(fit.visibleChips, 0)
        let tighter = ToolbarFit.plan(total: 480, search: 180, filter: 90, right: 290, rightCompact: 110, chips: [], plus: { _ in 40 })
        XCTAssertTrue(tighter.compactRight)
    }

    // MARK: Facets

    func testSlackStatusesAndMatching() {
        let notWritten = item("a", "slack", .open)
        let ready = item("b", "slack", .ready, body: "Hi", fields: ["to": "Mei Tanaka"], labels: ["tea-club"])
        let copied = item("c", "slack", .ready, body: "Hi", events: [ActionEvent(at: now, event: "copied")])
        XCTAssertEqual(ActionFacets.values("slack", "status", notWritten), ["Not written"])
        XCTAssertEqual(ActionFacets.values("slack", "status", ready), ["Ready to paste"])
        XCTAssertEqual(ActionFacets.values("slack", "status", copied), ["Copied"])
        var f = FacetFilter()
        f.toggle("status", "Ready to paste")
        f.toggle("label", "#tea-club")
        XCTAssertEqual(f.count, 2)
        XCTAssertTrue(ActionFacets.matches("slack", f, ready))
        XCTAssertFalse(ActionFacets.matches("slack", f, copied))
        XCTAssertEqual(ActionFacets.chips("slack", f).map(\.text), ["Ready to paste", "#tea-club"])
        f.remove("label", "#tea-club")
        XCTAssertEqual(f.count, 1)
        f.clear()
        XCTAssertFalse(f.isNarrowed)
    }

    func testSectionsPerKindAsDesigned() {
        XCTAssertEqual(ActionFacets.layout("todo").map(\.title), ["STATUS", "DUE", "PERSON", "LABEL", "SOURCE NOTE", "PRIORITY", "MORE"])
        XCTAssertEqual(ActionFacets.layout("slack").map(\.title), ["STATUS", "RECIPIENT", "SOURCE NOTE", "LABEL"])
        XCTAssertEqual(ActionFacets.layout("jira").map(\.title), ["STATUS", "PROJECT", "TYPE", "PRIORITY", "ASSIGNEE", "SOURCE NOTE"])
        XCTAssertEqual(ActionFacets.layout("confluence").map(\.title), ["STATUS", "SPACE", "SOURCE NOTE"])
        XCTAssertEqual(ActionFacets.layout("history").map(\.title), ["TYPE", "OUTCOME", "DATE", "SOURCE"])
        // History dates are presets only.
        XCTAssertEqual(ActionFacets.fixed("history", "date"), ["Today", "This week", "Last 30 days"])
        XCTAssertEqual(ActionFacets.fixed("history", "outcome"), ["Completed", "Sent", "Created", "Removed", "Dismissed"])
    }

    func testLongSectionsShowTopFiveThenShowAll() {
        let s = FacetSection(id: "label", title: "LABEL", options: (1...7).map { FacetOption(id: "#l\($0)", count: 8 - $0) })
        XCTAssertEqual(s.visible().rows.count, 5)
        XCTAssertEqual(s.visible().all, 7)
        XCTAssertEqual(s.visible(expanded: true).rows.count, 7)
        let six = FacetSection(id: "x", title: "X", options: (1...6).map { FacetOption(id: "\($0)") })
        XCTAssertEqual(six.visible().rows.count, 6)
        let people = FacetSection(id: "person", title: "PERSON", searchPlaceholder: "Find a person",
                                  options: ["Mei Tanaka", "Tom Kim"].map { FacetOption(id: $0) })
        XCTAssertEqual(people.visible(query: "mei").rows.map(\.id), ["Mei Tanaka"])
    }

    func testTodoChipsSkipDefaultStatus() {
        var f = ActionFilter()
        XCTAssertEqual(f.count, 0)
        f.toggle("due", "Today")
        f.toggle("person", "You (Jin Liu)")
        f.toggle("label", "#project-x")
        XCTAssertEqual(ActionFacets.todoChips(f).map(\.text), ["Due: Today", "Person: You", "#project-x"])
        f.toggle("status", "all")
        XCTAssertEqual(f.count, 4)
        XCTAssertEqual(ActionFacets.todoChips(f).first?.text, "Status: All")
        f.remove(ActionFacets.todoChips(f)[0])
        XCTAssertEqual(f.status, .open)
        f.text = "tin"
        f.clearFilters()
        XCTAssertEqual(f.count, 0)
        XCTAssertEqual(f.text, "tin", "Clear all keeps the search")
    }

    // MARK: History outcomes

    func testOutcomes() {
        let completed = item("a", "slack", .done, events: [ActionEvent(at: now, event: "done", detail: "ready")])
        let auto = item("b", "jira", .done, events: [ActionEvent(at: now, event: "done", detail: "in Jira (Done)")])
        let sentOn = item("c", "todo", .sent, events: [ActionEvent(at: now, event: "sent-to:jira", detail: "x")])
        let marked = item("d", "slack", .sent, events: [ActionEvent(at: now, event: "sent")])
        let dismissed = item("e", "todo", .dismissed, events: [ActionEvent(at: now, event: "dismissed")])
        XCTAssertEqual(ActionHistory.outcome(completed), .completed)
        XCTAssertEqual(ActionHistory.outcome(auto), .created)
        XCTAssertEqual(ActionHistory.outcome(sentOn), .sent)
        XCTAssertEqual(ActionHistory.outcome(dismissed), .dismissed)
        XCTAssertEqual(ActionHistory.outcome(item("r", "todo", .removed)), .removed)
        XCTAssertNil(ActionHistory.outcome(item("o", "todo", .open)))
        // Restore: everything but a to-do sent on to another type.
        XCTAssertTrue(ActionHistory.canRestoreOutcome(completed))
        XCTAssertTrue(ActionHistory.canRestoreOutcome(marked))
        XCTAssertTrue(ActionHistory.canRestoreOutcome(dismissed))
        XCTAssertFalse(ActionHistory.canRestoreOutcome(sentOn))
        XCTAssertEqual(ActionHistory.outcomeLine(sentOn, types: types, now: now).prefix(21), "Sent to Jira tickets ")
        XCTAssertTrue(ActionHistory.outcomeLine(completed, types: types, now: now).hasPrefix("Completed by you"))
    }

    func testDatePresets() {
        let cal = Calendar.current
        XCTAssertTrue(HistoryDate.today.contains(now, now: now))
        let fiveDays = cal.date(byAdding: .day, value: -5, to: now)!
        XCTAssertFalse(HistoryDate.today.contains(fiveDays, now: now))
        XCTAssertTrue(HistoryDate.thisWeek.contains(fiveDays, now: now))
        let twentyDays = cal.date(byAdding: .day, value: -20, to: now)!
        XCTAssertFalse(HistoryDate.thisWeek.contains(twentyDays, now: now))
        XCTAssertTrue(HistoryDate.last30.contains(twentyDays, now: now))
        XCTAssertFalse(HistoryDate.last30.contains(cal.date(byAdding: .day, value: -40, to: now)!, now: now))
    }
}
