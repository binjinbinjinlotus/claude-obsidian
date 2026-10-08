import AppKit
import SwiftUI
import DistillKit

// Whose items, Pending and Highlights (spec actions-routing.md; canvas board ActionsRouting):
// settings-actions-people, actions-confirm-routed, actions-pending-list, actions-pending-detail,
// actions-highlights-list and actions-highlights-note, with the canvas's people and notes.

enum RoutingFixtures {
    static let people = [
        ActionPerson(id: "you", name: "Jin Bin Liu", aliases: ["Jin", "Jin Liu", "@jin"]),
        ActionPerson(id: "p-aditya", name: "Aditya Pradhan", aliases: ["A", "Aditya", "@aditya"]),
    ]
    /// Tuesday Oct 6, 2026, 6:12 PM: Fri is Oct 9, Mon Oct 12; Sep 30's benchmark is overdue.
    static let now: Date = {
        var c = DateComponents(); c.year = 2026; c.month = 10; c.day = 6; c.hour = 18; c.minute = 12
        return Calendar(identifier: .gregorian).date(from: c) ?? Date()
    }()
    static func at(_ day: Int, _ hour: Int = 18, _ minute: Int = 12) -> Date {
        var c = DateComponents(); c.year = 2026; c.month = day > 6 ? 9 : 10; c.day = day; c.hour = hour; c.minute = minute
        return Calendar(identifier: .gregorian).date(from: c) ?? now
    }

    static let sync = "2026-10-05 AI FE Platform Sync"
    static let vj = "2026-09-30 Vladan and Jin"
    static let guild = "2026-09-29 FE guild"

    static func source(_ title: String, _ quote: String, job: String) -> ActionSource {
        .note(jobID: job, notePath: "wiki/sources/\(title).md", pageTitle: title, quote: quote)
    }

    static func lines(_ from: Int, _ text: [String]) -> ActionContextRefs {
        ActionContextRefs(raw: ActionRawRef(path: ".raw/captured/7c1e.md", inboxPath: "inbox/\(sync).md", lines: from...(from + text.count - 1),
                                            excerpt: text.joined(separator: "\n"), match: "quote"))
    }

    static func item(_ id: String, _ status: ActionStatus, _ title: String, type: String = "todo", summary: String? = nil, why: String? = nil,
                     fields: [String: String] = [:], note: String = sync, job: String = "job-sync", route: ActionRoute? = nil,
                     owner: String? = nil, ownerID: String? = nil, owedToID: String? = nil, what: String? = nil, due: String? = nil,
                     unclear: Bool = false, received: ActionReceived? = nil, context: ActionContextRefs = .none, at: Date = at(5)) -> ActionItem {
        var i = ActionItem(id: id, type: type, status: status, title: title, fields: fields, why: why, source: source(note, title, job: job),
                           createdAt: at, events: [ActionEvent(at: at, event: "found", detail: "Sonnet")], context: context, summary: summary)
        i.route = route; i.owner = owner; i.ownerID = ownerID; i.owedToID = owedToID; i.what = what; i.due = due
        i.ownerUnclear = unclear; i.received = received
        return i
    }

