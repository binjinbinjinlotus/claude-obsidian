import AppKit
import Combine
import DistillKit
import Foundation

/// What the windows show, kept in sync with the Distill core over HTTP + SSE.
/// The core owns every piece of state (settings, queue, jobs, schedule,
/// runners); this model only mirrors it and sends commands. It never writes
/// settings.json or jobs.json and never runs an AI turn itself.
@MainActor
final class AppModel: ObservableObject {
    enum Connection: Equatable {
        case connecting
        case connected
        case unreachable(String)
        /// Snapshot mode: fixture data, no core.
        case offline
    }

    @Published private(set) var connection: Connection = .connecting
    /// Edit freely (SwiftUI bindings); changes are sent to the core as a patch
    /// after a short pause. Core `settings` events replace it unless an edit is pending.
    @Published var settings = Settings() {
        didSet { if !applyingRemote && settings != oldValue { scheduleSettingsSave() } }
    }
    @Published var jobs: [Job] = []
    @Published var queued: [QueueEntry] = []
    @Published private(set) var status: StatusResponse?
    @Published var lastError: String?
    /// Live progress by key (job id, `ask:<conversationID>`, `note:<requestID>`); see AppModel+Ask.swift.
    @Published var progress: [String: CoreProgress] = [:]
    /// Buttons waiting on the core ("process", "approve:<job id>") and when they were pressed;
    /// cleared by the job event or an error.
    @Published var pendingActions: [String: Date] = [:]
    /// Session continuity (AppModel+Session.swift): a batch call the core refused because the
    /// batch's AI session is gone, by job id; SessionReplaceConfirm shows it in Review.
    @Published var sessionPrompts: [String: SessionPrompt] = [:]
    /// Open in Terminal hit a gone session: the popover's prompt (one at a time).
    @Published var terminalSessionPrompt: SessionPrompt?
    /// Job markers (`Job.sessionUnavailable`) the user cancelled, so they don't come back.
    @Published var dismissedSessionMarkers: Set<String> = []
    /// A reply put back in Review's box after Cancel (job id, text).
    @Published var returnedReply: ReturnedReply?
    /// Opens a Terminal `.command` script (tests replace it so nothing launches).
    var openTerminalScript: (URL) -> Void = { NSWorkspace.shared.open($0) }
    /// QueueRefresh: "Checking…", then a result for 4 s after Refresh (AppModel+Queue.swift).
    @Published var refreshState: QueueRefreshState = .idle
    /// The last full queue scan this app saw (Refresh, window, periodic); see `queueCheckedAt`.
    @Published var lastScanSeen: Date?
    /// Rows that just appeared through a scan flash once.
    @Published var flashingPaths: Set<String> = []
    /// The dark toast at the bottom of the main window after Process now (AppModel+Labels.swift).
    @Published var queueToast: QueueToast?
    var queueToastTask: Task<Void, Never>?
    var refreshResetTask: Task<Void, Never>?
    var flashTask: Task<Void, Never>?
    var lastWindowScan: Date?
    var windowScanPending = false
    /// Ask chats, the Ask screen and the quick ask window (AskModel.swift).
    lazy var ask = AskModel(engine: self)

    let launcher: CoreLauncher?
    private(set) var client: CoreClient?
    private var eventTask: Task<Void, Never>?
    private var connectTask: Task<Void, Never>?
    private var settingsSaveTask: Task<Void, Never>?
    private var statusTask: Task<Void, Never>?
    private var statusTimer: Timer?
    private var syncedSettings = Settings()
    private var applyingRemote = false

    init(launcher: CoreLauncher) {
        self.launcher = launcher
    }

    /// Tests: talk to a stubbed core.
    func useClientForTesting(_ client: CoreClient) { self.client = client }

    /// Fixture model for `--snapshot` (no core, nothing is sent anywhere).
    init(fixtureSettings: Settings, jobs: [Job], queue: [QueueEntry], status: StatusResponse?) {
        launcher = nil
        connection = .offline
        applyingRemote = true
        settings = fixtureSettings
        applyingRemote = false
        syncedSettings = fixtureSettings
        self.jobs = jobs
        queued = queue
        self.status = status
    }

