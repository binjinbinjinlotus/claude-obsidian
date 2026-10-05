import AppKit
import SwiftUI
import DistillKit

/// Live log (canvas row 9: LiveLog, CollectorsLog). Steps are core-shaped `JobStep`s, the way
/// `GET /v1/jobs/:id/steps` and `job.step` events bring them.
@MainActor
enum LiveLogFixtures {
    typealias F = CollectorFixtures
    static let jobID = "job-20261004-233313-0018"
    static let start = F.at(23, 33, s: 13)

    static let files = ["Gyokuro tasting · Sep 28", "Tea club stand-up · Sep 28", "Supplier call · Sep 28", "Kettle comparison", "Sencha water temperature",
                        "Tea club stand-up · Sep 29", "Matcha whisk care", "Hojicha roast notes", "Supplier call · Sep 29", "Oolong rinse test",
                        "Q3 tea club plan", "Tea club stand-up · Sep 30", "Darjeeling first flush", "Shop visit · Sep 30", "Tea club stand-up · Oct 1",
                        "Gaiwan sizes", "Supplier call · Oct 1", "Tea club stand-up · Oct 2", "Shop visit · Oct 2", "Cold brew trial", "Kyusu care", "Tea club budget"]

    static func t(_ seconds: Double) -> Date { start.addingTimeInterval(seconds) }

    static func step(_ id: String, _ at: Double, _ phase: String, _ verb: String, _ text: String, state: String = "done",
                     kind: String = "step", detail: String? = nil, count: String? = nil, parent: String? = nil) -> JobStep {
        JobStep(id: id, at: t(at), phase: phase, kind: kind, state: state, verb: verb, text: text, detail: detail, count: count, parent: parent)
    }

    /// While labels are suggested: 14 of 22 done, one running, the rest waiting.
    static var labeling: [JobStep] {
        var s = [step("prepare-1", 0, "prepare", "move", "Moved 22 files from the queue to your inbox"),
                 step("labels", 1, "prepare", "labels", "Suggesting labels", state: "running", count: "14 of 22")]
        for (i, name) in files.prefix(14).enumerated() {
            s.append(step("label-\(i)", 1 + Double(i) * 9, "prepare", "label", name, count: "\(2 + i % 3) labels", parent: "labels"))
        }
        s.append(step("label-14", 130, "prepare", "label", files[14], state: "running", parent: "labels"))
        return s
    }

    /// Claude's steps, drafting (labels done, reads folded, its own notes).
    static var drafting: [JobStep] {
        var s = [step("prepare-1", 0, "prepare", "move", "Moved 22 files from the queue to your inbox"),
                 step("labels", 1, "prepare", "labels", "Suggested labels for 22 files", count: "3 min 51 s")]
        for (i, name) in files.enumerated() { s.append(step("label-\(i)", 1 + Double(i) * 10, "prepare", "label", name, count: "\(2 + i % 3) labels", parent: "labels")) }
        s.append(step("a1-1", 241, "agent", "skill", "Started the wiki-ingest instructions", detail: "Skill · claude-obsidian:wiki-ingest"))
        for (i, page) in ["hot", "index", "log", "overview"].enumerated() {
            s.append(step("a1-p\(i)", 254 + Double(i), "agent", "readPage", "Read your page “\(page)”", detail: "Read · wiki/\(page).md"))
        }
        for (i, name) in files.enumerated() {
            s.append(step("a1-r\(i)", 261 + Double(i) * 1.2, "agent", "read", "Read “\(name)”", detail: "Read · inbox/\(name).md · lines 1–110"))
        }
        s.append(step("a1-n1", 273, "agent", "note", "Still reading sources: 8 of 22 are done. For the rest I’m reading the notes sections at the top of each file.", kind: "note"))
        for i in 0..<3 {
            s.append(step("a1-g\(i)", 297 + Double(i), "agent", "search", "Searched for “source_manifest_updates”", detail: "Grep · “address_requests|source_manifest_updates” in claude_obsidian/"))
        }
        s.append(step("a1-n2", 310, "agent", "note", "Next I’m checking how the core validates ingest bundles, so the ledger comes out right.", kind: "note"))
        for i in 0..<3 {
            s.append(step("a1-c\(i)", 388 + Double(i) * 3, "agent", "command", "Ran a command: shasum", detail: "Bash · shasum -a 256 \"inbox/\(files[i]).md\""))
        }
        s.append(step("a1-n3", 411, "agent", "note", "Now I’m writing the drafts, starting with the source pages for Sep 28 and Sep 29.", kind: "note"))
        for i in 1...9 {
            s.append(step("a1-w\(i)", 417 + Double(i) * 5, "agent", "write", "Wrote a draft (s0\(i).md)", state: i == 9 ? "running" : "done",
                          detail: "Write · .vault-meta/worker/\(jobID)/drafts/s0\(i).md"))
        }
        return s
    }

