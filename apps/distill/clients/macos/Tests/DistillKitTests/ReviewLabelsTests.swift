import XCTest
@testable import DistillKit

/// v6 (2026-10-05): labels in the queue and in Review, picking and removing sources, approving in parts.
final class ReviewLabelsDecodingTests: XCTestCase {
    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.core.decode(T.self, from: Data(json.utf8))
    }

    func testQueueEntryLabelsAndGate() throws {
        let e = try decode(QueueEntry.self, #"""
        {"path":"/q/a.md","modified":"2026-10-05T01:00:00Z","size":5,"settled":true,"heldForLabels":true,
         "labels":{"state":"failed","labels":[{"name":"tea","existing":true},{"name":"kettle"},{"oops":1}],"error":"Haiku timed out","attempts":3}}
        """#)
        XCTAssertTrue(e.heldForLabels)
        XCTAssertEqual(e.labels?.state, .failed)
        XCTAssertEqual(e.labels?.labels, [LabelSuggestion(name: "tea", existing: true), LabelSuggestion(name: "kettle", existing: false)])
        XCTAssertEqual(e.labels?.error, "Haiku timed out")
        XCTAssertEqual(e.labels?.attempts, 3)
        XCTAssertEqual(e.labels?.allowsSkip, true)
        XCTAssertEqual(QueueRows.status(e, batchRunning: true), .labeling, "held for labels shows Next batch (amber) even while a batch runs")
        XCTAssertEqual(QueueRows.pillText(.labeling), "Next batch")
        XCTAssertEqual(QueueRowStatus.labeling.tone, .amber)

        // Encoding keeps them (a save never drops a field).
        let again = try JSONDecoder.core.decode(QueueEntry.self, from: JSONEncoder.core.encode(e))
        XCTAssertEqual(again, e)
    }

    func testOldQueueEntryAndUnknownLabelState() throws {
        let old = try decode(QueueEntry.self, #"{"path":"/q/a.md","modified":"2026-10-05T01:00:00Z","size":5,"settled":true}"#)
        XCTAssertNil(old.labels)
        XCTAssertFalse(old.heldForLabels)
        XCTAssertNil(LabelLineState(queue: old.labels), "no labels object = no label line")

        let newer = try decode(QueueEntry.self, #"{"path":"/q/a.md","labels":{"state":"pondering","labels":"x","attempts":"two"},"heldForLabels":"yes"}"#)
        XCTAssertEqual(newer.labels?.state, .waiting, "an unknown state reads as waiting")
        XCTAssertEqual(newer.labels?.labels, [])
        XCTAssertEqual(newer.labels?.attempts, 0)
        XCTAssertFalse(newer.heldForLabels)
    }

    func testApprovalV6Fields() throws {
        let a = try decode(ApprovalRequest.self, #"""
        {"summary":"s","questions":[],"denials":[],"skipped":[],
         "sources":[{"page":"wiki/sources/A.md","title":"A","source":"inbox/a.md","labels":["tea"],"by":"ai"},
                    {"page":"wiki/sources/B.md","labels":[],"by":"robot","state":"suggesting","removed":true},
                    {"title":"no page"}],
         "labels":{"state":"confirming","message":null,"done":3,"total":22,"revision":2},
         "unconfirmed":{"bundlePath":"/x/b.json","plan":{"operation_id":"op","valid":true,"changed_paths":["wiki/a.md"],"approval_sha256":"h"}},
         "rebuilt":{"reason":"remaining","pages":["wiki/sources/A.md"],"labels":"later"},
         "sessionUnavailable":"Claude Code no longer has its conversation."}
        """#)
        XCTAssertEqual(a.sources?.count, 2, "a source without a page is skipped")
        XCTAssertEqual(a.sources?[0].by, .ai)
        XCTAssertEqual(a.sources?[1].title, "B", "no title: the page's file stem")
        XCTAssertEqual(a.sources?[1].by, ReviewSource.By.none, "an unknown by with no labels reads as none")
        XCTAssertEqual(a.sources?[1].state, .suggesting)
        XCTAssertEqual(a.sources?[1].removed, true)
        XCTAssertEqual(a.labels, ReviewLabels(state: .confirming, done: 3, total: 22, revision: 2))
        XCTAssertTrue(a.labels?.blocksApprove ?? false)
        XCTAssertEqual(a.unconfirmed?.bundlePath, "/x/b.json")
        XCTAssertEqual(a.unconfirmed?.plan?.changedPaths, ["wiki/a.md"])
        XCTAssertEqual(a.rebuilt, RebuiltPlan(reason: .remaining, pages: ["wiki/sources/A.md"], labels: .later))
        XCTAssertEqual(a.sessionUnavailable, "Claude Code no longer has its conversation.")
    }

    func testOldApprovalAndUnknownValues() throws {
        let old = try decode(ApprovalRequest.self, #"{"summary":"s","questions":[],"denials":[],"skipped":[]}"#)
        XCTAssertNil(old.sources)
        XCTAssertNil(old.labels)
        XCTAssertNil(old.unconfirmed)
        XCTAssertNil(old.rebuilt)
        XCTAssertNil(old.sessionUnavailable)

        let odd = try decode(ApprovalRequest.self, #"""
        {"summary":"s","sources":"nope","labels":{"state":"thinking"},"unconfirmed":{"plan":null},
         "rebuilt":{"reason":"mystery","labels":"someday"},"sessionUnavailable":""}
        """#)
        XCTAssertNil(odd.sources)
        XCTAssertEqual(odd.labels?.state, .confirmed, "an unknown labels state reads as confirmed")
        XCTAssertNil(odd.unconfirmed, "no bundle path = no unconfirmed change")
        XCTAssertEqual(odd.rebuilt, RebuiltPlan(reason: .partial, pages: [], labels: .confirm))
        XCTAssertNil(odd.sessionUnavailable)
    }

    func testJobPartsAndPendingPart() throws {
        let job = try decode(Job.self, #"""
        {"id":"job-1","state":"running","files":[],"turns":[],
         "parts":[{"operationID":"op-1","pages":["wiki/sources/A.md"],"labels":"later","at":"2026-10-05T09:10:00Z"},{"pages":5}],
         "pendingPart":{"reason":"stale","expected":{"wiki/sources/A.md":"abc"},"excluded":["wiki/sources/B.md"],"labels":"confirm"}}
        """#)
        XCTAssertEqual(job.parts?.count, 2)
        XCTAssertEqual(job.parts?[0].operationID, "op-1")
        XCTAssertEqual(job.parts?[0].labels, .later)
        XCTAssertEqual(job.parts?[0].at, CoreDate.parse("2026-10-05T09:10:00Z"))
        XCTAssertEqual(job.parts?[1].pages, [], "a part of the wrong shape keeps its defaults")
        XCTAssertEqual(job.pendingPart, PendingPart(reason: .stale, expected: ["wiki/sources/A.md": "abc"], excluded: ["wiki/sources/B.md"]))

        let again = try JSONDecoder.core.decode(Job.self, from: JSONEncoder.core.encode(job))
        XCTAssertEqual(again.parts, job.parts)
        XCTAssertEqual(again.pendingPart, job.pendingPart)

        let old = try decode(Job.self, #"{"id":"job-0","state":"completed"}"#)
        XCTAssertNil(old.parts)
        XCTAssertNil(old.pendingPart)
    }

    func testProgressItemAndGroup() throws {
        let p = try decode(CoreProgress.self, #"{"key":"label:job-1:inbox/a.md","kind":"labelSuggest","message":"Suggesting labels","item":"inbox/a.md","group":"job-1"}"#)
        XCTAssertEqual(p.item, "inbox/a.md")
        XCTAssertEqual(p.group, "job-1")
        let old = try decode(CoreProgress.self, #"{"key":"job-1","kind":"batch","message":"Reading"}"#)
        XCTAssertNil(old.item)
        XCTAssertNil(old.group)
    }
}

final class ReviewLabelsClientTests: XCTestCase {
    var client: CoreClient!

    override func setUp() {
        StubProtocol.recorded = []
        StubProtocol.handler = nil
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: String(repeating: "f", count: 64)), session: URLSession(configuration: config))
    }

    private func respond(_ json: String, status: Int = 200) { StubProtocol.handler = { _ in (status, Data(json.utf8)) } }
    private var last: StubProtocol.Recorded { StubProtocol.recorded.last! }
    private func body() throws -> JSONValue { try JSONDecoder.core.decode(JSONValue.self, from: last.body ?? Data()) }

    private let entries = #"{"entries":[{"path":"/q/a.md","modified":"2026-10-05T01:00:00Z","size":1,"settled":true,"labels":{"state":"confirmed","labels":[{"name":"tea","existing":true}]}}]}"#
    private let job = #"{"job":{"id":"job-1","state":"awaitingApproval","files":[],"turns":[]}}"#

    func testQueueLabelRoutes() async throws {
        respond(entries)
        let confirmed = try await client.labelQueueItem(path: "/q/a.md", labels: ["tea"])
        XCTAssertEqual(confirmed.first?.labels?.state, .confirmed)
        XCTAssertEqual(last.method, "POST")
        XCTAssertEqual(last.path, "/v1/queue/labels")
        XCTAssertEqual(try body(), .object(["path": .string("/q/a.md"), "labels": .array([.string("tea")])]))

        _ = try await client.retryQueueLabels(path: "/q/a.md")
        XCTAssertEqual(last.path, "/v1/queue/labels/retry")
        XCTAssertEqual(try body(), .object(["path": .string("/q/a.md")]))

        _ = try await client.skipQueueLabels(path: "/q/a.md")
        XCTAssertEqual(last.path, "/v1/queue/labels/skip")
    }

    func testReviewRoutes() async throws {
        respond(job)
        _ = try await client.editReviewLabels("job-1", edits: [(page: "wiki/sources/A.md", labels: ["tea", "kettle"])])
        XCTAssertEqual(last.path, "/v1/jobs/job-1/labels")
        XCTAssertEqual(try body(), .object(["edits": .array([.object(["page": .string("wiki/sources/A.md"),
                                                                      "labels": .array([.string("tea"), .string("kettle")])])])]))

        _ = try await client.removeReviewSource("job-1", page: "wiki/sources/A.md", removed: true)
        XCTAssertEqual(last.path, "/v1/jobs/job-1/sources")
        XCTAssertEqual(try body(), .object(["page": .string("wiki/sources/A.md"), "removed": .bool(true)]))

        _ = try await client.approve("job-1", options: ApproveOptions(labels: .later, pages: ["wiki/sources/A.md"]))
        XCTAssertEqual(last.path, "/v1/jobs/job-1/approve")
        XCTAssertEqual(try body(), .object(["labels": .string("later"), "pages": .array([.string("wiki/sources/A.md")])]))

        _ = try await client.approve("job-1", options: ApproveOptions())
        XCTAssertEqual(try body(), .object([:]), "no options: an empty body, as before")
    }

    func testRefusedLabelEditCarriesTheMessage() async {
        respond(#"{"error":{"code":"conflict","message":"The vault changed after Claude prepared this batch."}}"#, status: 409)
        do {
            _ = try await client.editReviewLabels("job-1", edits: [(page: "wiki/sources/A.md", labels: [])])
            XCTFail("expected a refusal")
        } catch let e as CoreClientError {
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.description, "The vault changed after Claude prepared this batch.")
        } catch {
            XCTFail("\(error)")
        }
    }
}
