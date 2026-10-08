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
        // Jira at the minimum window: "Atlassian · not connected" + Set up connection is about 300 pt.
        let fit = ToolbarFit.plan(total: 600, search: 180, filter: 90, right: 290, rightCompact: 110, chips: [80], plus: { _ in 40 })
        XCTAssertEqual(fit.searchWidth, 140)
        // 600 - (140+6+90+6+8+6+290) = 54: no room for the chip, but "+1" fits; the text stays.
        XCTAssertFalse(fit.compactRight)
        XCTAssertEqual(fit.visibleChips, 0)
        let tighter = ToolbarFit.plan(total: 480, search: 180, filter: 90, right: 290, rightCompact: 110, chips: [], plus: { _ in 40 })
        XCTAssertTrue(tighter.compactRight)
    }

    // MARK: Facets

    func testANameDistillDoesNotKnowNeedsARecipientWhenAButtonSendsToIt() {
        let ready = item("b", "slack", .ready, body: "Hi", fields: ["to": "Mei Tanaka"])
        var slack = ActionTypeInfo(id: "slack", label: "Slack message")
        let send = AutomationButton(id: "send", label: "Send in Slack", bindings: ["target": "{fields.to}", "text": "{body}"], slot: .send)
        slack.buttons = [ActionButtonInfo(button: send)]
        let unknown = SlackTarget.resolve(to: "Mei Tanaka", thread: nil, lookup: { _ in nil })
        let known = SlackTarget.resolve(to: "Mei Tanaka", thread: nil, lookup: { _ in "@mei" })
        // The row pill and the status filter say the same words.
        XCTAssertEqual(slack.readyWords(for: unknown), "Needs a recipient")
        XCTAssertEqual(ActionFacets.values("slack", "status", ready, types: [slack], slackTarget: unknown), ["Needs a recipient"])
        var f = FacetFilter()
        f.toggle("status", "Needs a recipient")
        XCTAssertTrue(ActionFacets.matches("slack", f, ready, types: [slack], slackTarget: unknown))
        XCTAssertFalse(ActionFacets.matches("slack", f, ready, types: [slack], slackTarget: known))
        XCTAssertEqual(slack.readyWords(for: known), "Ready to send", "a remembered name resolves it")
        XCTAssertEqual(slack.readyWords(for: nil), "Ready to send")
        // Copy and paste work with any name: a button that doesn't send to the To field keeps Ready to send.
        var toMe = slack
        toMe.buttons = [ActionButtonInfo(button: AutomationButton(id: "me", label: "Send to me", bindings: ["target": "@me", "text": "{body}"], slot: .send))]
        XCTAssertEqual(toMe.readyWords(for: unknown), "Ready to send")
        // An off button doesn't count; nor does a group (another problem, not a missing name).
        var off = slack
        off.buttons[0].button.enabled = false
        XCTAssertEqual(off.readyWords(for: unknown), "Ready to paste")
        XCTAssertEqual(slack.readyWords(for: SlackTarget.resolve(to: "Mei, Aditya", thread: nil, lookup: { _ in nil })), "Ready to send")
    }

    func testAThreadTheButtonCannotReachCannotBeRepliedIn() {
        let ready = item("b", "slack", .ready, body: "Hi", fields: ["to": "#eng", "thread": "1759600000.123456"])
        var slack = ActionTypeInfo(id: "slack", label: "Slack message")
        let send = AutomationButton(id: "send", label: "Send in Slack", bindings: ["thread": "", "target": "{fields.to}", "text": "{body}"], slot: .send)
        slack.buttons = [ActionButtonInfo(button: send)]
        let thread = SlackTarget.resolve(to: "#eng", thread: "1759600000.123456", lookup: { _ in nil })
        // The pill and the filter say what the card's callout says: Send is off.
        XCTAssertEqual(slack.readyWords(for: thread), "Can’t reply in thread")
        XCTAssertTrue(ActionTypeInfo.isBlocked(slack.readyWords(for: thread)))
        XCTAssertEqual(ActionFacets.values("slack", "status", ready, types: [slack], slackTarget: thread), ["Can’t reply in thread"])
        var f = FacetFilter()
        f.toggle("status", "Can’t reply in thread")
        XCTAssertTrue(ActionFacets.matches("slack", f, ready, types: [slack], slackTarget: thread))
        // An unreadable link is the same: a reply that can't find its thread.
        let unreadable = SlackTarget.resolve(to: "#eng", thread: "the standup thread", lookup: { _ in nil })
        XCTAssertEqual(slack.readyWords(for: unreadable), "Can’t reply in thread")
        // A button that fills in the thread is ready.
        var threaded = slack
        threaded.buttons[0].button.bindings["thread"] = "{fields.thread}"
        XCTAssertEqual(threaded.readyWords(for: thread), "Ready to send")
        XCTAssertFalse(ActionTypeInfo.isBlocked("Ready to send"))
    }

    func testSlackStatusesAndMatching() {
        let notWritten = item("a", "slack", .open)
        let ready = item("b", "slack", .ready, body: "Hi", fields: ["to": "Mei Tanaka"], labels: ["tea-club"])
        let copied = item("c", "slack", .ready, body: "Hi", events: [ActionEvent(at: now, event: "copied")])
        XCTAssertEqual(ActionFacets.values("slack", "status", notWritten), ["Not written"])
        XCTAssertEqual(ActionFacets.values("slack", "status", ready), ["Ready to paste"])
        // A button in the Send slot: the filter says what the rows say.
        var slack = ActionTypeInfo(id: "slack", label: "Slack message")
        slack.buttons = [ActionButtonInfo(button: AutomationButton(id: "send", label: "Send in Slack", slot: .send))]
        XCTAssertEqual(ActionFacets.values("slack", "status", ready, types: [slack]), ["Ready to send"])
        XCTAssertEqual(ActionFacets.fixed("slack", "status", types: [slack]), ["Not written", "Draft", "Ready to send", "Needs a recipient", "Can’t reply in thread", "Copied"])
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

    // MARK: Panel sections from the items

    func testCountedSectionsListMostUsedFirstThenByNameAndKeepAStaleSelection() {
        let items = [item("a", "jira", .open, fields: ["project": "beta", "assignee": "Mei"]),
                     item("b", "jira", .open, fields: ["project": "Alpha"]),
                     item("c", "jira", .open, fields: ["project": "Gamma"]),
                     item("d", "jira", .open, fields: ["project": "Gamma"])]
        let f = FacetFilter(selected: ["project": ["Zeta"], "status": ["Draft"]])
        let sections = ActionFacets.sections("jira", items: items, filter: f)
        XCTAssertEqual(sections.map(\.id), ["status", "project", "type", "priority", "assignee", "note"])
        let project = sections[1]
        // Gamma (2), then Alpha and beta (1 each) by name ignoring case, then the selected Zeta no item has.
        XCTAssertEqual(project.options.map(\.id), ["Gamma", "Alpha", "beta", "Zeta"])
        XCTAssertEqual(project.options.map(\.count), [2, 1, 1, 0])
        XCTAssertEqual(project.selected, ["Zeta"])
        XCTAssertNil(project.searchPlaceholder)
        XCTAssertFalse(sections.contains(where: \.single), "only To do's Status is radio rows")
        // Fixed lists have no counts and keep their order; a selected fixed value isn't added twice.
        XCTAssertEqual(sections[0].options.map(\.id), ["Not written", "Draft", "Created"])
        XCTAssertEqual(sections[0].options.map(\.count), [nil, nil, nil])
        XCTAssertEqual(sections[0].selected, ["Draft"])
        // Nobody assigned counts as Unassigned; the section has its search field.
        XCTAssertEqual(sections[4].options.map(\.id), ["Unassigned", "Mei"])
        XCTAssertEqual(sections[4].options.map(\.count), [3, 1])
        XCTAssertEqual(sections[4].searchPlaceholder, "Find a person")
        XCTAssertEqual(sections[5].options.map(\.id), ["Tea club planning"])
        XCTAssertEqual(sections[5].options.first?.count, 4)
        // No items and nothing selected: an empty section.
        XCTAssertEqual(ActionFacets.sections("confluence", items: [], filter: FacetFilter())[1].options, [])
    }

    func testSlackSectionsCountCopiedItemsByTheirIDs() {
        let a = item("a", "slack", .ready, body: "Hi")
        let b = item("b", "slack", .ready, body: "Hi")
        let status = ActionFacets.sections("slack", items: [a, b], filter: FacetFilter(), copied: ["a"])
        XCTAssertEqual(status.map(\.id), ["status", "recipient", "note", "label"])
        XCTAssertEqual(status[1].searchPlaceholder, "Find a person or channel")
        let recipient = ActionFacets.sections("slack", items: [item("x", "slack", .open, fields: ["to": "#eng"]), a], filter: FacetFilter())[1]
        XCTAssertEqual(recipient.options.map(\.id), ["#eng"])
        // The copied set decides Copied for counted sections too.
        XCTAssertEqual(ActionFacets.values("slack", "status", a, copied: true), ["Copied"])
        XCTAssertEqual(ActionFacets.values("slack", "status", b, copied: false), ["Ready to paste"])
    }

    func testStatusValuesOutsideSlack() {
        XCTAssertEqual(ActionFacets.values("jira", "status", item("a", "jira", .created)), ["Created"])
        XCTAssertEqual(ActionFacets.values("jira", "status", item("b", "jira", .open)), ["Not written"])
        XCTAssertEqual(ActionFacets.values("jira", "status", item("c", "jira", .open, body: "")), ["Not written"])
        XCTAssertEqual(ActionFacets.values("jira", "status", item("d", "jira", .open, body: "Body")), ["Draft"])
        XCTAssertEqual(ActionFacets.values("confluence", "status", item("e", "confluence", .ready, body: "Body")), ["Draft"])
        // A ready Jira item is a draft, never "Ready to paste" or Copied (those are Slack's words).
        XCTAssertEqual(ActionFacets.values("jira", "status", item("f", "jira", .ready), copied: true), ["Draft"])
        // Slack: an open item with words is a draft; a created one too.
        XCTAssertEqual(ActionFacets.values("slack", "status", item("g", "slack", .open, body: "Hi")), ["Draft"])
        XCTAssertEqual(ActionFacets.values("slack", "status", item("h", "slack", .created, body: "Hi")), ["Draft"])
    }

    func testFieldValuesPerSection() {
        let jira = item("a", "jira", .open, fields: ["project": "OPS", "issueType": "Bug", "priority": "High", "assignee": "Tom", "space": "ENG", "to": "@mei"],
                        labels: ["x", "y"])
        XCTAssertEqual(ActionFacets.values("jira", "project", jira), ["OPS"])
        XCTAssertEqual(ActionFacets.values("jira", "type", jira), ["Bug"])
        XCTAssertEqual(ActionFacets.values("jira", "priority", jira), ["High"])
        XCTAssertEqual(ActionFacets.values("jira", "assignee", jira), ["Tom"])
        XCTAssertEqual(ActionFacets.values("confluence", "space", jira), ["ENG"])
        XCTAssertEqual(ActionFacets.values("slack", "recipient", jira), ["@mei"])
        XCTAssertEqual(ActionFacets.values("slack", "label", jira), ["#x", "#y"])
        XCTAssertEqual(ActionFacets.values("slack", "note", jira), ["Tea club planning"])
        XCTAssertEqual(ActionFacets.values("slack", "unknown", jira), [])
        // Missing (or blank) fields: no value, so a filter on that section never matches.
        let bare = item("b", "jira", .open, fields: ["project": "  "], note: nil)
        for key in ["project", "type", "priority", "space", "recipient", "note", "label"] {
            XCTAssertEqual(ActionFacets.values("jira", key, bare), [], key)
        }
        XCTAssertEqual(ActionFacets.values("jira", "assignee", bare), ["Unassigned"])
        var f = FacetFilter(selected: ["project": ["OPS"]])
        XCTAssertFalse(ActionFacets.matches("jira", f, bare))
        XCTAssertTrue(ActionFacets.matches("jira", f, jira))
        // An emptied section matches everything; search still narrows.
        f.selected["project"] = []
        XCTAssertTrue(ActionFacets.matches("jira", f, bare))
        f.text = "nothing like this"
        XCTAssertFalse(ActionFacets.matches("jira", f, jira))
    }

    func testHistoryTypeSourceOutcomeAndDateValues() {
        let custom = ActionTypeInfo(id: "email", label: "Email draft")
        let hidden = ActionTypeInfo(id: "internal", label: "Internal", reserved: true)
        let all = types + [custom, hidden]
        func type(_ t: String, _ known: [ActionTypeInfo] = []) -> [String] {
            ActionFacets.values("history", "type", item("a", t, .done), types: known)
        }
        XCTAssertEqual(type("todo", all), ["To do"])
        XCTAssertEqual(type("jira", all), ["Jira ticket"])
        XCTAssertEqual(type("email", all), ["Email draft"])
        // Without the type list: the built-in names, else the raw id.
        XCTAssertEqual(type("slack"), ["Slack message"])
        XCTAssertEqual(type("jira"), ["Jira ticket"])
        XCTAssertEqual(type("confluence"), ["Confluence page"])
        XCTAssertEqual(type("webhook"), ["webhook"])
        // The type list: the four built-ins, then non-reserved extras by label.
        XCTAssertEqual(ActionFacets.fixed("history", "type", types: all), ["To do", "Slack message", "Jira ticket", "Confluence page", "Email draft"])
        XCTAssertEqual(ActionFacets.fixed("history", "source"), ["Notes", "Ask answers", "Added by you"])
        XCTAssertNil(ActionFacets.fixed("history", "nothing"))
        XCTAssertNil(ActionFacets.fixed("todo", "status"))
        // Source.
        XCTAssertEqual(ActionFacets.values("history", "source", item("n", "todo", .done)), ["Notes"])
        XCTAssertEqual(ActionFacets.values("history", "source", item("m", "todo", .done, note: nil)), ["Added by you"])
        let ask = ActionItem(id: "q", title: "Q", source: .ask(conversationID: "c", question: nil, quote: nil, citedPaths: [], turnIndex: nil, gap: false))
        XCTAssertEqual(ActionFacets.values("history", "source", ask), ["Ask answers"])
        XCTAssertEqual(ActionFacets.values("history", "source", ActionItem(id: "g", title: "G", source: .agent)), [])
        // Outcome: an open item has none.
        XCTAssertEqual(ActionFacets.values("history", "outcome", item("r", "todo", .removed)), ["Removed"])
        XCTAssertEqual(ActionFacets.values("history", "outcome", item("o", "todo", .open)), [])
        // Date: today is in all three presets; 10 days ago only in the last 30.
        let today = item("t", "todo", .done, events: [ActionEvent(at: now, event: "done")])
        XCTAssertEqual(ActionFacets.values("history", "date", today, now: now), ["Today", "This week", "Last 30 days"])
        let old = item("u", "todo", .done, events: [ActionEvent(at: now.addingTimeInterval(-10 * 86_400), event: "done")])
        XCTAssertEqual(ActionFacets.values("history", "date", old, now: now), ["Last 30 days"])
        // History panel: every section fixed.
        let sections = ActionFacets.sections("history", items: [today, old], filter: FacetFilter(), now: now, types: all)
        XCTAssertEqual(sections.map(\.id), ["type", "outcome", "date", "source"])
        XCTAssertTrue(sections.allSatisfy { $0.options.allSatisfy { $0.count == nil } })
    }

    func testChipWordsAndOrder() {
        let f = FacetFilter(selected: ["status": ["Created", "Draft", "Not written"], "project": ["OPS", "ACME"],
                                       "assignee": ["Tom"], "note": ["Retro"], "label": ["#z"]])
        // Fixed sections follow their list's order; the rest sort by name. Panel order across sections.
        XCTAssertEqual(ActionFacets.chips("jira", f).map(\.text),
                       ["Not written", "Draft", "Created", "Project: ACME", "Project: OPS", "Assignee: Tom", "Note: Retro"])
        XCTAssertEqual(ActionFacets.chips("slack", FacetFilter(selected: ["recipient": ["#eng"]])).map(\.text), ["To: #eng"])
        XCTAssertEqual(ActionFacets.chips("confluence", FacetFilter(selected: ["space": ["ENG"]])).map(\.text), ["Space: ENG"])
        let chip = ActionFacets.chips("jira", f)[3]
        XCTAssertEqual(chip.section, "project")
        XCTAssertEqual(chip.value, "ACME")
        XCTAssertEqual(chip.id, "project\u{1F}ACME")
        // History: plain words for type, outcome, date and source.
        let h = FacetFilter(selected: ["date": ["Last 30 days", "Today"], "source": ["Notes"], "type": ["Webhook", "To do"], "outcome": ["Sent"]])
        XCTAssertEqual(ActionFacets.chips("history", h).map(\.text), ["To do", "Webhook", "Sent", "Today", "Last 30 days", "Notes"])
    }

    func testFacetFilterToggleAndRemove() {
        var f = FacetFilter()
        XCTAssertFalse(f.isNarrowed)
        f.text = "   "
        XCTAssertFalse(f.isNarrowed, "blank search is not a filter")
        f.text = "tea"
        XCTAssertTrue(f.isNarrowed)
        f.text = ""
        f.toggle("label", "#a")
        f.toggle("label", "#b")
        f.toggle("project", "OPS")
        XCTAssertEqual(f.count, 3)
        XCTAssertEqual(f.values("label"), ["#a", "#b"])
        XCTAssertEqual(f.values("nothing"), [])
        f.toggle("project", "OPS")
        XCTAssertNil(f.selected["project"], "the last value off drops the section")
        f.remove("label", "#a")
        XCTAssertEqual(f.selected["label"], ["#b"])
        f.remove("label", "#b")
        XCTAssertNil(f.selected["label"])
        f.remove("label", "#gone")
        XCTAssertEqual(f, FacetFilter())
        f.text = "kept"
        f.toggle("status", "Draft")
        f.clear()
        XCTAssertEqual(f.count, 0)
        XCTAssertEqual(f.text, "kept")
        XCTAssertTrue(f.isNarrowed)
    }

    func testSearchOnlyNarrowsSectionsWithASearchField() {
        let labels = FacetSection(id: "label", title: "LABEL", options: (1...7).map { FacetOption(id: "#l\($0)") })
        // No search field: the query filters nothing.
        XCTAssertEqual(labels.visible(query: "l3").all, 7)
        let people = FacetSection(id: "person", title: "PERSON", searchPlaceholder: "Find a person",
                                  options: (1...8).map { FacetOption(id: "Person \($0)") })
        // A blank query is no query.
        XCTAssertEqual(people.visible(query: "  ").rows.count, 5)
        XCTAssertEqual(people.visible(query: "  ").all, 8)
        // While searching, everything that matches shows (no fold).
        XCTAssertEqual(people.visible(query: "person").rows.count, 8)
        XCTAssertEqual(people.visible(query: "PERSON 7").rows.map(\.id), ["Person 7"])
        // A label differs from the id: search reads the label.
        let more = FacetSection(id: "more", title: "MORE", searchPlaceholder: "x", options: [FacetOption(id: "vault:/a/Work", label: "Work")])
        XCTAssertEqual(more.visible(query: "vault").rows, [])
        XCTAssertEqual(more.visible(query: "work").rows.count, 1)
    }

    // MARK: To do panel

    func testTodoSectionsCountOnlyTheChosenStatus() {
        let open1 = ActionItem(id: "1", status: .open, title: "A", fields: ["person": "Mei, Tom", "priority": "High"],
                               source: .note(jobID: "j", notePath: "notes/Retro.md", pageTitle: nil, quote: nil),
                               vaultPath: "/v/Work", labels: ["a"])
        let open2 = ActionItem(id: "2", status: .open, title: "B", fields: ["person": "Mei"], vaultPath: "/v/Home", labels: ["a", "b"])
        let done = ActionItem(id: "3", status: .done, title: "C", fields: ["person": "Zed"], vaultPath: "/v/Old")
        var f = ActionFilter()
        f.people = ["Gone"]
        f.labels = ["c"]
        f.notes = ["Old note"]
        let s = ActionFacets.todoSections([open1, open2, done], filter: f)
        XCTAssertEqual(s.map(\.id), ["status", "due", "person", "label", "note", "priority", "more"])
        XCTAssertTrue(s[0].single)
        XCTAssertEqual(s[0].options.map(\.label), ["Open", "Completed", "All"])
        XCTAssertEqual(s[0].selected, ["open"])
        XCTAssertEqual(s[1].options.map(\.id), ["Overdue", "Today", "This week", "Later", "No due date"])
        XCTAssertEqual(s[1].selected, [])
        // Person: Mei (2), Tom (1); the done item's Zed is outside Open; a selected name nobody has stays, at 0.
        XCTAssertEqual(s[2].options.map(\.id), ["Mei", "Tom", "Gone"])
        XCTAssertEqual(s[2].options.map(\.count), [2, 1, 0])
        XCTAssertEqual(s[2].searchPlaceholder, "Find a person")
        XCTAssertEqual(s[3].options.map(\.id), ["#a", "#b", "#c"])
        XCTAssertEqual(s[3].selected, ["#c"])
        XCTAssertEqual(s[4].options.map(\.id), ["Retro", "Old note"])
        XCTAssertEqual(s[5].options.map(\.id), ["High", "Medium", "Low", "None"])
        // More: who added it, then every vault (all statuses), sorted, by folder name. No batch option without a job.
        XCTAssertEqual(s[6].options.map(\.id), ["added:distill", "added:you", "vault:/v/Home", "vault:/v/Old", "vault:/v/Work"])
        XCTAssertEqual(s[6].options.map(\.label), ["Distill", "You", "Home", "Old", "Work"])
        XCTAssertEqual(s[6].options.map(\.group), ["ADDED BY", "ADDED BY", "VAULT", "VAULT", "VAULT"])
        XCTAssertEqual(s[6].selected, [])
        // Completed counts the done item instead.
        f.status = .completed
        XCTAssertEqual(ActionFacets.todoSections([open1, open2, done], filter: f)[2].options.map(\.id), ["Zed", "Gone"])
    }

    func testTodoMoreSectionShowsWhatIsSelected() {
        var f = ActionFilter()
        f.due = [.today, .later]
        f.addedBy = .you
        f.vaults = ["/v/Work"]
        f.jobID = "job-1"
        f.priorities = ["Low"]
        let s = ActionFacets.todoSections([], filter: f)
        XCTAssertEqual(s[1].selected, ["Today", "Later"])
        XCTAssertEqual(s[5].selected, ["Low"])
        XCTAssertEqual(s[6].options.last?.id, "job")
        XCTAssertEqual(s[6].options.last?.label, "Only from the last batch")
        XCTAssertEqual(s[6].selected, ["vault:/v/Work", "added:you", "job"])
    }

    func testTodoChipsInPanelOrder() {
        var f = ActionFilter()
        f.status = .completed
        f.due = [.none, .overdue]
        f.people = ["Tom", "Mei"]
        f.labels = ["b", "a"]
        f.notes = ["Retro"]
        f.priorities = ["None", "High"]
        f.addedBy = .distill
        f.vaults = ["/v/Work", "/v/Home"]
        f.jobID = "j"
        XCTAssertEqual(ActionFacets.todoChips(f).map(\.text), [
            "Status: Completed", "Due: Overdue", "Due: No due date", "Person: Mei", "Person: Tom", "#a", "#b", "Note: Retro",
            "Priority: High", "Priority: None", "Added by Distill", "Home", "Work", "This batch",
        ])
        XCTAssertEqual(f.count, 14)
        f.addedBy = .you
        XCTAssertTrue(ActionFacets.todoChips(f).contains { $0.text == "Added by you" && $0.value == "added:you" })
        // Every chip's × takes its own filter off.
        for chip in ActionFacets.todoChips(f) { f.remove(chip) }
        XCTAssertEqual(f, ActionFilter())
    }

    func testTodoToggleRules() {
        var f = ActionFilter()
        f.toggle("status", "completed")
        XCTAssertEqual(f.status, .completed)
        f.toggle("status", "no such status")
        XCTAssertEqual(f.status, .open)
        f.toggle("due", "This week")
        XCTAssertEqual(f.due, [.thisWeek])
        f.toggle("due", "Next year")
        XCTAssertEqual(f.due, [.thisWeek], "an unknown due value does nothing")
        f.toggle("due", "This week")
        XCTAssertEqual(f.due, [])
        f.toggle("label", "plain")
        XCTAssertEqual(f.labels, ["plain"])
        f.toggle("label", "#plain")
        XCTAssertEqual(f.labels, [])
        f.toggle("note", "Retro")
        f.toggle("priority", "High")
        XCTAssertEqual(f.notes, ["Retro"])
        XCTAssertEqual(f.priorities, ["High"])
        // Added by: one at a time; the same one again turns it off.
        f.toggle("more", "added:you")
        XCTAssertEqual(f.addedBy, .you)
        f.toggle("more", "added:distill")
        XCTAssertEqual(f.addedBy, .distill)
        f.toggle("more", "added:distill")
        XCTAssertNil(f.addedBy)
        f.toggle("more", "vault:/v/Work")
        XCTAssertEqual(f.vaults, ["/v/Work"])
        f.toggle("more", "vault:/v/Work")
        XCTAssertEqual(f.vaults, [])
        // The batch option only clears (it is set from Review).
        f.jobID = "j"
        f.toggle("more", "job")
        XCTAssertNil(f.jobID)
        f.toggle("more", "job")
        XCTAssertNil(f.jobID)
        let before = f
        f.toggle("more", "something else")
        f.toggle("nowhere", "x")
        XCTAssertEqual(f, before)
        // A status chip's × goes back to Open even for Open.
        f.status = .all
        f.remove(FacetChip(section: "status", value: "all", text: "Status: All"))
        XCTAssertEqual(f.status, .open)
    }

    // MARK: History lines

    func testOutcomeLinesAndHelp() {
        let at = now.addingTimeInterval(-60)
        let phrase = HistoryTime.phrase(at, now: now)
        let marked = item("d", "slack", .sent, events: [ActionEvent(at: at, event: "sent")])
        XCTAssertEqual(ActionHistory.outcomeLine(marked, types: types, now: now), "Marked as sent \(phrase)")
        // Sent on to a type Distill doesn't list: the raw id.
        let sentOn = item("c", "todo", .sent, events: [ActionEvent(at: at, event: "sent-to:webhook")])
        XCTAssertEqual(ActionHistory.outcomeLine(sentOn, types: types, now: now), "Sent to webhook \(phrase)")
        XCTAssertEqual(ActionHistory.outcomeLine(item("r", "todo", .removed, events: [ActionEvent(at: at, event: "removed")]), types: types, now: now),
                       "Removed \(phrase)")
        XCTAssertEqual(ActionHistory.outcomeLine(item("e", "todo", .dismissed, events: [ActionEvent(at: at, event: "dismissed")]), types: types, now: now),
                       "Dismissed \(phrase)")
        XCTAssertEqual(ActionHistory.outcomeLine(item("c", "slack", .done, events: [ActionEvent(at: at, event: "done")]), types: types, now: now),
                       "Completed by you \(phrase)")
        // Created: the type's first word, and when the core last checked.
        let checked = now.addingTimeInterval(-86_400)
        var auto = item("b", "jira", .done, events: [ActionEvent(at: at, event: "done", detail: "in Jira (Done)")])
        auto.external = ActionExternal(key: "OPS-1", checkedAt: checked)
        XCTAssertEqual(ActionHistory.outcomeLine(auto, types: types, now: now), "Done in Jira · checked \(HistoryTime.phrase(checked, now: now))")
        auto.external = nil
        auto.type = "linear"
        XCTAssertEqual(ActionHistory.outcomeLine(auto, types: types, now: now), "Done in linear · checked \(phrase)")
        // No outcome: just the time.
        let open = item("o", "todo", .open, events: [])
        XCTAssertEqual(ActionHistory.outcomeLine(open, types: types, now: now), HistoryTime.phrase(open.updatedAt, now: now))
        XCTAssertEqual(ActionHistory.Outcome.allCases.map(\.help), ["Handled: any type, by you", "To-dos handed to an action type",
                                                                    "Jira and Confluence items created", "Can be restored", "Found but not added"])
    }

    func testAutomaticDoneNeedsADoneEventSayingWhere() {
        XCTAssertFalse(ActionHistory.isAutomaticDone(item("a", "jira", .done)))
        XCTAssertFalse(ActionHistory.isAutomaticDone(item("b", "jira", .done, events: [ActionEvent(at: now, event: "done")])))
        XCTAssertFalse(ActionHistory.isAutomaticDone(item("c", "jira", .done, events: [ActionEvent(at: now, event: "done", detail: "by you")])))
        XCTAssertFalse(ActionHistory.isAutomaticDone(item("d", "jira", .sent, events: [ActionEvent(at: now, event: "done", detail: "in Jira")])))
        // The last done event decides.
        let reopened = item("e", "jira", .done, events: [ActionEvent(at: now, event: "done", detail: "in Jira (Done)"),
                                                         ActionEvent(at: now, event: "done", detail: "ready")])
        XCTAssertFalse(ActionHistory.isAutomaticDone(reopened))
        XCTAssertFalse(ActionHistory.canRestoreOutcome(item("o", "todo", .open)))
        XCTAssertTrue(ActionHistory.canRestoreOutcome(item("r", "todo", .removed)))
    }

    func testWhenADismissedItemLeftTheList() {
        let later = now.addingTimeInterval(3600)
        let withEvent = ActionItem(id: "a", status: .dismissed, title: "A", createdAt: now, updatedAt: later,
                                   events: [ActionEvent(at: now.addingTimeInterval(60), event: "dismissed")])
        XCTAssertEqual(ActionHistory.whenOutcome(withEvent), now.addingTimeInterval(60))
        let without = ActionItem(id: "b", status: .dismissed, title: "B", createdAt: now, updatedAt: later)
        XCTAssertEqual(ActionHistory.whenOutcome(without), later)
        let removed = ActionItem(id: "c", status: .removed, title: "C", createdAt: now, updatedAt: later,
                                 events: [ActionEvent(at: now.addingTimeInterval(5), event: "removed")])
        XCTAssertEqual(ActionHistory.whenOutcome(removed), now.addingTimeInterval(5))
    }

    func testDatePresetEdgesAtMidnight() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let noon = cal.date(from: DateComponents(year: 2026, month: 10, day: 6, hour: 12))!
        let midnight = cal.date(from: DateComponents(year: 2026, month: 10, day: 6))!
        XCTAssertTrue(HistoryDate.today.contains(midnight, now: noon, calendar: cal))
        XCTAssertFalse(HistoryDate.today.contains(midnight.addingTimeInterval(-1), now: noon, calendar: cal))
        let weekStart = cal.date(byAdding: .day, value: -6, to: midnight)!
        XCTAssertTrue(HistoryDate.thisWeek.contains(weekStart, now: noon, calendar: cal))
        XCTAssertFalse(HistoryDate.thisWeek.contains(weekStart.addingTimeInterval(-1), now: noon, calendar: cal))
        let monthStart = cal.date(byAdding: .day, value: -29, to: midnight)!
        XCTAssertTrue(HistoryDate.last30.contains(monthStart, now: noon, calendar: cal))
        XCTAssertFalse(HistoryDate.last30.contains(monthStart.addingTimeInterval(-1), now: noon, calendar: cal))
        // A future date counts as today.
        XCTAssertTrue(HistoryDate.today.contains(noon.addingTimeInterval(86_400), now: noon, calendar: cal))
    }

    // MARK: Toolbar fit edges

    func testNothingFitsFallsBackToTheNarrowestSearchAndCompactSlot() {
        // Far too narrow for even the "+N" chip: the last candidate, nothing shown.
        let fit = ToolbarFit.plan(total: 200, search: 190, filter: 96, right: 110, rightCompact: 60, chips: [80, 80], plus: { _ in 40 })
        XCTAssertEqual(fit, ToolbarFit(searchWidth: 140, compactRight: true, visibleChips: 0))
        // A search already narrower than 160 isn't widened; with no chips, the designed width stays when it fits.
        let narrow = ToolbarFit.plan(total: 600, search: 150, filter: 96, right: 110, rightCompact: 60, chips: [], plus: { _ in 40 })
        XCTAssertEqual(narrow, ToolbarFit(searchWidth: 150, compactRight: false, visibleChips: 0))
    }

    func testToolbarFitExactWidthsAndPlusChipRoom() {
        // Exactly enough for search, filter, gap and right slot: 190+6+96+6+8+6+110 = 422; one 100 pt chip needs 106 more.
        XCTAssertEqual(ToolbarFit.plan(total: 528, search: 190, filter: 96, right: 110, rightCompact: 60, chips: [100], plus: { _ in 40 }),
                       ToolbarFit(searchWidth: 190, compactRight: false, visibleChips: 1))
        // One point short: the search narrows to 160 and the chip still fits.
        XCTAssertEqual(ToolbarFit.plan(total: 527, search: 190, filter: 96, right: 110, rightCompact: 60, chips: [100], plus: { _ in 40 }),
                       ToolbarFit(searchWidth: 160, compactRight: false, visibleChips: 1))
        // Not all chips fit: the search narrows to 160 first, then a chip shows only if "+N" fits after it.
        let plusWidths = ToolbarFit.plan(total: 544, search: 190, filter: 96, right: 110, rightCompact: 60, chips: [100, 300], plus: { n in Double(n) * 40 })
        XCTAssertEqual(plusWidths, ToolbarFit(searchWidth: 160, compactRight: false, visibleChips: 1))
        // One point less: the chip folds into "+2" (80 + 6 fits) before the search narrows any further.
        XCTAssertEqual(ToolbarFit.plan(total: 543, search: 190, filter: 96, right: 110, rightCompact: 60, chips: [100, 300], plus: { n in Double(n) * 40 }),
                       ToolbarFit(searchWidth: 160, compactRight: false, visibleChips: 0))
        // No chips and the right slot only fits compact: 140+6+96+6+8+6+60 = 322.
        XCTAssertEqual(ToolbarFit.plan(total: 322, search: 190, filter: 96, right: 110, rightCompact: 60, chips: [], plus: { _ in 40 }),
                       ToolbarFit(searchWidth: 140, compactRight: true, visibleChips: 0))
        // Hidden chips: "+N" needs room even when no chip shows, so the right slot drops its text (322 + 40 + 6 = 368).
        XCTAssertEqual(ToolbarFit.plan(total: 368, search: 140, filter: 96, right: 110, rightCompact: 60, chips: [200], plus: { _ in 40 }),
                       ToolbarFit(searchWidth: 140, compactRight: true, visibleChips: 0))
    }

    func testToolbarFitBoundaries() {
        func plan(_ total: Double, search: Double = 190, chips: [Double]) -> ToolbarFit {
            ToolbarFit.plan(total: total, search: search, filter: 96, right: 110, rightCompact: 60, chips: chips, plus: { _ in 40 })
        }
        // 190+6+96+6+8+6+110 = 422 fixed. No chips and exactly that much room: the designed search.
        XCTAssertEqual(plan(422, chips: []), ToolbarFit(searchWidth: 190, compactRight: false, visibleChips: 0))
        // Two 100 pt chips: the first needs room for "+1" after it (152), the last only itself (212 in all).
        XCTAssertEqual(plan(634, chips: [100, 100]), ToolbarFit(searchWidth: 190, compactRight: false, visibleChips: 2))
        // One point less: everything still fits once the search narrows to 160.
        XCTAssertEqual(plan(633, chips: [100, 100]), ToolbarFit(searchWidth: 160, compactRight: false, visibleChips: 2))
        // "+1" exactly fits at 160 (392 + 40 + 6): the search stops narrowing there.
        XCTAssertEqual(plan(438, chips: [200]), ToolbarFit(searchWidth: 160, compactRight: false, visibleChips: 0))
        // A designed search of exactly 160: when not everything fits, it goes on to 140.
        XCTAssertEqual(plan(438, search: 160, chips: [200]), ToolbarFit(searchWidth: 140, compactRight: false, visibleChips: 0))
    }
}
