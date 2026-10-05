import SwiftUI
import DistillKit

/// `--states` renders for Action context (canvas row 12, ActionContext; spec action-context.md). Fixtures
/// only: Open original and Try again do nothing here.
extension StatesSnapshot {
    enum ActionContextFixtures {
        static let rawPath = ".raw/captured/9f2c4be1a7d0c3e85b16f2a4d9e0c7b1a3f5e8d2c6b4a9e7f1d3c5b8a2e4f6d0.md"
        static let inbox = "inbox/2026-09-30 Tomasz _ Jin.md"
        static let lines = """
        Jin: So we cap it. Three retries, exponential backoff, and then we fail loud.
        Tomasz: Three is fine. Start at 500 ms, double each time.
        Jin: Can you put a ticket in PAY for that? I want it this sprint,
        Jin: before the Telus cut-over on the 9th.
        Tomasz: Yes, I’ll file it today and take it.
        """
        static let wiki = ActionWikiRef(path: "wiki/sources/Tomasz and Jin 2026-09-30.md", title: "Tomasz and Jin · Sep 30",
                                        heading: "Payment client retries",
                                        excerpt: "Decision: cap retries at 3 with exponential backoff from 500 ms; fail loudly after the third. Owner: Tomasz. Due before the Telus cut-over (Oct 9).")

        static func source(job: String = "job-actx") -> ActionSource {
            .note(jobID: job, notePath: inbox, pageTitle: "Tomasz and Jin", quote: "Can you put a ticket in PAY for that? I want it this sprint")
        }

        static func items(status: ActionStatus = .pending, job: String = "job-actx") -> [ActionItem] {
            let at = ActionFixtures.at(9, 24)
            let found = [ActionEvent(at: at, event: "found", detail: "Sonnet")]
            let jira = ActionItem(id: "x1", type: "jira", status: status, title: "Cap payment client retries at 3 with exponential backoff from 500 ms",
                                  fields: ["project": "PAY", "issueType": "Task", "priority": "High"],
                                  why: "Tomasz agreed to file a PAY ticket for the retry cap this sprint, before the Telus cut-over on the 9th.",
                                  source: source(job: job), createdAt: at, events: found,
                                  context: ActionContextRefs(raw: ActionRawRef(path: rawPath, inboxPath: inbox, sha256: "9f2c4be1", lines: 210...214, excerpt: lines, match: "quote"),
                                                             wiki: [wiki]))
            let slack = ActionItem(id: "x2", type: "slack", status: status, title: "Tell Mei the Telus cut-over moves the retry change into this sprint",
                                   fields: ["to": "Mei"], why: "Jin asked to let Mei know, since her team owns the cut-over plan.",
                                   source: source(job: job), createdAt: at, events: found,
                                   context: ActionContextRefs(raw: ActionRawRef(path: rawPath, inboxPath: inbox, lines: 230...233,
                                                                                excerpt: "Jin: Mei needs to hear this before Thursday’s plan review.\nJin: Tell her the retry change lands this sprint,\nTomasz: I can, or you do it, you talk to her daily.\nJin: I’ll message her.",
                                                                                match: "quote"),
                                                              wiki: [ActionWikiRef(path: wiki.path, title: wiki.title, heading: "Telus cut-over")]))
            let todo = ActionItem(id: "x3", type: "todo", status: status == .pending ? .pending : .open, title: "Log the final retry failure with the request id",
                                  fields: ["due": ActionFixtures.day(4), "person": "You (Jin Liu)", "priority": "Medium"], why: "Jin asked for it with the retry cap.",
                                  source: source(job: job), createdAt: at, events: found,
                                  context: ActionContextRefs(raw: ActionRawRef(path: rawPath, inboxPath: inbox, lines: 215...215,
                                                                               excerpt: "Jin: Good. And log the final failure with the request id.", match: "quote"),
                                                             wiki: [wiki]))
            return [jira, slack, todo]
        }
    }

    static func actionContextStates() {
        let f = Flow.actions

        // A · To confirm with the Jira preview open
        var e = engine()
        ActionFixtures.load(e, items: ActionFixtures.live() + ActionContextFixtures.items(), select: "t2")
        var ui = TodoUI(); ui.previewing = ["x1"]
        main("actx-confirm-preview", f, "Actions · To do", "To confirm: preview",
             "The full title and where it goes; open, it shows the original’s lines, the fields, the wiki section and what Create draft will write.",
             e, section: .actions, size: CGSize(width: 1200, height: 1060)) { TodoScreen(store: e.actions, ui: ui) }

        // B · Item detail with the original's lines and the wiki section
        e = engine()
        let open = ActionContextFixtures.items(status: .open)
        ActionFixtures.load(e, items: ActionFixtures.live() + [open[2]], select: "x3")
        main("actx-detail", f, "Actions · To do", "Detail: original + wiki",
             "FROM shows the original’s lines (archived in .raw/captured/) and the wiki section, each with Open.",
             e, section: .actions) { TodoScreen(store: e.actions) }

        // C · Review: looking for actions
        e = labelEngine()
        ActionFixtures.load(e, items: ActionFixtures.live())
        var job = teaClub(e, sourceCount: 3)
        job.actionsFound = JobActionsSummary(status: "finding", model: "Sonnet", stage: "review", lines: 1_380, linesOf: 2_243, sources: 3)
        e.jobs = [job]
        main("actx-review-finding", Flow.intake, "Review", "Looking for actions",
             "Found while the batch is read; Approve doesn’t wait for it.",
             e, section: .review, job: teaID, size: CGSize(width: 1200, height: 1500)) { ReviewSection(selectedJob: .constant(teaID)) }

        // D · Review: actions found; a source left out dims its actions
        e = labelEngine()
        ActionFixtures.load(e, items: ActionFixtures.live())
        job = teaClub(e, sourceCount: 3, removed: [2])
        let summary = JobActionsSummary(status: "done", found: 4, byType: ["jira": 1, "slack": 1, "todo": 2], model: "Sonnet",
                                        stage: "review", proposed: 4, lines: 2_243, linesOf: 2_243, sources: 3, duplicates: 1)
        job.actionsFound = summary
        e.jobs = [job]
        let props = ActionContextFixtures.items(job: job.id)
        let leftOut = ActionItem(id: "x4", type: "todo", status: .pending, title: "Ask Telus for the stand-up recording",
                                 source: .note(jobID: job.id, notePath: "inbox/\(slug(2)).md", pageTitle: teaTitles[2], quote: nil))
        e.actions.jobActions[job.id] = JobActions(summary: summary, proposals:
            props.map { JobActionProposal(item: $0, file: ActionContextFixtures.inbox, page: page(0)) }
            + [JobActionProposal(item: leftOut, file: "inbox/\(slug(2)).md", page: page(2))])
        main("actx-review-found", Flow.intake, "Review", "Actions found",
             "Every line looked through; they go to To confirm when you approve. A source left out dims its actions.",
             e, section: .review, job: teaID, size: CGSize(width: 1200, height: 1500)) { ReviewSection(selectedJob: .constant(teaID)) }
    }
}
