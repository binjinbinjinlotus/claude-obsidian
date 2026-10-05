import SwiftUI
import DistillKit

/// `--states` renders for labels in the queue and in Review (canvas: screens/review.json and the label
/// states of screens/queue.json): a 22-note batch with groups that fold, editing and saving labels, picking,
/// the Approve menu, removed sources, a rebuilt change, several batches, History in parts, the label gate.
extension StatesSnapshot {
    static func reviewLabelStates() {
        let f = Flow.intake
        var e = engine()

        e = labelEngine()
        e.jobs = [teaClub(e)]
        main("review", f, "Review", "A 22-note batch", "One summary line, New pages open, Updated and Sources folded; the folded Sources line names the most used labels.",
             e, section: .review, job: teaID) { ReviewSection(selectedJob: .constant(teaID)) }

        e = labelEngine()
        e.jobs = [teaClub(e, sourceCount: 4)]
        main("review-sources-open", f, "Review", "Sources opened", "Each source with the page it made and its labels; hover shows Open page, Remove and Edit.",
             e, section: .review, job: teaID) {
            JobDetailView(jobID: teaID, openGroups: ["New pages": false, "Sources": true], hoverPage: page(1))
        }

        e = labelEngine()
        e.jobs = [teaClub(e, sourceCount: 4)]
        main("review-label-edit", f, "Review", "Editing one source’s labels", "Removable chips, an Add field, Done and Cancel; Approve waits until Done.",
             e, section: .review, job: teaID) {
            JobDetailView(jobID: teaID, editing: (page(1), ["tasting"]), openGroups: ["New pages": false, "Sources": true])
        }

        e = labelEngine()
        e.jobs = [teaClub(e, sourceCount: 4, labels: ReviewLabels(state: .confirming, revision: 2))]
        main("review-label-saving", f, "Review", "Saving the labels", "After Done: the labels go into the change and the core checks it again; Approve is off meanwhile.",
             e, section: .review, job: teaID) {
            JobDetailView(jobID: teaID, openGroups: ["New pages": false, "Sources": true])
        }

        e = labelEngine()
        e.jobs = [teaClub(e, sourceCount: 4)]
        main("review-label-save-failed", f, "Review", "The label edit could not be checked", "The core refused the edited change: nothing changed, the labels are as before.",
             e, section: .review, job: teaID) {
            JobDetailView(jobID: teaID, labelError: "The vault changed after Claude prepared this batch (wiki/index.md), so the core refused the edited change.",
                          openGroups: ["New pages": false, "Sources": true])
        }

        e = labelEngine()
        e.jobs = [teaClub(e, sourceCount: 4, labels: ReviewLabels(state: .suggesting, done: 9, total: 22), attaching: true)]
        main("review-labels-attaching", f, "Review", "Labels suggested now, 3 at a time", "A batch that reached Review without labels: Approve waits until they are in.",
             e, section: .review, job: teaID) {
            JobDetailView(jobID: teaID, openGroups: ["New pages": false, "Sources": true])
        }

        e = labelEngine()
        e.jobs = [teaClub(e, sourceCount: 6)]
        let eight = Set((2..<6).map(page))
        main("review-pick", f, "Review", "Pick the sources to approve", "Unpicked sources stay in Review for later; Approve says how many go in.",
             e, section: .review, job: teaID) {
            JobDetailView(jobID: teaID, unpicked: eight, openGroups: ["New pages": false, "Sources": true])
        }
        main("review-approve-menu", f, "Review", "Approve, or review the labels later", "The chevron offers Approve N sources and Approve, review labels later.",
             e, section: .review, job: teaID) {
            JobDetailView(jobID: teaID, unpicked: eight, openGroups: ["New pages": false, "Sources": true], menuOpen: true)
        }

        e = labelEngine()
        e.jobs = [teaClub(e, sourceCount: 6, removed: [3])]
        main("review-removed", f, "Review", "Removed from the batch", "Never added to the vault; its inbox file stays. Undo while the batch is in Review.",
             e, section: .review, job: teaID) {
            JobDetailView(jobID: teaID, unpicked: [page(5)], openGroups: ["New pages": false, "Sources": true])
        }

        e = labelEngine()
        var rebuilding = teaClub(e, sourceCount: 6)
        rebuilding.state = .running
        rebuilding.pendingPart = PendingPart(reason: .partial, expected: Dictionary(uniqueKeysWithValues: (0..<2).map { (page($0), "x") }),
                                             excluded: (2..<6).map(page))
        e.jobs = [rebuilding]
        main("review-rebuilding", f, "Review", "Rebuilding the change for the picked sources", "The batch’s own session rebuilds the change; Approve waits.",
             e, section: .review, job: teaID) {
            ReviewSection(selectedJob: .constant(teaID))
        }

        e = labelEngine()
        var rebuilt = teaClub(e, sourceCount: 2)
        rebuilt.approval?.rebuilt = RebuiltPlan(reason: .partial, pages: [page(0), page(1)])
        e.jobs = [rebuilt]
        main("review-rebuilt", f, "Review", "Check the rebuilt change, then approve it", "Rebuilt and checked by the vault core; approve it once more.",
             e, section: .review, job: teaID) { ReviewSection(selectedJob: .constant(teaID)) }

        e = labelEngine()
        var first = teaClub(e, sourceCount: 5, minutesAgo: 90)
        first.parts = [JobPart(operationID: "ingest-20261004-tea-club-part-1", pages: ["wiki/sources/a.md"], at: Date().addingTimeInterval(-3000))]
        first.approval?.rebuilt = RebuiltPlan(reason: .stale, pages: (0..<5).map(page))
        var scans = awaiting(e, id: "job-20261003-scans", files: ["inbox/scan-1.pdf", "inbox/scan-2.pdf", "inbox/scan-3.pdf"],
                             summary: "Three scans become source pages.", paths: ["wiki/sources/Scan 1.md", "wiki/index.md"], minutesAgo: 10)
        scans.approval?.sources = (1...3).map { ReviewSource(page: "wiki/sources/Scan \($0).md", title: "Scans · Oct 3 (\($0))", source: "inbox/scan-\($0).pdf") }
        e.jobs = [scans, first]
        main("review-batches", f, "Review", "Several batches wait", "One tab each, oldest first; “14 left” after a part was applied.",
             e, section: .review, job: teaID) {
            ReviewSection(selectedJob: .constant(teaID))
        }

        e = labelEngine()
        var done = teaClub(e)
        done.state = .completed
        done.changedPaths = done.approval?.plan?.changedPaths ?? []
        done.operationID = "ingest-20261005-tea-club-part-2"
        done.parts = [JobPart(operationID: "ingest-20261004-tea-club-part-1", pages: (0..<8).map(page), at: Date().addingTimeInterval(-36000)),
                      JobPart(operationID: "ingest-20261005-tea-club-part-2", pages: (8..<21).map(page), labels: .later, at: Date().addingTimeInterval(-600))]
        done.approval?.sources?[21].removed = true
        e.jobs = [done]
        main("review-history-parts", f, "History · Jobs", "A batch applied in parts", "Applied in 2 parts: one line per part and the source removed.",
             e, section: .history, job: teaID) { HistorySection(selectedJob: .constant(teaID)) }

        e = labelEngine()
        e.jobs = [teaClub(e)]
        main("review-narrow", f, "Review", "Smallest window (900 × 640)", "The conversation moves behind a Conversation button in the heading row.",
             e, section: .review, job: teaID, size: CGSize(width: 900, height: 640)) { ReviewSection(selectedJob: .constant(teaID)) }
    }

