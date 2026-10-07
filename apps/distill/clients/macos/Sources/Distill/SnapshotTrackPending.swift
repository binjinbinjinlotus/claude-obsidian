import AppKit
import SwiftUI
import DistillKit

// Track as Pending from To confirm, and Move to Pending for an added to-do (spec actions-routing.md;
// canvas board "Actions · Track as Pending"): tp-menu, tp-panel, tp-rowmenu, tp-after, tp-mine,
// tp-list-sendto and tp-list-panel, with the board's items and people.

enum TrackPendingFixtures {
    static let people = [
        ActionPerson(id: "you", name: "Jin Bin Liu", aliases: ["Jin", "@jin"]),
        ActionPerson(id: "p-aditya", name: "Aditya Pradhan", aliases: ["A", "Aditya", "@aditya"]),
        ActionPerson(id: "p-tomasz", name: "Tomasz Kowal", aliases: ["Tomasz", "@tomasz"]),
        ActionPerson(id: "p-mei", name: "Mei Tanaka", aliases: ["Mei"]),
        ActionPerson(id: "p-priya", name: "Priya Shah", aliases: ["Priya"]),
    ]
    static let testing = "Testing sync"

    static func item(_ id: String, _ title: String, type: String = "todo", status: ActionStatus = .pending, summary: String? = nil, why: String? = nil,
                     fields: [String: String] = [:], note: String, quote: String? = nil, job: String = "job-tp", route: ActionRoute? = .list,
                     owner: String? = nil, ownerID: String? = nil, owedToID: String? = nil, due: String? = nil, minute: Int = 12) -> ActionItem {
        let at = RoutingFixtures.at(30, 16, minute)
        var i = ActionItem(id: id, type: type, status: status, title: title, fields: fields, why: why,
                           source: .note(jobID: job, notePath: "wiki/sources/\(note).md", pageTitle: note, quote: quote ?? title),
                           createdAt: at, events: [ActionEvent(at: at, event: "found", detail: "Sonnet")], summary: summary)
        i.route = route; i.owner = owner; i.ownerID = ownerID; i.owedToID = owedToID; i.due = due
        return i
    }

    static let guide = item("c2", "Write the migration guide for the shared fixtures",
                            summary: "The new reusable test setup has no docs yet. Aditya owns the shared fixtures and said a migration guide would be ready by Friday; the team’s test migration waits on it.",
                            why: "Aditya said the guide would be ready by Friday. You handle to-dos for Aditya, so it is here.",
                            fields: ["due": "2026-10-09"], note: testing, quote: "A: migration guide for the fixtures, ready by Friday",
                            owner: "Aditya", ownerID: "p-aditya", minute: 50)

    static let migrate = item("c2", "Migrate all existing tests to the new reusable architecture",
                              summary: "The suite still uses the old per-feature fixtures. You and Aditya agreed to move every test onto the new reusable architecture before the Q4 release; Aditya owns the shared fixtures.",
                              why: "You said you would migrate the tests and tell Aditya when you start.",
                              fields: ["due": "2026-10-09"], note: testing, quote: "me: migrate all existing tests", owner: "me", ownerID: "you", minute: 50)

