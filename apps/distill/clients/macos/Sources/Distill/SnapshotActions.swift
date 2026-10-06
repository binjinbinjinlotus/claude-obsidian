import AppKit
import SwiftUI
import DistillKit

/// Fixture registry and items for the Actions snapshots (canvas row 6). Times
/// are today's clock times, as on the boards ("today at 3:44 PM").
enum ActionFixtures {
    static let cal = Calendar.current

    static func at(_ hour: Int, _ minute: Int, daysAgo: Int = 0) -> Date {
        let day = cal.date(byAdding: .day, value: -daysAgo, to: Date()) ?? Date()
        return cal.date(bySettingHour: hour, minute: minute, second: 0, of: day) ?? day
    }

    static func day(_ offset: Int) -> String { ActionDue.format(cal.date(byAdding: .day, value: offset, to: Date()) ?? Date()) }

    static let types: [ActionTypeInfo] = [
        ActionTypeInfo(id: "todo", label: "To-do", pluralLabel: "To do",
                       fields: [ActionFieldSpec(key: "due", label: "Due", kind: "date"),
                                ActionFieldSpec(key: "priority", label: "Priority", kind: "choice", choices: ["High", "Medium", "Low"]),
                                ActionFieldSpec(key: "person", label: "People", kind: "person")],
                       handlers: [ActionHandlerInfo(id: "complete", label: "Complete")], draftWhen: "onFind"),
        ActionTypeInfo(id: "slack", label: "Slack message", pluralLabel: "Slack messages",
                       fields: [ActionFieldSpec(key: "to", label: "To", kind: "person", required: true)],
                       handlers: [ActionHandlerInfo(id: "copy", label: "Copy"), ActionHandlerInfo(id: "markSent", label: "Mark as sent"),
                                  ActionHandlerInfo(id: "complete", label: "Complete"),
                                  ActionHandlerInfo(id: "send", label: "Send in Slack", available: false, reason: "Later")],
                       draftWhen: "onFind", improveAfterEdit: true),
        ActionTypeInfo(id: "jira", label: "Jira ticket", pluralLabel: "Jira tickets",
                       fields: [ActionFieldSpec(key: "project", label: "Project", required: true),
                                ActionFieldSpec(key: "issueType", label: "Type", kind: "choice", choices: ["Task", "Bug", "Story"], required: true),
                                ActionFieldSpec(key: "priority", label: "Priority", kind: "choice", choices: ["Highest", "High", "Medium", "Low"]),
                                ActionFieldSpec(key: "assignee", label: "Assignee", kind: "person")],
                       handlers: [ActionHandlerInfo(id: "create", label: "Create in Jira"), ActionHandlerInfo(id: "refresh", label: "Refresh"),
                                  ActionHandlerInfo(id: "complete", label: "Complete")],
                       connectionID: "atlassian", draftWhen: "onFind", improveAfterEdit: true),
        ActionTypeInfo(id: "confluence", label: "Confluence page", pluralLabel: "Confluence pages",
                       fields: [ActionFieldSpec(key: "space", label: "Space", required: true), ActionFieldSpec(key: "parent", label: "Parent page")],
                       handlers: [ActionHandlerInfo(id: "create", label: "Create in Confluence"), ActionHandlerInfo(id: "refresh", label: "Refresh"),
                                  ActionHandlerInfo(id: "complete", label: "Complete")],
                       connectionID: "atlassian", draftWhen: "onFind", improveAfterEdit: true),
        ActionTypeInfo(id: "email", label: "Email", pluralLabel: "Emails", enabled: false, reserved: true,
                       handlers: [ActionHandlerInfo(id: "copy", label: "Copy", available: false, reason: "Later")]),
    ]

    static func types(disconnected: Bool = false, slackOff: Bool = false) -> [ActionTypeInfo] {
        types.map { t in
            var t = t
            if disconnected, t.connectionID == "atlassian" {
                t.handlers = t.handlers.map { var h = $0; if h.id == "create" { h.available = false; h.reason = "Not connected" }; return h }
            }
            if slackOff, t.id == "slack" { t.enabled = false }
            return t
        }
    }

    static func note(_ title: String, _ quote: String, job: String = "job-tea") -> ActionSource {
        .note(jobID: job, notePath: "wiki/notes/\(title).md", pageTitle: title, quote: quote)
    }

    static let auth = "Action for me: cap the payment client at 3 retries with exponential backoff before Thursday. Needs a ticket in PX."
    static let tea = "I’ll book the tasting room for Saturday afternoon and tell Mei so she can bring the new tin."

    static func todo(_ id: String, _ title: String, due: String?, priority: String?, person: String?, labels: [String],
                     source: ActionSource, why: String, status: ActionStatus = .open, at: Date = at(15, 44)) -> ActionItem {
        var f: [String: String] = [:]
        if let due { f["due"] = due }
        if let priority { f["priority"] = priority }
        if let person { f["person"] = person }
        return ActionItem(id: id, type: "todo", status: status, title: title, fields: f, why: why, source: source, vaultPath: nil,
                          labels: labels, createdAt: at, events: [ActionEvent(at: at, event: "found", detail: "Sonnet")])
    }

    static let jiraBody = """
    ## Why
    The INC-212 retry storm came from unbounded payment client retries.
    ## What to do
    - Cap retries at 3
    - Exponential backoff from 200 ms, with jitter
    - Log the final failure with the request ID
    ## Done when
    - [ ] Retries stop after 3 attempts in staging
    - [ ] Alert fires above 50 retries a minute
    """

    static let pageBody = """
    ## Summary
    On Sep 29 the auth service slowed for 40 minutes because the payment client retried without a limit.
    ## Timeline
    - 9:12 AM retries spike to 900 a minute
    - 9:31 AM Priya rolls back the client
    ## What we change
    - Cap retries at 3 (PX-481)
    - Alert on retry storms (PX-482)
    """

    static let meiMessage = "Hi @Mei, I booked the tasting room for **Saturday at 2 PM**. Could you bring the new 50 g gyokuro tin? The shop recommends 60 °C for the first steep."

