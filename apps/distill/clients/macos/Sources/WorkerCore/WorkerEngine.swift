import Combine
import Foundation

/// Owns the schedule, the job list, and the approval/resume state machine.
/// UI binds to it; nothing here imports AppKit.
@MainActor
public final class WorkerEngine: ObservableObject {
    @Published public var settings: WorkerSettings {
        didSet {
            guard settings != oldValue else { return }
            try? settingsStore.save(settings)
            if settings.batchIntervalMinutes != oldValue.batchIntervalMinutes
                || settings.activeVaultPath != oldValue.activeVaultPath {
                scheduleNextBatch(from: Date())
            }
            refreshQueue()
        }
    }
    @Published public private(set) var jobs: [Job] = []
    @Published public private(set) var queued: [QueueScanner.Entry] = []
    @Published public private(set) var nextBatchAt: Date?
    @Published public var lastError: String?

    private let settingsStore: JSONFileStore<WorkerSettings>
    private let jobStore: JSONFileStore<[Job]>
    private var runners: [String: ProcessRunner] = [:]
    private var timer: Timer?
    private static let maxStoredJobs = 300

    public init(
        settingsStore: JSONFileStore<WorkerSettings> = .init(filename: "settings.json"),
        jobStore: JSONFileStore<[Job]> = .init(filename: "jobs.json")
    ) {
        self.settingsStore = settingsStore
        self.jobStore = jobStore
        self.settings = settingsStore.load() ?? WorkerSettings()
        self.jobs = (jobStore.load() ?? []).map(Self.recoverInterrupted)
    }

    /// A job that was mid-turn when the app quit keeps its session; the user
    /// can reply to resume it.
    private static func recoverInterrupted(_ job: Job) -> Job {
        guard job.state == .running else { return job }
        var j = job
        j.state = .awaitingApproval
        j.approval = ApprovalRequest(
            summary: "The worker quit while this turn was running. Reply to resume the same session, or reject.",
            questions: [], bundlePath: nil, plan: nil, planError: nil, denials: [], skipped: [])
        return j
    }

    // MARK: Derived state

    public var activeVault: VaultProfile? { settings.activeVault }
    public var problems: [SetupProblem] { SetupValidator.problems(settings) }
    public var pendingApprovals: [Job] { jobs.filter { $0.state == .awaitingApproval } }
    public var runningJobs: [Job] { jobs.filter { $0.state == .running } }

    public func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    /// Why the next batch cannot start right now, if anything.
    public var batchBlocker: String? {
        if let p = problems.first { return p.description }
        guard let vault = activeVault else { return SetupProblem.noVault.description }
        if let holder = jobs.first(where: { $0.vaultPath == vault.path && $0.state.holdsVault }) {
            return holder.state == .running
                ? "Waiting for \(holder.id) to finish."
                : "Waiting for your decision on \(holder.id)."
        }
        return nil
    }

    // MARK: Schedule

