import XCTest
@testable import DistillKit

/// Collectors DTOs, routes (URL stub, see CoreClientTests.StubProtocol), events and wording.
final class CollectorsTests: XCTestCase {
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

    static let folder = #"""
    {"id":"col-1","kind":"folder","name":"Distill Inbox","vaultPath":"/v/Research","enabled":true,
     "schedule":{"cron":"0 * * * *","preset":"hourly"},"folder":{"source":"/Users/mei/Distill Inbox","afterCollect":"copy"},
     "createdAt":"2026-10-04T08:00:00Z","updatedAt":"2026-10-04T09:00:00.123Z",
     "status":{"running":false,"nextRunAt":"2026-10-04T10:00:00Z","needsConsent":false,"collectedCount":128,"needsAttention":false,
       "lastRun":{"id":"run-1","collectorId":"col-1","kind":"folder","vaultPath":"/v/Research","trigger":"schedule",
         "startedAt":"2026-10-04T09:00:00Z","endedAt":"2026-10-04T09:00:00.400Z","durationMs":400,"result":"success",
         "counts":{"copied":3,"moved":0,"skipped":2,"waiting":0,"errors":0,"added":3},"filesAdded":["a.md"]}},
     "future":{"x":1}}
    """#

    func testCollectorDecodesLeniently() throws {
        let c = try JSONDecoder.core.decode(Collector.self, from: Data(Self.folder.utf8))
        XCTAssertEqual(c.kind, .folder)
        XCTAssertEqual(c.schedule.preset, .hourly)
        XCTAssertEqual(c.folder?.afterCollect, "copy")
        XCTAssertEqual(c.status?.collectedCount, 128)
        XCTAssertEqual(c.lastRun?.counts.skipped, 2)
        XCTAssertEqual(c.lastRun?.durationMs, 400)

        // Unknown kinds, results, error codes and outcomes stay raw.
        let odd = try JSONDecoder.core.decode(Collector.self, from: Data(#"""
        {"id":"col-2","kind":"rss","enabled":"yes","schedule":"bad","status":{"lastRun":{"id":"r","result":"weird","error":{"code":"newCode","message":"m"},
          "files":[{"name":"x","outcome":"teleported"},{"bad":1},3]},"needsAttention":true}}
        """#.utf8))
        XCTAssertEqual(odd.kind.rawValue, "rss")
        XCTAssertFalse(odd.enabled)
        XCTAssertEqual(odd.schedule.cron, "0 * * * *")
        XCTAssertEqual(odd.lastRun?.result.rawValue, "weird")
        XCTAssertEqual(odd.lastRun?.error?.code.rawValue, "newCode")
        XCTAssertEqual(odd.lastRun?.files?.map(\.outcome.rawValue), ["teleported", "error"])
        XCTAssertTrue(odd.needsAttention)
        XCTAssertThrowsError(try JSONDecoder.core.decode(Collector.self, from: Data(#"{"kind":"folder"}"#.utf8)))

        let script = try JSONDecoder.core.decode(Collector.self, from: Data(#"""
        {"id":"col-3","kind":"script","script":{"source":{"inline":"echo hi"},"interpreter":"fish","timeoutSeconds":60,"allowedSha256":null}}
        """#.utf8))
        XCTAssertEqual(script.script?.source, .inline("echo hi"))
        XCTAssertEqual(script.script?.interpreter.rawValue, "fish")
        XCTAssertNil(script.script?.allowedSha256)
    }

    func testRoundTrip() throws {
        let c = try JSONDecoder.core.decode(Collector.self, from: Data(Self.folder.utf8))
        let again = try JSONDecoder.core.decode(Collector.self, from: JSONEncoder.core.encode(c))
        // Dates are written without fractional seconds; everything else survives.
        let third = try JSONDecoder.core.decode(Collector.self, from: JSONEncoder.core.encode(again))
        XCTAssertEqual(again, third)
        XCTAssertEqual(again.status?.lastRun?.counts, c.status?.lastRun?.counts)
        XCTAssertEqual(again.folder, c.folder)
    }

    func testRoutes() async throws {
        respond("{\"collectors\":[\(Self.folder),{\"nope\":1}]}")
        let list = try await client.collectors()
        XCTAssertEqual(list.map(\.id), ["col-1"])
        XCTAssertEqual(last.path, "/v1/collectors")

        respond(Self.folder, status: 201)
        _ = try await client.createCollector(NewCollectorInput(kind: .script, name: "K", schedule: .hourly,
                                                               script: .init(source: .inline("echo"), interpreter: .zsh)))
        XCTAssertEqual(last.method, "POST")
        let body = try bodyJSON()
        XCTAssertEqual(body["kind"], .string("script"))
        XCTAssertEqual(body["script"]?["source"]?["inline"], .string("echo"))
        XCTAssertNil(body["enabled"])

        respond(Self.folder)
        _ = try await client.updateCollector("col 1", CollectorPatch(enabled: false))
        XCTAssertEqual(last.method, "PATCH"); XCTAssertEqual(last.path, "/v1/collectors/col 1")
        XCTAssertEqual(try bodyJSON(), .object(["enabled": .bool(false)]))

        respond(#"{"run":{"id":"run-2","collectorId":"col-1","result":"running","startedAt":"2026-10-04T10:00:00Z"}}"#)
        let run = try await client.runCollector("col-1")
        XCTAssertEqual(run.result, .running)
        XCTAssertEqual(last.path, "/v1/collectors/col-1/run")

        respond(#"{"run":null}"#)
        let stopped = try await client.stopCollector("col-1")
        XCTAssertNil(stopped)
        XCTAssertEqual(last.path, "/v1/collectors/col-1/stop")

        respond(Self.folder)
        _ = try await client.allowCollector("col-1", sha256: "abc")
        XCTAssertEqual(last.path, "/v1/collectors/col-1/consent")
        XCTAssertEqual(try bodyJSON(), .object(["sha256": .string("abc")]))
        _ = try await client.revokeCollector("col-1")
        XCTAssertEqual(last.method, "DELETE")

        respond(#"{"runs":[{"id":"r1","result":"nothing","startedAt":"2026-10-04T08:00:00Z"}]}"#)
        _ = try await client.collectorRuns("col-1", limit: 50)
        XCTAssertEqual(last.path, "/v1/collectors/col-1/runs"); XCTAssertEqual(last.query, "limit=50")

        let file = #"{"sha256":"aa","name":"a.md","sourcePath":"/s/a.md","size":3,"mtime":"m","collectedAt":"2026-10-04T09:00:00Z","collectorId":"col-1","queueName":"a.md","outcome":"copied"}"#
        respond("{\"files\":[\(file)]}")
        let files = try await client.collected("col-1", query: "a+b c")
        XCTAssertEqual(files.count, 1)
        XCTAssertEqual(last.query, "query=a%2Bb%20c")

        respond("{\"forgotten\":[\(file)]}")
        let forgotten = try await client.forgetCollected("col-1", sha256: "aa")
        XCTAssertEqual(last.method, "DELETE"); XCTAssertEqual(last.path, "/v1/collectors/col-1/collected/aa")
        respond(#"{"restored":1}"#)
        let n = try await client.restoreCollected("col-1", files: forgotten)
        XCTAssertEqual(n, 1)
        guard case .array(let sent)? = try bodyJSON()["files"] else { return XCTFail("files") }
        XCTAssertEqual(sent.first?["sourcePath"], .string("/s/a.md"))
        respond(#"{"forgotten":[]}"#)
        _ = try await client.forgetCollected("col-1")
        XCTAssertEqual(last.path, "/v1/collectors/col-1/collected")

        respond(Self.folder)
        _ = try await client.createCollectorFolder("col-1", which: "source")
        XCTAssertEqual(try bodyJSON(), .object(["which": .string("source")]))

        respond(#"{"cron":"30 8 * * 1,3,5","valid":true,"preset":"custom","nextRuns":["2026-10-05T08:30:00Z"]}"#)
        let check = try await client.checkSchedule("30 8 * * 1,3,5")
        XCTAssertTrue(check.valid)
        XCTAssertEqual(check.nextRuns.count, 1)
        XCTAssertEqual(last.path, "/v1/collectors/check-schedule")
    }

    func testOldCoreIsNotAvailable() async {
        respond(#"{"error":{"code":"not_found","message":"no route for GET /v1/collectors"}}"#, status: 404)
        do {
            _ = try await client.collectors()
            XCTFail("expected an error")
        } catch let e as CoreClientError {
            XCTAssertTrue(e.isNotAvailable)
        } catch { XCTFail("\(error)") }
    }

    func testEvents() throws {
        if case .collector(let c, let deleted) = try CoreEvent.decode(Data("{\"type\":\"collector.changed\",\"collector\":\(Self.folder),\"deleted\":true}".utf8)) {
            XCTAssertEqual(c.id, "col-1"); XCTAssertTrue(deleted)
        } else { XCTFail() }
        let run = #"{"id":"r","collectorId":"col-1","result":"running","startedAt":"2026-10-04T10:00:00Z"}"#
        guard case .collectorRunStarted(let s) = try CoreEvent.decode(Data("{\"type\":\"collector.run.started\",\"run\":\(run)}".utf8)) else { return XCTFail() }
        XCTAssertEqual(s.id, "r")
        guard case .collectorRunFinished = try CoreEvent.decode(Data("{\"type\":\"collector.run.finished\",\"run\":\(run)}".utf8)) else { return XCTFail() }
        let out = try CoreEvent.decode(Data(#"{"type":"collector.run.output","collectorId":"col-1","runId":"r","stream":"stderr","text":"oops\n"}"#.utf8))
        XCTAssertEqual(out, .collectorRunOutput(collectorId: "col-1", runId: "r", stream: "stderr", text: "oops\n"))
        var parser = SSEParser()
        XCTAssertNil(parser.feed(#"data: {"type":"collector.changed","collector":{"kind":"folder"}}"#))
        XCTAssertEqual(parser.malformed, 1)
        XCTAssertEqual(try CoreEvent.decode(Data(#"{"type":"collector.someday"}"#.utf8)), .unknown(type: "collector.someday"))
    }

    // MARK: Wording

    private var cal: Calendar = {
        var c = Calendar(identifier: .gregorian)
        c.timeZone = TimeZone(identifier: "UTC")!
        return c
    }()
    private var text: CollectorText { CollectorText(calendar: cal, locale: Locale(identifier: "en_US"), home: "/Users/mei") }
    private func date(_ d: Int, _ h: Int, _ m: Int = 0) -> Date { cal.date(from: DateComponents(year: 2026, month: 10, day: d, hour: h, minute: m))! }

    func testPathsAndSchedules() {
        XCTAssertEqual(text.tilde("/Users/mei/Distill Inbox"), "~/Distill Inbox")
        XCTAssertEqual(text.tilde("/Users/meiko/x"), "/Users/meiko/x")
        XCTAssertEqual(text.expand("~/Distill Inbox"), "/Users/mei/Distill Inbox")
        XCTAssertEqual(text.schedule("0 * * * *"), "Every hour")
        XCTAssertEqual(text.schedule("30 * * * *"), "Every hour at :30")
        XCTAssertEqual(text.schedule("*/15 * * * *"), "Every 15 minutes")
        XCTAssertEqual(text.schedule("0 7 * * *"), "Every day at 7:00 AM")
        XCTAssertEqual(text.schedule("0 9 * * 1-5"), "Weekdays at 9:00 AM")
        XCTAssertEqual(text.schedule("30 8 * * 1,3,5"), "Mon, Wed and Fri at 8:30 AM")
        XCTAssertEqual(text.schedule("@daily"), "Every day at 12:00 AM")
        XCTAssertEqual(text.schedule("0 8 1 * *"), "Custom: 0 8 1 * *")
        XCTAssertEqual(text.preview("0 * * * *"), "Every hour, on the hour")
        XCTAssertEqual(text.preview("0 9 * * 1-5"), "Monday to Friday at 9:00 AM")
        XCTAssertEqual(text.shortSchedule("0 7 * * *"), "Daily at 7:00 AM")
        XCTAssertEqual(text.lowerSchedule("0 7 * * *"), "every day at 7:00 AM")
        XCTAssertEqual(CollectorText.cron(preset: .weekdays, hour: 9, minute: 5), "5 9 * * 1-5")
        XCTAssertEqual(CollectorText.shape("0 7 * * *")?.preset, .daily)
        XCTAssertNil(CollectorText.shape("30 8 * *"))
    }

    func testTimes() {
        let now = date(4, 10, 15)
        XCTAssertEqual(text.runTime(date(4, 9), previous: nil, now: now), "Today 9:00 AM")
        XCTAssertEqual(text.runTime(date(4, 8), previous: date(4, 9), now: now), "8:00 AM")
        XCTAssertEqual(text.runTime(date(3, 7), previous: date(4, 8), now: now), "Yesterday 7:00 AM")
        XCTAssertEqual(text.runTime(date(2, 7), previous: date(3, 7), now: now), "Oct 2, 7:00 AM")
        XCTAssertEqual(text.next(date(4, 11), now: now), "next at 11:00 AM")
        XCTAssertEqual(text.next(date(5, 7), now: now), "next tomorrow at 7:00 AM")
        XCTAssertEqual(CollectorText.duration(400), "0.4 s")
        XCTAssertEqual(CollectorText.duration(65_000), "1:05")
        XCTAssertEqual(CollectorText.timeout(300), "5 min")
    }

    func testRowsTitleAndRuns() throws {
        let now = date(4, 9, 30)
        var c = try JSONDecoder.core.decode(Collector.self, from: Data(Self.folder.utf8))
        XCTAssertEqual(text.rowSummary(c, now: now), "Every hour · copied 3 at 9:00 AM")
        XCTAssertNil(text.pill(c))
        XCTAssertEqual(text.titleLine(c, now: now), "Folder · every hour · next at 10:00 AM")
        let r = c.lastRun!
        XCTAssertEqual(text.runSummary(r), "Copied 3 files · skipped 2 already collected")
        XCTAssertEqual(text.runMeta(r), "0.4 s")

        c.enabled = false
        XCTAssertEqual(text.rowSummary(c, now: now), "Off")
        XCTAssertEqual(text.statusKind(c), .off)

        c.enabled = true
        c.status?.needsAttention = true
        c.status?.lastRun = CollectorRun(id: "r2", collectorId: c.id, startedAt: date(4, 9), result: .failed,
                                         error: CollectorRunError(code: .sourceMissing, message: "missing"))
        XCTAssertEqual(text.rowSummary(c, now: now), "Folder missing")
        XCTAssertEqual(text.pill(c), "Failed")
        XCTAssertEqual(text.runSummary(c.lastRun!), "Folder missing")

        var s = Collector(id: "s", kind: .script, name: "Slack", vaultPath: "/v",
                          script: ScriptCollectorSettings(source: .file("/Users/mei/s.mjs"), interpreter: .node, allowedSha256: "aa"))
        s.status = CollectorStatus(lastRun: CollectorRun(id: "r", collectorId: "s", kind: .script, startedAt: date(4, 8, 30), durationMs: 800,
                                                         result: .failed, error: CollectorRunError(code: .scriptFailed, message: "exit 1"),
                                                         exitCode: 1, stderrTail: "Error: SLACK_TOKEN is not set\n"),
                                   needsAttention: true)
        XCTAssertEqual(text.rowSummary(s, now: now), "Exit 1 at 8:30 AM")
        XCTAssertEqual(text.runSummary(s.lastRun!), "Failed · added nothing")
        XCTAssertEqual(text.runMeta(s.lastRun!), "exit 1")
        let (kind, lines) = text.runLines(s.lastRun!, command: "node ~/s.mjs")
        XCTAssertEqual(kind, "stderr")
        XCTAssertEqual(lines, ["$ node ~/s.mjs", "Error: SLACK_TOKEN is not set"])

        s.status = CollectorStatus(currentSha256: "bb", needsConsent: true, needsAttention: true)
        XCTAssertTrue(text.scriptChanged(s))
        XCTAssertEqual(text.rowSummary(s, now: now), "Script changed · paused")
        XCTAssertEqual(text.pill(s), "Needs your OK")
        XCTAssertEqual(text.titleLine(s, now: now), "Script · paused")
        s.script?.allowedSha256 = nil
        XCTAssertEqual(text.rowSummary(s, now: now), "Never run")
    }

    func testQuietRunsCollapse() {
        let runs = (0..<8).map { i in CollectorRun(id: "r\(i)", collectorId: "c", startedAt: date(4, 9 - i), result: i == 1 ? .success : .nothing) }
        let rows = CollectorText.collapse(runs)
        XCTAssertEqual(rows.count, 4)
        XCTAssertEqual(rows.last, .quiet(count: 5, newest: date(4, 6)))
    }
}