    /// The open lists: To do 6, Slack 1 ready (+1 not written), Jira 1 ready (+1 not written, 1 created), Confluence 1 ready (+…).
    static func live() -> [ActionItem] {
        [
            todo("t1", "Cap payment client retries at 3 with backoff", due: day(-2), priority: "High", person: "You (Jin Liu)", labels: ["project-x"],
                 source: note("Auth retry bug", auth, job: "job-auth"), why: "You assigned it to yourself. The note says it needs a ticket, so Jira ticket is suggested.", at: at(11, 24)),
            todo("t2", "Book the tasting room for Saturday", due: day(0), priority: "Medium", person: "Mei Tanaka", labels: ["tea-club"],
                 source: note("Tea club planning", tea), why: "You said you would book it. Booking a room isn’t an action type Distill can do, so it’s a to-do."),
            todo("t3", "Read Priya’s INC-212 timeline before the review",
                 due: CoreDate.format(at(17, 0)), priority: "Medium", person: "Priya Shah", labels: ["project-x", "incidents"],
                 source: note("Incident review prep", "Read Priya’s timeline before Friday’s review.", job: "job-inc"), why: "The review needs it.", at: at(13, 5)),
            todo("t4", "Write the on-call handoff checklist", due: day(3), priority: nil, person: "You (Jin Liu)", labels: ["project-x"],
                 source: note("Q3 architecture sync", "Jin writes the on-call handoff checklist this week.", job: "job-q3"), why: "You took it in the meeting.", at: at(10, 2)),
            todo("t5", "Ask the shop about the spring harvest", due: day(6), priority: "Low", person: "Mei Tanaka", labels: ["tea"],
                 source: note("Gyokuro at 60 °C", "Ask the shop when the spring harvest arrives.", job: "job-gyo"), why: "Mei wants the new harvest.", at: at(9, 40)),
            todo("t6", "Buy the 50 g gyokuro tin", due: nil, priority: nil, person: nil, labels: ["tea"],
                 source: note("Gyokuro at 60 °C", "…bring the new tin.", job: "job-gyo"), why: "The club runs out on Saturday.", at: at(9, 40)),
            ActionItem(id: "s1", type: "slack", status: .ready, title: "Message to Mei", body: meiMessage, fields: ["to": "Mei Tanaka"],
                       why: "Mei is bringing the tea, so she needs the time. You said you would tell her.", source: note("Tea club planning", tea),
                       labels: ["tea-club"], createdAt: at(15, 44), draftModel: "Sonnet",
                       events: [ActionEvent(at: at(15, 44), event: "found", detail: "Sonnet"), ActionEvent(at: at(15, 44), event: "drafted", detail: "Sonnet")]),
            ActionItem(id: "s2", type: "slack", status: .open, title: "Message to #project-x about retries", fields: ["to": "#project-x"],
                       why: "The channel needs a heads-up before the deploy changes retry behaviour.",
                       source: note("Auth retry bug", "Let #project-x know we’re capping payment client retries at 3 before Thursday’s deploy.", job: "job-auth"),
                       labels: ["project-x"], createdAt: at(11, 24), events: [ActionEvent(at: at(11, 24), event: "found", detail: "Sonnet")]),
            ActionItem(id: "j1", type: "jira", status: .ready, title: "Cap payment client retries at 3 with exponential backoff", body: jiraBody,
                       fields: ["project": "PX · Project X", "issueType": "Task", "priority": "High", "assignee": "You (Jin Liu)"],
                       why: "You asked for a ticket in PX. Sent from To do at 3:50 PM.", source: note("Auth retry bug", auth, job: "job-auth"),
                       labels: ["project-x", "retries"], createdAt: at(15, 50), draftModel: "Sonnet", fromActionID: "h4",
                       events: [ActionEvent(at: at(11, 24), event: "found", detail: "Sonnet"), ActionEvent(at: at(15, 50), event: "drafted", detail: "Sonnet")]),
            ActionItem(id: "j2", type: "jira", status: .open, title: "Write a runbook entry for payment client timeouts",
                       fields: ["project": "PX · Project X", "issueType": "Task"], why: "The sync agreed timeouts need a runbook.",
                       source: note("Q3 architecture sync", "Someone should write a runbook entry for payment client timeouts.", job: "job-q3"),
                       createdAt: at(10, 2), events: [ActionEvent(at: at(10, 2), event: "found", detail: "Sonnet")]),
            ActionItem(id: "j3", type: "jira", status: .created, title: "Add an alert for retry storms on the auth service", body: "Alert above 50 retries a minute.",
                       fields: ["project": "PX · Project X", "issueType": "Task"], why: "INC-212 follow-up.",
                       source: note("Incident review prep", "We need an alert for retry storms.", job: "job-inc"), createdAt: at(13, 5), updatedAt: at(15, 52),
                       external: ActionExternal(key: "PX-482", url: "https://acme.atlassian.net/browse/PX-482", status: "In progress", checkedAt: at(15, 52)),
                       events: [ActionEvent(at: at(13, 5), event: "found"), ActionEvent(at: at(15, 51), event: "created", detail: "PX-482")]),
            ActionItem(id: "c1", type: "confluence", status: .ready, title: "Incident review: INC-212 auth retry storm", body: pageBody,
                       fields: ["space": "Project X", "parent": "Incident reviews"], why: "The note asks for a page in a named place. Distill can draft it for you.",
                       source: note("Incident review prep", "Write up INC-212 in Confluence under Incident reviews before Friday’s review.", job: "job-inc"),
                       labels: ["incident", "retries"], createdAt: at(13, 12), draftModel: "Sonnet",
                       events: [ActionEvent(at: at(13, 5), event: "found", detail: "Sonnet"), ActionEvent(at: at(13, 12), event: "drafted", detail: "Sonnet")]),
            ActionItem(id: "c2", type: "confluence", status: .open, title: "Tea club: brewing temperatures cheat sheet", fields: ["space": "Tea club"],
                       why: "A cheat sheet for the club.", source: note("Gyokuro at 60 °C", "Make a cheat sheet of brewing temperatures.", job: "job-gyo"),
                       createdAt: at(9, 40), events: [ActionEvent(at: at(9, 40), event: "found")]),
            ActionItem(id: "c3", type: "confluence", status: .created, title: "On-call handoff checklist", fields: ["space": "Project X", "parent": "Runbooks"],
                       why: "Runbook page.", source: note("Q3 architecture sync", "Publish the handoff checklist.", job: "job-q3"),
                       createdAt: at(15, 40), updatedAt: at(15, 52),
                       external: ActionExternal(key: "Project X › Runbooks", url: "https://acme.atlassian.net/wiki/x", status: "Published", checkedAt: at(15, 52)),
                       events: [ActionEvent(at: at(15, 51), event: "created")]),
        ]
    }

    static func history() -> [ActionItem] {
        [
            ActionItem(id: "h1", type: "slack", status: .removed, title: "Message to #project-x about retries",
                       body: "Heads-up @here: we’re capping payment client retries at **3** with exponential backoff. It ships with Thursday’s deploy; PX-481 has the details.",
                       fields: ["to": "#project-x"], why: "The channel needs a heads-up before the deploy changes retry behaviour.",
                       source: note("Auth retry bug", "Let #project-x know we’re capping payment client retries at 3 before Thursday’s deploy.", job: "job-auth"),
                       createdAt: at(11, 24), updatedAt: at(16, 2), draftModel: "Sonnet",
                       events: [ActionEvent(at: at(11, 24), event: "found", detail: "Sonnet"), ActionEvent(at: at(11, 25), event: "drafted", detail: "Sonnet"),
                                ActionEvent(at: at(16, 2), event: "removed", detail: "ready")]),
            todo("h2", "Book the tasting room for Saturday", due: day(0), priority: "Medium", person: "Mei Tanaka", labels: ["tea-club"],
                 source: note("Tea club planning", tea), why: "You said you would book it.", status: .done),
            ActionItem(id: "h3", type: "jira", status: .done, title: "Add an alert for retry storms", source: note("Incident review prep", "We need an alert."),
                       createdAt: at(13, 5), updatedAt: at(15, 55),
                       external: ActionExternal(key: "PX-482", url: "https://acme.atlassian.net/browse/PX-482", status: "Done", checkedAt: at(15, 55)),
                       events: [ActionEvent(at: at(15, 51), event: "created", detail: "PX-482"), ActionEvent(at: at(15, 55), event: "done", detail: "created")]),
            ActionItem(id: "h4", type: "todo", status: .sent, title: "Cap payment client retries at 3 with backoff", why: "You assigned it to yourself.",
                       source: note("Auth retry bug", auth, job: "job-auth"), createdAt: at(11, 24), updatedAt: at(15, 50),
                       events: [ActionEvent(at: at(11, 24), event: "found", detail: "Sonnet"), ActionEvent(at: at(15, 50), event: "sent-to:jira", detail: "j1"),
                                ActionEvent(at: at(15, 51), event: "created", detail: "PX-481 in Jira")]),
            ActionItem(id: "h5", type: "slack", status: .sent, title: "Message to Mei about the kyusu", body: "Could you bring the kyusu too?", fields: ["to": "Mei Tanaka"],
                       source: note("Tea club planning", tea), createdAt: at(17, 0, daysAgo: 1), updatedAt: at(18, 12, daysAgo: 1),
                       events: [ActionEvent(at: at(18, 12, daysAgo: 1), event: "sent")]),
            ActionItem(id: "h6", type: "confluence", status: .done, title: "On-call handoff checklist", source: note("Q3 architecture sync", "Publish it."),
                       createdAt: at(10, 0, daysAgo: 1), updatedAt: at(17, 40, daysAgo: 1), events: [ActionEvent(at: at(17, 40, daysAgo: 1), event: "done", detail: "ready")]),
            todo("h7", "Order tasting cups for the club", due: nil, priority: nil, person: nil, labels: ["tea-club"],
                 source: note("Tea club planning", "Order tasting cups."), why: "The club needs cups.", status: .removed)
                .with { $0.updatedAt = at(9, 14, daysAgo: 2); $0.events.append(ActionEvent(at: at(9, 14, daysAgo: 2), event: "removed", detail: "open")) },
        ]
    }

