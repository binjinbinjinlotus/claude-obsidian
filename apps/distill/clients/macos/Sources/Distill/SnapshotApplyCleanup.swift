import SwiftUI
import DistillKit

/// `--states` renders for Review after Approve and Clean up inbox (canvas: ReviewProgress, InboxCleanup;
/// state ids match screens/review.json). Fixtures only: no core, no runner, nothing moves.
extension StatesSnapshot {
    static func applyCleanupStates() {
        let f = Flow.intake
        let approvedAt = Date().addingTimeInterval(-120)

        func approved(_ e: AppModel, state: JobState) -> Job {
            var job = teaClub(e)
            job.state = state
            job.approvedChange = ApprovedChange(at: approvedAt, operationID: "ingest-20261004-tea-club", changes: 31, sources: 22, concepts: 3,
                                                entities: 1, updated: 6, sourcesApproved: 22)
            job.turns.append(TurnRecord(date: approvedAt, author: .user, text: "Approved ingest-20261004-tea-club (3f2a91c0…)"))
            return job
        }
        func steps(_ e: AppModel, _ list: [(String, String, String, String, Double)], hint: String? = nil) {
            e.jobSteps.steps[teaID] = [JobStep(id: "review-1", at: approvedAt.addingTimeInterval(-300), endedAt: approvedAt, phase: "review",
                                               state: "done", verb: "answer", text: "You approved", count: "22 sources")]
                + list.map { JobStep(id: $0.0, at: approvedAt.addingTimeInterval($0.4), phase: "apply", state: $0.2, verb: $0.1, text: $0.3,
                                     hint: $0.2 == "failed" ? hint : nil) }
            e.jobSteps.kept[teaID] = true
        }

        var e = labelEngine()
        e.jobs = [approved(e, state: .running)]
        steps(e, [("start-7", "start", "running", "Claude is starting: resuming this batch’s session", 1), ("apply-7", "apply", "waiting", "", 1)])
        main("review-progress-starting", f, "Review", "Approved: Claude resumes this batch’s session",
             "The steps after Approve, live: Approve and Reject are gone; nothing else needs you.", e, section: .review, job: teaID) {
            ReviewSection(selectedJob: .constant(teaID))
        }

        e = labelEngine()
        e.jobs = [approved(e, state: .running)]
        steps(e, [("start-7", "start", "done", "", 1), ("apply-7", "apply", "running", "", 40)])
        main("review-progress-applying", f, "Review", "Applying through the vault core", "The one apply command you approved.",
             e, section: .review, job: teaID) { ReviewSection(selectedJob: .constant(teaID)) }

        func added(_ e: AppModel, actions: JobActionsSummary) -> Job {
            var job = approved(e, state: .completed)
            job.operationID = "ingest-20261004-tea-club"
            job.changedPaths = job.approval?.plan?.changedPaths ?? []
            job.actionsFound = actions
            steps(e, [("start-7", "start", "done", "", 1), ("apply-7", "apply", "done", "", 40), ("added-7", "added", "done", "", 60)])
            e.jobSteps.steps[teaID]?.append(JobStep(id: "actions", at: approvedAt.addingTimeInterval(61), endedAt: approvedAt.addingTimeInterval(90),
                                                    phase: "apply", state: actions.status == "finding" ? "running" : "done", verb: "actions", text: ""))
            return job
        }
        e = labelEngine()
        e.jobs = [added(e, actions: JobActionsSummary(status: "finding"))]
        e.inboxCleanup.previews[teaID] = cleanupPreview(moving: 22)
        main("review-progress-added", f, "Review", "Added: counts from the checked plan", "Finding actions follows; Clean up inbox and Done in the footer.",
             e, section: .review, job: teaID) { ReviewSection(selectedJob: .constant(teaID)) }

        e = labelEngine()
        e.jobs = [added(e, actions: JobActionsSummary(status: "done", found: 5, pending: 5))]
        e.inboxCleanup.previews[teaID] = cleanupPreview(moving: 22)
        main("review-progress-done", f, "Review", "Done: open the new pages, clean up the inbox, then Done",
             "The card folds to one line; new pages open from their rows.", e, section: .review, job: teaID) {
            ReviewSection(selectedJob: .constant(teaID))
        }
        main("review-progress-narrow", f, "Review", "890 pt", "The same, with the conversation behind its button.",
             e, section: .review, job: teaID, size: CGSize(width: 890, height: 760)) { ReviewSection(selectedJob: .constant(teaID)) }

        e = labelEngine()
        var stale = approved(e, state: .awaitingApproval)
        stale.turns.append(TurnRecord(date: approvedAt.addingTimeInterval(50), author: .app, text: "Not applied: the vault changed after review."))
        e.jobs = [stale]
        steps(e, [("start-7", "start", "done", "", 1), ("apply-7", "apply", "failed", "Not added: the vault changed after you reviewed this batch", 50)],
              hint: "Nothing was changed. This batch’s own session rebuilds the change for the vault as it is now; it comes back here for your OK.")
        main("review-progress-stale", f, "Review", "The vault changed after review (exit 75)", "Rebuilt in the same session, then your OK again.",
             e, section: .review, job: teaID) { ReviewSection(selectedJob: .constant(teaID)) }

        // Clean up inbox
        e = labelEngine()
        var history = added(e, actions: JobActionsSummary(status: "done", found: 5))
        history.reviewDoneAt = Date()
        e.jobs = [history]
        e.inboxCleanup.previews[teaID] = cleanupPreview(moving: 21, stay: [InboxCleanupStay(path: "inbox/kettle-care-chat-2026-09-29.md", reason: "changed")])
        main("cleanup-history", f, "History · Jobs", "A batch that was added offers Clean up inbox", "Counted when you open it; only the files this batch used.",
             e, section: .history, job: teaID) { HistorySection(selectedJob: .constant(teaID)) }
        natural("cleanup-confirm", f, "History · Jobs", "Before anything moves", "What goes to the Trash, what stays and why.", e) {
            InboxCleanupSheet(preview: e.inboxCleanup.previews[teaID]!, onMove: { _ in }, onCancel: {})
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
        }
        e.inboxCleanup.results[teaID] = InboxCleanupResult(moved: (0..<20).map { .init(path: "inbox/\(slug($0)).md", fileCount: 1) },
                                                           stayed: [InboxCleanupStay(path: "inbox/kettle-care-chat-2026-09-29.md", reason: "changed"),
                                                                    InboxCleanupStay(path: "inbox/tea-club-sync-2026-09-29.md", reason: "changed")],
                                                           method: "finder")
        e.inboxCleanup.previews[teaID] = cleanupPreview(moving: 0, stay: e.inboxCleanup.results[teaID]!.stayed)
        main("cleanup-done", f, "History · Jobs", "After: what moved, and what stayed", "Each file is checked again when you press Move.",
             e, section: .history, job: teaID) { HistorySection(selectedJob: .constant(teaID)) }

        e = labelEngine()
        e.jobs = [history]
        var vault = cleanupPreview(moving: 21, stay: [InboxCleanupStay(path: "inbox/scan-1.pdf", reason: "inReview", fileCount: 14),
                                                      InboxCleanupStay(path: "inbox/new.md", reason: "notAdded", fileCount: 4),
                                                      InboxCleanupStay(path: "inbox/kettle.md", reason: "changed")])
        vault.items += (1...18).map { InboxCleanupItem(path: "inbox/scan-\($0).pdf", jobId: "job-20261003-scans", addedAt: "2026-10-03") }
        e.inboxCleanup.previews[""] = vault
        natural("cleanup-card-settings", f, "Settings → Batching", "Every file in inbox/ that can go", "A new last row; it opens the clean-up for the whole vault.", e) {
            InboxCleanupSettingsRow(store: e.inboxCleanup).frame(width: 516).padding(22)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        }
        natural("cleanup-card-sheet", f, "Settings → Batching", "The whole vault: pick with select-all", "Grouped by the batch that added them.", e) {
            InboxCleanupSheet(preview: vault, selectable: true, titles: [teaID: "Tea club notes, Sep 28 – Oct 2", "job-20261003-scans": "Scans"],
                              onMove: { _ in }, onCancel: {})
                .background(RoundedRectangle(cornerRadius: 18).fill(Color.white))
        }
    }

    static func cleanupPreview(moving: Int, stay: [InboxCleanupStay] = []) -> InboxCleanupPreview {
        InboxCleanupPreview(vaultPath: "/Research", jobId: teaID,
                            items: (0..<moving).map { InboxCleanupItem(path: "inbox/\(slug($0)).md", jobId: teaID, addedAt: "2026-10-04",
                                                                       pages: [page($0)]) },
                            stays: stay)
    }
}
