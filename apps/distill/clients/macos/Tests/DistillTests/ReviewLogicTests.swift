import XCTest
@testable import Distill
@testable import DistillKit

/// The v6 Review: summary line, groups that fold, picking → Approve options; the queue label line and toast;
/// the wait setting in hours and minutes.
final class ReviewLogicTests: XCTestCase {
    private func source(_ name: String, labels: [String] = ["tea"], by: ReviewSource.By = .ai, removed: Bool = false) -> ReviewSource {
        ReviewSource(page: "wiki/sources/\(name).md", title: name, source: "inbox/\(name).md", labels: labels, by: by, removed: removed)
    }

    /// Continue after SessionReplaceConfirm approves the same version and part: options from the call, else the marker.
    func testSessionPromptCarriesApproveOptions() {
        let marker = SessionUnavailable(place: "batch", reason: "notFound", action: "approve", labels: "later", pages: ["wiki/sources/A.md"])
        XCTAssertEqual(SessionPrompt(jobID: "j", info: marker).approve, ApproveOptions(labels: .later, pages: ["wiki/sources/A.md"]))
        let fromCall = SessionPrompt(jobID: "j", info: SessionUnavailable(place: "batch", reason: "missing"), action: "approve",
                                     approve: ApproveOptions(pages: ["wiki/sources/B.md"]))
        XCTAssertEqual(fromCall.approve, ApproveOptions(pages: ["wiki/sources/B.md"]))
        XCTAssertTrue(SessionPrompt(jobID: "j", info: SessionUnavailable(place: "batch", reason: "missing")).approve.isEmpty)
    }

    private let teaPaths = ["wiki/sources/A.md", "wiki/sources/B.md", "wiki/sources/C.md",
                            "wiki/entities/Wazuka Tea Farm.md", "wiki/concepts/Water temperature.md", "wiki/concepts/Shading.md",
                            "wiki/index.md", "wiki/overview.md", "wiki/log.md", "wiki/hot.md",
                            "wiki/meta/ledgers/sources.md", "wiki/meta/ledgers/claims.md",
                            ".raw/.manifest.json", ".vault-meta/journal/op.json"]

    // MARK: Summary line

    func testSummaryLineFromChangedPathsAndSources() {
        let s = ReviewSummary.make(changedPaths: teaPaths, sources: [source("A"), source("B"), source("C")])
        XCTAssertEqual(s.line, "3 new source pages · 2 new concepts · 1 new entity · 6 pages updated")
        XCTAssertEqual(s.bookkeeping, [".raw/.manifest.json", ".vault-meta/journal/op.json"], "paths outside wiki/ are bookkeeping, never pages")
        XCTAssertEqual(s.parts.map(\.0), [3, 2, 1, 6])
    }

    func testRemovedSourcesLeaveTheCountAndShowAsRemoved() {
        let s = ReviewSummary.make(changedPaths: teaPaths, sources: [source("A"), source("B", removed: true), source("C")])
        XCTAssertEqual(s.sourcePages, ["wiki/sources/A.md", "wiki/sources/C.md"])
        XCTAssertEqual(s.line, "2 new source pages · 2 new concepts · 1 new entity · 6 pages updated · 1 removed")
    }

    func testExistingPagesInReviewCountAsUpdated() {
        // In Review the vault can tell: an existing concept is updated, a missing other page is new; the vault's own
        // index/log/hot/ledgers always read as updated (even in a fresh vault).
        let exists: (String) -> Bool = { $0 == "wiki/concepts/Shading.md" }
        let s = ReviewSummary.make(changedPaths: teaPaths + ["wiki/Tea club.md"], sources: [source("A"), source("B"), source("C")], exists: exists)
        XCTAssertEqual(s.concepts, ["wiki/concepts/Water temperature.md"])
        XCTAssertEqual(s.otherNew, ["wiki/Tea club.md"])
        XCTAssertTrue(s.updated.contains("wiki/concepts/Shading.md"))
        XCTAssertTrue(s.updated.contains("wiki/index.md"))
        XCTAssertEqual(s.line, "3 new source pages · 1 new concept · 1 new entity · 1 new page · 7 pages updated")
    }

    func testOlderJobsWithoutSourcesReadSourcePagesFromTheirFolder() {
        let s = ReviewSummary.make(changedPaths: teaPaths, sources: nil)
        XCTAssertEqual(s.sourcePages.count, 3)
        XCTAssertEqual(s.removed, 0)
    }

    // MARK: Groups