    /// A third message, already copied ("Copied" in the list).
    static let tomKim = ActionItem(id: "s3", type: "slack", status: .ready, title: "Message to Tom Kim", body: "Tom, the Q3 sync notes are in the wiki now.",
                                   fields: ["to": "Tom Kim"], why: "You said you would send him the notes.",
                                   source: note("Q3 architecture sync", "Send Tom the sync notes.", job: "job-q3"), createdAt: at(10, 2), draftModel: "Sonnet",
                                   events: [ActionEvent(at: at(10, 2), event: "found", detail: "Sonnet"), ActionEvent(at: at(15, 52), event: "copied")])

    static func pending() -> [ActionItem] {
        [todo("p1", "Book the tasting room for Saturday", due: day(0), priority: nil, person: "Mei Tanaka", labels: ["tea-club"],
              source: note("Tea club planning", tea, job: "job-new"), why: "You said you would book it.", status: .pending),
         todo("p2", "Buy the 50 g gyokuro tin", due: nil, priority: nil, person: nil, labels: ["tea"],
              source: note("Gyokuro at 60 °C", "…bring the new tin.", job: "job-new"), why: "The club runs out.", status: .pending)]
    }

    @MainActor static func load(_ e: AppModel, items: [ActionItem]? = nil, tab: String = "todo", select: String? = nil,
                     disconnected: Bool = false, slackOff: Bool = false) {
        e.actions.loadFixture(types: types(disconnected: disconnected, slackOff: slackOff), items: items ?? (live() + history()))
        e.actions.tab = tab
        if let select { e.actions.selected[tab] = select }
        // The canvas site: "acme.atlassian.net · connected", or acme named while not connected.
        e.settingsUI.connections = [ConnectionInfo(id: "atlassian", label: "Atlassian", status: disconnected ? .notConnected : .connected,
                                                   site: "https://acme.atlassian.net", account: disconnected ? nil : "Jin Liu")]
    }
}

extension ActionItem {
    func with(_ edit: (inout ActionItem) -> Void) -> ActionItem { var c = self; edit(&c); return c }
}

// MARK: - Flow 6: Actions

extension StatesSnapshot {
    static func actionsStates() {
        actionsTodoStates()
        actionsSlackStates()
        actionsExternalStates()
        actionsHistoryStates()
        actionsAskStates()
    }

    private static func actionsEngine(items: [ActionItem]? = nil, tab: String = "todo", select: String? = nil,
                                      disconnected: Bool = false, slackOff: Bool = false) -> AppModel {
        let e = engine()
        ActionFixtures.load(e, items: items, tab: tab, select: select, disconnected: disconnected, slackOff: slackOff)
        return e
    }