    public func start() {
        refreshQueue()
        scheduleNextBatch(from: Date())
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.tick() }
        }
    }

    private func scheduleNextBatch(from date: Date) {
        nextBatchAt = date.addingTimeInterval(TimeInterval(max(1, settings.batchIntervalMinutes) * 60))
    }

    private func tick() {
        refreshQueue()
        guard settings.autoProcessEnabled, let next = nextBatchAt, Date() >= next else { return }
        scheduleNextBatch(from: Date())
        processQueue()
    }

    public func refreshQueue() {
        guard let vault = activeVault else { queued = []; return }
        let entries = QueueScanner.pending(in: vault.queueURL)
        if vault.queueURL.standardizedFileURL.path == vault.inboxURL.standardizedFileURL.path {
            let claimed = claimedFiles(vault: vault)
            queued = entries.filter { !claimed.contains("inbox/" + $0.url.lastPathComponent) }
        } else {
            queued = entries
        }
    }

    private func claimedFiles(vault: VaultProfile) -> Set<String> {
        Set(jobs.filter { $0.vaultPath == vault.path }.flatMap(\.files))
    }

    // MARK: Intake

    public func enqueue(files: [URL]) {
        guard let vault = activeVault else { lastError = SetupProblem.noVault.description; return }
        do { try QueueIntake.copyFiles(files, into: vault.queueURL) } catch { lastError = "\(error)" }
        refreshQueue()
    }

    public func enqueue(data: Data, prefix: String, ext: String) {
        guard let vault = activeVault else { lastError = SetupProblem.noVault.description; return }
        do { try QueueIntake.write(data, prefix: prefix, ext: ext, into: vault.queueURL) } catch { lastError = "\(error)" }
        refreshQueue()
    }

    // MARK: Jobs

    /// Claims settled queue files into one batch job. `force` ignores the settle delay.
    public func processQueue(force: Bool = false) {
        if let blocker = batchBlocker {
            if force { lastError = blocker }
            return
        }
        guard let vault = activeVault else { return }
        let settle = force ? 0 : TimeInterval(settings.settleSeconds)
        let ready = QueueScanner.settled(QueueScanner.pending(in: vault.queueURL), settle: settle)
        guard !ready.isEmpty else { return }
        let files: [String]
        do {
            files = try QueueMover.claim(ready, vault: vault, alreadyClaimed: claimedFiles(vault: vault))
        } catch {
            lastError = "Could not move queue files into the vault inbox: \(error)"
            return
        }
        refreshQueue()
        guard !files.isEmpty else { return }
        let kind = JobKinds.queueConsumer
        let selection = settings.selection(for: kind.task)
        var job = Job(id: Job.makeID(), kind: kind.id, vaultPath: vault.path, files: files, model: selection.model)
        job.selection = selection
        job.turns.append(TurnRecord(author: .app, text: "Batched \(files.count) file(s):\n" + files.map { "- \($0)" }.joined(separator: "\n")))
        insert(job)
        let ctx = JobContext(job: job, vault: vault, settings: settings)
        runTurn(job.id, prompt: kind.initialPrompt(ctx), first: true)
    }

    public func approve(_ id: String) {
        guard let job = job(id), job.state == .awaitingApproval,
              let approval = job.approval, let plan = approval.plan, plan.valid,
              let bundle = approval.bundlePath, let vault = vaultProfile(for: job) else { return }
        let ctx = JobContext(job: job, vault: vault, settings: settings)
        // Only the exact approved command is permitted, and only for this turn.
        let applyRule = "Bash(\(WorkerProtocol.applyCommand(ctx, plan: plan, bundlePath: bundle)))"
        appendTurn(id, TurnRecord(author: .user, text: "Approved \(plan.operationID) (\(plan.approvalSHA256.prefix(12))…)"))
        runTurn(id, prompt: WorkerProtocol.approvedPrompt(ctx, plan: plan, bundlePath: bundle), extraTools: [applyRule])
    }

    public func reply(_ id: String, text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty, let job = job(id), job.state != .running else { return }
        if job.state != .awaitingApproval, holdsOtherJob(job) { lastError = "Another job holds this vault."; return }
        appendTurn(id, TurnRecord(author: .user, text: trimmed))
        runTurn(id, prompt: WorkerProtocol.replyPrompt(trimmed))
    }

    /// Grants rules for previously denied calls for the rest of this job, then resumes.
    public func allow(_ id: String, rules: [String]) {
        guard !rules.isEmpty, job(id)?.state == .awaitingApproval else { return }
        mutate(id) { $0.grantedTools = Array(Set($0.grantedTools + rules)).sorted() }
        appendTurn(id, TurnRecord(author: .user, text: "Allowed:\n" + rules.map { "- \($0)" }.joined(separator: "\n")))
        runTurn(id, prompt: WorkerProtocol.grantedPrompt(rules))
    }

    public func reject(_ id: String) {
        mutate(id) {
            guard $0.state == .awaitingApproval else { return }
            $0.state = .rejected
            $0.turns.append(TurnRecord(author: .user, text: "Rejected. Inbox files are kept; nothing was applied."))
        }
    }

    public func cancel(_ id: String) {
        runners[id]?.cancel()
    }

    public func removeFinished() {
        jobs.removeAll { $0.state.isFinished }
        persist()
    }

    /// Shell script that reopens this job's session interactively.
    public func terminalScript(for id: String) throws -> URL {
        guard let job = job(id) else { throw RunnerError.launchFailed("unknown job") }
        try FileManager.default.createDirectory(at: job.stateDirectory, withIntermediateDirectories: true)
        let url = job.stateDirectory.appendingPathComponent("resume.command")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        guard let runner = Runners.runner(job.selection.runnerID),
              let command = runner.resumeCommand(sessionID: job.sessionID, model: job.model, settings: settings) else {
            throw RunnerError.unsupported(runner: job.selection.runnerID, task: .ask)
        }
        let script = """
        #!/bin/zsh
        cd \(q(job.vaultPath)) || exit 1
        exec \(command.map(q).joined(separator: " "))
        """
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        return url
    }

    // MARK: Turn execution

    private func runTurn(_ id: String, prompt: String, extraTools: [String] = [], first: Bool = false) {
        guard let job = job(id), let vault = vaultProfile(for: job) else { return }
        guard let kind = JobKinds.kind(job.kind) else {
            fail(id, "Unknown job kind \(job.kind)")
            return
        }
        guard let aiRunner = Runners.runner(job.selection.runnerID) else {
            fail(id, RunnerError.unknownRunner(job.selection.runnerID).description)
            return
        }
        guard aiRunner.supports(kind.task) else {
            fail(id, RunnerError.unsupported(runner: aiRunner.displayName, task: kind.task).description)
            return
        }
        mutate(id) { $0.state = .running; $0.error = nil }
        let ctx = JobContext(job: job, vault: vault, settings: settings)
        let request = RunRequest(
            workingDirectory: vault.path,
            prompt: prompt,
            session: first ? .start(job.sessionID) : .resume(job.sessionID),
            selection: job.selection,
            allowedTools: kind.allowedTools(ctx) + extraTools,
            readableDirectories: [settings.productRoot],
            pluginDirectory: settings.productRoot,
            outputSchema: WorkerProtocol.schema,
            systemPrompt: WorkerProtocol.systemPrompt(ctx),
            environment: ["CLAUDE_OBSIDIAN_VAULT": vault.path]
        )
        let settingsSnapshot = settings
        let runner = ProcessRunner()
        runners[id] = runner
        let stateDir = job.stateDirectory
        let turnIndex = job.turns.count
        Task {
            defer { runners[id] = nil }
            do {
                try FileManager.default.createDirectory(at: stateDir, withIntermediateDirectories: true)
                let result = try await aiRunner.run(request, settings: settingsSnapshot, process: runner)
                try? result.raw.write(to: stateDir.appendingPathComponent("turn-\(turnIndex).json"))
                await handle(result, for: id, vault: vault)
            } catch RunnerError.cancelled {
                mutate(id) {
                    $0.state = .cancelled
                    $0.turns.append(TurnRecord(author: .app, text: "Cancelled. Reply to resume the session."))
                }
            } catch {
                fail(id, "\(error)")
            }
        }
    }

    private func handle(_ result: RunResult, for id: String, vault: VaultProfile) async {
        let status = WorkerStatus(result.structured)
        let summary = status?.summary ?? result.resultText
        mutate(id) {
            if let sid = result.sessionID { $0.sessionID = sid }
            $0.turns.append(TurnRecord(author: .worker, text: summary, costUSD: result.costUSD))
        }
        guard let status else {
            if result.isError { fail(id, result.resultText) } else { await ask(id, status: WorkerStatus(status: .needsInput, summary: summary), result: result, vault: vault) }
            return
        }
        switch status.status {
        case .done, .nothingToDo:
            if !result.denials.isEmpty, status.status != .done {
                await ask(id, status: status, result: result, vault: vault)
                return
            }
            mutate(id) {
                $0.state = .completed
                $0.approval = nil
                $0.operationID = status.operationID ?? $0.operationID
                if !status.changedPaths.isEmpty { $0.changedPaths = status.changedPaths }
            }
        case .needsApproval, .needsInput:
            await ask(id, status: status, result: result, vault: vault)
        case .failed:
            if result.denials.isEmpty {
                fail(id, status.summary)
            } else {
                await ask(id, status: status, result: result, vault: vault)
            }
        }
    }

    private func ask(_ id: String, status: WorkerStatus, result: RunResult, vault: VaultProfile) async {
        var request = ApprovalRequest(
            summary: status.summary, questions: status.questions, bundlePath: nil, plan: nil,
            planError: nil, denials: Array(Set(result.denials)), skipped: status.skipped)
        if status.status == .needsApproval {
            if let raw = status.bundlePath {
                let bundle = URL(fileURLWithPath: raw, relativeTo: vault.url).standardizedFileURL
                let jobDir = job(id)?.stateDirectory.standardizedFileURL.path ?? ""
                if bundle.path.hasPrefix(jobDir + "/") {
                    request.bundlePath = bundle.path
                    switch await inspect(bundle: bundle.path, vault: vault) {
                    case .success(let plan): request.plan = plan
                    case .failure(let message): request.planError = message
                    }
                } else {
                    request.planError = "Bundle \(bundle.path) is outside this job's directory; refusing to inspect it."
                }
            } else {
                request.planError = "Claude asked for approval but returned no bundle_path."
            }
        }
        mutate(id) {
            $0.state = .awaitingApproval
            $0.approval = request
        }
    }

    enum InspectOutcome { case success(TransactionPlan), failure(String) }

    /// The approval screen shows what the core says, not Claude's summary.
    private func inspect(bundle: String, vault: VaultProfile) async -> InspectOutcome {
        let runner = ProcessRunner()
        do {
            let out = try await runner.run(
                executable: settings.pythonPath,
                arguments: [settings.coreScriptPath, "transaction", "inspect", bundle, "--vault", vault.path],
                cwd: vault.path)
            if out.status == 0, let plan = try? JSONDecoder().decode(TransactionPlan.self, from: out.stdout) {
                return .success(plan)
            }
            let text = String(decoding: out.stdout + out.stderr, as: UTF8.self)
            return .failure("transaction inspect exited \(out.status): \(text.prefix(4000))")
        } catch {
            return .failure("transaction inspect could not run: \(error)")
        }
    }

    // MARK: Helpers

    private func vaultProfile(for job: Job) -> VaultProfile? {
        settings.vaults.first { $0.path == job.vaultPath }
            ?? VaultProfile(path: job.vaultPath, queueDirectory: VaultProfile.defaultQueueDirectory(forVault: job.vaultPath))
    }

    private func holdsOtherJob(_ job: Job) -> Bool {
        jobs.contains { $0.id != job.id && $0.vaultPath == job.vaultPath && $0.state.holdsVault }
    }

    private func fail(_ id: String, _ message: String) {
        mutate(id) {
            $0.state = .failed
            $0.error = message
            $0.turns.append(TurnRecord(author: .app, text: "Failed: \(message)"))
        }
    }

    private func insert(_ job: Job) {
        jobs.insert(job, at: 0)
        if jobs.count > Self.maxStoredJobs {
            jobs = Array(jobs.prefix(Self.maxStoredJobs))
        }
        persist()
    }

    private func appendTurn(_ id: String, _ turn: TurnRecord) {
        mutate(id) { $0.turns.append(turn) }
    }

    private func mutate(_ id: String, _ change: (inout Job) -> Void) {
        guard let i = jobs.firstIndex(where: { $0.id == id }) else { return }
        change(&jobs[i])
        jobs[i].updatedAt = Date()
        persist()
    }

    private func persist() {
        do { try jobStore.save(jobs) } catch { lastError = "Could not save jobs: \(error)" }
    }
}
