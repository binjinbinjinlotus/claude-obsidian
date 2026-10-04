import Foundation
import DistillKit

/// Refresh and the queue check (queue-and-batching.md "Sync: Refresh and the queue check"). The core
/// scans; the app asks for a scan (Refresh, the main window becoming active) and mirrors the result.
extension AppModel {
    /// How long Refresh shows its result before going back to "checked at …".
    static var refreshResultSeconds: Double = 4 // tests shorten it
    /// The window-active scan runs at most this often (switching windows back and forth is free).
    static let windowScanSpacing: TimeInterval = 15

    /// The last full scan of any kind: the core's `lastQueueScanAt`, or a newer one this app saw.
    var queueCheckedAt: Date? {
        switch (lastScanSeen, status?.lastQueueScanAt) {
        case let (a?, b?): return max(a, b)
        case let (a, b): return a ?? b
        }
    }

    /// Refresh: scan now, show "Checking…", then the result for 4 seconds.
    func refreshQueueNow() {
        guard refreshState != .checking else { return }
        guard let client else { return }
        refreshResetTask?.cancel()
        refreshState = .checking
        Task { [weak self] in
            do {
                let result = try await client.scanQueue(trigger: .manual)
                guard let self else { return }
                self.applyScan(result)
                self.showRefreshResult(QueueRefreshState.result(result))
            } catch let e as CoreClientError where e.isNotAvailable {
                // An older core has no scan route: fall back to re-reading the list, no banner.
                guard let self else { return }
                self.refreshState = .idle
                self.refreshQueue()
            } catch {
                guard let self else { return }
                self.refreshState = .idle
                self.report(error)
            }
        }
    }

    /// The main window became active: a full scan (folders walked again), throttled; the result
    /// moves "checked at" and the list but shows no result text.
    func scanQueueOnWindowActive(now: Date = Date()) {
        guard launcher != nil, isConnected, let client else { return }
        if let last = lastWindowScan, now.timeIntervalSince(last) < Self.windowScanSpacing { return }
        lastWindowScan = now
        Task { [weak self] in
            guard let result = try? await client.scanQueue(trigger: .window) else { return }
            self?.applyScan(result)
        }
    }

    /// A scan result from Refresh, the window scan or the `queue.scanned` event (any trigger).
    func applyScan(_ result: QueueScanResult) {
        if let entries = result.entries { queued = entries }
        if lastScanSeen.map({ result.checkedAt > $0 }) ?? true { lastScanSeen = result.checkedAt }
        let added = Set(result.addedEntries.map(\.path))
        guard !added.isEmpty else { return }
        flashingPaths.formUnion(added)
        flashTask?.cancel()
        flashTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_600_000_000)
            guard !Task.isCancelled else { return }
            self?.flashingPaths = []
        }
    }

    private func showRefreshResult(_ state: QueueRefreshState) {
        refreshState = state
        refreshResetTask?.cancel()
        refreshResetTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: UInt64(Self.refreshResultSeconds * 1_000_000_000))
            guard !Task.isCancelled else { return }
            self?.refreshState = .idle
        }
    }
}