    func testGroupSummaries() {
        let s = ReviewSummary.make(changedPaths: teaPaths, sources: [source("A"), source("B"), source("C")])
        XCTAssertEqual(s.newPages, ["wiki/entities/Wazuka Tea Farm.md", "wiki/concepts/Water temperature.md", "wiki/concepts/Shading.md"],
                       "entities first, then concepts")
        XCTAssertEqual(s.newPagesSummary, "2 concepts · 1 entity")
        XCTAssertEqual(s.updatedSummary, "Index, Overview, Log, Hot cache, 2 ledgers · plus 2 bookkeeping files")
        XCTAssertEqual(ReviewSummary.kind("wiki/entities/Wazuka Tea Farm.md"), "entity")
        XCTAssertEqual(ReviewSummary.directory("wiki/concepts/Shading.md"), "wiki/concepts")
        XCTAssertEqual(ReviewSummary.pageName("wiki/hot.md"), "Hot cache")
    }

    func testMostUsedLabelsAndNewOnes() {
        let sources = [source("A", labels: ["tea-club", "tasting"]), source("B", labels: ["tasting", "shading"]),
                       source("C", labels: ["tasting", "tea-club", "sourcing"]), source("D", labels: ["kettle"], removed: true)]
        let usage = LabelUsage.make(sources, known: ["tea-club", "tasting", "kettle"])
        XCTAssertEqual(usage.top.map(\.name), ["tasting", "tea-club"])
        XCTAssertEqual(usage.top.map(\.count), [3, 2])
        XCTAssertEqual(usage.new, ["shading", "sourcing"])
        XCTAssertEqual(LabelUsage.make(sources, known: nil).new, [], "labels not loaded: nothing is guessed new")
    }

    func testLabelLineStates() {
        XCTAssertEqual(LabelLineState(review: source("A")), .suggested)
        XCTAssertEqual(LabelLineState(review: source("A", by: .user)), .confirmed)
        XCTAssertEqual(LabelLineState(review: source("A", labels: [])), LabelLineState.none)
        var waiting = source("A", labels: [])
        waiting.state = .waiting
        XCTAssertEqual(LabelLineState(review: waiting), .waiting)
        XCTAssertEqual(LabelLineState(queue: QueueLabels(state: .skipped)), LabelLineState.none)
        XCTAssertEqual(LabelLineState(queue: QueueLabels(state: .own, labels: [LabelSuggestion(name: "tea", existing: true)])), .own)
        XCTAssertNil(LabelLineState(queue: nil))
        XCTAssertEqual(QueueLabelText.note(QueueLabels(state: .failed, attempts: 3)), "tried 3 times")
        XCTAssertNil(QueueLabelText.note(QueueLabels(state: .failed, attempts: 1)))
        XCTAssertEqual(LabelLineText.clean("  #Tea club "), "Tea-club")
    }

    // MARK: Picking → Approve

    func testPickingAllSendsNoPages() {
        let sources = [source("A"), source("B"), source("C", removed: true)]
        XCTAssertEqual(ReviewPicking.options(sources, unpicked: []), ApproveOptions())
        let approval = ApprovalRequest(summary: "", sources: sources)
        XCTAssertEqual(ReviewPicking.approveTitle(approval, unpicked: []), "Approve & apply")
        XCTAssertFalse(ReviewPicking.offersLater(approval, unpicked: []), "no unconfirmed change and everything picked: no menu")
    }

    func testPickingASubset() {
        let sources = [source("A"), source("B"), source("C"), source("D", removed: true)]
        let unpicked: Set = ["wiki/sources/B.md"]
        XCTAssertEqual(ReviewPicking.options(sources, unpicked: unpicked), ApproveOptions(pages: ["wiki/sources/A.md", "wiki/sources/C.md"]))
        XCTAssertEqual(ReviewPicking.options(sources, unpicked: unpicked, later: true),
                       ApproveOptions(labels: .later, pages: ["wiki/sources/A.md", "wiki/sources/C.md"]))
        let approval = ApprovalRequest(summary: "", sources: sources)
        XCTAssertEqual(ReviewPicking.approveTitle(approval, unpicked: unpicked), "Approve 2 sources")
        XCTAssertEqual(ReviewPicking.menuApproveTitle(approval, unpicked: unpicked), "Approve 2 sources")
        XCTAssertTrue(ReviewPicking.offersLater(approval, unpicked: unpicked))
        XCTAssertEqual(ReviewPicking.sourcesSummary(sources, unpicked: unpicked, selectable: true, tail: "labels suggested"),
                       "2 of 3 picked · 1 removed")
        XCTAssertEqual(ReviewPicking.sourcesSummary(sources, unpicked: [], selectable: false, tail: "one page per note"),
                       "1 removed · one page per note")
    }

    func testLaterIsOfferedWhenTheCoreHasAnUnconfirmedChange() {
        let approval = ApprovalRequest(summary: "", sources: [source("A"), source("B")], unconfirmed: UnconfirmedPlan(bundlePath: "/x"))
        XCTAssertTrue(ReviewPicking.offersLater(approval, unpicked: []))
        XCTAssertEqual(ReviewPicking.options(approval.sources, unpicked: [], later: true), ApproveOptions(labels: .later))
    }

