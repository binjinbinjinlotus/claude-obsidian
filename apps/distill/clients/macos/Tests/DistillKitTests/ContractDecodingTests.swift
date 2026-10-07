import XCTest
@testable import DistillKit

/// Lenient decoding and round trips of contract types the other model tests don't reach:
/// vault profiles, the approved change, queue scans, add-note results, Ask turns and events.
final class ContractDecodingTests: XCTestCase {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.core.decode(T.self, from: Data(json.utf8))
    }

    func roundTrip<T: Codable & Equatable>(_ value: T) throws -> T {
        try JSONDecoder.core.decode(T.self, from: JSONEncoder.core.encode(value))
    }

    func json<T: Encodable>(_ value: T) throws -> JSONValue {
        try JSONDecoder.core.decode(JSONValue.self, from: JSONEncoder.core.encode(value))
    }

    // MARK: Vaults

    func testVaultProfileDefaultsItsQueueFolder() throws {
        let v = try decode(VaultProfile.self, #"{"path":"/Users/mei/Research","queueDirectory":7}"#)
        XCTAssertEqual(v.queueDirectory, VaultProfile.defaultQueueDirectory(forVault: "/Users/mei/Research"))
        XCTAssertTrue(v.queueDirectory.hasSuffix("/Documents/Distill Queue/Research"))
        XCTAssertEqual(v.name, "Research")
        XCTAssertEqual(v.id, "/Users/mei/Research")
        XCTAssertThrowsError(try decode(VaultProfile.self, #"{"queueDirectory":"/q"}"#), "a vault needs its path")
    }

    func testQueueIsInboxComparesStandardizedPaths() {
        XCTAssertTrue(VaultProfile(path: "/v/Research", queueDirectory: "/v/Research/inbox").queueIsInbox)
        XCTAssertTrue(VaultProfile(path: "/v/Research", queueDirectory: "/v/Research/inbox/").queueIsInbox)
        XCTAssertTrue(VaultProfile(path: "/v/Research", queueDirectory: "/v/Research/x/../inbox").queueIsInbox)
        XCTAssertFalse(VaultProfile(path: "/v/Research", queueDirectory: "/v/Research/inbox/sub").queueIsInbox)
        XCTAssertFalse(VaultProfile(path: "/v/Research", queueDirectory: "/q/Research").queueIsInbox)
        XCTAssertEqual(VaultProfile(path: "/v/Research", queueDirectory: "/q").inboxURL.path, "/v/Research/inbox")
    }

    func testAVaultIsAFolderWithItsMarkerFile() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distill-vault-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        XCTAssertFalse(VaultProfile.isVault(dir.path))
        try Data("{}".utf8).write(to: dir.appendingPathComponent(".claude-obsidian.json"))
        XCTAssertTrue(VaultProfile.isVault(dir.path))
    }

    func testRemovingTheActiveVaultPicksTheFirstLeft() {
        var s = Settings()
        s.upsert(VaultProfile(path: "/a", queueDirectory: "/qa"))
        s.upsert(VaultProfile(path: "/b", queueDirectory: "/qb"))
        s.upsert(VaultProfile(path: "/c", queueDirectory: "/qc"))
        s.upsert(VaultProfile(path: "/b", queueDirectory: "/qb2"))
        XCTAssertEqual(s.vaults.map(\.path), ["/a", "/b", "/c"], "an upsert replaces in place")
        XCTAssertEqual(s.vaults[1].queueDirectory, "/qb2")
        XCTAssertEqual(s.activeVault?.path, "/a", "no active path: the first")
        s.activeVaultPath = "/c"
        XCTAssertEqual(s.activeVault?.path, "/c")
        s.removeVault("/a")
        XCTAssertEqual(s.activeVaultPath, "/c", "another vault going leaves the active one")
        s.removeVault("/c")
        XCTAssertEqual(s.activeVaultPath, "/b")
        s.removeVault("/b")
        XCTAssertNil(s.activeVaultPath)
        XCTAssertNil(s.activeVault)
        s.activeVaultPath = "/gone"
        s.upsert(VaultProfile(path: "/d", queueDirectory: "/qd"))
        XCTAssertEqual(s.activeVault?.path, "/d", "an active path no vault has falls back to the first")
    }

    func testQueueScanMinutesAreClamped() {
        var s = Settings()
        XCTAssertEqual(s.resolvedQueueScanMinutes, 5)
        s.queueScanMinutes = -3
        XCTAssertEqual(s.resolvedQueueScanMinutes, 0)
        s.queueScanMinutes = 2000
        XCTAssertEqual(s.resolvedQueueScanMinutes, 1440)
        s.queueScanMinutes = 1440
        XCTAssertEqual(s.resolvedQueueScanMinutes, 1440)
        s.queueScanMinutes = 30
        XCTAssertEqual(s.resolvedQueueScanMinutes, 30)
    }

    // MARK: Jobs

    func testApprovedChangeDecodesLenientlyAndRoundTrips() throws {
        let c = try decode(ApprovedChange.self, #"{"operationID":"op","changes":"many","sources":2,"appliedOutside":"yes","extra":1}"#)
        XCTAssertEqual(c.at, Date(timeIntervalSince1970: 0))
        XCTAssertEqual(c.operationID, "op")
        XCTAssertEqual(c.changes, 0)
        XCTAssertEqual(c.sources, 2)
        XCTAssertFalse(c.appliedOutside)
        XCTAssertNil(c.sourcesApproved)
        XCTAssertNil(c.approvalSha256)
        var full = ApprovedChange(at: Date(timeIntervalSince1970: 1_791_300_600), operationID: "op-1", changes: 9, sources: 1, concepts: 2,
                                  entities: 3, otherPages: 4, updated: 5, sourcesApproved: 6)
        full.approvalSha256 = "abc"
        XCTAssertEqual(try roundTrip(full), full)
        XCTAssertNil(try json(full)["appliedOutside"], "false is left out")
        full.appliedOutside = true
        XCTAssertEqual(try json(full)["appliedOutside"], .bool(true))
        XCTAssertEqual(try roundTrip(full), full)
        XCTAssertEqual(try decode(ApprovedChange.self, "{}").operationID, "")
    }

    func testJobCostAddsUpItsTurns() {
        var job = Job(id: "j", vaultPath: "/v", files: [])
        XCTAssertEqual(job.totalCostUSD, 0)
        job.turns = [TurnRecord(author: .user, text: "a", costUSD: 0.25), TurnRecord(author: .app, text: "b", costUSD: 0.5)]
        XCTAssertEqual(job.totalCostUSD, 0.75)
    }

    // MARK: Queue

    func testQueueScanResultDecodesLeniently() throws {
        let r = try decode(QueueScanResult.self, #"""
        {"added":-2,"removed":"x","changed":3,"trigger":"telepathy","problem":"","addedEntries":[{"path":"/q/a.md","name":"a.md","modified":"2026-10-01T12:00:00Z","size":1,"settled":true},{"bad":1}]}
        """#)
        XCTAssertEqual(r.added, 0, "never below zero")
        XCTAssertEqual(r.removed, 0)
        XCTAssertEqual(r.changed, 3)
        XCTAssertEqual(r.trigger, .periodic, "an unknown trigger reads as the queue check")
        XCTAssertNil(r.problem, "an empty problem is none")
        XCTAssertEqual(r.addedEntries.map(\.name), ["a.md"])
        XCTAssertNil(r.entries, "the core didn't send the whole list")
        let listed = try decode(QueueScanResult.self, #"{"trigger":"window","problem":"Can't read it","entries":[{"x":1}]}"#)
        XCTAssertEqual(listed.trigger, .window)
        XCTAssertEqual(listed.problem, "Can't read it")
        XCTAssertEqual(listed.entries, [], "sent but empty is not nil")
        let full = QueueScanResult(added: 1, removed: 2, changed: 3, checkedAt: Date(timeIntervalSince1970: 1_791_300_600), trigger: .manual,
                                   problem: "p", addedEntries: r.addedEntries, entries: r.addedEntries)
        XCTAssertEqual(try roundTrip(full), full)
        XCTAssertNil(try json(QueueScanResult(checkedAt: Date(timeIntervalSince1970: 0)))["entries"])
    }

    func testAddNoteResultDecodesLeniently() throws {
        let r = try decode(AddNoteResult.self, #"{"queued":["/q/n.md",3],"requestID":5,"suggestedLabels":[{"name":"tea"},{"existing":true}],"suggestError":"busy"}"#)
        XCTAssertEqual(r.queued, ["/q/n.md"])
        XCTAssertEqual(r.notePath, "")
        XCTAssertEqual(r.requestID, "")
        XCTAssertEqual(r.suggestedLabels, [LabelSuggestion(name: "tea", existing: false)])
        XCTAssertEqual(r.suggestError, "busy")
        XCTAssertNil(try decode(AddNoteResult.self, "{}").suggestedLabels, "not asked: nil, not empty")
    }

    // MARK: Ask

    func testAskTurnsAndConversationsRoundTrip() throws {
        let summary = AskConversationSummary(id: "c1", title: "How hot?", vaultPath: "/v", createdAt: Date(timeIntervalSince1970: 1_791_300_000),
                                             updatedAt: Date(timeIntervalSince1970: 1_791_300_600), pinned: true, turnCount: 1)
        let turn = AskTurn(askedAt: Date(timeIntervalSince1970: 1_791_300_000), request: AskRequest(question: "How hot?", labels: ["tea"]),
                           response: AskResponse(conversationID: "c1", answer: "70 °C [1]", citations: [AskCitation(n: 1, path: "wiki/a.md", title: "A")],
                                                 gaps: ["gyokuro"], costUSD: 0.02, notices: ["n"]))
        let conversation = AskConversation(summary: summary, turns: [turn])
        XCTAssertEqual(try roundTrip(conversation), conversation)
        XCTAssertEqual(conversation.id, "c1")
        XCTAssertEqual(try roundTrip(turn), turn)
        XCTAssertEqual(try roundTrip(summary), summary)
        // The summary's keys sit beside the turns, as the core writes a chat file.
        XCTAssertEqual(try json(conversation)["title"], .string("How hot?"))
    }

    func testAskSummaryDefaults() throws {
        let s = try decode(AskConversationSummary.self, #"{"id":"c","createdAt":"2026-10-01T12:00:00Z","pinned":"yes","turnCount":"2"}"#)
        XCTAssertEqual(s.title, "")
        XCTAssertEqual(s.vaultPath, "")
        XCTAssertEqual(s.updatedAt, s.createdAt, "no update time: when it started")
        XCTAssertFalse(s.pinned)
        XCTAssertEqual(try decode(AskConversationSummary.self, #"{"id":"c"}"#).createdAt, .distantPast)
        let turn = try decode(AskTurn.self, #"{"request":{"question":"q"},"response":{}}"#)
        XCTAssertEqual(turn.askedAt, .distantPast)
        XCTAssertEqual(turn.response.answer, "")
        XCTAssertThrowsError(try decode(AskTurn.self, #"{"response":{}}"#), "a turn without its question is skipped by the list")
        let chat = try decode(AskConversation.self, #"{"id":"c","turns":[{"response":{}},{"request":{"question":"q"},"response":{}}]}"#)
        XCTAssertEqual(chat.turns.count, 1)
        let cite = try decode(AskCitation.self, #"{"n":"1","path":"wiki/a.md"}"#)
        XCTAssertEqual(cite.title, "wiki/a.md", "no title: the path")
    }

    // MARK: Events

    func testConversationAndDeletedJobEvents() throws {
        let deleted = try CoreEvent.decode(Data(#"{"type":"conversation","conversation":{"id":"c1","title":"T"},"deleted":true}"#.utf8))
        guard case .conversation(let s, let gone) = deleted else { return XCTFail("\(deleted)") }
        XCTAssertEqual(s.id, "c1")
        XCTAssertTrue(gone)
        let kept = try CoreEvent.decode(Data(#"{"type":"conversation","conversation":{"id":"c1"}}"#.utf8))
        guard case .conversation(_, let gone2) = kept else { return XCTFail("\(kept)") }
        XCTAssertFalse(gone2)
        XCTAssertEqual(try CoreEvent.decode(Data(#"{"type":"job","job":{"id":"j9","vaultPath":"/v"},"deleted":true}"#.utf8)), .jobDeleted(id: "j9"))
        XCTAssertEqual(try CoreEvent.decode(Data(#"{"type":"log"}"#.utf8)), .log(level: "info", message: ""))
    }
}
