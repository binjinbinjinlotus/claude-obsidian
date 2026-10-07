import Foundation

/// Saves that must land before the app quits (actions.md, When field edits save). Every live
/// draft field registers a flush; every save to the core is counted while it runs. ⌘Q flushes
/// them all, then waits for the saves, never longer than a short timeout.
@MainActor
public final class PendingSaves {
    public static let shared = PendingSaves()

    private var flushers: [UUID: () -> Void] = [:]
    public private(set) var running = 0

    public init() {}

    /// A draft field's "save now"; keep the id to unregister when the field goes away.
    public func register(_ flush: @escaping () -> Void) -> UUID {
        let id = UUID()
        flushers[id] = flush
        return id
    }

    public func unregister(_ id: UUID) { flushers[id] = nil }

    /// Saves every registered draft (each starts its save to the core).
    public func flushAll() {
        for flush in Array(flushers.values) { flush() }
    }

    /// Call when a save to the core starts, and `ended()` when it finishes, either way.
    public func began() { running += 1 }
    public func ended() { running = max(0, running - 1) }

    /// Waits until no save is running, or `timeout` passes. True: every save finished.
    public func waitForSaves(timeout: TimeInterval, poll: UInt64 = 20_000_000) async -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while running > 0 {
            if Date() >= deadline { return false }
            try? await Task.sleep(nanoseconds: poll)
        }
        return true
    }
}