    func testApproveWaitsForLabelsAndAPick() {
        let sources = [source("A"), source("B")]
        XCTAssertEqual(ReviewPicking.blocker(ApprovalRequest(summary: "", sources: sources, labels: ReviewLabels(state: .confirming)), unpicked: []),
                       "Saving your labels into the change and checking it again…")
        XCTAssertEqual(ReviewPicking.blocker(ApprovalRequest(summary: "", sources: sources, labels: ReviewLabels(state: .suggesting)), unpicked: []),
                       "Approve when the labels are in")
        XCTAssertEqual(ReviewPicking.blocker(ApprovalRequest(summary: "", sources: sources), unpicked: ["wiki/sources/A.md", "wiki/sources/B.md"]),
                       "Pick at least one source")
        XCTAssertNil(ReviewPicking.blocker(ApprovalRequest(summary: "", sources: sources, labels: ReviewLabels(state: .unconfirmed)), unpicked: []))
        XCTAssertEqual(ReviewPicking.approveTitle(ApprovalRequest(summary: "", sources: sources, rebuilt: RebuiltPlan(reason: .partial)), unpicked: []),
                       "Approve the rebuilt change")
    }

    // MARK: Several batches

    func testBatchesOldestFirstWithSubtitles() {
        var older = Job(id: "job-a", vaultPath: "/v", files: ["inbox/a.md"], createdAt: Date(timeIntervalSince1970: 100))
        older.approval = ApprovalRequest(summary: "", sources: [source("A"), source("B"), source("C", removed: true)])
        older.parts = [JobPart(operationID: "op-1", pages: ["wiki/sources/Z.md"], at: Date())]
        let newer = Job(id: "job-b", vaultPath: "/v", files: ["inbox/x.pdf", "inbox/y.pdf", "inbox/z.pdf"], createdAt: Date(timeIntervalSince1970: 200))
        XCTAssertEqual(ReviewBatches.ordered([newer, older]).map(\.id), ["job-a", "job-b"])
        XCTAssertEqual(ReviewBatches.tabSubtitle(older), "2 left")
        XCTAssertEqual(ReviewBatches.tabSubtitle(newer), "3 sources")
        let utc = TimeZone(identifier: "UTC")!
        let part = JobPart(operationID: "op-2", pages: ["a", "b"], labels: .later, at: Date(timeIntervalSince1970: 0))
        XCTAssertEqual(ReviewBatches.partLine(part, now: Date(timeIntervalSince1970: 0), locale: Locale(identifier: "en_US"), timeZone: utc)
                        .replacingOccurrences(of: "\u{202F}", with: " "),
                       "2 sources at 12:00 AM · op-2 · labels left to review")
    }

    // MARK: Queue toast

    func testProcessNowToast() {
        let started = QueueLabelText.processToast(started: 19, held: 3, rows: 3, next: nil)
        XCTAssertEqual(started?.title, "Started a batch with 19 files")
        XCTAssertEqual(started?.detail, "3 notes are still being labeled; they’ll go in the next batch.")
        let nothing = QueueLabelText.processToast(started: nil, held: 3, rows: 3, next: "7:30 AM")
        XCTAssertEqual(nothing?.title, "Nothing to batch yet")
        XCTAssertEqual(nothing?.detail, "All 3 files are still being labeled. Distill starts the batch when their labels are in (or at 7:30 AM).")
        XCTAssertNil(QueueLabelText.processToast(started: nil, held: 2, rows: 5, next: nil), "something else held the batch: no label toast")
        XCTAssertNil(QueueLabelText.processToast(started: 4, held: 0, rows: 0, next: nil))
        XCTAssertEqual(QueueLabelText.held(3), "3 files wait for labels")
        XCTAssertNil(QueueLabelText.held(0))
    }

    // MARK: Wait before picking up a file

    func testSettleHoursAndMinutes() {
        var w = SettleWait(totalSeconds: 4 * 3600 + 15 * 60)
        XCTAssertEqual([w.hours, w.minutes], [4, 15])
        w.minutes = 0
        XCTAssertEqual(w.totalSeconds, 14_400)
        w.hours = 24
        w.minutes = 30
        XCTAssertEqual(w.totalSeconds, 86_400, "clamped to 24 hours")
        XCTAssertEqual(SettleWait.clamp(-5), 0)
        XCTAssertEqual(SettleWait.presets.map(\.1), [0, 60, 600, 3600, 14_400, 86_400])
        XCTAssertEqual(QueueRows.waitPhrase(5400), "1 hour 30 min")
        XCTAssertEqual(QueueRows.waitPhrase(7200), "2 hours")
        XCTAssertEqual(QueueRows.waitPhrase(90), "1 min 30 s")
    }
}