    /// Finished: checked, waiting for review (and, applied, through Found actions).
    static func finished(applied: Bool) -> [JobStep] {
        var s = drafting.map { var x = $0; if x.state == "running" { x.state = "done" }; return x }
        for i in 10...26 { s.append(step("a1-w\(i)", 470 + Double(i) * 10, "agent", "write", "Wrote a draft (s\(i).md)", detail: "Write · drafts/s\(i).md")) }
        s.append(step("a1-n4", 1040, "agent", "note", "All 22 sources are in. Two claims come from a single note, so I kept them provisional.", kind: "note"))
        s.append(step("check-1", 1090, "check", "check", "Checked the changes with the vault core", count: "31 changes"))
        if applied {
            s.append(step("review-1", 1140, "review", "answer", "You approved"))
            s.append(step("apply-1", 1440, "apply", "apply", "Applied 31 changes to Research", count: "op-20261004-235712"))
            s.append(step("actions", 1470, "apply", "actions", "Found 5 actions to confirm"))
        } else {
            s.append(step("review-1", 1140, "review", "review", "Waiting for your review", state: "review"))
        }
        return s
    }

    static func job(_ e: AppModel, _ state: JobState) -> Job {
        var j = StatesSnapshot.job(e, jobID, state, files: files.map { "inbox/\($0).md" }, minutesAgo: 0)
        j.createdAt = start
        j.updatedAt = state == .running ? Date() : t(state == .completed ? 1470 : 1140)
        j.model = "sonnet"
        if state == .awaitingApproval {
            j.approval = ApprovalRequest(summary: "Claude turned 22 meeting notes into 22 source pages and 4 topic pages, and kept 2 claims provisional because they come from a single note.",
                                         bundlePath: "/x/bundle.json",
                                         plan: TransactionPlan(operationID: "op-20261004-235712", operationType: "ingest", valid: true,
                                                               changedPaths: StatesSnapshot.changePaths, approvalSHA256: "a"))
            j.turns = StatesSnapshot.turns(19, worker: "All set and checked. Approve and I will apply it.")
        }
        if state == .completed { j.changedPaths = StatesSnapshot.changePaths; j.operationID = "op-20261004-235712" }
        return j
    }

    static func progress(_ job: Job, labels: Bool) -> CoreProgress {
        labels
            ? CoreProgress(key: job.id, kind: "batch", message: "Suggesting labels for 22 sources",
                           steps: ["Moved to inbox", "Suggesting labels", "Read sources", "Drafting page changes", "Ready for review"],
                           stepIndex: 1, done: 14, total: 22, startedAt: start, runnerID: "claude-code", model: "haiku",
                           current: "inbox/\(files[14]).md")
            : CoreProgress(key: job.id, kind: "batch", message: "Reading 22 sources",
                           steps: ["Moved to inbox", "Suggesting labels", "Read sources", "Drafting page changes", "Ready for review"],
                           stepIndex: 3, startedAt: start, runnerID: "claude-code", model: "sonnet")
    }
}

