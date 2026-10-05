import SwiftUI
import DistillKit

/// `--states` renders for Full reads (canvas: FullRead; spec full-read.md, "Visible parts"). Fixtures only:
/// no core, no runner; Try again and Show in Finder do nothing here.
extension StatesSnapshot {
    static func fullReadStates() {
        let f = Flow.intake
        let budget = BatchBudget(tokens: 100_000, contextWindow: 1_000_000, model: "claude-sonnet-5-5", automatic: true)
        func status(_ e: AppModel, held: Int = 0) {
            e.setFixtureState(connection: .offline, status: StatusResponse(activeVault: e.settings.activeVault,
                                                                           nextBatchAt: Date().addingTimeInterval(9 * 60 + 20),
                                                                           batchBudget: budget, heldCount: held))
        }
        func covered(_ n: Int, lines: [Int], images: [Int: Int] = [:], later: [Int: Int] = [:]) -> [CoverageSource] {
            (0..<n).map { i in
                let total = lines[i % lines.count]
                if let read = later[i] { return CoverageSource(file: "inbox/\(slug(i)).md", lines: total, read: read, state: "later") }
                return CoverageSource(file: "inbox/\(slug(i)).md", lines: total, images: images[i] ?? 0)
            }
        }

        // Queue: Batch 1 of 3
        var e = labelEngine()
        status(e)
        let started = Date().addingTimeInterval(-6 * 60)
        var batch = job(e, "job-batch-1", .running, files: (0..<9).map { "inbox/\(slug($0)).md" }, minutesAgo: 6)
        batch.createdAt = started
        batch.batchOf = BatchOf(index: 1, total: 3, tokens: 96_000)
        e.jobs = [batch]
        e.progress[batch.id] = CoreProgress(key: batch.id, kind: "batch", message: "Reading 9 sources",
                                            steps: ["Moved to inbox", "Read sources", "Drafting page changes", "Ready for review"],
                                            stepIndex: 1, startedAt: started, runnerID: "claude-code", model: "sonnet")
        main("fullread-queue", f, "Queue", "Batch 1 of 3", "The queue split by size: this batch takes about 96K tokens; the rest follow one after another.",
             e, section: .queue) { QueueView() }

        // Review: every source read in full, checked against its page
        e = labelEngine()
        status(e)
        var job = teaClub(e, sourceCount: 9)
        job.batchOf = BatchOf(index: 1, total: 3, tokens: 96_000)
        job.coverage = CoverageSummary(sources: covered(9, lines: [644, 787, 630, 412, 518, 539], images: [0: 1, 1: 1, 3: 2, 5: 2]),
                                       full: 9, of: 9, lines: 4_870, rounds: 2, continued: 2, state: "complete",
                                       detail: CoverageDetail(checked: 9, added: 7, left: 2), archived: 9)
        e.jobs = [job]
        main("fullread-review", f, "Review", "Read in full, checked, archived",
             "Information under the heading: counted by Distill from Claude’s reads; each source row says how much was read.",
             e, section: .review, job: teaID) { ReviewSection(selectedJob: .constant(teaID)) }

        // Review: two sources go to a fresh session (the covered part)
        e = labelEngine()
        status(e)
        job = teaClub(e, sourceCount: 4)
        job.batchOf = BatchOf(index: 2, total: 3, tokens: 98_000)
        job.approval?.rebuilt = RebuiltPlan(reason: .covered, pages: (0..<4).map(page))
        job.coverage = CoverageSummary(sources: covered(4, lines: [644, 520, 630, 439])
                                        + [CoverageSource(file: "inbox/Develop FE With AI.md", lines: 789, read: 412, state: "later"),
                                           CoverageSource(file: "inbox/Tomasz and Jin.md", lines: 647, read: 400, state: "later")],
                                       full: 4, of: 4, lines: 2_233, rounds: 3, continued: 2, state: "split",
                                       detail: CoverageDetail(checked: 4, added: 3),
                                       later: ["inbox/Develop FE With AI.md", "inbox/Tomasz and Jin.md"], archived: 4)
        e.jobs = [job]
        main("fullread-split", f, "Review", "Two sources go to a fresh session",
             "3 rounds didn’t finish them: they were taken out of this change and come back as the next part.",
             e, section: .review, job: teaID) { ReviewSection(selectedJob: .constant(teaID)) }

        // Review: hard stop
        e = labelEngine()
        status(e)
        job = teaClub(e, sourceCount: 5)
        job.batchOf = BatchOf(index: 3, total: 3, tokens: 61_000)
        job.stopped = [StoppedSource(file: "inbox/Vendor call export.md", reason: "it isn’t valid UTF-8 text from line 412", at: Date())]
        job.coverage = CoverageSummary(sources: covered(5, lines: [512, 498, 466, 530, 482])
                                        + [CoverageSource(file: "inbox/Vendor call export.md", lines: 0, read: 0, state: "unreadable",
                                                          reason: "it isn’t valid UTF-8 text from line 412")],
                                       full: 5, of: 5, lines: 2_488, state: "stopped", detail: CoverageDetail(checked: 5), archived: 5)
        e.jobs = [job]
        main("fullread-stop", f, "Review", "Not added · couldn’t be read",
             "The file is not in the change and has no pick box; Approve counts only the others.",
             e, section: .review, job: teaID) { ReviewSection(selectedJob: .constant(teaID)) }

        // Queue: held in inbox/
        e = engine()
        status(e, held: 1)
        e.queued = []
        e.heldSources.held = [HeldSource(file: "inbox/Vendor call export.md", reason: "it isn’t valid UTF-8 text from line 412",
                                         at: Date().addingTimeInterval(-40 * 60), jobId: "job-batch-3", size: 212_000)]
        main("fullread-held", f, "Queue", "Held in inbox/", "Couldn’t be read in full: it counts in the sidebar and Clean up never clears it.",
             e, section: .queue) { QueueView() }

        // Settings → Batching
        e = engine()
        status(e)
        natural("fullread-settings", f, "Settings → Batching", "Batch size and detail level",
                "Automatic is 30% of the model’s context, at most 100K; each source type has its own level.", e) {
            BatchingSettings().frame(width: 560).padding(22)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        }
    }
}
