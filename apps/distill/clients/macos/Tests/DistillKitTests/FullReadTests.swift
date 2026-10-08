import XCTest
@testable import DistillKit

/// v10 Full reads (full-read.md): the new job, status and settings fields decode leniently, unknown keys
/// survive a save, the held routes, the inbox stay reasons, and the words the app shows.
final class FullReadTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: String(repeating: "f", count: 64)), session: URLSession(configuration: config))
    }

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.core.decode(T.self, from: Data(json.utf8))
    }

    // MARK: Decoding

    func testJobDecodesCoverageStoppedAndBatchOf() throws {
        let job = try decode(Job.self, #"""
        {"id":"job-1","state":"awaitingApproval",
         "coverage":{"sources":[{"file":"inbox/a.md","lines":644,"read":644,"state":"full","images":1},
                                {"file":"inbox/b.md","lines":647,"read":400,"state":"later","rounds":2,"readTo":400},
                                {"file":"inbox/c.md","lines":"many","state":"somethingNew"},
                                {"lines":3}],
                     "full":1,"of":1,"lines":644,"rounds":3,"continued":"one","state":"split",
                     "detail":{"checked":1,"added":7,"left":2,"note":"  "},
                     "partialWording":["wiki/sources/a.md",3],"later":["inbox/b.md"],"archived":1},
         "stopped":[{"file":"inbox/v.md","reason":"it isn’t valid UTF-8 text from line 412","at":"2026-10-05T10:40:00Z"},{"reason":"no file"}],
         "batchOf":{"index":1,"total":3,"tokens":96000},
         "approval":{"summary":"s","rebuilt":{"reason":"covered","pages":["wiki/sources/a.md"]}},
         "pendingPart":{"reason":"unread","expected":{},"unread":["inbox/b.md"]}}
        """#)
        let c = try XCTUnwrap(job.coverage)
        XCTAssertEqual(c.sources.count, 3, "an entry without a file is skipped")
        XCTAssertEqual(c.sources[2].lines, 0)
        XCTAssertEqual(c.sources[2].state, "somethingNew")
        XCTAssertEqual(c.rounds, 3)
        XCTAssertEqual(c.continued, 0, "a wrong type reads as 0")
        XCTAssertNil(c.sources[0].rounds)
        XCTAssertEqual(c.sources[1].rounds, 2)
        XCTAssertEqual(c.sources[1].readTo, 400)
        XCTAssertNil(c.sources[0].readTo, "absent for a full source")
        XCTAssertEqual(c.laterSources.map(\.file), ["inbox/b.md"])
        XCTAssertEqual(c.state, "split")
        XCTAssertEqual(c.detail, CoverageDetail(checked: 1, added: 7, left: 2, note: nil), "a blank note is none")
        XCTAssertEqual(c.partialWording, ["wiki/sources/a.md"])
        XCTAssertEqual(c.later, ["inbox/b.md"])
        XCTAssertEqual(c.archived, 1)
        XCTAssertEqual(c.images, 1, "images of sources in the change only")
        XCTAssertEqual(job.stopped.map(\.file), ["inbox/v.md"])
        XCTAssertNotNil(job.stopped[0].at)
        XCTAssertEqual(job.batchOf, BatchOf(index: 1, total: 3, tokens: 96_000))
        XCTAssertEqual(job.approval?.rebuilt?.reason, .covered)
        XCTAssertEqual(job.pendingPart?.reason, .unread)
        XCTAssertEqual(job.pendingPart?.unread, ["inbox/b.md"])

        // Round trip keeps them (jobs.json written by an older Swift build must not lose them).
        let again = try JSONDecoder.core.decode(Job.self, from: JSONEncoder.core.encode(job))
        XCTAssertEqual(again.coverage, job.coverage)
        XCTAssertEqual(again.stopped, job.stopped)
        XCTAssertEqual(again.batchOf, job.batchOf)
    }

    func testOlderCoresAndWrongTypesFallBack() throws {
        let old = try decode(Job.self, #"{"id":"job-1","state":"running"}"#)
        XCTAssertNil(old.coverage)
        XCTAssertEqual(old.stopped, [])
        XCTAssertNil(old.batchOf)
        let wrong = try decode(Job.self, #"{"id":"job-1","state":"running","coverage":"full","stopped":{"file":"x"},"batchOf":{"index":"one","total":3}}"#)
        XCTAssertNil(wrong.coverage)
        XCTAssertEqual(wrong.stopped, [])
        XCTAssertNil(wrong.batchOf)
        XCTAssertNil(try decode(Job.self, #"{"id":"j","batchOf":{"index":4,"total":3}}"#).batchOf, "an index past the total is no batch")
        let unknown = try decode(RebuiltPlan.self, #"{"reason":"fromTheFuture","pages":[]}"#)
        XCTAssertEqual(unknown.reason, .partial)
    }

    func testStatusDecodesBudgetAndHeldCount() throws {
        let s = try decode(StatusResponse.self, #"{"batchBudget":{"tokens":100000,"contextWindow":1000000,"model":"claude-sonnet-5-5","automatic":true},"heldCount":2}"#)
        XCTAssertEqual(s.batchBudget, BatchBudget(tokens: 100_000, contextWindow: 1_000_000, model: "claude-sonnet-5-5", automatic: true))
        XCTAssertEqual(s.heldCount, 2)
        let old = try decode(StatusResponse.self, #"{"version":"1"}"#)
        XCTAssertNil(old.batchBudget)
        XCTAssertEqual(old.heldCount, 0)
        let wrong = try decode(StatusResponse.self, #"{"batchBudget":{"tokens":"lots"},"heldCount":"two"}"#)
        XCTAssertNil(wrong.batchBudget)
        XCTAssertEqual(wrong.heldCount, 0)
        let again = try JSONDecoder.core.decode(StatusResponse.self, from: JSONEncoder.core.encode(s))
        XCTAssertEqual(again, s)
    }

    // MARK: Settings

    func testBatchSizeSettingAndPatch() throws {
        let absent = try decode(Settings.self, #"{}"#)
        XCTAssertNil(absent.batchSourceTokens)
        XCTAssertNil(absent.jsonObject()["batchSourceTokens"], "absent stays absent on save")
        XCTAssertEqual(BatchSize(tokens: absent.batchSourceTokens), .automatic)
        XCTAssertNil(try decode(Settings.self, #"{"batchSourceTokens":null}"#).batchSourceTokens)
        XCTAssertNil(try decode(Settings.self, #"{"batchSourceTokens":"big"}"#).batchSourceTokens)
        XCTAssertNil(try decode(Settings.self, #"{"batchSourceTokens":-5}"#).batchSourceTokens)

        var smaller = absent
        smaller.batchSourceTokens = BatchSize.smaller.tokens
        XCTAssertEqual(Settings.patch(from: absent, to: smaller), ["batchSourceTokens": .number(50_000)])
        var automatic = smaller
        automatic.batchSourceTokens = BatchSize.automatic.tokens
        XCTAssertEqual(Settings.patch(from: smaller, to: automatic), ["batchSourceTokens": .null], "Automatic writes null")

        XCTAssertEqual(BatchSize(tokens: 200_000), .larger)
        XCTAssertEqual(BatchSize(tokens: 75_000).label, "75K")
        XCTAssertEqual(BatchSize.options.map(\.label), ["Automatic", "Smaller (50K)", "Larger (200K)"])
    }

    func testDetailLevelsKeepUnknownKeysAndDefault() throws {
        let s = try decode(Settings.self, #"{"detailLevel":{"meeting":"nearComplete","research":"bogus","podcast":"detailed"}}"#)
        XCTAssertEqual(s.detailLevel.level("meeting"), .nearComplete)
        XCTAssertEqual(s.detailLevel.level("research"), .highlights, "an unknown value reads as the default")
        XCTAssertEqual(s.detailLevel.level("conversation"), .detailed)
        XCTAssertEqual(s.detailLevel.level("other"), .highlights)

        var edited = s
        var levels = edited.detailLevel ?? DetailLevels()
        levels.set("conversation", .highlights)
        edited.detailLevel = levels
        let patch = Settings.patch(from: s, to: edited)
        XCTAssertEqual(patch["detailLevel"], .object(["meeting": .string("nearComplete"), "research": .string("bogus"),
                                                       "podcast": .string("detailed"), "conversation": .string("highlights")]),
                       "every key the core sent survives; only the row changed")

        let none = try decode(Settings.self, #"{"detailLevel":"detailed"}"#)
        XCTAssertNil(none.detailLevel)
        XCTAssertEqual(none.detailLevel.level("meeting"), .detailed)
        XCTAssertEqual(DetailLevels.rows.map(\.title), ["Meetings and calls", "Conversations and chats", "Articles and research"])
        XCTAssertEqual(DetailLevel.allCases.map(\.label), ["Highlights", "Detailed", "Near-complete"])
    }

    // MARK: Routes

    func testHeldListAndRetry() async throws {
        StubProtocol.handler = { _ in (200, Data(#"""
        {"held":[{"file":"inbox/Vendor call export.md","sha256":"ab","reason":"it isn’t valid UTF-8 text from line 412","at":"2026-10-05T10:31:00Z","jobId":"job-3","size":212000},
                 {"reason":"no file"}]}
        """#.utf8)) }
        let held = try await client.held(vaultPath: "/My Vault")
        XCTAssertEqual(held.map(\.file), ["inbox/Vendor call export.md"])
        XCTAssertEqual(held[0].jobId, "job-3")
        XCTAssertEqual(held[0].size, 212_000)
        var last = try XCTUnwrap(StubProtocol.recorded.last)
        XCTAssertEqual(last.path, "/v1/held")
        XCTAssertEqual(last.query, "vault=/My%20Vault")

        StubProtocol.handler = { _ in (201, Data(#"""
        {"id":"rr-1","vaultPath":"/v","perBatch":1,"groups":[{"index":1,"files":["inbox/Vendor call export.md"]}],
         "started":[{"id":"job-9","state":"running"}],"waiting":0}
        """#.utf8)) }
        let r = try await client.retryHeld(file: "inbox/Vendor call export.md", vaultPath: "/v")
        XCTAssertEqual(r.id, "rr-1")
        XCTAssertEqual(r.groups, 1)
        XCTAssertEqual(r.started.map(\.id), ["job-9"])
        last = try XCTUnwrap(StubProtocol.recorded.last)
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.path, "/v1/held/retry")
        XCTAssertEqual(try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data()),
                       .object(["file": .string("inbox/Vendor call export.md"), "vault": .string("/v")]))
    }

    func testHeldOnAnOlderCoreIsEmpty() async throws {
        StubProtocol.handler = { _ in (501, Data(#"{"error":{"code":"not_implemented","message":"listHeld: not implemented"}}"#.utf8)) }
        let a = try await client.held()
        XCTAssertEqual(a, [])
        StubProtocol.handler = { _ in (404, Data(#"{"error":{"code":"not_found","message":"no route for GET /v1/held"}}"#.utf8)) }
        let b = try await client.held()
        XCTAssertEqual(b, [])
    }

    // MARK: Inbox: Clear inbox

    func testNewStayReasonsAndClearWords() throws {
        let p = try decode(InboxCleanupPreview.self, #"""
        {"vaultPath":"/v","items":[{"path":"inbox/a.md","fileCount":21}],
         "stays":[{"path":"inbox/t.md","reason":"notReadInFull"},{"path":"inbox/o.md","reason":"notArchived"},{"path":"inbox/v.md","reason":"held"}]}
        """#)
        XCTAssertEqual(p.stays.map(\.reasonWords), ["not read in full yet", "not archived yet", "couldn’t be read"])
        XCTAssertEqual(p.stays.map(\.isWarning), [false, false, true])
        XCTAssertEqual(p.staysByReason.map(\.reason), ["notReadInFull", "notArchived", "held"], "every new reason is counted")
        XCTAssertEqual(InboxCleanupWords.button(p), "Clear inbox · 21 files")
        XCTAssertEqual(InboxCleanupWords.confirmTitle(21), "Clear 21 files from inbox?")
        XCTAssertEqual(InboxCleanupWords.moveButton(21), "Clear 21 from inbox")
        XCTAssertEqual(InboxCleanupWords.willClear(21), "Will clear · 21 files, all archived")
        XCTAssertEqual(InboxCleanupWords.title, "Clear inbox")
        XCTAssertEqual(InboxCleanupWords.confirmText,
                       "Their originals are archived in your vault (.raw/captured/), byte for byte, and are never changed or deleted. Every one was read in full. The inbox copies go to the Trash.")
    }

    // MARK: Words

    func testBudgetAndQueueWords() {
        let b = BatchBudget(tokens: 100_000, contextWindow: 1_000_000, model: "claude-sonnet-5-5", automatic: true)
        XCTAssertEqual(FullReadWords.budgetLine(b), "Sonnet (1M context): up to 100K tokens, about 260 KB of text")
        XCTAssertEqual(FullReadWords.budgetLine(BatchBudget(tokens: 60_000, model: "sonnet")), "Sonnet: up to 60K tokens, about 156 KB of text")
        XCTAssertTrue(FullReadWords.batchSizeNote(nil).hasPrefix("How much text one batch takes"))
        XCTAssertTrue(FullReadWords.batchSizeNote(b).hasSuffix("Sonnet (1M context): up to 100K tokens, about 260 KB of text."))
        XCTAssertEqual(FullReadWords.tokens(96_000), "96K")
        XCTAssertEqual(FullReadWords.tokens(1_500), "1.5K")
        XCTAssertEqual(FullReadWords.tokens(800), "800")

        let of = BatchOf(index: 1, total: 3, tokens: 96_000)
        XCTAssertEqual(FullReadWords.batchTitle(of, sources: 9, vault: "MyKnowledgeVault"), "Batch 1 of 3 · reading 9 sources into MyKnowledgeVault")
        XCTAssertNil(FullReadWords.batchTitle(BatchOf(index: 1, total: 1), sources: 9, vault: "V"), "one batch is not \"1 of 1\"")
        XCTAssertNil(FullReadWords.batchTitle(nil, sources: 9, vault: "V"))
        XCTAssertEqual(FullReadWords.batchTokens(of), "About 96K tokens of text")
        XCTAssertEqual(FullReadWords.queueTitle(inBatch: 9, waiting: 14, of: of), "9 in this batch · 14 in the next 2 batches")
        XCTAssertEqual(FullReadWords.queueTitle(inBatch: 9, waiting: 2, of: BatchOf(index: 2, total: 3)), "9 in this batch · 2 in the next batch")
        XCTAssertEqual(FullReadWords.queueTitle(inBatch: 3, waiting: 2, of: nil), "3 in this batch · 2 waiting")
        XCTAssertEqual(FullReadWords.queueTitle(inBatch: 3, waiting: 0, of: of), "3 in this batch")
    }

    func testReviewCoverageWords() {
        let c = CoverageSummary(sources: [CoverageSource(file: "inbox/a.md", lines: 644, images: 1),
                                          CoverageSource(file: "inbox/b.md", lines: 787, images: 5)],
                                full: 9, of: 9, lines: 4_870, rounds: 5, continued: 2, state: "complete", archived: 9)
        let read = FullReadWords.readLine(c)
        XCTAssertEqual(read.title, "Read in full")
        XCTAssertEqual(read.text, "9 of 9 sources · 4,870 lines")
        XCTAssertEqual(read.quiet, "counted by Distill from Claude’s reads; 2 needed a second round")
        XCTAssertEqual(FullReadWords.readLine(CoverageSummary(full: 1, of: 1, lines: 1)).quiet, "counted by Distill from Claude’s reads")
        XCTAssertEqual(FullReadWords.readLine(CoverageSummary(full: 1, of: 1, lines: 1, rounds: 1)).quiet, "counted by Distill from Claude’s reads",
                       "rounds of other kinds (the detail pass) don't count as a second round")
        XCTAssertEqual(FullReadWords.readLine(c, stopped: 1).text, "9 of 9 sources in this change · 4,870 lines")

        XCTAssertEqual(FullReadWords.detailLine(CoverageDetail(checked: 9, added: 7, left: 2)).text,
                       "each page checked against its source · 7 missing items were added before this review · 2 left out")
        XCTAssertEqual(FullReadWords.detailLine(CoverageDetail(checked: 5)).text, "each page checked against its source · nothing missing")
        XCTAssertEqual(FullReadWords.detailLine(CoverageDetail(added: 1)).text,
                       "each page checked against its source · 1 missing item was added before this review")

        XCTAssertEqual(FullReadWords.archivedLine(c)?.title, "Originals archived")
        XCTAssertNil(FullReadWords.archivedLine(CoverageSummary()))
        XCTAssertEqual(FullReadWords.imagesLine(c), "6 embedded images are not text and were not read.")
        XCTAssertNil(FullReadWords.imagesLine(CoverageSummary()))
        XCTAssertEqual(FullReadWords.partialWordingLine("wiki/sources/Tomasz and Jin.md"),
                       "The page for Tomasz and Jin still calls itself partial, though every line was read")
    }

    func testSourceRowMetaAndMatching() {
        XCTAssertEqual(FullReadWords.sourceMeta(CoverageSource(file: "inbox/a.md", lines: 644, images: 1)), "644 lines · read in full · 1 image not read")
        XCTAssertEqual(FullReadWords.sourceMeta(CoverageSource(file: "inbox/a.md", lines: 630)), "630 lines · read in full")
        XCTAssertEqual(FullReadWords.sourceMeta(CoverageSource(file: "inbox/b.md", lines: 789, read: 412, state: "later", readTo: 412)),
                       "789 lines · read up to line 412 in this session · next: a fresh session")
        XCTAssertEqual(FullReadWords.sourceMeta(CoverageSource(file: "inbox/b.md", lines: 789, read: 300, state: "later", readTo: 0)),
                       "789 lines · next: a fresh session", "nothing read from line 1 on")
        XCTAssertEqual(FullReadWords.sourceMeta(CoverageSource(file: "inbox/b.md", lines: 789, read: 300, state: "later")),
                       "789 lines · next: a fresh session", "an older core without readTo")
        XCTAssertEqual(FullReadWords.sourceMeta(CoverageSource(file: "inbox/c.md", lines: 1_200, read: 400, state: "partial")),
                       "1,200 lines · read up to line 400")
        XCTAssertEqual(FullReadWords.sourceMeta(CoverageSource(file: "inbox/scan.pdf", lines: 1)), "read in full")
        XCTAssertEqual(FullReadWords.sourceMeta(CoverageSource(file: "inbox/v.md", lines: 0, read: 0, state: "unreadable")), "couldn’t be read")

        let c = CoverageSummary(sources: [CoverageSource(file: "inbox/a.md", lines: 3), CoverageSource(file: "inbox/sub/b.md", lines: 4)])
        XCTAssertEqual(c.source("inbox/a.md")?.lines, 3)
        XCTAssertEqual(c.source("/Vault/inbox/sub/b.md")?.lines, 4, "by name when the path form differs")
        XCTAssertNil(c.source(nil))
        XCTAssertNil(c.source("inbox/zzz.md"))
    }

    func testLaterAndStoppedWords() throws {
        let two = try XCTUnwrap(FullReadWords.laterNotice(["inbox/Develop FE With AI.md", "inbox/Tomasz and Jin.md"]))
        XCTAssertEqual(two.title, "2 sources are read next, in a fresh session")
        XCTAssertEqual(two.names, "Develop FE With AI, Tomasz and Jin")
        XCTAssertEqual(two.text, "This session ran out of room before their last lines, so they were taken out of this change. Once you approve these, Claude reads them again from the start and they come back here as the next part.")
        XCTAssertEqual(FullReadWords.laterNotice(["inbox/a.md"])?.title, "1 source is read next, in a fresh session")
        XCTAssertNil(FullReadWords.laterNotice([]))

        XCTAssertEqual(FullReadWords.stoppedTitle(1), "Not added · couldn’t be read · 1 file")
        XCTAssertEqual(FullReadWords.stoppedTitle(2), "Not added · couldn’t be read · 2 files")
        XCTAssertEqual(FullReadWords.stoppedText("it isn’t valid UTF-8 text from line 412"),
                       "It isn’t valid UTF-8 text from line 412. It is not part of this change, and nothing from it is in your vault.")
        XCTAssertEqual(FullReadWords.sentence("the reads stopped at line 139 of 644 every time."), "The reads stopped at line 139 of 644 every time.")
        XCTAssertEqual(FullReadWords.stoppedFooter(1), "The file that couldn’t be read is not in this change")
        XCTAssertEqual(FullReadWords.stoppedFooter(2), "The 2 files that couldn’t be read are not in this change")
    }

    func testNewActivityKindsUseTheBatchRow() throws {
        let e = try decode(ActivityEntry.self, #"""
        {"id":"a1","at":"2026-10-05T10:40:00.000Z","type":"batch.read_stopped","source":"core",
         "object":{"kind":"batch","id":"job-3","name":"Meeting notes, Oct 1 – 2"},
         "summary":"Couldn’t read “Vendor call export” in full: it isn’t valid UTF-8 text from line 412","outcome":"failed",
         "details":{"file":"inbox/Vendor call export.md","reason":"it isn’t valid UTF-8 text from line 412"}}
        """#)
        XCTAssertEqual(e.family, "batch")
        XCTAssertEqual(e.verb, "read_stopped")
        let facts = ActivityText().facts(e, now: e.at)
        XCTAssertTrue(facts.rows.contains { $0.value == "it isn’t valid UTF-8 text from line 412" }, "the core's facts show as they are")
        XCTAssertTrue(facts.rows.contains { $0.value == "batch.read_stopped" })
        let repair = try decode(ActivityEntry.self, #"{"id":"a2","at":"2026-10-05T08:40:00.000Z","type":"batch.repair_queued","object":{"kind":"batch","id":"rr-1"},"summary":"19 sources weren’t checked for a full read; reading them again"}"#)
        XCTAssertEqual(repair.family, "batch")
        XCTAssertEqual(repair.summary, "19 sources weren’t checked for a full read; reading them again")
    }

    func testCoveredPartFooterFollowsTheBoard() {
        func job(_ reason: PartReason?, pending: PartReason? = nil) -> Job {
            var j = Job(id: "job-1", vaultPath: "/v", files: ["inbox/a.md", "inbox/b.md"], state: .awaitingApproval)
            j.approval = ApprovalRequest(summary: "s", rebuilt: reason.map { RebuiltPlan(reason: $0, pages: ["wiki/sources/a.md", "wiki/sources/b.md"]) })
            j.approval?.sources = [ReviewSource(page: "wiki/sources/a.md", title: "A", source: "inbox/a.md"),
                                   ReviewSource(page: "wiki/sources/b.md", title: "B", source: "inbox/b.md")]
            j.pendingPart = pending.map { PendingPart(reason: $0) }
            return j
        }
        let covered = job(.covered)
        XCTAssertTrue(ReviewPicking.isCoveredPart(covered))
        XCTAssertFalse(ReviewPicking.offersDiscardPart(covered), "nothing is applied before the covered part")
        XCTAssertEqual(ReviewPicking.rejectTitle(covered), "Reject")
        XCTAssertEqual(ReviewPicking.approveTitle(covered.approval, unpicked: []), "Approve 2 sources")
        XCTAssertTrue(ReviewPicking.isCoveredPart(job(nil, pending: .covered)))

        let unread = job(.unread)
        XCTAssertFalse(ReviewPicking.isCoveredPart(unread))
        XCTAssertTrue(ReviewPicking.offersDiscardPart(unread), "a part is already in the vault")
        XCTAssertEqual(ReviewPicking.rejectTitle(unread), "Reject batch")
        XCTAssertEqual(ReviewPicking.approveTitle(unread.approval, unpicked: []), "Approve the rebuilt change")

        let plain = job(nil)
        XCTAssertFalse(ReviewPicking.offersDiscardPart(plain))
        XCTAssertEqual(ReviewPicking.rejectTitle(plain), "Reject")
    }

    func testReadToDecodesLeniently() throws {
        let c = try decode(CoverageSummary.self, #"""
        {"sources":[{"file":"inbox/a.md","lines":10,"state":"later","readTo":"ten"},{"file":"inbox/b.md","lines":10,"state":"later","readTo":-3},
                    {"file":"inbox/c.md","lines":10,"state":"later","readTo":7.0}]}
        """#)
        XCTAssertEqual(c.sources.map(\.readTo), [nil, 0, 7])
        let again = try JSONDecoder.core.decode(CoverageSummary.self, from: JSONEncoder.core.encode(c))
        XCTAssertEqual(again.sources.map(\.readTo), [nil, 0, 7])
    }

    func testHeldWords() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = Date(timeIntervalSince1970: 1_791_200_000) // 2026-10-05 11:33 UTC
        XCTAssertEqual(FullReadWords.heldSince(now.addingTimeInterval(-3_600), now: now, calendar: cal), "In inbox/ since 10:33 AM")
        XCTAssertEqual(FullReadWords.heldSince(now.addingTimeInterval(-2 * 86_400), now: now, calendar: cal), "In inbox/ since Oct 3")
        XCTAssertEqual(FullReadWords.heldSince(nil), "In inbox/")
        XCTAssertEqual(FullReadWords.heldHint("it isn’t valid UTF-8 text from line 412"),
                       "It isn’t valid UTF-8 text from line 412. Fix the file, then Try again: Distill reads it in a batch of its own.")
        XCTAssertEqual(FullReadWords.heldCaption, "A held file counts in the sidebar until it is read in full or you remove it. Clean up never clears it.")
    }
}

/// The "Not added" card after a failed apply: gone once a rebuilt plan replaces the approved one,
/// and "added" when the vault's journal shows the plan applied in Terminal.
final class ApplyRecoveryTests: XCTestCase {
    private func job(_ json: String) throws -> Job { try JSONDecoder().decode(Job.self, from: Data(json.utf8)) }

    func testARebuiltPlanReplacesTheApprovedOne() throws {
        let base = #""id":"j","vaultPath":"/v","state":"awaitingApproval","approvedChange":{"at":"2026-10-06T01:55:00Z","operationID":"op","changes":3"#
        let same = try job("{\(base),\"approvalSha256\":\"aaaa1111\"},\"approval\":{\"plan\":{\"operation_id\":\"op\",\"approval_sha256\":\"aaaa1111\"}}}")
        XCTAssertFalse(ApplyTimeline.planReplaced(same))
        let rebuilt = try job("{\(base),\"approvalSha256\":\"aaaa1111\"},\"approval\":{\"plan\":{\"operation_id\":\"op\",\"approval_sha256\":\"bbbb2222\"}}}")
        XCTAssertTrue(ApplyTimeline.planReplaced(rebuilt))
    }

    func testOlderJobsUseTheApprovedTurn() throws {
        let j = try job(#"{"id":"j","vaultPath":"/v","state":"awaitingApproval","approvedChange":{"at":"2026-10-06T01:55:00Z","operationID":"op","changes":3},"approval":{"plan":{"operation_id":"op","approval_sha256":"bbbb2222cccc3333"}},"turns":[{"id":"t","date":"2026-10-06T01:55:00Z","author":"user","text":"Approved op (aaaa1111bbbb…)"}]}"#)
        XCTAssertTrue(ApplyTimeline.planReplaced(j))
    }

    func testAppliedInTerminalShowsAddedDespiteTheFailedStep() throws {
        let j = try job(#"{"id":"j","vaultPath":"/v","kind":"ingest","state":"completed","operationID":"op","changedPaths":["wiki/a.md"],"approvedChange":{"at":"2026-10-06T01:55:00Z","operationID":"op","changes":1,"appliedOutside":true}}"#)
        let failed = JobStep(id: "apply-1", at: Date(timeIntervalSince1970: 1_791_252_000), phase: "apply", state: "failed", verb: "apply", text: "Not added")
        let t = try XCTUnwrap(ApplyTimeline.make(job: j, steps: [failed]))
        XCTAssertFalse(t.isFailed)
    }
}
