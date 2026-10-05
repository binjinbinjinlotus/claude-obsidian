import AppKit
import DistillKit
import Foundation

// AppModel pieces for v3 loading states (progress events, pending buttons,
// job clearing). Kept out of AppModel.swift so parallel branches merge cleanly.
extension AppModel {
    // MARK: Progress

    func applyProgress(_ p: CoreProgress) {
        progress[p.key] = p
        guard p.finished else { return }
        if p.kind == "apply" { pendingActions["approve:\(p.key)"] = nil }
        // Keep a finished entry briefly so the last step / error can be shown.
        let key = p.key, startedAt = p.startedAt
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            guard let self, let current = self.progress[key], current.finished, current.startedAt == startedAt else { return }
            self.progress[key] = nil
        }
    }

    /// Progress for a running job, if the core sends any.
    func progress(forJob id: String) -> CoreProgress? { progress[id] }

    /// v3 data loaded after (re)connecting. Each part fails quietly on an older core.
    func refreshLiveExtras() {
        guard let client else { return }
        Task { [weak self] in
            if let list = try? await client.listProgress() {
                guard let self else { return }
                var map: [String: CoreProgress] = [:]
                for p in list where !p.finished { map[p.key] = p }
                self.progress = map
            }
        }
        ask.refresh()
    }

    // MARK: Pending buttons

    /// The batch button: "Processing…" while the request is in flight or a batch is running on the active vault.
    var isProcessing: Bool {
        if pendingActions["process"] != nil { return true }
        guard let vault = activeVault?.path else { return false }
        return jobs.contains { $0.vaultPath == vault && $0.state == .running && $0.kind == "ingest" }
    }

    /// The running batch on the active vault, if any.
    var runningBatch: Job? {
        guard let vault = activeVault?.path else { return nil }
        return jobs.first { $0.vaultPath == vault && $0.state == .running && $0.kind == "ingest" }
    }

    func isApplying(_ jobID: String) -> Bool { pendingActions["approve:\(jobID)"] != nil }
    /// When Approve was pressed (for the elapsed timer).
    func applyingSince(_ jobID: String) -> Date? { progress[jobID].flatMap { $0.kind == "apply" ? $0.startedAt : nil } ?? pendingActions["approve:\(jobID)"] }

    /// Called for every job event: a decision the user waited on has landed.
    func settlePendingActions(for job: Job) {
        if pendingActions["approve:\(job.id)"] != nil, job.state != .awaitingApproval {
            pendingActions["approve:\(job.id)"] = nil
        }
        if job.state == .running { pendingActions["process"] = nil }
    }

    /// Process now, showing "Processing…" until the batch starts (or nothing was ready).
    func processNowTracked() {
        guard let client else { lastError = "The Distill core is not connected."; return }
        pendingActions["process"] = Date()
        Task {
            do {
                let job = try await client.processQueue(force: true)
                upsert(job)
                // The label gate: say what waits. Read the queue now; its event may not have landed yet.
                if let queue = try? await client.queue() {
                    queued = queue
                    showProcessToast(started: job, queue: queue)
                }
            } catch {
                report(error)
            }
            pendingActions["process"] = nil
        }
    }

    /// Approve & apply, showing "Applying N changes…" until the job leaves Review.
    func approveTracked(_ id: String, options: ApproveOptions = ApproveOptions()) {
        guard let client else { lastError = "The Distill core is not connected."; return }
        let key = "approve:\(id)"
        pendingActions[key] = Date()
        Task {
            do {
                let job = options.isEmpty ? try await client.approve(id) : try await client.approve(id, options: options)
                upsert(job)
                if let job, job.state != .awaitingApproval { pendingActions[key] = nil }
                else if job == nil { pendingActions[key] = nil }
            } catch let e as CoreClientError where e.sessionUnavailable != nil {
                pendingActions[key] = nil
                showSessionPrompt(e.sessionUnavailable!, jobID: id, action: "approve", approve: options)
            } catch {
                pendingActions[key] = nil
                report(error)
            }
        }
    }

    // MARK: Jobs and queue

    /// Removes finished jobs from History (`DELETE /v1/jobs/:id`).
    func clearFinishedJobs() {
        guard let client else { return }
        let ids = jobs.filter { $0.state.isFinished }.map(\.id)
        Task {
            var kept = 0
            for id in ids {
                do {
                    try await client.deleteJob(id)
                    jobs.removeAll { $0.id == id }
                } catch let e as CoreClientError where e.isNotAvailable {
                    lastError = "This Distill core can't clear jobs yet. Update the core and try again."
                    return
                } catch let e as CoreClientError where e.status == 409 {
                    kept += 1 // e.g. its files are still in inbox/ (inbox-queue mode)
                } catch {
                    report(error)
                    return
                }
            }
            if kept > 0 {
                lastError = kept == 1 ? "1 job was kept: the core can't clear it yet (its files may still be in inbox/)."
                    : "\(kept) jobs were kept: the core can't clear them yet (their files may still be in inbox/)."
            }
        }
    }

    var hasFinishedJobs: Bool { jobs.contains { $0.state.isFinished } }

    /// Drops a file from the queue through the core only. The core refuses items a batch already
    /// took from inbox/, so the app never trashes queue files itself (decision 2026-10-04).
    func removeFromQueue(_ entry: QueueEntry) {
        guard let client else {
            lastError = "Can't remove \(entry.name) while the Distill core isn't running."
            return
        }
        Task {
            do {
                try await client.removeQueueEntry(path: entry.path)
                let gone = QueueRows.paths(removing: entry) // a note takes its members along
                queued.removeAll { gone.contains($0.path) }
            } catch {
                report(error)
            }
        }
    }

    /// Reopens a job's runner session in Terminal: the core's resume argv (`GET /v1/jobs/:id/resume`).
    /// A session the core reports gone shows SessionReplaceConfirm (never a blind `--resume`); the
    /// local Claude Code command is only for an older core that has no resume route.
    func openInTerminal(_ job: Job) {
        Task {
            do {
                guard let client else {
                    lastError = "The Distill core is not connected."
                    return
                }
                let resume: ResumeCommand
                do {
                    resume = try await client.jobResume(job.id)
                } catch let e as CoreClientError where e.sessionUnavailable != nil {
                    terminalSessionPrompt = SessionPrompt(jobID: job.id, info: e.sessionUnavailable!, action: "resume")
                    return
                } catch let e as CoreClientError where e.isNotAvailable {
                    openTerminalScript(try terminalScript(for: job)) // an older core: no session check there
                    return
                }
                guard !resume.argv.isEmpty else {
                    lastError = "This batch has no AI session to open in Terminal."
                    return
                }
                openTerminalScript(try Self.writeTerminalScript(name: job.id, argv: resume.argv, cwd: resume.cwd ?? job.vaultPath))
            } catch {
                report(error)
            }
        }
    }

    static func writeTerminalScript(name: String, argv: [String], cwd: String) throws -> URL {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("Distill-resume", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let url = dir.appendingPathComponent("\(name).command")
        let q = { (s: String) in "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'" }
        let script = "#!/bin/zsh\ncd \(q(cwd)) || exit 1\nexec \(argv.map(q).joined(separator: " "))\n"
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o700], ofItemAtPath: url.path)
        return url
    }

    /// Whether we are still waiting for the core's first answer.
    var isStarting: Bool { connection == .connecting && status == nil }
}