    static func actionsTodoStates() {
        let f = Flow.actions
        func todo(_ file: String, _ state: String, _ desc: String, _ e: AppModel, ui: TodoUI = TodoUI(), defaults: [String: Any] = [:],
                  size: CGSize = mainSize) {
            main(file, f, "Actions · To do", state, desc, e, section: .actions, defaults: defaults, size: size) {
                TodoScreen(store: e.actions, ui: ui)
                    .overlay(alignment: .bottom) {
                        if let toast = e.actions.toast { ActionToastView(toast: toast, openHistory: {}, dismiss: {}) }
                    }
            }
        }
        var e = actionsEngine(select: "t2")
        todo("actions-todo", "Grouped by due date, one open", "Overdue / Today / This week / No due date; the open to-do's fields, context and Complete / Send to.", e)

        e = actionsEngine(select: "t1")
        todo("actions-todo-sendto", "Send to", "Send to ▾ lists the types that are on (Jira suggested), Email disabled as Coming later.", e,
             ui: TodoUI(menu: "sendto"))

        e = actionsEngine()
        var ui = TodoUI(); ui.filter.labels = ["project-x"]; ui.selection = ["t1", "t3", "t4"]
        todo("actions-todo-select", "Select several", "Checkboxes and one bar: Complete, Due date, Priority, Label, Send to, Remove, Clear.", e, ui: ui)

        e = actionsEngine(select: "t1")
        todo("actions-todo-by-note", "Grouped by source note", "Group by Source note: every to-do from one note together.", e,
             defaults: ["distill.todo.group": "note", "distill.todo.sort": "title"])

        e = actionsEngine(select: "t2")
        ui = TodoUI(); ui.filter.due = [.today]; ui.panel = "due"; ui.inlinePanel = true
        todo("actions-todo-filter-due", "Filter: due date", "One Filter panel for every filter; choosing Due: Today adds a chip and the list updates as you pick.", e, ui: ui)

        e = actionsEngine(select: "t1")
        ui = TodoUI(); ui.filter.people = ["You (Jin Liu)"]; ui.filter.labels = ["project-x"]
        todo("actions-todo-filter-person", "Two filters set", "Filter · 2 and one chip each; × clears it, clicking a chip opens the panel at its section.", e, ui: ui)

        e = actionsEngine(select: "t4")
        ui = TodoUI(); ui.filter.status = .all; ui.filter.due = [.thisWeek]; ui.filter.people = ["You (Jin Liu)"]; ui.filter.labels = ["project-x", "tea"]
        todo("todo-frame-7", "Narrow window (900 pt)", "Still one line: chips that don't fit collapse into +N, which opens the Filter panel.", e, ui: ui,
             size: CGSize(width: 900, height: 760))

        e = actionsEngine(select: "t2")
        ui = TodoUI(); ui.panel = ""; ui.inlinePanel = true
        todo("todo-card-filter-menu", "Filter menu", "Status (Open is the default and shows no chip), Due, Person with search, Label, Source note, Priority, More.", e, ui: ui)

        e = actionsEngine(select: "t1")
        ui = TodoUI(); ui.filter.people = ["You (Jin Liu)"]; ui.filter.labels = ["project-x"]; ui.panel = "person"; ui.inlinePanel = true
        todo("todo-card-opened-from-a-chip", "Opened from a chip", "Clicking “Person: You ×” opens the panel at PERSON, its heading in blue.", e, ui: ui)

        e = actionsEngine(items: ActionFixtures.live() + ActionFixtures.history(), select: "t1")
        ui = TodoUI(); ui.filter.status = .all
        todo("todo-card-status-all-shows-a", "Status: All shows a chip", "Any status other than Open is a chip; Clear all returns to Status: Open.", e, ui: ui)

        e = actionsEngine(select: "t2")
        ui = TodoUI(); ui.panel = "more"; ui.inlinePanel = true
        todo("actions-todo-more", "More filters", "MORE: added by, vault (and this batch's notes when opened from a job).", e, ui: ui)

        e = actionsEngine(select: "t2")
        todo("actions-todo-group-sort", "Group and sort", "Group by due (default), note, label, person, priority, created or none; sort inside groups.", e, ui: TodoUI(menu: "group"))

        e = actionsEngine(select: "t6")
        ui = TodoUI(); ui.filter.text = "tin"
        todo("actions-todo-search", "Search", "“tin” matches a title and a note excerpt; the excerpt line is shown.", e, ui: ui)

        e = actionsEngine(select: "t2")
        todo("actions-todo-add", "Add by hand", "A new row at the top; only the title is needed. ↩ adds, Esc cancels.", e,
             ui: TodoUI(adding: NewTodo(title: "Order more 180 ml kyusu lids", due: ActionFixtures.day(1), labels: ["tea"])))

        e = actionsEngine(select: "t2")
        todo("actions-todo-edit", "Edit", "Every field editable in place; saved as you type; Done.", e, ui: TodoUI(editing: true))

        e = actionsEngine(select: "t1")
        e.actions.toast = ActionToast(text: "Completed", undo: {})
        todo("actions-todo-complete", "Complete", "Struck through for 2 seconds, then to History; Undo or ⌘Z.", e, ui: TodoUI(completing: ["t2"]))

        e = actionsEngine(items: ActionFixtures.live().filter { $0.id != "t2" } + ActionFixtures.history(), select: "t1")
        e.actions.toast = ActionToast(text: "Removed “Book the tasting room for Saturday”", undo: {}, history: true)
        todo("actions-todo-remove", "Remove", "Taken out without asking; Undo, History.", e)

        e = actionsEngine(items: ActionFixtures.live().filter { $0.id != "t1" } + ActionFixtures.history(), select: "t2")
        e.actions.toast = ActionToast(text: "Moved to Jira tickets as a draft", undo: {}, open: {})
        todo("actions-todo-sent", "Sent to an action type", "The to-do leaves To do and lives in Jira tickets; Undo, Open.", e)

        e = actionsEngine(items: ActionFixtures.live().filter { $0.type != "todo" })
        todo("actions-todo-empty", "Nothing to do", "Empty To do: Add to-do, History. The Actions total still counts drafts.", e)

        e = actionsEngine(items: ActionFixtures.live() + [ActionFixtures.history()[1].with { $0.title = "Descale the kettle"; $0.labels = ["tea"] }])
        ui = TodoUI(); ui.filter.text = "kettle"; ui.filter.labels = ["tea"]
        todo("actions-todo-no-match", "No match for the filters", "Names the filters, Clear filters, and that 1 completed to-do matches.", e, ui: ui)

        e = actionsEngine(select: "t1")
        var finding = historyJobs(e).first { $0.state == .completed } ?? job(e, "job-tea", .completed, files: ["inbox/a.md", "inbox/b.md"], minutesAgo: 2)
        finding.actionsFound = JobActionsSummary(status: "finding", model: "sonnet")
        e.jobs = [finding]
        e.progress[finding.id] = CoreProgress(key: finding.id, kind: "batch", message: "Finding actions in 2 notes",
                                              steps: ["Moved to inbox", "Read sources", "Applied changes", "Finding actions", "Done"], stepIndex: 3,
                                              startedAt: ActionFixtures.at(15, 43), model: "sonnet")
        todo("actions-todo-finding", "Finding actions after a batch", "A strip names the model, the notes and the start time.", e)

        e = engine()
        e.actions.types = ActionFixtures.types
        e.actions.phase = .loading
        todo("actions-todo-first-load", "First load", "Shimmer rows before the core answers, never an empty state.", e)

        e = actionsEngine(select: "t1")
        var failed = job(e, "job-failed", .completed, files: ["inbox/tea-club-planning.md"], minutesAgo: 3)
        failed.actionsFound = JobActionsSummary(status: "failed", error: "Claude Code isn’t signed in.")
        e.jobs = [failed]
        todo("actions-todo-error", "Couldn't find actions", "What failed, what is safe, Try again and Settings.", e)

        e = actionsEngine(items: ActionFixtures.live() + ActionFixtures.pending(), select: "t3")
        todo("actions-todo-to-confirm", "To confirm", "Found items wait at the top with Add and ×, Add all and Dismiss all.", e)

        // Add as at confirm time (actions.md): the menu, the Slack panel prefilled, and a required field left empty.
        func addAs(_ open: (AppModel) -> Void) -> AppModel {
            var items = ActionFixtures.live() + ActionFixtures.pending()
            if let i = items.firstIndex(where: { $0.id == "p1" }) {
                items[i].title = "Tell Mei the tasting room is booked for Saturday"
                items[i].summary = "Mei brings the tea for the club. You booked the tasting room for Saturday at 2 PM and said you would tell her."
            }
            let e = actionsEngine(items: items, select: "p1")
            e.actions.types = ScriptActionFixtures.types
            e.actions.fixtureInlineMenus = true
            open(e)
            return e
        }
        e = addAs { $0.actions.addAsMenu = "p1" }
        todo("actions-confirm-addas-menu", "Add as…", "Dismiss | Add as to-do ▾: the menu lists To-do first, then the types with a handler or button, each with what happens.", e)

        e = addAs { e in
            if let item = e.actions.items["p1"], let slack = e.actions.type("slack") { e.actions.addingAs["p1"] = AddAs.prefill(item, as: slack) }
        }
        todo("actions-confirm-addas-slack", "Add as Slack message", "The panel, prefilled: title, To from the person, the summary as the text; Who is Mei Tanaka in Slack? right there.", e)

        e = addAs { e in
            if let item = e.actions.items["p1"], let slack = e.actions.type("slack") {
                var draft = AddAs.prefill(item, as: slack)
                draft.fields["to"] = "Vladan Dimitrijevic"
                e.actions.addingAs["p1"] = draft
            }
        }
        todo("actions-confirm-addas-blocked", "A required field empty", "Add as Slack message to a name Distill doesn't know: Who is Vladan Dimitrijevic in Slack?, Cancel · Fill in who it goes to · Add as Slack message (off).", e)

        e = actionsEngine(select: "t2")
        e.actions.toast = ActionToast(text: "Added 2 to-dos and created 1 draft from Tea club planning", undo: {})
        todo("actions-todo-auto-added", "Added without confirming", "Confirm off: items are added at once; Undo dismisses them.", e)

        e = engine()
        e.actions.phase = .unavailable
        main("actions-update-core", f, "Actions", "Old core", "A core without the Actions routes: a calm Update state, never a crash.", e, section: .actions) {
            ActionsScreen()
        }

        e = actionsEngine()
        main("actions-sidebar-collapsed", f, "Sidebar", "Actions collapsed", "Closed, Actions shows the total of its sub-items (6 + 1 + 1 + 1).", e, section: .queue) {
            QueueView()
        }
        e = actionsEngine()
        main("actions-sidebar-history", f, "Sidebar", "History › Actions", "History's sub-items Jobs, Ask chats and Actions replace its tabs.", e, section: .history,
             historyPart: .actions) {
            HistorySection(selectedJob: .constant(nil), part: .actions)
        }
    }