    static func queueLabelStates() {
        let f = Flow.intake
        var e = labelEngine()
        e.queued = labelQueue(e, held: false)
        main("queue-labeling", f, "Queue", "Labels as files arrive", "Labels suggested 3 at a time: confirmed, suggested, suggesting, failed and waiting rows.",
             e, section: .queue) { QueueView() }

        e = labelEngine()
        e.queued = labelQueue(e, held: true)
        main("queue-label-gate", f, "Queue", "Files wait for their labels", "A batch started: files still being labeled wait for the next one (Next batch).",
             e, section: .queue) { QueueView() }

        e = labelEngine()
        natural("queue-card-wait", f, "Settings → Batching", "Wait in hours and minutes", "0 (no wait) to 24 hours; the presets fill the two fields.", e) {
            BatchingSettings().frame(width: 560).padding(22)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        }
        let started = QueueLabelText.processToast(started: 19, held: 3, rows: 3, next: nil)!
        natural("queue-card-process-now", f, "Queue", "Process now, with files still being labeled", "The batch starts with the files whose labels are in.", e) {
            QueueToastView(toast: QueueToast(title: started.title, detail: started.detail, started: true))
        }
        let nothing = QueueLabelText.processToast(started: nil, held: 3, rows: 3, next: "7:30 AM")!
        natural("queue-card-nothing-yet", f, "Queue", "Process now, when every file is still being labeled", "No batch starts.", e) {
            QueueToastView(toast: QueueToast(title: nothing.title, detail: nothing.detail, started: false))
        }
    }

    // MARK: Fixtures

    static let teaID = "job-20261004-233300-tea1"

    nonisolated static let teaTitles = ["Tea club sync · Sep 28", "Tasting circle stand-up · Sep 28", "Wazuka farm call · Sep 28",
                                        "Shading and umami talk · Sep 28", "Tea club sync · Sep 29", "Kettle care chat · Sep 29"]
    nonisolated static let teaLabels: [[String]] = [["tea-club", "tasting", "gyokuro"], ["tasting", "sencha"], ["wazuka", "sourcing", "shading"],
                                                    ["gyokuro", "shading", "water-temperature"], ["tea-club", "matcha"], ["kettle", "water-temperature"]]

    static func page(_ i: Int) -> String { "wiki/sources/\(slug(i)).md" }

