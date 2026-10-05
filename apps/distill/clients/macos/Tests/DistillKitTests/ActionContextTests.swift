import XCTest
@testable import DistillKit

/// Action context (action-context.md): the additive `source.raw` / `source.wiki` / `source.contextNote`,
/// JobActionsSummary's new fields, and GET /v1/jobs/:id/actions.
final class ActionContextTests: XCTestCase {
    static let old = #"""
    {"id":"a1","type":"todo","status":"open","title":"Book the room","fields":{},
     "source":{"kind":"note","jobID":"j1","notePath":"inbox/tea.md","pageTitle":"Tea","quote":"I'll book it"},
     "createdAt":"2026-10-02T15:44:00Z","updatedAt":"2026-10-02T15:44:00Z","events":[]}
    """#

    static let withContext = #"""
    {"id":"a2","type":"jira","status":"pending","title":"Cap retries at 3","fields":{"project":"PAY"},
     "source":{"kind":"note","jobID":"j2","notePath":"inbox/t.md","quote":"put a ticket in PAY",
       "raw":{"path":".raw/captured/abc.md","inboxPath":"inbox/t.md","sha256":"abc","lines":[210,214],
              "excerpt":"line a\nline b\nline c\nline d\nline e","match":"quote"},
       "wiki":[{"path":"wiki/sources/T.md","title":"Tomasz and Jin","heading":"Retries","excerpt":"Cap at 3."},{"title":"no path"}],
       "contextNote":null,"future":1},
     "createdAt":"2026-10-05T09:24:00Z","updatedAt":"2026-10-05T09:24:00Z","events":[]}
    """#

    func decode(_ s: String) throws -> ActionItem { try JSONDecoder.core.decode(ActionItem.self, from: Data(s.utf8)) }

    func testOldItemDecodesUnchanged() throws {
        let item = try decode(Self.old)
        XCTAssertEqual(item.source, .note(jobID: "j1", notePath: "inbox/tea.md", pageTitle: "Tea", quote: "I'll book it"))
        XCTAssertTrue(item.context.isEmpty)
        // Re-encoding writes no context keys.
        let json = try JSONDecoder.core.decode(JSONValue.self, from: JSONEncoder().encode(item))
        guard case .object(let o) = json, case .object(let src)? = o["source"] else { return XCTFail("no source") }
        XCTAssertNil(src["raw"]); XCTAssertNil(src["wiki"])
        XCTAssertEqual(src["quote"]?.stringValue, "I'll book it")
    }

    func testNewItemDecodesAndRoundTrips() throws {
        let item = try decode(Self.withContext)
        XCTAssertEqual(item.source, .note(jobID: "j2", notePath: "inbox/t.md", pageTitle: nil, quote: "put a ticket in PAY"))
        let raw = try XCTUnwrap(item.context.raw)
        XCTAssertEqual(raw.path, ".raw/captured/abc.md")
        XCTAssertEqual(raw.lines, 210...214)
        XCTAssertEqual(raw.linesText, "lines 210–214")
        XCTAssertEqual(raw.numberedLines.map(\.0), [210, 211, 212, 213, 214])
        XCTAssertTrue(raw.isQuote)
        XCTAssertEqual(item.context.wiki.count, 1, "a wiki ref without a path is skipped")
        XCTAssertEqual(item.context.wiki[0].heading, "Retries")

        let again = try JSONDecoder.core.decode(ActionItem.self, from: JSONEncoder().encode(item))
        XCTAssertEqual(again.context, item.context)
        XCTAssertEqual(again.source, item.source)
    }

    func testBadLinesAreDropped() throws {
        for bad in [#""lines":"210-214""#, #""lines":[214,210]"#, #""lines":[0,3]"#, #""lines":[1.5,3]"#, #""lines":[3]"#] {
            let json = #"{"id":"b","title":"t","source":{"kind":"ask","conversationID":"c","raw":{"path":"x.md",\#(bad),"match":"closest"}}}"#
            let item = try decode(json)
            XCTAssertEqual(item.context.raw?.path, "x.md", bad)
            XCTAssertNil(item.context.raw?.lines, bad)
            XCTAssertEqual(item.source.conversationID, "c")
        }
        let noPath = try decode(#"{"id":"b","title":"t","source":{"kind":"note","raw":{"lines":[1,2]},"wiki":"nope","contextNote":5}}"#)
        XCTAssertTrue(noPath.context.isEmpty)
    }

    func testWikiOnlyAndResolve() {
        let ctx = ActionContextRefs(raw: nil, wiki: [ActionWikiRef(path: "wiki/a.md")], note: "the cited pages have no archived original")
        XCTAssertTrue(ctx.isWikiOnly)
        let raw = ActionRawRef(path: ".raw/captured/abc.md", inboxPath: "inbox/t.md")
        XCTAssertEqual(raw.candidates(vault: "/v"), ["/v/.raw/captured/abc.md", "/v/inbox/t.md"])
        XCTAssertEqual(raw.resolve(vault: "/v") { $0 == "/v/inbox/t.md" }, "/v/inbox/t.md")
        XCTAssertNil(raw.resolve(vault: "/v") { _ in false })
    }

    func testPreviewWords() throws {
        let item = try decode(Self.withContext)
        XCTAssertEqual(ActionContextText.target(item, typeLabel: "Jira ticket"), "Jira ticket · PAY")
        XCTAssertEqual(ActionContextText.willWrite(item, typeLabel: "Jira ticket", model: "Sonnet"),
                       "A Jira ticket draft with Sonnet, from lines 185–239 of the original and 1 wiki section. Nothing is created in Jira until you click Create in Jira.")
        let old = try decode(Self.old)
        XCTAssertEqual(ActionContextText.willWrite(old, typeLabel: "To-do", model: "Sonnet"), "Add puts it in To do as it is. Nothing is written by AI.")
        let f = ActionContextText.fields(item, specs: [ActionFieldSpec(key: "project", label: "Project"), ActionFieldSpec(key: "assignee", label: "Assignee")])
        XCTAssertEqual(f.set.map(\.1), ["PAY"])
        XCTAssertEqual(f.unset, ["Assignee"])
    }

    func testSummaryNewFieldsAndJobActions() throws {
        let old = try JSONDecoder.core.decode(JobActionsSummary.self, from: Data(#"{"status":"done","found":2,"pending":2,"added":0,"byType":{"todo":2}}"#.utf8))
        XCTAssertFalse(old.foundInBatch)
        XCTAssertNil(old.lines)

        let json = #"""
        {"summary":{"status":"done","found":3,"pending":0,"added":0,"byType":{"jira":1,"todo":2},"stage":"review","proposed":3,
                    "lines":2243,"linesOf":2243,"sources":3,"duplicates":1},
         "proposals":[{"item":\#(Self.withContext),"file":"inbox/t.md","page":"wiki/sources/T.md","state":"waiting"},
                      {"item":{"id":"d","title":"dup"},"file":"inbox/t.md","state":"duplicate","existingID":"act-1"},
                      {"item":"broken"},
                      {"item":{"id":"l","title":"left"},"file":"inbox/u.md","state":"notApplied"}]}
        """#
        let found = try JSONDecoder.core.decode(JobActions.self, from: Data(json.utf8))
        XCTAssertEqual(found.summary?.stage, "review")
        XCTAssertTrue(found.summary?.foundInBatch ?? false)
        XCTAssertEqual(found.summary?.duplicates, 1)
        XCTAssertEqual(found.proposals.count, 3, "a broken proposal is skipped")
        XCTAssertEqual(found.shown.map(\.id), ["a2", "l"], "duplicates are counted, not listed")
        XCTAssertTrue(found.proposals[2].isLeftOut)
        XCTAssertEqual(found.proposals[0].item.context.raw?.lines, 210...214)

        // Job.actionsFound keeps the new fields on re-encode.
        let summary = try XCTUnwrap(found.summary)
        let again = try JSONDecoder.core.decode(JobActionsSummary.self, from: JSONEncoder().encode(summary))
        XCTAssertEqual(again, summary)

        XCTAssertEqual(ReviewActionsWords.finding(JobActionsSummary(status: "finding", lines: 1_380, linesOf: 2_243, sources: 3), sources: 1),
                       "Looking for actions in 3 sources · lines 1–1,380 of 2,243")
        XCTAssertEqual(ReviewActionsWords.footer(summary, confirm: true, applied: false),
                       "Looked through 2,243 of 2,243 lines. They go to To confirm when you approve; 1 was already in Actions and isn’t shown again.")
        XCTAssertEqual(ReviewActionsWords.headerSummary(waiting: 3, added: 0, confirm: false), "3 are added when you approve")
    }

    func testJobActionsRoute() async throws {
        StubProtocol.recorded = []
        let config = URLSessionConfiguration.ephemeral
        config.protocolClasses = [StubProtocol.self]
        let client = CoreClient(endpoint: CoreEndpoint(port: 5555, token: "t"), session: URLSession(configuration: config))
        StubProtocol.handler = { _ in (200, Data(#"{"summary":null,"proposals":[]}"#.utf8)) }
        let found = try await client.jobActions("job 1")
        XCTAssertNil(found.summary)
        XCTAssertEqual(StubProtocol.recorded.last?.method, "GET")
        let path = StubProtocol.recorded.last?.path ?? ""
        XCTAssertTrue(path.hasPrefix("/v1/jobs/job") && path.hasSuffix("/actions"), path)

        StubProtocol.handler = { _ in (404, Data(#"{"error":{"code":"not_found","message":"no route for GET /v1/jobs/x/actions"}}"#.utf8)) }
        do {
            _ = try await client.jobActions("x")
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertTrue(e.isNotAvailable)
        }
        StubProtocol.handler = nil
    }
}