    static func actionsSlackStates() {
        let f = Flow.actions
        func slack(_ file: String, _ state: String, _ desc: String, _ e: AppModel) {
            main(file, f, "Actions · Slack messages", state, desc, e, section: .actions) { ActionsScreen() }
        }
        func typed(_ file: String, _ tab: String, _ screen: String, _ state: String, _ desc: String, _ e: AppModel, ui: TypeListUI = TypeListUI()) {
            typedState(file, tab, screen, state, desc, e, ui: ui)
        }
        var e = actionsEngine(tab: "slack")
        slack("actions-slack", "Ready and not written", "A message ready to paste; one written only when you ask (Create message).", e)

        e = actionsEngine(tab: "slack")
        e.actions.items["s1"]?.previousBody = "Hi @Mei, booked the tasting room for Saturday at 2 PM - could you bring the new gyokuro tin and the kyusu to"
        e.actions.items["s1"]?.body = "Hi @Mei, I booked the tasting room for **Saturday at 2 PM**. Could you bring the new gyokuro tin and the kyusu too?"
        e.actions.items["s1"]?.events.append(ActionEvent(at: ActionFixtures.at(15, 51), event: "improved", detail: "fixed grammar and punctuation"))
        e.actions.justImproved = ["s1"]
        e.actions.running["s2"] = .drafting(Date())
        slack("actions-slack-improved", "Polished with Undo; writing", "Improved by Sonnet with Undo ⌘Z and Show changes; below, Writing with Sonnet… Cancel.", e)

        e = actionsEngine(tab: "slack")
        e.actions.items["s1"]?.previousBody = "Hi @Mei, booked the tasting room for Saturday at 2 PM - could you bring the new gyokuro tin and the kyusu to"
        e.actions.items["s1"]?.body = "Hi @Mei, I booked the tasting room for **Saturday at 2 PM**. Could you bring the new gyokuro tin and the kyusu too?"
        e.actions.showingChanges = ["s1"]
        slack("actions-slack-changes", "Show changes", "What the improve pass changed, removed and added.", e)

        e = actionsEngine(tab: "slack")
        e.actions.editing["s1"] = ActionEditDraft(title: "Message to Mei", body: "Hi @Mei, booked the tasting room for **Saturday at 2 PM** - could you bring the new gyokuro tin and the kyusu to",
                                                  fields: ["to": "Mei Tanaka"])
        slack("actions-slack-editing", "Editing", "The shared Markdown editor with the compact style bar; Done (⌘↩) polishes with Sonnet.", e)

        e = actionsEngine(tab: "slack")
        e.actions.items["s1"]?.body = "Hi @Mei, booked the tasting room for **Saturday at 2 PM** - could you bring the new gyokuro tin and the kyusu to"
        e.actions.running["s1"] = .improving(Date())
        slack("actions-slack-polishing", "Polishing", "The text dims with a shimmer; Polishing with Sonnet… Cancel keeps your version.", e)

        e = actionsEngine(tab: "slack")
        e.actions.copiedAt["s1"] = ActionFixtures.at(15, 52)
        e.actions.copiedFlash = ["s1"]
        slack("actions-slack-copied", "Copied", "Copied for 2 seconds; copying isn't sending: Mark as sent / Not yet.", e)

        e = actionsEngine(tab: "slack")
        e.actions.items["s1"]?.fields["to"] = "Mei Tanaka"
        main("actions-slack-recipient", f, "Actions · Slack messages", "Recipient", "Click the recipient to pick another or type someone else.", e, section: .actions) {
            MessageRecipientSnapshot(store: e.actions)
        }

        e = actionsEngine(items: ActionFixtures.live().filter { $0.id != "s1" }, tab: "slack")
        e.actions.toast = ActionToast(text: "Removed the message to Mei", undo: {}, history: true)
        slack("actions-slack-removed", "Removed", "Out of the list at once; Undo, History.", e)

        e = actionsEngine(items: ActionFixtures.live().filter { $0.id != "s1" }, tab: "slack")
        e.actions.toast = ActionToast(text: "Message to Mei marked as sent", undo: {}, history: true)
        slack("actions-slack-sent", "Marked as sent", "It leaves the list and goes to History as Sent.", e)

        e = actionsEngine(tab: "slack", slackOff: true)
        slack("actions-slack-off", "Turned off", "What a link to a type that is off opens: its items are to-dos now; Open Settings.", e)

        // v57: list plus detail, ActionRow hover, Complete, empty and no-results.
        e = actionsEngine(items: ActionFixtures.live() + [ActionFixtures.tomKim], tab: "slack", select: "s1")
        e.actions.toast = ActionToast(text: "Completed", undo: {})
        typed("slack-frame-2", "slack", "Actions · Slack messages", "Hover: Complete and ⋯", "Hovering a row shows ✓ Complete and ⋯; Complete moves it to History (toast: Completed · Undo).",
              e, ui: TypeListUI(hover: "s3"))

        e = actionsEngine(items: ActionFixtures.live().filter { $0.type != "slack" }, tab: "slack")
        slack("slack-frame-3", "Empty", "No Slack messages to send: one primary action, Open To do.", e)

        e = actionsEngine(items: ActionFixtures.live() + [ActionFixtures.tomKim], tab: "slack")
        var tl = TypeListUI(); tl.filter.toggle("status", "Ready to paste"); tl.filter.toggle("label", "#tea")
        typed("slack-frame-4", "slack", "Actions · Slack messages", "No results for the filters", "Names the filters; Clear filters.", e, ui: tl)

        e = actionsEngine(items: ActionFixtures.live() + [ActionFixtures.tomKim], tab: "slack", select: "s2")
        e.actions.completing = ["s1"]
        e.actions.toast = ActionToast(text: "Completed", undo: {})
        typed("slack-card-completed", "slack", "Actions · Slack messages", "Completed", "Struck through, then it moves to History as Completed; Undo brings it back.", e)

        e = actionsEngine(items: ActionFixtures.live() + [ActionFixtures.tomKim], tab: "slack", select: "s1")
        tl = TypeListUI(); tl.panel = ""; tl.inlinePanel = true; tl.filter.toggle("status", "Ready to paste")
        typed("actions-slack-filter", "slack", "Actions · Slack messages", "Filter panel", "kind slack: Status, Recipient, Source note, Label.", e, ui: tl)
    }