extension StatesSnapshot {
    static func liveLogStates() {
        let f = Flow.liveLog
        typealias L = LiveLogFixtures
        let tall = CGSize(width: 1200, height: 860)
        let n890 = CGSize(width: 890, height: 760)

        // A · Queue: the batch card says what it is doing now, and Show steps.
        var e = engine()
        var job = L.job(e, .running)
        e.jobs = [job]
        e.queued = []
        e.progress[job.id] = L.progress(job, labels: true)
        e.jobSteps.steps[job.id] = L.labeling
        main("livelog-queue", f, "Queue", "A · Batch card: Now and Show steps", "The batch card says what it is doing now (labeling one file of 22), with Show steps.", e, section: .queue, size: tall) { QueueView() }

        // B · Steps while labels are suggested.
        main("livelog-labels", f, "Queue · Steps", "B · Steps, live: labels per file", "Labels one file at a time before Claude starts; the newest line is followed.", e, section: .queue, size: tall) {
            QueueView(stepsJob: job.id)
        }

        // C · Claude's steps, scrolled up: Jump to latest.
        e = engine()
        job = L.job(e, .running)
        e.jobs = [job]
        e.queued = []
        e.progress[job.id] = L.progress(job, labels: false)
        e.jobSteps.steps[job.id] = L.drafting
        main("livelog-ai", f, "Queue · Steps", "C · Claude’s steps; scrolled up", "Plain words; repeats fold into one line; scrolled up, so Jump to latest.", e, section: .queue, size: tall) {
            QueueView(stepsJob: job.id, stepsOptions: StepsSnapshot(following: false))
        }

        // D · Details on.
        main("livelog-details", f, "Queue · Steps", "D · Details on", "The tool and what it touched under each step (reads opened), never what it read or wrote.", e, section: .queue, size: tall) {
            QueueView(stepsJob: job.id, stepsOptions: StepsSnapshot(details: true, expanded: ["g-a1-p0"]))
        }

        // E · Review with Show steps; F · its steps.
        e = engine()
        job = L.job(e, .awaitingApproval)
        e.jobs = [job]
        e.jobSteps.steps[job.id] = L.finished(applied: false)
        main("livelog-review-entry", f, "Review", "E · Review: Show steps", "Show steps next to the batch’s times.", e, section: .review, job: job.id) {
            ReviewSection(selectedJob: .constant(job.id))
        }
        main("livelog-review", f, "Review · Steps", "F · Steps after the run", "Checked by the vault core, waiting for your review.", e, section: .review, job: job.id) {
            JobDetailView(jobID: job.id, showSteps: true)
        }

        // G · History: a past batch's steps, kept.
        e = engine()
        job = L.job(e, .completed)
        e.jobs = [job] + historyJobs(e).filter { $0.state != .running }
        e.jobSteps.steps[job.id] = L.finished(applied: true)
        main("livelog-history", f, "History · Steps", "G · A past batch’s steps", "Kept with the job: through Applied and Found actions.", e, section: .history, job: job.id) {
            JobDetailView(jobID: job.id, showSteps: true)
        }

        // A batch from before steps were kept.
        e = engine()
        let old = historyJobs(e)[1]
        e.jobs = historyJobs(e)
        e.jobSteps.kept[old.id] = false
        main("livelog-card-old", f, "History · Steps", "A batch from before", "No steps were kept; the view says so instead of an empty list.", e, section: .history, job: old.id) {
            JobDetailView(jobID: old.id, showSteps: true)
        }

        // H · 890 pt.
        e = engine()
        job = L.job(e, .running)
        e.jobs = [job]
        e.queued = []
        e.progress[job.id] = L.progress(job, labels: false)
        e.jobSteps.steps[job.id] = L.drafting
        main("livelog-narrow", f, "Queue · Steps", "H · 890 pt window", "The same view in an 890 pt window; times stay on the right.", e, section: .queue, size: n890) {
            QueueView(stepsJob: job.id)
        }

        collectorLogStates()
    }

