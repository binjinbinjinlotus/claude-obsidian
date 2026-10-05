import Foundation
import DistillKit

/// The dark two-line toast after Process now ("Started a batch with 19 files · 3 notes are still being labeled…").
struct QueueToast: Identifiable, Equatable {
    let id = UUID()
    var title: String
    var detail: String
    /// A batch started (a check before the title).
    var started: Bool
}

/// v6 labels in the queue and in Review: confirm, retry or skip a queue file's labels; edit labels, remove
/// sources and approve some of them in Review. The core owns every state; these only send commands.
extension AppModel {
    // MARK: Queue labels

    /// Confirms a queue file's labels ([] = no labels): × on a suggested chip (the rest), Accept all, + Add, Edit → Done.
    func labelQueueItem(_ path: String, labels: [String]) {
        queueLabelCall { try await $0.labelQueueItem(path: path, labels: labels) }
    }

    func retryQueueLabels(_ path: String) {
        queueLabelCall { try await $0.retryQueueLabels(path: path) }
    }

    func skipQueueLabels(_ path: String) {
        queueLabelCall { try await $0.skipQueueLabels(path: path) }
    }

    private func queueLabelCall(_ call: @escaping (CoreClient) async throws -> [QueueEntry]) {
        guard let client else { lastError = "The Distill core is not connected."; return }
        Task {
            do { queued = try await call(client) } catch { report(error) }
        }
    }

    /// Rows held for labels in the active queue.
    var heldForLabelsCount: Int { QueueRows.visible(queued).filter(\.heldForLabels).count }

    func showProcessToast(started job: Job?, queue: [QueueEntry]) {
        let rows = QueueRows.visible(queue)
        let held = rows.filter(\.heldForLabels).count
        guard let text = QueueLabelText.processToast(started: job.map { $0.sources.count }, held: held, rows: rows.count,
                                                     next: nextBatchAt.map { QueueRows.clock($0) }) else { return }
        showQueueToast(QueueToast(title: text.title, detail: text.detail, started: job != nil))
    }

    func showQueueToast(_ toast: QueueToast) {
        queueToast = toast
        queueToastTask?.cancel()
        let id = toast.id
        queueToastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 7_000_000_000)
            guard let self, !Task.isCancelled, self.queueToast?.id == id else { return }
            self.queueToast = nil
        }
    }

    // MARK: Review

    /// Writes edited labels into the change. `done` gets nil on success, or the core's message when it refused
    /// (409: nothing changed, the labels stay as before).
    func editReviewLabels(_ jobID: String, page: String, labels: [String], done: @escaping (String?) -> Void = { _ in }) {
        guard let client else { lastError = "The Distill core is not connected."; done(lastError); return }
        Task {
            do {
                upsert(try await client.editReviewLabels(jobID, edits: [(page: page, labels: labels)]))
                done(nil)
            } catch let e as CoreClientError where e.status == 409 {
                done(e.description)
            } catch {
                report(error)
                done("\(error)")
            }
        }
    }

    /// Remove takes a source out of the batch (never added to the vault; its inbox file stays); Undo puts it back.
    func removeReviewSource(_ jobID: String, page: String, removed: Bool) {
        guard let client else { lastError = "The Distill core is not connected."; return }
        Task {
            do { upsert(try await client.removeReviewSource(jobID, page: page, removed: removed)) } catch { report(error) }
        }
    }

    /// Review lists the batches waiting for you and a batch whose part is being rebuilt, oldest first.
    var reviewJobs: [Job] {
        ReviewBatches.ordered(jobs.filter { $0.state == .awaitingApproval || ($0.state == .running && $0.pendingPart != nil) })
    }
}