    /// To confirm (12, the board's first six), Pending (5) and Testing sync's other people.
    static func items(second: ActionItem = guide) -> [ActionItem] {
        var x1 = StatesSnapshot.ActionContextFixtures.items()[0]
        x1.id = "c1"; x1.route = .list; x1.ownerID = "you"
        x1.summary = "The payment client retried failed calls every 200 ms with no limit, which flooded the gateway in the Sep 29 incident. Tomasz and Jin agreed to cap it at 3 retries with backoff from 500 ms, then fail loudly."
        let rest: [ActionItem] = [
            item("c3", "Tell Mei the Telus cut-over moves to Oct 9", type: "slack",
                 summary: "Telus asked to move the cut-over from Oct 7 to Oct 9 because their change freeze runs late. Mei owns the launch checklist and hasn’t heard yet; you said you’d tell her today.",
                 fields: ["to": "Mei"], note: "Tomasz and Jin", owner: "me", ownerID: "you", minute: 40),
            item("c4", "Write up the Sep 29 retry storm postmortem", type: "confluence",
                 summary: "The retry storm took payments down for 41 minutes on Sep 29. Jin asked for a postmortem in the PAY space with the timeline, the 200 ms retry loop as the cause, and the retry cap as the fix.",
                 fields: ["space": "PAY"], note: "Tomasz and Jin", owner: "me", ownerID: "you", minute: 30),
            item("c5", "Send Priya the Q4 vendor budget numbers",
                 summary: "Priya needs the Q4 vendor spend split by team to finish the budget deck for the Oct 8 planning meeting.",
                 fields: ["due": "2026-10-12"], note: "Quick notes", owner: "me", ownerID: "you", minute: 20),
            item("c6", "Renew the Figma team plan before it lapses on Oct 12",
                 summary: "Figma emailed that the team plan ends on Oct 12; renewing keeps the design files shared with the agency.",
                 fields: ["due": "2026-10-12"], note: "Inbox: Figma billing", owner: "me", ownerID: "you", minute: 10),
        ] + (7...12).map { n in
            item("c\(n)", ["Book the Q4 offsite room", "Order the new test devices", "Reply to the Telus SOW comments",
                           "Review Mei’s launch checklist draft", "Update the on-call rota", "File the expense report"][n - 7],
                 note: "Quick notes", owner: "me", ownerID: "you", minute: 9 - (n - 7))
        }
        let pending = (1...5).map { n in
            item("w\(n)", ["Aditya will send you the ticket links", "Tomasz will share the retry metrics", "Mei will confirm the cut-over date",
                           "Priya will send the vendor list", "Aditya will review your fixtures PR"][n - 1],
                 status: .open, note: "Planning", job: "job-tp-0", route: .waiting, owner: ["Aditya", "Tomasz", "Mei", "Priya", "Aditya"][n - 1],
                 ownerID: ["p-aditya", "p-tomasz", "p-mei", "p-priya", "p-aditya"][n - 1], owedToID: "you")
        }
        // Testing sync: Tomasz's and Aditya's own actions (IN THIS NOTE).
        let others = [
            item("x1", "Move the CI runners to the new fixtures", status: .open, note: testing, route: .others, owner: "Tomasz", ownerID: "p-tomasz"),
            item("x2", "Publish the shared fixtures package", status: .open, note: testing, route: .others, owner: "Aditya", ownerID: "p-aditya"),
        ]
        return [x1, second] + rest + pending + others
    }

    @MainActor static func load(_ e: AppModel, items: [ActionItem], select: String) {
        SettingsEdits.setActions(&e.settings) { p in
            p.people = people
            p.setHandlesFor("todo", ["you", "p-aditya"])
        }
        e.actions.loadFixture(types: ScriptActionFixtures.types, items: [])
        for i in items { e.actions.put(i) }
        e.actions.fixtureNow = RoutingFixtures.now
        e.actions.fixtureInlineMenus = true
        e.actions.tab = "todo"
        e.actions.selected["todo"] = select
    }
}

/// The row's right-click menu as the board draws it (a native context menu isn't captured).
private struct RowMenuSketch: View {
    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            line("Add as", trailing: "▸")
            line(TrackPending.menuTitle, trailing: TrackPending.shortcut, selected: true)
            Rectangle().fill(Theme.border).frame(height: 1).padding(.horizontal, 10).padding(.vertical, 5)
            line("Dismiss", trailing: "⌫")
        }
        .padding(.vertical, 5)
        .frame(width: 250)
        .background(RoundedRectangle(cornerRadius: 9).fill(Theme.window).shadow(color: .black.opacity(0.2), radius: 16, y: 12))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.ink.opacity(0.12)))
    }

    private func line(_ title: String, trailing: String, selected: Bool = false) -> some View {
        HStack(spacing: 18) {
            Text(title).font(Theme.body(13))
            Spacer(minLength: 0)
            Text(trailing).font(Theme.body(12)).opacity(0.7)
        }
        .foregroundStyle(selected ? Theme.window : Theme.ink)
        .padding(.horizontal, 10).frame(height: 24)
        .background(RoundedRectangle(cornerRadius: 5).fill(selected ? Theme.primary : .clear))
        .padding(.horizontal, 5)
    }
}