    /// To confirm (yours, Aditya's to-do, an unclear one), one open to-do, Pending (5) and Others' actions (6).
    static func items() -> [ActionItem] {
        [
            item("c1", .pending, "Share the FE platform roadmap draft with the team",
                 summary: "You said you would circulate the draft before Thursday’s review so people can comment.", fields: ["due": "2026-10-08"],
                 owner: "me", ownerID: "you"),
            item("c2", .pending, "Set up the shared Storybook for the design system",
                 summary: "Aditya asked for one Storybook both FE teams can publish to; it unblocks the component audit.",
                 why: "Aditya asked and you agreed to set it up this week.", owner: "A", ownerID: "p-aditya",
                 context: lines(17, ["- storybook: one shared instance for both FE teams", "- A: can you set it up? we need it for the audit", "- Jin: yes, this week"]), at: at(5, 18, 11)),
            item("c3", .pending, "Tell Anant the API mock server is ready", type: "slack",
                 summary: "Anant’s team is waiting to switch their tests to the mock server; you said you’d tell him when it’s up.", fields: ["to": "Anant"],
                 owner: "me", ownerID: "you", at: at(5, 18, 10)),
            item("c4", .pending, "Update the onboarding doc for the new repo layout",
                 summary: "The notes say “someone should update the onboarding doc”, with no name.", note: vj, job: "job-vj", unclear: true, at: at(30)),
            item("o1", .open, "Review Vladan’s caching proposal", fields: ["due": "2026-10-09"], note: vj, job: "job-vj", route: .list, owner: "me", ownerID: "you", at: at(30)),
            // Pending: what others said they would do for you.
            item("w1", .open, "Aditya will send you the ticket links",
                 summary: "The Jira links for the three migration tickets, so you can link them from the FE platform epic. Aditya said he would send them by Friday.",
                 why: "Aditya promised them to you, so you are waiting on him; it isn’t your job to do.",
                 route: .waiting, owner: "Aditya", ownerID: "p-aditya", owedToID: "you", what: "the ticket links", due: "2026-10-09",
                 context: lines(23, ["- tickets for migration: A creating them today", "- A: “I’ll send you the links by Friday”", "- next sync Oct 12"])),
            item("w2", .open, "Aditya will review your Storybook setup PR", job: "job-sync-0", route: .waiting, owner: "Aditya", ownerID: "p-aditya", owedToID: "you",
                 what: "the Storybook setup PR review", at: at(5, 18, 10)),
            item("w3", .open, "Vladan will share the caching benchmark numbers", note: vj, job: "job-vj-0", route: .waiting, owner: "Vladan Dimitrijevic", owedToID: "you",
                 what: "the caching benchmark numbers", due: "2026-10-02", at: at(30)),
            item("w4", .open, "Vladan will send the access request for the staging cluster", note: vj, job: "job-vj-0", route: .waiting, owner: "Vladan Dimitrijevic",
                 owedToID: "you", what: "the access request", received: ActionReceived(notePath: "wiki/sources/2026-10-06 Standup.md", pageTitle: "2026-10-06 Standup",
                                                                                         quote: "Vladan sent the staging access request this morning"), at: at(30, 18, 10)),
            item("w5", .open, "Anant will confirm the mock server endpoints", route: .waiting, owner: "Anant Gadodia", owedToID: "you", what: "the endpoints",
                 due: "2026-10-12", at: at(5, 18, 8)),
            // Others' actions (Highlights).
            item("x1", .open, "Benchmark the Redis cache on staging", route: .others, owner: "Vladan Dimitrijevic", due: "2026-10-07"),
            item("x2", .open, "Switch the API tests to the mock server", route: .others, owner: "Anant Gadodia"),
            item("x3", .open, "Write the mock server README", route: .others, owner: "Anant Gadodia"),
            item("x4", .open, "Split the deploy migration ticket", route: .others, owner: "Aditya", ownerID: "p-aditya"),
            item("x5", .open, "Draft the Telus cut-over checklist", route: .others, owner: "Aditya", ownerID: "p-aditya"),
            item("x6", .open, "Share the Redis TTL options", note: vj, job: "job-vj", route: .others, owner: "Vladan Dimitrijevic", at: at(30)),
        ]
    }

    static func highlights() -> [HighlightNote] {
        let line = { (t: String, n: Int) in HighlightNote.Wiki.Line(text: t, line: n) }
        return [
            HighlightNote(notePath: "wiki/sources/\(sync).md", title: sync, date: "2026-10-05", kind: "meeting", duration: "45 min",
                          people: ["Jin Bin Liu", "Aditya Pradhan", "Vladan Dimitrijevic", "Anant Gadodia"],
                          wiki: .init(path: "wiki/sources/\(sync).md", title: sync,
                                      summary: "The FE platform teams agreed on one shared Storybook, split the migration into three tickets and set the mock server live before the test switch.",
                                      keyPoints: [line("One shared Storybook for both FE teams", 17), line("Migration tickets split into API, tests and deploy", 23),
                                                  line("Mock server goes live before the test switch", 31)],
                                      decisions: [line("Storybook lives in the design-system repo", 18), line("Deploy migration waits for the Telus cut-over", 27)]),
                          others: [.init(person: "Vladan Dimitrijevic", items: [.init(id: "x1", title: "Benchmark the Redis cache on staging", due: "2026-10-07", line: 29)]),
                                   .init(person: "Anant Gadodia", items: [.init(id: "x2", title: "Switch the API tests to the mock server", line: 32),
                                                                         .init(id: "x3", title: "Write the mock server README", line: 33)])],
                          yours: .init(lists: ["todo": 2, "slack": 1], waiting: [.init(id: "w1", person: "Aditya Pradhan", what: "the ticket links"),
                                                                              .init(id: "w5", person: "Anant Gadodia", what: "the endpoints")]),
                          counts: .init(others: 5, decisions: 2, lists: 3, waiting: 2), foundAt: "2026-10-05T18:12:00Z"),
            HighlightNote(notePath: "wiki/sources/\(vj).md", title: vj, date: "2026-09-30", kind: "meeting", duration: "30 min",
                          people: ["Jin Bin Liu", "Vladan Dimitrijevic"],
                          wiki: .init(path: "wiki/sources/\(vj).md", title: vj,
                                      keyPoints: [line("Caching layer: Redis in front of the catalog API", 9), line("Benchmark before choosing the TTL", 14)],
                                      decisions: [line("Redis, not an in-process cache", 20)]),
                          others: [.init(person: "Vladan Dimitrijevic", items: [.init(id: "x6", title: "Share the Redis TTL options", onPage: true)])],
                          counts: .init(others: 2, decisions: 1, lists: 1, waiting: 2), foundAt: "2026-09-30T18:12:00Z"),
            HighlightNote(notePath: "wiki/sources/\(guild).md", title: guild, date: "2026-09-29", kind: "meeting", duration: "60 min",
                          people: ["Aditya Pradhan", "Anant Gadodia"],
                          wiki: .init(path: "wiki/sources/\(guild).md", title: guild,
                                      keyPoints: [line("Lint rules move to the shared config", 7), line("Next guild talk: testing with the mock server", 12)],
                                      decisions: [line("One shared ESLint config", 15)]),
                          counts: .init(others: 4, decisions: 1), foundAt: "2026-09-29T18:12:00Z"),
        ]
    }