    static func collectorLogStates() {
        let f = Flow.liveLog
        typealias F = CollectorFixtures
        typealias S = ScriptFixtures
        let size = CGSize(width: 1200, height: 860)
        let n890 = CGSize(width: 890, height: 760)
        func shot(_ file: String, _ state: String, _ desc: String, _ e: AppModel, size: CGSize = size) {
            main(file, f, "Collectors · Log", state, desc, e, section: .collectors, size: size) { CollectorsScreen() }
        }
        func chunk(_ s: Int, _ text: String, err: Bool = false) -> CollectorOutputChunk {
            CollectorOutputChunk(stream: err ? "stderr" : "stdout", text: text, at: F.at(10, 14, s: s))
        }

        // Live: a running script's whole output.
        var e = engine()
        var pr = F.base
        pr[1].status?.running = true
        var s = F.load(e, pr, select: "pocket", now: F.at(10, 14, s: 13))
        var live = F.run("pl", "pocket", kind: .script, F.at(10, 14), .running, trigger: "now")
        live.runtime = CollectorRuntime(label: "python3", path: "/usr/bin/python3")
        s.live["pocket"] = live
        s.output["pl"] = ("Fetching articles since Oct 4, 7:00 AM…\n", "")
        s.ordered["pl"] = [chunk(2, "Fetching articles since Oct 4, 7:00 AM…\nPage 1 of 3: 40 articles\nWrote pocket-2026-10-04-1.md\n"),
                           chunk(6, "Skipping “Tea grading guide”: no text (paywalled)\n", err: true),
                           chunk(9, "Page 2 of 3: 40 articles\nWrote pocket-2026-10-04-2.md\n"),
                           chunk(11, "Retrying page 3 after a 429 (1 of 3)…\n", err: true),
                           chunk(13, "Page 3 of 3: 12 articles\n")]
        s.openLog(.run(collectorId: "pocket", runId: "pl"))
        shot("collectors-log-live", "Log · a running script", "Every line as it comes, stderr in peach; it follows the newest line.", e)
        shot("collectors-log-narrow", "Log · 890 pt", "The log takes the whole window; ‹ goes back to the collector.", e, size: n890)

        // An install, live.
        e = engine()
        let x = S.slack(.node, state: "installing", count: 2)
        s = S.load(e, S.list(slack: x), select: "slack", now: F.at(10, 50, s: 14))
        var ins = S.install("slack", "running", at: F.at(10, 50))
        ins.runtime = CollectorRuntime(label: "Node 22.22.1", path: F.home + "/.nvm/versions/node/v22.22.1/bin/node", version: "22.22.1")
        s.installs["slack"] = ins
        s.installOutput[ins.id] = "npm http fetch GET 200 https://registry.npmjs.org/@slack%2fweb-api 212ms\nnpm http fetch GET 200 https://registry.npmjs.org/p-retry 96ms\nadded 11 packages, changed 1 package in 3s\n"
        s.openLog(.install(collectorId: "slack", installId: ins.id))
        shot("collectors-log-install", "Log · a package install", "npm’s output, live; a run waits for it.", e)

        // A Test run, finished.
        e = engine()
        var p = S.pocket()
        var test = CollectorRun(id: "pt", collectorId: "pocket", kind: .script, trigger: "test", startedAt: F.at(10, 20, s: 12),
                                endedAt: F.at(10, 20, s: 14), durationMs: 1900, result: .success,
                                counts: .init(added: 2), filesAdded: ["pocket-2026-10-04-1.md", "pocket-2026-10-04-2.md"], exitCode: 0,
                                stdoutTail: "Fetched 2 new articles since 7:00 AM\n",
                                outputDir: F.home + "/Library/Application Support/Distill/collectors/test-runs/col-3f2a")
        test.outputLog = [CollectorOutputChunk(stream: "stdout", text: "[test run] the queue is Distill’s test folder\n", at: F.at(10, 20, s: 12)),
                          CollectorOutputChunk(stream: "stdout", text: "Fetched 2 new articles since 7:00 AM\nWrote pocket-2026-10-04-1.md\nWrote pocket-2026-10-04-2.md\n", at: F.at(10, 20, s: 13))]
        test.runtime = CollectorRuntime(label: "python3 (.venv)", path: S.dirRoot + "/col-3f2a/.venv/bin/python3")
        p.status?.script?.lastTestRun = test
        s = S.load(e, S.list(pocket: p), select: "pocket", now: F.at(10, 21))
        s.runs["pocket"] = [test] + S.pocketRuns()
        s.openLog(.run(collectorId: "pocket", runId: "pt"))
        shot("collectors-log-test", "Log · a Test run, finished", "The whole output stays, with Reveal in Finder.", e)

        // From All runs: a run saved before lines were kept in order.
        e = engine()
        s = F.load(e, F.base, select: "slack")
        var failed = F.run("s3", "slack", kind: .script, F.at(8, 30, daysAgo: 2), ms: 800, .failed, exit: 1,
                           out: "Listing saved items for @mei…\nFound 3 saved items\n", err: "Error: SLACK_TOKEN is not set\n    at main (slack-saved.mjs:12:11)\n")
        failed.runtime = CollectorRuntime(label: "Node 22.22.1", path: F.home + "/.nvm/versions/node/v22.22.1/bin/node", version: "22.22.1")
        s.runs["slack"] = (s.runs["slack"] ?? []) + [failed]
        s.page = .allRuns
        s.openLog(.run(collectorId: "slack", runId: "s3"))
        shot("collectors-log-past", "Log · from All runs, saved before", "Output, then stderr: the run was saved before lines were kept in order.", e)

        // All runs: an opened run shows what ran it, Copy output and Open log.
        e = engine()
        s = F.load(e, F.base, select: "slack")
        s.runs["slack"] = (s.runs["slack"] ?? []) + [failed]
        s.page = .allRuns
        s.openRuns = ["s3"]
        shot("collectors-log-all-runs", "All runs · an opened run", "What ran it (Node 22.22.1 and its path), Copy output and Open log.", e)
    }
}