    static func actionsExternalStates() {
        let f = Flow.actions
        func ext(_ file: String, _ tab: String, _ state: String, _ desc: String, _ e: AppModel) {
            main(file, f, tab == "jira" ? "Actions · Jira tickets" : "Actions · Confluence pages", state, desc, e, section: .actions) { ActionsScreen() }
        }
        var e = actionsEngine(tab: "jira", select: "j1")
        ext("actions-jira", "jira", "Drafts and created", "Drafts you check, and tickets already created with their status.", e)

        e = actionsEngine(tab: "jira", select: "j1", disconnected: true)
        e.actions.items["j1"]?.error = ActionError(code: "not_connected", message: "Not connected")
        ext("actions-jira-not-connected", "jira", "Not connected", "The draft waits; Set up connection opens Settings → Connections to paste an API token.", e)

        e = actionsEngine(tab: "jira", select: "j2")
        ext("actions-jira-not-written", "jira", "Not written yet", "Write draft fills it in; nothing is sent to Jira.", e)

        e = actionsEngine(tab: "jira", select: "j1")
        e.actions.items["j1"]?.status = .drafting
        ext("actions-jira-writing", "jira", "Writing the draft", "Names the model and can be cancelled; Create waits.", e)

        e = actionsEngine(tab: "jira", select: "j1")
        e.actions.editing["j1"] = ActionEditDraft(title: "Cap payment client retries at 3 with exponential backoff",
                                                  body: "## Why\nINC-212 retry storm, retries are unbounded\n## What to do\n- cap at 3, backoff 200ms\n- add jitter",
                                                  fields: ["project": "PX · Project X", "issueType": "Task", "priority": "High", "assignee": "You (Jin Liu)"])
        ext("actions-jira-editing", "jira", "Editing", "Fields become editable; the description uses the shared Markdown editor with the compact bar.", e)

        e = actionsEngine(tab: "jira", select: "j1")
        e.actions.items["j1"]?.body = "## Why\nINC-212 retry storm, retries are unbounded\n## What to do\n- cap at 3, backoff 200ms\n- add jitter"
        e.actions.running["j1"] = .improving(Date())
        ext("actions-jira-improving", "jira", "Improving", "Improving with Sonnet… Cancel keeps your edit.", e)

        e = actionsEngine(tab: "jira", select: "j1")
        e.actions.items["j1"]?.previousBody = "## Why\nINC-212 retry storm, retries are unbounded\n## What to do\n- cap at 3, backoff 200ms\n- add jitter"
        e.actions.items["j1"]?.events.append(ActionEvent(at: ActionFixtures.at(15, 51), event: "improved", detail: "clearer sentences, added Done when"))
        e.actions.justImproved = ["j1"]
        ext("actions-jira-improved", "jira", "Improved, with Undo", "Changes tinted; Undo ⌘Z and Show changes.", e)

        e = actionsEngine(tab: "jira", select: "j1")
        e.actions.running["j1"] = .creating(Date())
        ext("actions-jira-creating", "jira", "Creating in Jira", "Locked while it runs; it can't be cancelled halfway.", e)

        e = actionsEngine(tab: "jira", select: "j3")
        ext("actions-jira-created", "jira", "Created", "Key, link, status from Jira with its clock time, Refresh; Complete, then Open in Jira.", e)

        e = actionsEngine(tab: "jira", select: "j1", disconnected: true)
        e.actions.items["j1"]?.error = ActionError(code: "auth_expired", message: "It expired on Sep 30 at 6:00 PM.")
        ext("actions-jira-expired", "jira", "Sign-in expired", "Update the token (Settings → Connections), plus Retry.", e)

        e = actionsEngine(tab: "jira", select: "j1")
        e.actions.items["j1"]?.error = ActionError(code: "not_connected", message: "Not connected")
        ext("actions-jira-signed-in", "jira", "Signed in → Retry", "Connected in Settings meanwhile: Retry finishes what you started.", e)

        e = actionsEngine(tab: "jira", select: "j1")
        e.actions.items["j1"]?.error = ActionError(code: "refused", message: "Component is required in project PX.", field: "component")
        ext("actions-jira-refused", "jira", "Jira refused it", "Its reason in plain words, and the field to fix is marked.", e)

        e = actionsEngine(tab: "jira", select: "j1")
        e.actions.items["j1"]?.error = ActionError(code: "unreachable", message: "offline")
        ext("actions-jira-unreachable", "jira", "Can't reach Jira", "Nothing was created, the draft is safe, Retry.", e)

        e = actionsEngine(items: ActionFixtures.live().filter { $0.id != "j1" }, tab: "jira", select: "j2")
        e.actions.toast = ActionToast(text: "Removed the jira ticket draft", undo: {}, history: true)
        ext("actions-jira-removed", "jira", "Removed", "Removing a draft; a created ticket stays in Jira.", e)

        e = actionsEngine(items: ActionFixtures.live().filter { $0.id != "j3" }, tab: "jira", select: "j1")
        e.actions.toast = ActionToast(text: "PX-482 is Done in Jira. Moved to History.", undo: {}, history: true)
        ext("actions-jira-done", "jira", "Done in Jira", "Done there (or Complete): it leaves the list for History.", e)

        e = actionsEngine(tab: "confluence", select: "c1")
        ext("actions-confluence", "confluence", "Drafts and created", "Space and parent page; Create in Confluence only on your click.", e)

        e = actionsEngine(tab: "confluence", select: "c1", disconnected: true)
        e.actions.items["c1"]?.error = ActionError(code: "not_connected", message: "Not connected")
        ext("actions-confluence-not-connected", "confluence", "Not connected", "One Atlassian connection covers Jira and Confluence.", e)

        e = actionsEngine(tab: "confluence", select: "c3")
        ext("actions-confluence-created", "confluence", "Created", "A link to the published page until you complete it.", e)

        // File names are the schema's state ids (design/screens/actions.json).
        let ids: [(tab: String, things: String, empty: String, hover: String, noMatch: String, completed: String, filter: String)] = [
            ("jira", "tickets", "jira-frame-3", "jira-frame-5", "jira-frame-6", "jira-card-completed", "actions-jira-filter"),
            ("confluence", "pages", "confluence-frame-3", "confluence-frame-5", "confluence-frame-6", "confluence-card-completed", "actions-confluence-filter"),
        ]
        for (tab, things, emptyID, hoverID, noMatchID, completedID, filterID) in ids {
            let screen = tab == "jira" ? "Actions · Jira tickets" : "Actions · Confluence pages"
            let created = tab == "jira" ? "j3" : "c3"
            e = actionsEngine(items: ActionFixtures.live().filter { $0.type != tab }, tab: tab, disconnected: true)
            ext(emptyID, tab, "Not connected, nothing yet", "Set up connection in the toolbar and in the empty state; it opens Settings → Connections. There is no Connecting state.", e)

            e = actionsEngine(tab: tab, select: tab == "jira" ? "j1" : "c1")
            e.actions.toast = ActionToast(text: "Completed", undo: {})
            typedState(hoverID, tab, screen, "Hover: Complete and ⋯", "On drafts and created \(things) alike; completing a created one doesn't change it in \(tab == "jira" ? "Jira" : "Confluence").",
                       e, ui: TypeListUI(hover: created))

            e = actionsEngine(tab: tab)
            var tl = TypeListUI(); tl.filter.toggle("status", "Draft"); tl.filter.toggle(tab == "jira" ? "project" : "space", "Operations")
            typedState(noMatchID, tab, screen, "No results for the filters", "Names the filters; Clear filters.", e, ui: tl)

            e = actionsEngine(tab: tab, select: tab == "jira" ? "j1" : "c1")
            e.actions.completing = [created]
            e.actions.toast = ActionToast(text: "Completed", undo: {})
            typedState(completedID, tab, screen, "Completed", "Complete on a created item leaves it as it is there; it goes to History as Completed, with Restore.", e)

            e = actionsEngine(tab: tab, select: tab == "jira" ? "j1" : "c1")
            tl = TypeListUI(); tl.panel = ""; tl.inlinePanel = true
            typedState(filterID, tab, screen, "Filter panel", tab == "jira" ? "kind jira: Status, Project, Type, Priority, Assignee, Source note." : "kind confluence: Status, Space, Source note.", e, ui: tl)
        }
    }