    @MainActor static func load(_ e: AppModel, tab: String, select: String? = nil) {
        SettingsEdits.setActions(&e.settings) { p in
            p.people = people
            p.setHandlesFor("todo", ["you", "p-aditya"])
            p.setHandlesFor("slack", ["you"])
            p.setHandlesFor("jira", ["you"])
        }
        let all = ActionFixtures.live().filter { $0.type != "todo" } + items()
        e.actions.loadFixture(types: ActionFixtures.types, items: [])
        for i in all { e.actions.put(i) }
        e.actions.highlights = highlights()
        e.actions.highlightsLoaded = true
        e.actions.fixtureNow = now
        e.actions.tab = tab
        if let select { e.actions.selected[tab] = select }
    }
}

extension StatesSnapshot {
    static let routingSize = CGSize(width: 1200, height: 900)

    static func routingStates() {
        let f = Flow.actions
        func shot(_ file: String, _ state: String, _ desc: String, _ e: AppModel) {
            main(file, f, "Actions · whose items", state, desc, e, section: .actions, size: routingSize) { ActionsScreen() }
        }
        var e = engine()
        RoutingFixtures.load(e, tab: "todo", select: "c2")
        shot("actions-confirm-routed", "To confirm after routing",
             "Only your items and Aditya’s to-dos (you handle them; “for Aditya”); the quiet line says 6 went to Highlights and 2 to Pending; an unclear owner asks Whose is this?", e)

        e = engine()
        RoutingFixtures.load(e, tab: "pending", select: "w1")
        shot("actions-pending-list", "Pending, by person",
             "What others said they would do for you; Overdue in peach; a later note suggests Mark received?; the detail with Not waiting anymore, Nudge and Mark received.", e)

        e = engine()
        RoutingFixtures.load(e, tab: "pending", select: "w1")
        e.actions.startNudge(e.actions.routed["w1"]!)
        shot("actions-pending-detail", "Nudge",
             "Nudge opens Add as Slack message to Aditya Pradhan (@aditya), prefilled “Hi Aditya, any update on the ticket links?”.", e)

        e = engine()
        RoutingFixtures.load(e, tab: "highlights")
        shot("actions-highlights-list", "Highlights",
             "One card per note or meeting, newest first: its people, the wiki page’s key points and where its items went.", e)

        e = engine()
        RoutingFixtures.load(e, tab: "highlights", select: "wiki/sources/\(RoutingFixtures.sync).md")
        shot("actions-highlights-note", "A note’s Highlights",
             "From the wiki page (summary, key points, decisions with their lines, Open page), Others’ actions by person (added to the page in the next batch; Track as Pending, It’s mine), Your items; Copy as summary, Open note.", e)

        e = engine { s in
            SettingsEdits.setActions(&s) { p in
                p.people = RoutingFixtures.people
                p.setHandlesFor("todo", ["you", "p-aditya"])
                p.setHandlesFor("slack", ["you"])
                p.setHandlesFor("jira", ["you"])
            }
        }
        e.settingsUI.fixtureRoutingPreview = RoutingPreview(lists: 14, waiting: 6, others: 31)
        settingsWindow("settings-actions-people", "Actions › Whose items Distill handles",
                       "People (you first, with the names the notes use), each type’s Handles items for, and what the last 7 days would have done.",
                       e, target: SettingsTarget(.actions, actionType: PeopleSettingsPage.id), size: CGSize(width: 1140, height: 760))
    }
}