    static func slug(_ i: Int) -> String {
        let base = teaTitles[i % teaTitles.count].lowercased()
            .replacingOccurrences(of: " · sep ", with: "-2026-09-").replacingOccurrences(of: " ", with: "-")
        return i < teaTitles.count ? base : "\(base)-\(i)"
    }

    /// The vault already uses these labels; "sourcing" and "shading" are new.
    static func labelEngine() -> AppModel {
        let e = engine { $0.taskDefaults[AITask.labelSuggest.rawValue] = ModelSelection(runnerID: "claude-code", model: "haiku") }
        e.notes.labelCounts = ["tea-club", "tasting", "gyokuro", "sencha", "wazuka", "water-temperature", "matcha", "kettle"]
            .map { LabelCount(name: $0, count: 5, unconfirmed: 0) }
        return e
    }

    static func teaClub(_ e: AppModel, sourceCount: Int = 22, labels: ReviewLabels? = ReviewLabels(state: .confirmed),
                        removed: Set<Int> = [], attaching: Bool = false, minutesAgo: Double = 20) -> Job {
        let sources: [ReviewSource] = (0..<sourceCount).map { i in
            let title = i < teaTitles.count ? teaTitles[i] : "\(teaTitles[i % teaTitles.count]) (\(i))"
            let state: ReviewSource.State? = attaching && i >= 3 ? (i == 3 ? .suggesting : .waiting) : nil
            return ReviewSource(page: page(i), title: title, source: "inbox/\(slug(i)).md",
                                labels: state == nil ? teaLabels[i % teaLabels.count] : [], by: i == 1 ? .user : .ai,
                                state: state, removed: removed.contains(i))
        }
        let paths = sources.map(\.page) + ["wiki/entities/Wazuka Tea Farm.md", "wiki/concepts/Water temperature.md",
                                           "wiki/concepts/Shading and umami.md", "wiki/concepts/Tea club season plan.md",
                                           "wiki/index.md", "wiki/overview.md", "wiki/log.md", "wiki/hot.md",
                                           "wiki/meta/ledgers/sources.md", "wiki/meta/ledgers/claims.md",
                                           ".raw/.manifest.json", ".vault-meta/journal/op.json"]
        var job = awaiting(e, id: teaID, files: sources.compactMap(\.source),
                           summary: "Claude kept 12 tasting claims as provisional, since each comes from a single note. Nothing conflicts with your vault.",
                           paths: paths, minutesAgo: minutesAgo,
                           worker: "Read all \(sourceCount) notes. Made \(sourceCount) source pages, 3 concept pages and 1 entity, and updated the index, overview, log, hot cache and both ledgers. Checked by the vault core.")
        job.approval?.sources = sources
        job.approval?.labels = labels
        job.approval?.unconfirmed = UnconfirmedPlan(bundlePath: "/x/bundle-unconfirmed.json")
        return job
    }

    static func labelQueue(_ e: AppModel, held: Bool) -> [QueueEntry] {
        guard let dir = e.activeVault?.queueURL else { return [] }
        let now = Date()
        func entry(_ name: String, _ size: Int, _ labels: QueueLabels) -> QueueEntry {
            QueueEntry(path: dir.appendingPathComponent(name).path, modified: now.addingTimeInterval(-3600), size: size, settled: true,
                       labels: labels, heldForLabels: held)
        }
        let s = { (names: [String], existing: [Bool]) in zip(names, existing).map { LabelSuggestion(name: $0.0, existing: $0.1) } }
        if held {
            return [entry("tea-club-sync-2026-10-02.md", 6_000, QueueLabels(state: .suggesting)),
                    entry("kettle-care-chat-2026-10-02.md", 3_000, QueueLabels(state: .waiting)),
                    entry("tasting-circle-stand-up-2026-10-01.md", 4_000, QueueLabels(state: .failed, error: "Haiku timed out 3 times.", attempts: 3))]
        }
        return [entry("tea-club-sync-2026-09-28.md", 6_000, QueueLabels(state: .confirmed, labels: s(["tea-club", "tasting", "gyokuro"], [true, true, true]))),
                entry("tasting-circle-stand-up-2026-09-28.md", 4_000, QueueLabels(state: .suggested, labels: s(["tasting", "sencha"], [true, true]))),
                entry("wazuka-farm-call-2026-09-28.md", 7_000, QueueLabels(state: .suggested, labels: s(["wazuka", "sourcing", "shading"], [true, false, false]))),
                entry("shading-and-umami-talk-2026-09-28.md", 5_000, QueueLabels(state: .suggesting)),
                entry("sencha-side-by-side.md", 3_000, QueueLabels(state: .own, labels: s(["tasting", "sencha"], [true, true]))),
                entry("tasting-circle-stand-up-2026-09-29.md", 4_000, QueueLabels(state: .failed, error: "Haiku timed out. Retry asks again.", attempts: 1)),
                entry("kettle-care-chat-2026-09-29.md", 3_000, QueueLabels(state: .waiting)),
                QueueEntry(path: dir.appendingPathComponent("gongfu-brewing-guide.pdf").path, modified: now.addingTimeInterval(-2400),
                           size: 2_300_000, settled: true)]
    }
}
