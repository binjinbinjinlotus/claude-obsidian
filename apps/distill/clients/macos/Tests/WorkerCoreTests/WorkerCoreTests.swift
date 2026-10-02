import XCTest
@testable import WorkerCore

final class ClaudeResultTests: XCTestCase {
    func testParsesStructuredOutputAndDenials() throws {
        let json = """
        {"session_id":"abc","result":"{}","is_error":false,"total_cost_usd":0.02,
         "structured_output":{"status":"needs_approval","summary":"ok","bundle_path":"/v/.vault-meta/worker/j/bundle.json"},
         "permission_denials":[{"tool_name":"Bash","tool_use_id":"t","tool_input":{"command":"ls /"}}]}
        """
        let result = try ClaudeResult.parse(Data(json.utf8))
        XCTAssertEqual(result.sessionID, "abc")
        XCTAssertEqual(result.costUSD, 0.02, accuracy: 1e-9)
        XCTAssertEqual(result.denials.first?.suggestedRule, "Bash(ls /)")
        let status = try XCTUnwrap(WorkerStatus(result.structured))
        XCTAssertEqual(status.status, .needsApproval)
        XCTAssertEqual(status.bundlePath, "/v/.vault-meta/worker/j/bundle.json")
    }

    func testMissingStructuredOutputIsNil() throws {
        let result = try ClaudeResult.parse(Data(#"{"session_id":"s","result":"hi","is_error":false}"#.utf8))
        XCTAssertNil(WorkerStatus(result.structured))
        XCTAssertEqual(result.resultText, "hi")
    }

    func testCompoundBashDenialHasNoRule() {
        let d = PermissionDenial(toolName: "Bash", input: ["command": .string("cd /x && python3 build.py")])
        XCTAssertNil(d.suggestedRule)
        XCTAssertTrue(d.bypassesApproval)
    }

    func testAbsolutePathDenialUsesDoubleSlashRule() {
        let d = PermissionDenial(toolName: "Read", input: ["file_path": .string("/Users/x/a.md")])
        XCTAssertEqual(d.suggestedRule, "Read(//Users/x/a.md)")
        let w = PermissionDenial(toolName: "Write", input: ["file_path": .string("/Users/x/b.md")])
        XCTAssertEqual(w.suggestedRule, "Edit(//Users/x/b.md)")
    }
}

final class InvocationTests: XCTestCase {
    func testStartThenResumeArguments() {
        var inv = ClaudeInvocation(claudePath: "/c", workingDirectory: "/v", prompt: "p", session: .start("id"),
                                   model: "haiku", allowedTools: ["Read", "Bash(x:*)"], pluginDirectory: "/prod")
        XCTAssertEqual(Array(inv.arguments.prefix(7)), ["-p", "--output-format", "json", "--model", "haiku", "--session-id", "id"])
        let i = inv.arguments.firstIndex(of: "--allowedTools")!
        XCTAssertEqual(Array(inv.arguments[(i + 1)...]), ["Read", "Bash(x:*)"])
        XCTAssertFalse(inv.arguments.contains("p"), "prompt goes over stdin")
        inv.session = .resume("id")
        XCTAssertTrue(inv.arguments.contains("--resume"))
        XCTAssertFalse(inv.arguments.contains("--session-id"))
    }

    func testPlanningToolsNeverAllowApply() {
        var settings = WorkerSettings()
        settings.productRoot = "/prod"
        let vault = VaultProfile(path: "/v", queueDirectory: "/q")
        let job = Job(id: "job-1", kind: "ingest", vaultPath: "/v", files: ["inbox/a.md"], model: "sonnet")
        let ctx = JobContext(job: job, vault: vault, settings: settings)
        let tools = IngestJobKind().allowedTools(ctx)
        XCTAssertFalse(tools.contains { $0.contains("transaction apply") })
        XCTAssertTrue(tools.contains("Bash(python3 /prod/scripts/claude-obsidian.py transaction inspect:*)"))
        XCTAssertTrue(tools.contains("Edit(//v/.vault-meta/worker/job-1/**)"))
    }

    func testPathsWithSpacesAreQuoted() {
        var settings = WorkerSettings()
        settings.productRoot = "/prod"
        let vault = VaultProfile(path: "/Users/me/Library/Mobile Documents/iCloud~md~obsidian/Documents/My Vault", queueDirectory: "/q")
        let ctx = JobContext(job: Job(id: "j", kind: "ingest", vaultPath: vault.path, files: [], model: "m"), vault: vault, settings: settings)
        let plan = TransactionPlan(operationID: "op", operationType: "ingest", valid: true, changedPaths: [], approvalSHA256: "abc")
        XCTAssertEqual(WorkerProtocol.applyCommand(ctx, plan: plan, bundlePath: ctx.bundlePath),
                       "python3 /prod/scripts/claude-obsidian.py transaction apply '\(ctx.bundlePath)' --vault '\(vault.path)' --approved-plan-sha256 abc")
        XCTAssertEqual(shellQuote("it's"), "'it'\\''s'")
    }

    func testApplyRuleIsExactCommand() {
        var settings = WorkerSettings()
        settings.productRoot = "/prod"
        let ctx = JobContext(job: Job(id: "j", kind: "ingest", vaultPath: "/v", files: [], model: "m"),
                             vault: VaultProfile(path: "/v", queueDirectory: "/q"), settings: settings)
        let plan = TransactionPlan(operationID: "op", operationType: "ingest", valid: true, changedPaths: [], approvalSHA256: "abc")
        XCTAssertEqual(WorkerProtocol.applyCommand(ctx, plan: plan, bundlePath: "/v/b.json"),
                       "python3 /prod/scripts/claude-obsidian.py transaction apply /v/b.json --vault /v --approved-plan-sha256 abc")
    }
}

final class QueueTests: XCTestCase {
    var tmp: URL!

    override func setUpWithError() throws {
        tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: tmp) }

    func testScannerSkipsHiddenPartialAndUnsettled() throws {
        let q = tmp.appendingPathComponent("q")
        try FileManager.default.createDirectory(at: q, withIntermediateDirectories: true)
        for name in ["a.md", ".hidden", "b.pdf.crdownload"] {
            try Data("x".utf8).write(to: q.appendingPathComponent(name))
        }
        let old = Date().addingTimeInterval(-60)
        try FileManager.default.setAttributes([.modificationDate: old], ofItemAtPath: q.appendingPathComponent("a.md").path)
        try Data("y".utf8).write(to: q.appendingPathComponent("fresh.md"))
        let pending = QueueScanner.pending(in: q)
        XCTAssertEqual(Set(pending.map { $0.url.lastPathComponent }), ["a.md", "fresh.md"])
        XCTAssertEqual(QueueScanner.settled(pending, settle: 10).map { $0.url.lastPathComponent }, ["a.md"])
    }

    func testClaimMovesIntoInboxWithoutClobbering() throws {
        let vaultURL = tmp.appendingPathComponent("vault")
        let inbox = vaultURL.appendingPathComponent("inbox")
        let q = tmp.appendingPathComponent("q")
        for d in [inbox, q] { try FileManager.default.createDirectory(at: d, withIntermediateDirectories: true) }
        try Data("existing".utf8).write(to: inbox.appendingPathComponent("note.md"))
        try Data("new".utf8).write(to: q.appendingPathComponent("note.md"))
        let vault = VaultProfile(path: vaultURL.path, queueDirectory: q.path)
        let claimed = try QueueMover.claim(QueueScanner.pending(in: q), vault: vault, alreadyClaimed: [])
        XCTAssertEqual(claimed, ["inbox/note 2.md"])
        XCTAssertEqual(try String(contentsOf: inbox.appendingPathComponent("note.md")), "existing")
        XCTAssertTrue(QueueScanner.pending(in: q).isEmpty)
    }

    func testQueueIsInboxSkipsClaimedFiles() throws {
        let vaultURL = tmp.appendingPathComponent("vault")
        let inbox = vaultURL.appendingPathComponent("inbox")
        try FileManager.default.createDirectory(at: inbox, withIntermediateDirectories: true)
        for n in ["a.md", "b.md"] { try Data("x".utf8).write(to: inbox.appendingPathComponent(n)) }
        let vault = VaultProfile(path: vaultURL.path, queueDirectory: inbox.path)
        let claimed = try QueueMover.claim(QueueScanner.pending(in: inbox), vault: vault, alreadyClaimed: ["inbox/a.md"])
        XCTAssertEqual(claimed, ["inbox/b.md"])
        XCTAssertTrue(FileManager.default.fileExists(atPath: inbox.appendingPathComponent("a.md").path))
    }

    func testValidatorRejectsQueueInsideRaw() {
        var s = WorkerSettings()
        s.vaults = [VaultProfile(path: tmp.path, queueDirectory: tmp.appendingPathComponent(".raw/x").path)]
        XCTAssertTrue(SetupValidator.problems(s).contains(.queueIsVaultInternal(tmp.appendingPathComponent(".raw/x").standardizedFileURL.path)))
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
        i[.minutes] = -5
        XCTAssertEqual(i.minutes, 0)
        XCTAssertEqual(i.totalMinutes, 23 * 60)
    }
}

final class RunnerTests: XCTestCase {
    func testClaudeCodeSupportsEveryTask() {
        let claude = ClaudeCodeRunner()
        for task in AITask.allCases { XCTAssertTrue(claude.supports(task), "\(task)") }
    }