    /// Snapshot fixtures only: puts a fixture model (no launcher) into a
    /// connection state ("Starting Distill…", core unreachable, setup problems).
    func setFixtureState(connection: Connection, status: StatusResponse?) {
        guard launcher == nil else { return }
        self.connection = connection
        self.status = status
    }

    // MARK: Derived state

    var activeVault: VaultProfile? { settings.activeVault }
    var problems: [SetupProblem] { status?.problems ?? [] }
    /// Batches that need the owner (badges, auto-open): the core's rule; queued, refreshing and recovering ones wait without them.
    var pendingApprovals: [Job] { jobs.filter(ReviewQueueText.needsOwner) }
    var runningJobs: [Job] { jobs.filter { $0.state == .running } }
    var nextBatchAt: Date? { status?.nextBatchAt }
    var isConnected: Bool { connection == .connected }

    func job(_ id: String) -> Job? { jobs.first { $0.id == id } }

    /// Why the next batch cannot start right now (same rules as the core's batchBlocker).
    var batchBlocker: String? {
        if case .unreachable = connection { return "The Distill core is not running." }
        if let p = problems.first { return p.message }
        guard let vault = activeVault else { return "No vault selected." }
        if let holder = jobs.first(where: { $0.vaultPath == vault.path && $0.state.holdsVault }) {
            return holder.state == .running ? "Waiting for \(holder.id) to finish." : "Waiting for your decision on \(holder.id)."
        }
        return nil
    }

    // MARK: Connection

