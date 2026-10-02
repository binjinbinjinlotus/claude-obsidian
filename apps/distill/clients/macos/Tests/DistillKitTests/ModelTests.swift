import XCTest
@testable import DistillKit

/// JSON shapes from both writers: the TS core (`sampleJob` in
/// core/src/server/fake-core.ts, `isoDate` without milliseconds) and the
/// retired Swift app (uppercase UUIDs; jobs.json still holds them).
enum Fixtures {
    static let tsJob = """
    {"id":"job-20261001-120000-abcd","kind":"ingest","vaultPath":"/tmp/vault","files":["inbox/a.md"],
     "sessionID":"00000000-0000-0000-0000-000000000001","runnerID":"claude-code","model":"sonnet",
     "state":"awaitingApproval","createdAt":"2026-10-01T12:00:00Z","updatedAt":"2026-10-01T12:01:00Z",
     "approval":{"summary":"Plan ready","questions":["Merge into Green tea?"],"bundlePath":"/tmp/vault/.vault-meta/worker/j/bundle.json",
       "plan":{"operation_id":"op-1","operation_type":"ingest","valid":true,"changed_paths":["wiki/tea.md","wiki/new.md"],"approval_sha256":"abc123"},
       "planError":null,"denials":[{"toolName":"Bash","input":{"command":"ls /"}}],"skipped":[]},
     "turns":[{"id":"6b0c7b49-6a43-4c4c-9a39-1f2bfb1a2c11","date":"2026-10-01T12:00:30.123Z","author":"worker","text":"Done","costUSD":0.05}],
     "grantedTools":[],"changedPaths":[]}
    """

    /// Written by the Swift app before the core existed: no runnerID, uppercase turn ids.
    static let swiftJob = """
    {"changedPaths":["wiki\\/a.md"],"createdAt":"2026-09-30T08:00:00Z","files":["inbox\\/x.pdf"],"grantedTools":["Read"],
     "id":"job-20260930-080000-1f2e","kind":"ingest","model":"opus","operationID":"op-9","sessionID":"s-1","state":"completed",
     "turns":[{"author":"app","costUSD":0,"date":"2026-09-30T08:00:00Z","id":"D3A8C9E4-1C3B-4E0B-9B5B-0F8E4C7D2A11","text":"Batched 1 file(s)"}],
     "updatedAt":"2026-09-30T08:05:00Z","vaultPath":"\\/Users\\/me\\/Vault"}
    """

    static let settingsV2 = """
    {"vaults":[{"path":"/tmp/vault","queueDirectory":"/tmp/vault/inbox"},{"path":"/tmp/other"}],
     "activeVaultPath":"/tmp/vault","batchIntervalMinutes":"oops","settleSeconds":5,"model":"opus",
     "claudePath":"/c","pythonPath":"/usr/bin/python3","productRoot":"/prod","extraAllowedTools":["Read", 3],
     "autoProcessEnabled":false,"enabledRunners":["claude-code","openrouter"],
     "taskDefaults":{"ask":{"runnerID":"claude-code","model":"sonnet","effort":"medium"},"bad":{"x":1}},
     "nodePath":"/opt/homebrew/bin/node",
     "sourceTaxonomy":[{"id":"discussion","label":"Discussion","sources":[{"id":"slack","label":"Slack"}]}],
     "askPreferences":{"labelMatch":"all","historyDays":7},
     "labeling":{"autoLabelQueueFolder":false},
     "shortcuts":{"ask":"ctrl+opt+space","addNote":null},
     "runnerOptions":{"openrouter":{"baseURL":"https://example.invalid"}},
     "someFutureKey":{"nested":true}}
    """
}

