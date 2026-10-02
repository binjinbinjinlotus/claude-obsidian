import XCTest
@testable import DistillKit

/// v3 routes (progress, cancelAsk, job delete/resume, queue entry removal) and
/// the UI-free Ask rules (filter defaults, Any/All, history policy, links).
final class AskFlowTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
    }

    func respond(_ json: String, status: Int = 200) { StubProtocol.handler = { _ in (status, Data(json.utf8)) } }
    var last: StubProtocol.Recorded { StubProtocol.recorded.last! }
    func bodyJSON() throws -> JSONValue { try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data()) }

    // MARK: DTOs and events

    func testProgressEventDecodes() throws {
        let line = #"{"type":"progress","progress":{"key":"job-1","kind":"batch","message":"Reading 3 sources","steps":["Moved to inbox","Read sources","Drafting page changes","Ready for review"],"stepIndex":2,"startedAt":"2026-10-01T12:00:00.123Z","runnerID":"claude-code","model":"sonnet"}}"#
        guard case .progress(let p) = try CoreEvent.decode(Data(line.utf8)) else { return XCTFail("not a progress event") }
        XCTAssertEqual(p.key, "job-1")
        XCTAssertEqual(p.kind, "batch")
        XCTAssertEqual(p.steps.count, 4)
        XCTAssertEqual(p.stepIndex, 2)
        XCTAssertFalse(p.finished)
        XCTAssertEqual(p.model, "sonnet")
        XCTAssertEqual(p.startedAt.timeIntervalSince1970, CoreDate.parse("2026-10-01T12:00:00Z")!.timeIntervalSince1970 + 0.123, accuracy: 0.01)

        let tolerant = #"{"type":"progress","progress":{"key":"note:r1","kind":"labelSuggest","message":7,"done":"x","finished":true,"error":"no runner"}}"#
        guard case .progress(let q) = try CoreEvent.decode(Data(tolerant.utf8)) else { return XCTFail() }
        XCTAssertEqual(q.message, "")
        XCTAssertNil(q.done)
        XCTAssertTrue(q.finished)
        XCTAssertEqual(q.error, "no runner")
        XCTAssertEqual(CoreProgress.noteKey("r1"), q.key)
        XCTAssertEqual(CoreProgress.askKey("c1"), "ask:c1")
    }

    func testProgressRoundTrips() throws {
        let p = CoreProgress(key: "job-2", kind: "apply", message: "Applying 4 changes", done: 1, total: 4,
                             startedAt: CoreDate.parse("2026-10-01T12:00:00Z")!, finished: true)
        let back = try JSONDecoder.core.decode(CoreProgress.self, from: JSONEncoder.core.encode(p))
        XCTAssertEqual(back, p)
    }

    // MARK: Routes

    func testListProgressWrappedAndSkipsBadItems() async throws {
        respond(#"{"progress":[{"key":"job-1","kind":"batch","message":"m","startedAt":"2026-10-01T12:00:00Z"},{"nokey":true}]}"#)
        let list = try await client.listProgress()
        XCTAssertEqual(list.map(\.key), ["job-1"])
        XCTAssertEqual(last.method, "GET")
        XCTAssertEqual(last.path, "/v1/progress")
    }

    func testListProgressOnOlderCoreIsNotAvailable() async {
        respond(#"{"error":{"code":"not_found","message":"no route for /v1/progress"}}"#, status: 404)
        do { _ = try await client.listProgress(); XCTFail() } catch let e as CoreClientError { XCTAssertTrue(e.isNotAvailable) } catch { XCTFail() }
    }

    func testCancelAsk() async throws {
        respond("{}")
        try await client.cancelAsk(conversationID: "c 1")
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.path, "/v1/conversations/c 1/cancel")
        respond(#"{"error":{"code":"not_implemented","message":"cancelAsk: not implemented"}}"#, status: 501)
        do { try await client.cancelAsk(conversationID: "c1"); XCTFail() } catch let e as CoreClientError { XCTAssertTrue(e.isNotAvailable) } catch { XCTFail() }
    }

    func testDeleteJobAndResume() async throws {
        respond(#"{"id":"job-1","deleted":true}"#)
        try await client.deleteJob("job-1")
        XCTAssertEqual(last.method, "DELETE")
        XCTAssertEqual(last.path, "/v1/jobs/job-1")

        respond(#"{"argv":["claude","--resume","s1"],"cwd":"/v"}"#)
        let resume = try await client.jobResume("job-1")
        XCTAssertEqual(resume.argv, ["claude", "--resume", "s1"])
        XCTAssertEqual(resume.cwd, "/v")
        XCTAssertEqual(last.path, "/v1/jobs/job-1/resume")
    }

    func testRemoveQueueEntry() async throws {
        respond(#"{"entries":[]}"#)
        try await client.removeQueueEntry(path: "/q/a b.md")
        XCTAssertEqual(last.method, "DELETE")
        XCTAssertEqual(last.path, "/v1/queue/entries")
        XCTAssertEqual(try bodyJSON(), .object(["path": .string("/q/a b.md")]))
    }

    func testAskNewChatSendsClientIDAndFallsBackOnOlderCore() async throws {
        // Newer core: accepts the id.
        respond(#"{"conversationID":"11111111-1111-1111-1111-111111111111","answer":"a","citations":[],"gaps":[],"costUSD":0}"#)
        let id = "11111111-1111-1111-1111-111111111111"
        let ok = try await client.askNewChat(AskRequest(question: "Q", conversationID: id))
        XCTAssertEqual(ok.conversationID, id)
        XCTAssertEqual(try bodyJSON()["conversationID"], .string(id))
        XCTAssertEqual(StubProtocol.recorded.count, 1)

        // Older core: unknown conversation → retried without the id.
        StubProtocol.recorded = []
        StubProtocol.handler = { _ in
            let body = try? JSONDecoder.core.decode(JSONValue.self, from: StubProtocol.recorded.last?.body ?? Data())
            if body?["conversationID"] != nil {
                return (404, Data(#"{"error":{"code":"conversation_not_found","message":"no conversation"}}"#.utf8))
            }
            return (200, Data(#"{"conversationID":"core-picked","answer":"a","citations":[],"gaps":[],"costUSD":0}"#.utf8))
        }
        let fallback = try await client.askNewChat(AskRequest(question: "Q", conversationID: id))
        XCTAssertEqual(fallback.conversationID, "core-picked")
        XCTAssertEqual(StubProtocol.recorded.count, 2)
        XCTAssertNil(try bodyJSON()["conversationID"])
    }

    func testAskNewChatDoesNotRetryOtherErrors() async {
        respond(#"{"error":{"code":"no_vault","message":"No vault"}}"#, status: 409)
        do { _ = try await client.askNewChat(AskRequest(question: "Q", conversationID: "x")); XCTFail() } catch {}
        XCTAssertEqual(StubProtocol.recorded.count, 1)
    }

    // MARK: Filter rules

    func testFilterDefaultsComeFromPreferences() {
        let none = AskFilter(preferences: nil)
        XCTAssertEqual(none.labelMatch, .any)
        XCTAssertTrue(none.includeUnconfirmed)
        XCTAssertTrue(none.isEmpty)

        var settings = Settings()
        settings.askPreferences = AskPreferences(labelMatch: .all, includeUnconfirmed: false)
        let custom = AskFilter(preferences: settings.resolvedAskPreferences)
        XCTAssertEqual(custom.labelMatch, .all)
        XCTAssertFalse(custom.includeUnconfirmed)

        settings.askPreferences = AskPreferences(keepHistory: false) // partial: other fields default
        let partial = AskFilter(preferences: settings.resolvedAskPreferences)
        XCTAssertEqual(partial.labelMatch, .any)
        XCTAssertTrue(partial.includeUnconfirmed)
        XCTAssertFalse(settings.resolvedAskPreferences.resolvedKeepHistory)
    }

    func testMatchSwitchNeedsTwoLabels() {
        var f = AskFilter()
        XCTAssertFalse(f.showsMatchSwitch)
        XCTAssertFalse(f.showsUnconfirmedToggle)
        f.addLabel("#Tea ")
        XCTAssertEqual(f.labels, ["tea"])
        XCTAssertFalse(f.showsMatchSwitch)
        XCTAssertTrue(f.showsUnconfirmedToggle)
        f.addLabel("tea")
        f.addLabel("has space")
        f.addLabel("  ")
        XCTAssertEqual(f.labels, ["tea"])
        f.addLabel("gyokuro")
        XCTAssertTrue(f.showsMatchSwitch)
        f.removeLabel("tea")
        XCTAssertFalse(f.showsMatchSwitch)
    }

    func testFilterFillsRequestOnlyWhenScoped() {
        var request = AskRequest(question: "Q")
        AskFilter().apply(to: &request)
        XCTAssertNil(request.labels)
        XCTAssertNil(request.sources)
        XCTAssertNil(request.labelMatch)
        XCTAssertNil(request.includeUnconfirmed)

        var f = AskFilter()
        f.addLabel("tea"); f.addLabel("gyokuro"); f.addSource("discussion")
        f.labelMatch = .all
        f.includeUnconfirmed = false
        f.apply(to: &request)
        XCTAssertEqual(request.labels, ["tea", "gyokuro"])
        XCTAssertEqual(request.sources, ["discussion"])
        XCTAssertEqual(request.labelMatch, .all)
        XCTAssertEqual(request.includeUnconfirmed, false)
        XCTAssertEqual(AskFilter(request: request), f)
        XCTAssertEqual(f.summary(taxonomy: SourceGroup.defaultTaxonomy), "#tea and #gyokuro · Discussion")
    }

    func testSourceOnlyFilterLeavesLabelFieldsOut() {
        var f = AskFilter()
        f.addSource("slack")
        var request = AskRequest(question: "Q")
        f.apply(to: &request)
        XCTAssertEqual(request.sources, ["slack"])
        XCTAssertNil(request.labelMatch)
        XCTAssertEqual(f.summary(taxonomy: Settings().resolvedSourceTaxonomy), "Slack")
    }

    func testPageCountAndInfoNotices() {
        let notices = ["Started a new session because the filter changed.", "Limited to 15 pages (3 unconfirmed)."]
        XCTAssertEqual(AskFilter.pageCount(notices: notices), "15 pages (3 unconfirmed)")
        XCTAssertEqual(AskFilter.infoNotices(notices), ["Started a new session because the filter changed."])
        XCTAssertNil(AskFilter.pageCount(notices: []))
    }

    // MARK: Selection

    func testSelectionOrder() throws {
        let runners = [
            RunnerInfo(id: "claude-code", displayName: "Claude Code", tasks: [.ingest, .ask], effortLevels: ["low", "medium", "high", "xhigh", "max"], defaultModel: "sonnet"),
            RunnerInfo(id: "openrouter", displayName: "OpenRouter", kind: "modelAPI", tasks: [.labelSuggest], defaultModel: "x"),
            RunnerInfo(id: "codex", displayName: "Codex", enabled: false, tasks: [.ask]),
        ]
        XCTAssertEqual(AskSelection.runners(runners).map(\.id), ["claude-code"])
        var settings = Settings()
        settings.model = "opus"
        XCTAssertEqual(AskSelection.resolve(current: nil, settings: settings, runners: runners), ModelSelection(runnerID: "claude-code", model: "opus"))
        settings.taskDefaults["ask"] = ModelSelection(runnerID: "claude-code", model: "haiku", effort: "low")
        XCTAssertEqual(AskSelection.resolve(current: nil, settings: settings, runners: runners).model, "haiku")
        let current = ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "high")
        XCTAssertEqual(AskSelection.resolve(current: current, settings: settings, runners: runners), current)
        // A selection on a runner that cannot ask is dropped.
        XCTAssertEqual(AskSelection.resolve(current: ModelSelection(runnerID: "codex", model: "m"), settings: settings, runners: runners).model, "haiku")
        XCTAssertEqual(AskSelection.effortLabel("xhigh"), "X-High")
        XCTAssertEqual(AskSelection.effortLabel("medium"), "Medium")
    }

    // MARK: History policy

    func testKeepHistoryOffDeletesOnlyIdleUnpinnedChats() {
        XCTAssertEqual(AskHistoryPolicy.conversationToDelete(leaving: "c1", keepHistory: false, pinned: false, isRunning: false, handedOff: false), "c1")
        XCTAssertNil(AskHistoryPolicy.conversationToDelete(leaving: "c1", keepHistory: true, pinned: false, isRunning: false, handedOff: false))
        XCTAssertNil(AskHistoryPolicy.conversationToDelete(leaving: "c1", keepHistory: false, pinned: true, isRunning: false, handedOff: false))
        XCTAssertNil(AskHistoryPolicy.conversationToDelete(leaving: "c1", keepHistory: false, pinned: false, isRunning: true, handedOff: false))
        XCTAssertNil(AskHistoryPolicy.conversationToDelete(leaving: "c1", keepHistory: false, pinned: false, isRunning: false, handedOff: true))
        XCTAssertNil(AskHistoryPolicy.conversationToDelete(leaving: nil, keepHistory: false, pinned: false, isRunning: false, handedOff: false))
    }

    func testHistorySortPinnedFirst() {
        let d = Date()
        let list = [
            AskConversationSummary(id: "old", title: "o", createdAt: d.addingTimeInterval(-100)),
            AskConversationSummary(id: "pinned", title: "p", createdAt: d.addingTimeInterval(-500), pinned: true),
            AskConversationSummary(id: "new", title: "n", createdAt: d),
        ]
        XCTAssertEqual(AskHistoryPolicy.sorted(list).map(\.id), ["pinned", "new", "old"])
    }

    // MARK: Links and answer markers

    func testObsidianLinkEncodesStrictly() {
        let url = ObsidianLink.url(vaultPath: "/Users/me/My Vault", page: "wiki/R&D + notes/Tea #1?.md")
        XCTAssertEqual(url?.absoluteString, "obsidian://open?vault=My%20Vault&file=wiki/R%26D%20%2B%20notes/Tea%20%231%3F")
    }

    func testAnswerPieces() {
        XCTAssertEqual(AskAnswer.pieces("Hot [1]. Cool [2, 3]."),
                       [.text("Hot "), .citation(1), .text(". Cool "), .citation(2), .citation(3), .text(".")])
        XCTAssertEqual(AskAnswer.pieces("See [docs](https://x) and [a]"), [.text("See [docs](https://x) and [a]")])
        XCTAssertEqual(AskAnswer.pieces("[1](x)"), [.text("[1](x)")])
    }
}
