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
        if pendingActions.contains("process") { return true }
        guard let vault = activeVault?.path else { return false }
        return jobs.contains { $0.vaultPath == vault && $0.state == .running && $0.kind == "ingest" }
    }

    /// The running batch on the active vault, if any.
    var runningBatch: Job? {
        guard let vault = activeVault?.path else { return nil }
        return jobs.first { $0.vaultPath == vault && $0.state == .running && $0.kind == "ingest" }
    }

    func isApplying(_ jobID: String) -> Bool { pendingActions.contains("approve:\(jobID)") }

    /// Called for every job event: a decision the user waited on has landed.
    func settlePendingActions(for job: Job) {
        if pendingActions.contains("approve:\(job.id)"), job.state != .awaitingApproval {
            pendingActions.remove("approve:\(job.id)")
        }
        if job.state == .running { pendingActions.remove("process") }
    }

    /// Process now, showing "Processing…" until the batch starts (or nothing was ready).
    func processNowTracked() {
        guard let client else { lastError = "The Distill core is not connected."; return }
        pendingActions.insert("process")
        Task {
            do {
                let job = try await client.processQueue(force: true)
                upsert(job)
            } catch {
                report(error)
            }
            pendingActions.remove("process")
        }
    }

    /// Approve & apply, showing "Applying N changes…" until the job leaves Review.
    func approveTracked(_ id: String) {
        guard let client else { lastError = "The Distill core is not connected."; return }
        let key = "approve:\(id)"
        pendingActions.insert(key)
        Task {
            do {
                let job = try await client.approve(id)
                upsert(job)
                if let job, job.state != .awaitingApproval { pendingActions.remove(key) }
                else if job == nil { pendingActions.remove(key) }
            } catch {
                pendingActions.remove(key)
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
            for id in ids {
                do {
                    try await client.deleteJob(id)
                    jobs.removeAll { $0.id == id }
                } catch let e as CoreClientError where e.isNotAvailable {
                    lastError = "This Distill core can't clear jobs yet. Update the core and try again."
                    return
                } catch {
                    report(error)
                    return
                }
            }
        }
    }

    var hasFinishedJobs: Bool { jobs.contains { $0.state.isFinished } }

    /// Drops a file from the queue through the core; falls back to the Trash on an older core.
    func removeFromQueue(_ entry: QueueEntry) {
        guard let client else { trash(entry); return }
        Task {
            do {
                try await client.removeQueueEntry(path: entry.path)
                queued.removeAll { $0.path == entry.path }
            } catch let e as CoreClientError where e.isNotAvailable {
                trash(entry)
            } catch {
                report(error)
            }
        }
    }

    /// Whether we are still waiting for the core's first answer.
    var isStarting: Bool { connection == .connecting && status == nil }
}