    /// A handler tab with its UI state set (panel open, a row hovered, filters).
    static func typedState(_ file: String, _ tab: String, _ screen: String, _ state: String, _ desc: String, _ e: AppModel,
                           ui: TypeListUI = TypeListUI(), size: CGSize = mainSize) {
        main(file, Flow.actions, screen, state, desc, e, section: .actions, size: size) {
            if let type = e.actions.type(tab) {
                TypeListScreen(store: e.actions, type: type, ui: ui)
                    .overlay(alignment: .bottom) {
                        if let toast = e.actions.toast { ActionToastView(toast: toast, openHistory: {}, dismiss: {}) }
                    }
            }
        }
    }

    static func actionsHistoryStates() {
        let f = Flow.actions
        func history(_ file: String, _ state: String, _ desc: String, _ e: AppModel, ui: ActionsHistoryUI = ActionsHistoryUI()) {
            main(file, f, "History · Actions", state, desc, e, section: .history, historyPart: .actions) {
                ActionsHistoryContent(store: e.actions, ui: ui)
            }
        }
        var e = actionsEngine()
        e.actions.selectedHistory = "h1"
        history("actions-history", "A removed message", "ActionRows by day; hovering a completed ticket shows Restore and ⋯; the removed message with its timeline, Restore, Delete forever.", e,
                ui: ActionsHistoryUI(hover: "h3"))

        e = actionsEngine()
        e.actions.selectedHistory = "h4"
        history("actions-history-sent", "A sent to-do", "Its whole path and where it lives now; no Restore.", e)

        e = actionsEngine()
        e.actions.selectedHistory = "h1"
        var ui = ActionsHistoryUI(); ui.filter.toggle("outcome", "Removed"); ui.panel = "outcome"; ui.inlinePanel = true
        history("actions-history-filter", "Filter: outcome", "The same Filter panel: TYPE, OUTCOME (Completed, Sent, Created, Removed, Dismissed), DATE presets, SOURCE.", e, ui: ui)

        e = actionsEngine()
        ui = ActionsHistoryUI(); ui.filter.toggle("outcome", "Dismissed"); ui.filter.toggle("date", "This week")
        history("history-card-no-results-for-the", "No results for the filters", "Names the filters; Clear filters goes back to everything.", e, ui: ui)

        e = actionsEngine(items: ActionFixtures.live() + ActionFixtures.history().filter { $0.id != "h1" })
        history("actions-history-restored", "Restored", "Restored to Slack messages · Open.", e,
                ui: ActionsHistoryUI(notice: .restored(id: "s2", to: "Slack messages")))

        e = actionsEngine(items: ActionFixtures.live() + ActionFixtures.history().filter { $0.id != "h1" })
        history("actions-history-note-gone", "Restore when the note is gone", "Says what is missing and keeps the quoted lines.", e,
                ui: ActionsHistoryUI(notice: .noteGone(note: "Auth retry bug")))

        e = actionsEngine(slackOff: true)
        e.actions.selectedHistory = "h1"
        history("actions-history-type-off", "Restore when the type is off", "Restore as a to-do, or turn Slack messages on.", e,
                ui: ActionsHistoryUI(notice: .typeOff(id: "h1", type: "slack")))

        e = actionsEngine()
        e.actions.selectedHistory = "h1"
        history("actions-history-delete", "Delete forever", "The only step in Actions that asks first.", e, ui: ActionsHistoryUI(confirmDelete: "h1"))

        e = actionsEngine(items: ActionFixtures.live())
        history("actions-history-empty", "Nothing in History yet", "Empty History → Actions.", e)

        e = actionsEngine()
        var done = job(e, "job-tea", .completed, files: ["inbox/tea-club-planning.md", "inbox/auth-retry-bug.md"], minutesAgo: 4)
        done.changedPaths = changePaths
        done.actionsFound = JobActionsSummary(status: "done", found: 5, pending: 5, byType: ["todo": 3, "slack": 1, "jira": 1], model: "Sonnet")
        e.jobs = [done]
        main("actions-history-job", f, "History · Jobs", "Job found actions", "The finished job: “Found 5 actions to confirm · 3 to-dos, 1 Slack message, 1 Jira ticket” with Review them.",
             e, section: .history, job: done.id) {
            HistorySection(selectedJob: .constant(done.id))
        }
        e = actionsEngine()
        var findingJob = job(e, "job-tea", .completed, files: ["inbox/tea-club-planning.md", "inbox/auth-retry-bug.md"], minutesAgo: 1)
        findingJob.changedPaths = changePaths
        findingJob.actionsFound = JobActionsSummary(status: "finding", model: "sonnet")
        e.jobs = [findingJob]
        main("actions-history-job-finding", f, "History · Jobs", "Job finding actions", "While the last step runs: the loading pattern with the model and start time.",
             e, section: .history, job: findingJob.id) {
            HistorySection(selectedJob: .constant(findingJob.id))
        }
    }
}

/// The Slack card with its recipient picker open (snapshots).
struct MessageRecipientSnapshot: View {
    @ObservedObject var store: ActionsStore
    var body: some View {
        VStack(alignment: .leading) {
            if let type = store.type("slack"), let item = store.items["s1"] {
                MessageCard(store: store, type: type, item: item, menu: "to").frame(maxWidth: 876)
            }
            Spacer()
        }
        .padding(32)
    }
}

// MARK: - Actions from Ask answers

extension ActionFixtures {
    static let askAnswer = "For the tea club, you said you’d **book the tasting room for Saturday** and tell Mei so she can bring the new tin [1]. For Project X, the INC-212 review is Friday and the write-up isn’t in Confluence yet [2]; the retry cap still needs a ticket in PX [3]."

    static func askSource(_ quote: String, gap: Bool = false) -> ActionSource {
        .ask(conversationID: "c9", question: "What do I still owe the tea club and Project X before Friday?", quote: quote,
             citedPaths: ["wiki/notes/Tea club planning.md"], turnIndex: 0, gap: gap)
    }

    static func askItems(_ status: ActionStatus = .pending) -> [ActionItem] {
        let found = [ActionEvent(at: at(15, 12), event: "found", detail: "Sonnet")]
        return [
            ActionItem(id: "a1", type: "todo", status: status, title: "Book the tasting room for Saturday", why: "You said you would book it",
                       source: askSource("you’d book the tasting room for Saturday"), createdAt: at(15, 12), events: found),
            ActionItem(id: "a2", type: "slack", status: status, title: "Tell Mei the room is booked and ask her to bring the tin", fields: ["to": "Mei Tanaka"],
                       why: "Mei is bringing the tea; she needs the time", source: askSource("tell Mei so she can bring the new tin"), createdAt: at(15, 12), events: found),
            ActionItem(id: "a3", type: "confluence", status: status, title: "Incident review: INC-212 auth retry storm",
                       fields: ["space": "Project X", "parent": "Incident reviews"], why: "The review is Friday and no page exists yet",
                       source: askSource("the write-up isn’t in Confluence yet"), createdAt: at(15, 12), events: found),
            ActionItem(id: "a4", type: "jira", status: status, title: "Cap payment client retries at 3 with backoff", fields: ["project": "PX · Project X"],
                       why: "The note says it needs a ticket in PX", source: askSource("the retry cap still needs a ticket in PX"), createdAt: at(15, 12), events: found),
        ]
    }