extension StatesSnapshot {
    static func trackPendingStates() {
        let f = Flow.actions
        func shot(_ file: String, _ state: String, _ desc: String, _ e: AppModel, ui: TodoUI = TodoUI(),
                  size: CGSize = CGSize(width: 1200, height: 900), overlay: AnyView? = nil) {
            main(file, f, "Actions · Track as Pending", state, desc, e, section: .actions, size: size) {
                TodoScreen(store: e.actions, ui: ui)
                    .overlay(alignment: .topLeading) { overlay }
                    .overlay(alignment: .bottom) {
                        if let toast = e.actions.toast { ActionToastView(toast: toast, openHistory: {}, dismiss: {}) }
                    }
            }
        }
        func confirm(second: ActionItem = TrackPendingFixtures.guide) -> AppModel {
            let e = engine()
            TrackPendingFixtures.load(e, items: TrackPendingFixtures.items(second: second), select: "c2")
            return e
        }

        var e = confirm()
        e.actions.addAsMenu = "c2"
        shot("tp-menu", "A · Add as… with Track as Pending…",
             "After the types, a divider and Track as Pending… (Someone else will do it; you wait, ⇧⌥↩); the keys line adds ⇧⌥Return.", e)

        e = confirm()
        e.actions.startTrack(TrackPendingFixtures.guide)
        shot("tp-panel", "B · Track as Pending",
             "Waiting on filled with the item’s owner (Aditya Pradhan, @aditya), By from its due date; It leaves To confirm; nothing is sent; how the Pending row will read.", e)

        e = confirm()
        shot("tp-rowmenu", "C · The row’s menu", "Right-click a To confirm row: Add as ▸, Track as Pending… (⇧⌥↩), Dismiss (⌫).", e,
             overlay: AnyView(RowMenuSketch().padding(.leading, 150).padding(.top, 245)))

        e = confirm()
        var tracked = TrackPendingFixtures.guide
        tracked.route = .waiting; tracked.status = .open; tracked.owner = "Aditya Pradhan"; tracked.owedToID = "you"; tracked.due = "2026-10-09"
        e.actions.put(tracked)
        e.actions.selected["todo"] = "c3"
        e.actions.toast = ActionToast(text: TrackPending.toast(TrackPending.Draft(origin: .confirm, personID: "p-aditya", name: "Aditya Pradhan"),
                                                               people: TrackPendingFixtures.people), undo: {})
        shot("tp-after", "D · After",
             "The item leaves To confirm (12 → 11), the next row is selected, Pending 5 → 6, and “Tracked as Pending · waiting on Aditya · Undo”.", e)

        e = confirm(second: TrackPendingFixtures.migrate)
        e.actions.startTrack(TrackPendingFixtures.migrate)
        shot("tp-mine", "E · The owner is you",
             "Waiting on is empty and required, the list open on IN THIS NOTE and PEOPLE; Track as Pending is off: Fill in who you’re waiting on.", e)

        func list() -> AppModel {
            let e = engine()
            SettingsEdits.setActions(&e.settings) { p in p.people = TrackPendingFixtures.people }
            ActionFixtures.load(e, items: ActionFixtures.live(), select: "t2")
            e.actions.items["t2"]?.why = "You added it as yours, but in the note Mei says she’ll book it."
            e.actions.fixtureInlineMenus = true
            return e
        }
        e = list()
        var ui = TodoUI(); ui.menu = "sendto"
        shot("tp-list-sendto", "F · Send to on an added to-do",
             "The action types, then a divider and Move to Pending… (Someone else will do it; you wait).", e, ui: ui, size: CGSize(width: 1200, height: 960))

        e = list()
        if let t2 = e.actions.items["t2"] { e.actions.startTrack(t2) }
        shot("tp-list-panel", "G · Move to Pending",
             "The same panel in the to-do’s detail, filled with Mei Tanaka (the to-do’s person) and its due date; Cancel · Move to Pending.", e,
             size: CGSize(width: 1200, height: 960))
    }
}