final class ModelDecodingTests: XCTestCase {
    func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder.core.decode(T.self, from: Data(json.utf8))
    }

    func testDecodesCoreJob() throws {
        let job = try decode(Job.self, Fixtures.tsJob)
        XCTAssertEqual(job.state, .awaitingApproval)
        XCTAssertEqual(job.approval?.plan?.approvalSHA256, "abc123")
        XCTAssertEqual(job.approval?.plan?.changedPaths, ["wiki/tea.md", "wiki/new.md"])
        XCTAssertTrue(job.approval?.canApplyPlan == true)
        XCTAssertEqual(job.approval?.denials.first?.suggestedRule, "Bash(ls /)")
        XCTAssertEqual(job.turns.first?.costUSD ?? 0, 0.05, accuracy: 1e-9)
        XCTAssertEqual(job.createdAt, CoreDate.parse("2026-10-01T12:00:00Z"))
        XCTAssertNotEqual(job.turns.first?.date, .distantPast, "fractional seconds parse")
    }

    func testDecodesSwiftWrittenJob() throws {
        let job = try decode(Job.self, Fixtures.swiftJob)
        XCTAssertNil(job.runnerID)
        XCTAssertEqual(job.selection.runnerID, "claude-code")
        XCTAssertEqual(job.turns.first?.id, "D3A8C9E4-1C3B-4E0B-9B5B-0F8E4C7D2A11")
        XCTAssertEqual(job.state, .completed)
        XCTAssertEqual(job.vaultPath, "/Users/me/Vault")
    }

    func testJobListSkipsMalformedEntries() throws {
        struct Body: Decodable { let jobs: [Lossy<Job>] }
        let json = #"{"jobs":[\#(Fixtures.tsJob),{"nope":1},\#(Fixtures.swiftJob)]}"#
        let jobs = try decode(Body.self, json).jobs.compactMap(\.value)
        XCTAssertEqual(jobs.map(\.id), ["job-20261001-120000-abcd", "job-20260930-080000-1f2e"])
    }

    func testUnknownJobStateStillDecodes() throws {
        let job = try decode(Job.self, #"{"id":"j","state":"paused","createdAt":"bad"}"#)
        XCTAssertEqual(job.state, .failed)
        XCTAssertEqual(job.createdAt, .distantPast)
    }

    func testJobRoundTripsThroughEncoding() throws {
        let job = try decode(Job.self, Fixtures.tsJob)
        let again = try JSONDecoder.core.decode(Job.self, from: JSONEncoder.core.encode(job))
        XCTAssertEqual(job.id, again.id)
        XCTAssertEqual(job.approval, again.approval)
        XCTAssertEqual(job.createdAt, again.createdAt)
    }

    func testSettingsAreTolerantAndKeepV2Fields() throws {
        let s = try decode(Settings.self, Fixtures.settingsV2)
        XCTAssertEqual(s.batchIntervalMinutes, 10, "wrong type falls back to the default")
        XCTAssertEqual(s.settleSeconds, 5)
        XCTAssertEqual(s.extraAllowedTools, ["Read"])
        XCTAssertEqual(s.vaults[1].queueDirectory, VaultProfile.defaultQueueDirectory(forVault: "/tmp/other"))
        XCTAssertEqual(s.taskDefaults.keys.sorted(), ["ask"])
        XCTAssertEqual(s.taskDefaults["ask"]?.effort, "medium")
        XCTAssertEqual(s.nodePath, "/opt/homebrew/bin/node")
        XCTAssertEqual(s.sourceTaxonomy?.first?.sources.first?.id, "slack")
        XCTAssertEqual(s.askPreferences?.labelMatch, .all)
        XCTAssertNil(s.askPreferences?.keepHistory)
        XCTAssertEqual(s.labeling?.autoLabelQueueFolder, false)
        XCTAssertEqual(s.shortcuts?.ask, "ctrl+opt+space")
        XCTAssertEqual(s.runnerOptions?["openrouter"]?["baseURL"], "https://example.invalid")
        XCTAssertEqual(s.activeVault?.path, "/tmp/vault")
    }

    func testEmptySettingsUseDefaults() throws {
        let s = try decode(Settings.self, "{}")
        XCTAssertEqual(s.batchIntervalMinutes, 10)
        XCTAssertEqual(s.settleSeconds, 600, "core default: 10 minutes")
        XCTAssertEqual(s.model, "sonnet")
        XCTAssertTrue(s.autoProcessEnabled)
        XCTAssertEqual(s.enabledRunners, ["claude-code"])
    }

    func testSettingsPatchSendsOnlyChangesAndNullForCleared() throws {
        let old = try decode(Settings.self, Fixtures.settingsV2)
        var new = old
        new.model = "haiku"
        new.nodePath = nil
        new.upsert(VaultProfile(path: "/tmp/third", queueDirectory: "/q"))
        let patch = Settings.patch(from: old, to: new)
        XCTAssertEqual(Set(patch.keys), ["model", "nodePath", "vaults"])
        XCTAssertEqual(patch["model"], .string("haiku"))
        XCTAssertEqual(patch["nodePath"], .null)
        XCTAssertNil(patch["someFutureKey"], "unknown keys are never sent, so the core keeps them")
        XCTAssertTrue(Settings.patch(from: old, to: old).isEmpty)
    }

    func testStatusResponse() throws {
        let s = try decode(StatusResponse.self, """
        {"version":"0.1.0","activeVault":{"path":"/v","queueDirectory":"/q"},"problems":[{"code":"missingClaude","message":"claude CLI not found"}],
         "queueCount":2,"pendingApprovals":1,"runningJobs":0,"nextBatchAt":"2026-10-01T12:10:00Z",
         "runners":[{"id":"claude-code","displayName":"Claude Code","enabled":true,"problems":[]}]}
        """)
        XCTAssertEqual(s.problems.first?.code, "missingClaude")
        XCTAssertEqual(s.nextBatchAt, CoreDate.parse("2026-10-01T12:10:00Z"))
        XCTAssertEqual(s.runners.first?.displayName, "Claude Code")
        let empty = try decode(StatusResponse.self, #"{"nextBatchAt":null}"#)
        XCTAssertNil(empty.nextBatchAt)
    }

    func testAskAndConversationShapes() throws {
        let r = try decode(AskResponse.self, """
        {"conversationID":"c1","answer":"Use 70 °C [1]","citations":[{"n":1,"path":"wiki/sencha.md","title":"Sencha"}],
         "gaps":["no data on gyokuro"],"selection":{"runnerID":"claude-code","model":"sonnet","effort":null},"costUSD":0.01}
        """)
        XCTAssertEqual(r.citations.first?.title, "Sencha")
        XCTAssertNil(r.selection?.effort)
        XCTAssertEqual(r.notices, [])
        let c = try decode(AskConversation.self, """
        {"id":"c1","title":"How hot?","vaultPath":"/v","createdAt":"2026-10-01T12:00:00Z","updatedAt":"2026-10-01T12:05:00Z",
         "pinned":true,"turnCount":1,"turns":[{"askedAt":"2026-10-01T12:00:00Z","request":{"question":"How hot?","labels":["tea"]},
         "response":{"conversationID":"c1","answer":"70","citations":[],"gaps":[],"costUSD":0}}]}
        """)
        XCTAssertEqual(c.summary.pinned, true)
        XCTAssertEqual(c.turns.first?.request.labels, ["tea"])
    }

    func testLabelAndRunnerShapes() throws {
        let review = try decode(LabelReview.self, """
        {"toReview":[{"path":"wiki/a.md","title":"A","labels":["tea"],"origin":"queue-folder"}],"unlabeled":[{"path":"wiki/b.md","title":"B"}]}
        """)
        XCTAssertEqual(review.toReview.first?.origin, "queue-folder")
        XCTAssertEqual(review.unlabeled.first?.title, "B")
        let runner = try decode(RunnerInfo.self, """
        {"id":"openrouter","displayName":"OpenRouter","kind":"modelAPI","enabled":false,"capabilities":["structuredOutput","telepathy"],
         "tasks":["labelSuggest","future"],"models":[{"id":"m","label":"M"}],"effortLevels":[],"defaultModel":"m","problems":[],
         "secrets":[{"name":"apiKey","label":"API key","isSet":false}]}
        """)
        XCTAssertEqual(runner.capabilities, ["structuredOutput", "telepathy"])
        XCTAssertEqual(runner.tasks, [.labelSuggest])
        XCTAssertEqual(runner.secrets.first?.isSet, false)
    }

    func testAddNoteRequestEncodesOnlyGivenFields() throws {
        let data = try JSONEncoder.core.encode(AddNoteRequest(title: "T", text: "x", source: "slack"))
        let json = try JSONDecoder.core.decode(JSONValue.self, from: data)
        XCTAssertEqual(json["origin"], .string("app"))
        XCTAssertNil(json["images"])
        XCTAssertEqual(json["source"], .string("slack"))
    }
}

final class SSEParserTests: XCTestCase {
    func testParsesCoreEventLinesAndIgnoresTheRest() throws {
        var parser = SSEParser()
        let lines = [
            "retry: 2000", ": connected", ": keep-alive", "event: job",
            "data: {\"type\":\"job\",\"job\":\(Fixtures.tsJob.replacingOccurrences(of: "\n", with: ""))}",
            "event: queue",
            #"data: {"type":"queue","entries":[{"path":"/q/a.md","name":"a.md","modified":"2026-10-01T12:00:00Z","size":12,"settled":false}]}"#,
            #"data: {"type":"log","level":"warn","message":"Waiting for your decision on job-1."}"#,
            #"data: {"type":"labelSuggestions","requestID":"r1","notePath":"/q/n.md","labels":[{"name":"tea","existing":true}]}"#,
            #"data: {"type":"brandNew","x":1}"#,
            "data: {not json",
        ]
        let events = lines.compactMap { parser.feed($0) }
        XCTAssertEqual(events.count, 5)
        guard case .job(let job) = events[0] else { return XCTFail("job") }
        XCTAssertEqual(job.id, "job-20261001-120000-abcd")
        guard case .queue(let entries) = events[1] else { return XCTFail("queue") }
        XCTAssertEqual(entries.first?.settled, false)
        XCTAssertEqual(events[2], .log(level: "warn", message: "Waiting for your decision on job-1."))
        guard case .labelSuggestions(let id, _, let labels, let error) = events[3] else { return XCTFail("labels") }
        XCTAssertEqual(id, "r1")
        XCTAssertEqual(labels, [LabelSuggestion(name: "tea", existing: true)])
        XCTAssertNil(error)
        XCTAssertEqual(events[4], .unknown(type: "brandNew"))
        XCTAssertEqual(parser.malformed, 1)
    }

    func testHandlesCRLFAndNoSpace() {
        var parser = SSEParser()
        XCTAssertEqual(parser.feed("data:{\"type\":\"log\",\"level\":\"info\",\"message\":\"m\"}\r"), .log(level: "info", message: "m"))
    }
}

final class BatchIntervalTests: XCTestCase {
    func testSplitsAndRecombines() {
        let i = BatchInterval(totalMinutes: 1440 + 120 + 30)
        XCTAssertEqual([i.days, i.hours, i.minutes], [1, 2, 30])
        XCTAssertEqual(i.totalMinutes, 1590)
        XCTAssertEqual(i.description, "1d 2h 30m")
        XCTAssertEqual(BatchInterval(totalMinutes: 180).description, "3h")
    }

    func testClampsPartsAndNeverZero() {
        var i = BatchInterval(totalMinutes: 1)
        i[.minutes] = 0
        XCTAssertEqual(i.totalMinutes, 1)
        i[.hours] = 99
        XCTAssertEqual(i.hours, 23)
    }
}

final class SettleWaitTests: XCTestCase {
    func testSplitsClampsAndRecombines() {
        var w = SettleWait(totalSeconds: 600)
        XCTAssertEqual([w.minutes, w.seconds], [10, 0])
        w.seconds = 75
        XCTAssertEqual(w.seconds, 59)
        XCTAssertEqual(w.totalSeconds, 659)
        w.minutes = -3
        XCTAssertEqual(w.totalSeconds, 59)
        XCTAssertEqual(SettleWait(totalSeconds: 7200).totalSeconds, 3599, "longer waits clamp to 59:59 in the editor")
        XCTAssertEqual(SettleWait(totalSeconds: 0).totalSeconds, 0)
    }
}

final class PermissionDenialTests: XCTestCase {
    func testRules() {
        XCTAssertNil(PermissionDenial(toolName: "Bash", input: ["command": .string("cd /x && make")]).suggestedRule)
        XCTAssertEqual(PermissionDenial(toolName: "Read", input: ["file_path": .string("/Users/x/a.md")]).suggestedRule, "Read(//Users/x/a.md)")
        XCTAssertEqual(PermissionDenial(toolName: "Write", input: ["file_path": .string("/Users/x/b.md")]).suggestedRule, "Edit(//Users/x/b.md)")
        XCTAssertTrue(PermissionDenial(toolName: "Bash", input: ["command": .string("ls")]).bypassesApproval)
    }
}