    @MainActor static func askThread(_ thread: AskThread, answer: String = askAnswer,
                                     question: String = "What do I still owe the tea club and Project X before Friday?", gaps: [String] = []) {
        thread.reset(filter: AskFilter())
        thread.conversationID = "c9"
        thread.selection = ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "medium")
        let response = AskResponse(conversationID: "c9", answer: answer,
                                   citations: [AskCitation(n: 1, path: "wiki/notes/Tea club planning.md", title: "Tea club planning"),
                                               AskCitation(n: 2, path: "wiki/notes/Incident review prep.md", title: "Incident review prep"),
                                               AskCitation(n: 3, path: "wiki/notes/Auth retry bug.md", title: "Auth retry bug")],
                                   gaps: gaps, selection: thread.selection)
        thread.entries = [AskEntry(question: question, askedAt: at(15, 12), request: AskRequest(question: question, conversationID: "c9"),
                                   response: response, duration: 6)]
    }
}

extension StatesSnapshot {
    static func actionsAskStates() {
        let f = Flow.actions
        func ask(_ file: String, _ state: String, _ desc: String, items: [ActionItem], _ setup: (AppModel) -> Void = { _ in }) {
            let e = engine()
            ActionFixtures.load(e, items: ActionFixtures.live() + items)
            ActionFixtures.askThread(e.ask.main)
            setup(e)
            main(file, f, "Actions · from Ask answers", state, desc, e, section: .ask) { AskScreen() }
        }
        ask("actions-ask-found", "Found: confirm each one", "Found in this answer: where each goes, what it says and why; Add or Create draft, ×, Add all.",
            items: ActionFixtures.askItems())
        ask("actions-ask-by-hand", "Add or send by hand", "Nothing detected: Add to to-do ▾ / Send to ▾ for the whole answer; selected text is a later step.",
            items: []) { $0.actions.fixtureAnswerMenu = true }
        ask("actions-ask-detecting", "Detecting", "Looking for actions in this answer… with Sonnet; shimmer holds the place.", items: []) { e in
            e.progress["actions:c9"] = CoreProgress(key: "actions:c9", kind: "actions", message: "Looking for actions", startedAt: Date(), model: "sonnet")
        }
        ask("actions-ask-target", "Change where it goes", "The type label is a menu of the types that are on.",
            items: Array(ActionFixtures.askItems().prefix(2))) { $0.actions.fixtureFoundMenu = "a1" }
        ask("actions-ask-edit", "Edit before adding", "Click the text to fix it; Return adds, Esc cancels.",
            items: Array(ActionFixtures.askItems().prefix(2))) { $0.actions.fixtureFoundEdit = "a1" }
        var mixed = ActionFixtures.askItems()
        mixed[0].status = .open; mixed[0].events.append(ActionEvent(at: Date(), event: "confirmed"))
        mixed[1].status = .drafting; mixed[1].events.append(ActionEvent(at: Date(), event: "confirmed"))
        mixed[2].status = .ready; mixed[2].events.append(ActionEvent(at: Date(), event: "confirmed"))
        ask("actions-ask-added", "Adding and added", "Each row turns into where it went, with Open; a draft being written says so.", items: mixed)
        var dismissed = ActionFixtures.askItems()
        dismissed[0].status = .open; dismissed[0].events.append(ActionEvent(at: Date(), event: "confirmed"))
        dismissed[1].status = .dismissed; dismissed[2].status = .dismissed
        ask("actions-ask-dismissed", "Dismissed", "Dismissed rows fold into one faded line with Undo.", items: dismissed)
        let all = ActionFixtures.askItems().map { i in i.with { $0.status = $0.type == "todo" ? .open : .ready; $0.events.append(ActionEvent(at: Date(), event: "confirmed")) } }
        ask("actions-ask-add-all", "Add all", "The header becomes the summary with one Undo for all of them.", items: all) {
            $0.actions.addedAll["c9#0"] = all.map(\.id)
        }
        ask("actions-ask-already", "Already there", "An item already open in Actions links to it instead of adding a copy.",
            items: Array(ActionFixtures.askItems().prefix(3))) { e in
            e.actions.already["c9"] = ["j1"]
        }
        let auto = ActionFixtures.askItems().map { i in i.with { $0.status = $0.type == "todo" ? .open : .ready } }
        ask("actions-ask-confirm-off", "Confirmation off", "Added right away: one line with Show, Undo and Open Actions.", items: auto)
        ask("actions-ask-form", "Added by hand: prefilled", "To-do from the whole answer opens a small prefilled form.", items: []) {
            $0.actions.fixtureTodoForm = NewTodo(title: "Write the INC-212 review in Confluence", due: ActionFixtures.day(1), labels: ["project-x"])
        }
        do {
            let e = engine()
            let gapItem = ActionItem(id: "g1", type: "todo", status: .pending, title: "Ask the shop for the gyokuro water temperature",
                                     why: "Your vault has no temperature for gyokuro",
                                     source: .ask(conversationID: "c9", question: "How hot should the water be?", quote: "no temperature for gyokuro",
                                                  citedPaths: [], turnIndex: 0, gap: true), createdAt: Date())
            ActionFixtures.load(e, items: ActionFixtures.live() + [gapItem])
            ActionFixtures.askThread(e.ask.main, answer: AskFixtures.answer, question: "How hot should the water be for green tea, and does it differ for gyokuro?",
                                     gaps: ["nothing in your vault on gyokuro water temperature."])
            main("actions-ask-gap", f, "Actions · from Ask answers", "Gap became an action", "The Gap callout is hidden when the gap became an action.", e, section: .ask) {
                AskScreen()
            }
        }
        // Quick ask: the same block, compact.
        for (file, state, desc, added) in [("actions-quickask-found", "Quick ask: found", "Compact: no Why line (hover shows it), no Dismiss all.", false),
                                           ("actions-quickask-added", "Quick ask: added", "Rows show where things went; Open closes the window and opens Actions.", true)] {
            let e = engine()
            var items = Array(ActionFixtures.askItems().prefix(3))
            if added {
                items[0].status = .open; items[1].status = .ready; items[2].status = .dismissed
                for i in 0..<2 { items[i].events.append(ActionEvent(at: Date(), event: "confirmed")) }
                e.actions.addedAll["c9#0"] = ["a1", "a2"]
            }
            ActionFixtures.load(e, items: ActionFixtures.live() + items)
            ActionFixtures.askThread(e.ask.quick, answer: "Book the tasting room for Saturday and tell Mei [1]. INC-212 needs a Confluence write-up [2] and the retry cap a PX ticket [3].")
            quickWindow(file, f, "Quick ask", state, desc, e, padding: 8) { QuickAskView(onDesiredHeight: $0) }
        }
    }
}