    func testRunnerWithoutPermissionsCannotIngest() {
        struct ChatOnly: AgentRunner {
            var id: String { "chat-only" }
            var displayName: String { "Chat only" }
            var capabilities: RunnerCapabilities { [.structuredOutput, .vision] }
            var models: [ModelOption] { [] }
            var effortLevels: [String] { [] }
            var defaultModel: String { "m" }
            func problems(_ settings: WorkerSettings) -> [SetupProblem] { [] }
            func run(_ request: RunRequest, settings: WorkerSettings, process: ProcessRunner) async throws -> RunResult {
                RunResult(sessionID: nil, resultText: "", isError: false, costUSD: 0, structured: nil, denials: [], raw: Data())
            }
        }
        let r = ChatOnly()
        XCTAssertFalse(r.supports(.ingest), "approval gate needs tools + permissions + resume")
        XCTAssertFalse(r.supports(.ask))
        XCTAssertTrue(r.supports(.labelSuggest))
        XCTAssertTrue(r.supports(.imageText))
    }

    func testSelectionFallbacksAndOverrides() {
        var s = WorkerSettings()
        s.model = "opus"
        XCTAssertEqual(s.selection(for: .ingest), ModelSelection(runnerID: "claude-code", model: "opus"))
        XCTAssertEqual(s.selection(for: .labelSuggest).model, "haiku")
        s.setSelection(ModelSelection(runnerID: "claude-code", model: "sonnet", effort: "high"), for: .ask)
        XCTAssertEqual(s.selection(for: .ask).effort, "high")
        let data = try! JSONEncoder().encode(s)
        let back = try! JSONDecoder().decode(WorkerSettings.self, from: data)
        XCTAssertEqual(back.selection(for: .ask), s.selection(for: .ask))
    }

    func testOldSettingsAndJobsStillDecode() throws {
        let settings = try JSONDecoder().decode(WorkerSettings.self, from: Data(#"{"model":"haiku"}"#.utf8))
        XCTAssertEqual(settings.enabledRunners, ["claude-code"])
        XCTAssertEqual(settings.selection(for: .ingest).model, "haiku")
        var job = Job(id: "j", kind: "ingest", vaultPath: "/v", files: [], model: "sonnet")
        job.runnerID = nil
        XCTAssertEqual(job.selection.runnerID, "claude-code")
    }

    func testRequestMapsToClaudeFlagsIncludingEffort() {
        var settings = WorkerSettings()
        settings.claudePath = "/c"
        let request = RunRequest(workingDirectory: "/v", prompt: "p", session: .resume("s1"),
                                 selection: ModelSelection(runnerID: "claude-code", model: "opus", effort: "high"),
                                 allowedTools: ["Read"])
        let args = ClaudeCodeRunner().invocation(request, settings: settings).arguments
        XCTAssertEqual(Array(args.prefix(9)), ["-p", "--output-format", "json", "--model", "opus", "--effort", "high", "--resume", "s1"])
    }
}