    /// Find or start the core, then subscribe to its events. Safe to call again (Retry).
    func connect() {
        guard let launcher else { return }
        connectTask?.cancel()
        eventTask?.cancel()
        connection = .connecting
        connectTask = Task { [weak self] in
            do {
                // Node discovery and spawning block; keep them off the main thread.
                let endpoint = try await Task.detached { try await launcher.ensureRunning() }.value
                guard let self, !Task.isCancelled else { return }
                self.attach(CoreClient(endpoint: endpoint))
                try await self.refreshAll()
                self.connection = .connected
                self.runPendingWindowScan() // the window became active before the core answered
            } catch {
                guard let self, !Task.isCancelled else { return }
                self.connection = .unreachable("\(error)")
            }
        }
        statusTimer?.invalidate()
        statusTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.refreshStatusSoon() }
        }
    }

    private func attach(_ client: CoreClient) {
        self.client = client
        eventTask?.cancel()
        eventTask = Task { [weak self] in await self?.runEvents() }
    }

    /// Reads events until the connection drops, then reconnects to the same (or
    /// a restarted) core. When no core is alive any more, shows the problem.
    private func runEvents() async {
        var delay: UInt64 = 500_000_000
        while !Task.isCancelled {
            guard let client else { return }
            do {
                for try await event in client.events() {
                    apply(event)
                    delay = 500_000_000
                }
            } catch {}
            if Task.isCancelled { return }
            // The core binds a new port when it restarts: re-read server.json every time.
            guard let launcher, let endpoint = launcher.liveEndpoint() else {
                connection = .unreachable("The Distill core stopped. Retry starts it again.")
                return
            }
            if endpoint != client.endpoint { self.client = CoreClient(endpoint: endpoint) }
            try? await Task.sleep(nanoseconds: delay)
            delay = min(delay * 2, 8_000_000_000)
            do {
                try await refreshAll()
                connection = .connected
            } catch {}
        }
    }

    func refreshAll() async throws {
        guard let client else { return }
        async let s = client.settings()
        async let q = client.queue()
        async let j = client.jobs()
        async let st = client.status()
        let (settings, queue, jobs, status) = try await (s, q, j, st)
        applyRemoteSettings(settings, force: settingsSaveTask == nil)
        queued = queue
        self.jobs = jobs
        self.status = status
        refreshLiveExtras()
        actions.load()
        collectors.load()
        activity.reconnected()
        jobSteps.reconnected()
    }

    private func apply(_ event: CoreEvent) {
        switch event {
        case .queue(let entries):
            queued = entries
            refreshStatusSoon()
        case .job(let job):
            if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.insert(job, at: 0) }
            settlePendingActions(for: job)
            refreshStatusSoon()
        case .settings(let s):
            applyRemoteSettings(s, force: false)
            refreshStatusSoon()
        case .log(let level, let message):
            if level == "warn" || level == "error" { lastError = message }
        case .labelSuggestions(let requestID, let notePath, let labels, let error):
            noteLabelSuggestions(requestID: requestID, notePath: notePath, labels: labels, error: error)
        case .conversation(let conversation, let deleted):
            ask.apply(conversation, deleted: deleted)
        case .progress(let p):
            applyProgress(p)
        case .connection(let connection):
            applyConnection(connection)
            actions.load() // the Create handlers' availability follows the connection
        case .jobDeleted(let id):
            jobs.removeAll { $0.id == id }
            refreshStatusSoon()
        case .action(let item, let deleted):
            actions.apply(item, deleted: deleted)
        case .collector(let c, let deleted):
            collectors.apply(c, deleted: deleted)
        case .collectorRunStarted(let run):
            collectors.runStarted(run)
        case .collectorRunOutput(let collectorId, let runId, let stream, let text):
            collectors.runOutput(collectorId: collectorId, runId: runId, stream: stream, text: text)
        case .collectorRunFinished(let run):
            collectors.runFinished(run)
        case .collectorInstallStarted(let install):
            collectors.installStarted(install)
        case .collectorInstallOutput(let collectorId, let installId, let text):
            collectors.installOutput(collectorId: collectorId, installId: installId, text: text)
        case .collectorInstallFinished(let install):
            collectors.installFinished(install)
        case .queueScanned(let result):
            applyScan(result)
        case .activity(let entry):
            activity.received(entry)
        case .jobStep(let jobId, let step):
            jobSteps.received(jobId: jobId, step: step)
        case .unknown:
            break
        }
    }

    private func refreshStatusSoon() {
        guard client != nil, statusTask == nil else { return }
        statusTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 300_000_000)
            guard let self else { return }
            defer { self.statusTask = nil }
            if let s = try? await self.client?.status() { self.status = s }
        }
    }

    // MARK: Settings sync

    private func applyRemoteSettings(_ s: Settings, force: Bool) {
        syncedSettings = s
        guard force || settingsSaveTask == nil else { return } // an edit is pending; our PUT answers it
        applyingRemote = true
        settings = s
        applyingRemote = false
    }

    private func scheduleSettingsSave() {
        guard launcher != nil else { return }
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 500_000_000)
            guard !Task.isCancelled else { return }
            await self?.flushSettings()
        }
    }

    /// ⌘Q: the settings save waiting out its pause goes now (AppDelegate waits for it).
    func saveSettingsNow() {
        guard settingsSaveTask != nil else { return }
        settingsSaveTask?.cancel()
        settingsSaveTask = Task { [weak self] in await self?.flushSettings() }
    }

    /// Sends the keys that differ from what the core last reported.
    func flushSettings() async {
        PendingSaves.shared.began()
        defer { PendingSaves.shared.ended() }
        guard let client else { settingsSaveTask = nil; return }
        let sent = settings
        let patch = Settings.patch(from: syncedSettings, to: sent)
        guard !patch.isEmpty else { settingsSaveTask = nil; return }
        do {
            let saved = try await client.updateSettings(patch)
            syncedSettings = saved
            if settings == sent {
                settingsSaveTask = nil
                applyRemoteSettings(saved, force: true)
            }
        } catch {
            settingsSaveTask = nil
            report(error)
        }
    }

    // MARK: Commands

    private func perform(_ work: @escaping (CoreClient) async throws -> Void) {
        guard let client else { lastError = "The Distill core is not connected."; return }
        Task {
            do { try await work(client) } catch { report(error) }
        }
    }

    func report(_ error: Error) {
        if let e = error as? CoreClientError, e.isUnreachable, launcher?.liveEndpoint() == nil {
            connection = .unreachable("The Distill core stopped. Retry starts it again.")
            return
        }
        lastError = "\(error)"
    }

    func upsert(_ job: Job?) {
        guard let job else { return }
        if let i = jobs.firstIndex(where: { $0.id == job.id }) { jobs[i] = job } else { jobs.insert(job, at: 0) }
    }

    func processQueue(force: Bool = true) {
        perform { client in
            let job = try await client.processQueue(force: force)
            await MainActor.run { self.upsert(job) }
        }
    }

    func approve(_ id: String) { sessionAware(id, action: "approve") { try await $0.approve(id) } }
    /// `sent` runs only once the core took the reply, so the box keeps the text on any failure.
    func reply(_ id: String, text: String, sent: (() -> Void)? = nil) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        sessionAware(id, action: "reply", text: trimmed, held: sent) { client in
            let job = try await client.reply(id, text: trimmed)
            await MainActor.run { sent?() }
            return job
        }
    }
    func allow(_ id: String, rules: [String]) { sessionAware(id, action: "allow", rules: rules) { try await $0.allow(id, rules: rules) } }
    /// A rebuilt part: `batch: false` discards only that part; `batch: true` rejects the whole batch.
    func reject(_ id: String, batch: Bool = false) { jobAction { try await $0.reject(id, batch: batch) } }
    func cancel(_ id: String) { jobAction { try await $0.cancel(id) } }
    /// review-queue.md: Don't apply yet.
    func unqueue(_ id: String) { jobAction { try await $0.unqueue(id) } }
    /// review-queue.md: Let recovery try again.
    func recover(_ id: String) { jobAction { try await $0.recover(id) } }

    private func jobAction(_ call: @escaping (CoreClient) async throws -> Job?) {
        perform { client in
            let job = try await call(client)
            await MainActor.run { self.upsert(job) }
        }
    }

    func refreshQueue() {
        perform { client in
            let q = try await client.queue()
            await MainActor.run { self.queued = q }
        }
    }

    // MARK: Intake

    /// Dropped or chosen files: the core copies them into the active vault's queue.
    func enqueue(files: [URL]) {
        let paths = files.map(\.path)
        guard !paths.isEmpty else { return }
        perform { client in _ = try await client.addQueueFiles(paths) }
    }

    /// Pasted data: written to a temp file with the intake name
    /// (`Screenshot <yyyy-MM-dd HHmmss>.png`), handed to the core, then removed.
    func enqueue(data: Data, prefix: String, ext: String, date: Date = Date()) {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Distill-intake-\(UUID().uuidString)", isDirectory: true)
        let file = dir.appendingPathComponent(Self.intakeName(prefix: prefix, ext: ext, date: date))
        do {
            try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
            try data.write(to: file, options: .atomic)
        } catch {
            lastError = "Could not stage the pasted content: \(error)"
            return
        }
        perform { client in
            defer { try? FileManager.default.removeItem(at: dir) }
            _ = try await client.addQueueFiles([file.path])
        }
    }

    static func intakeName(prefix: String, ext: String, date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        return "\(prefix) \(f.string(from: date)).\(ext)"
    }

    // MARK: Terminal

    /// A throwaway script that reopens a Claude Code job's session interactively.
    func terminalScript(for job: Job) throws -> URL {
        guard job.selection.runnerID == "claude-code" else {
            throw CoreClientError.badResponse("Only Claude Code sessions can be reopened in Terminal.")
        }
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Distill-resume", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(job.id).command")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let command = [settings.claudePath, "--resume", job.sessionID, "--plugin-dir", settings.productRoot, "--model", job.model]
        let script = "#!/bin/zsh\ncd \(q(job.vaultPath)) || exit 1\nexec \(command.map(q).joined(separator: " "))\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }
}
