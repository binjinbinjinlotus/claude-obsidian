import AppKit
import SwiftUI
import DistillKit

/// Where a link in an Activity detail goes (MainView switches section).
enum ActivityNav: Equatable {
    case collector(id: String, runs: Bool)
    case job(id: String)
}

/// History → Activity (canvas row 8). Mirrors the core's activity log
/// (`GET /v1/activity`, the `activity` event), its trash (`GET /v1/trash`) and
/// the restores, and sends Restore. Filters are the core's: a new filter asks
/// for page 1 again.
@MainActor
final class ActivityStore: ObservableObject {
    enum Phase: Equatable { case idle, loading, loaded, unavailable, failed(String) }

    @Published var phase: Phase = .idle
    @Published var entries: [ActivityEntry] = []
    @Published var nextCursor: String?
    @Published var loadingMore = false
    @Published var filter = ActivityFilter() {
        didSet { if filter != oldValue { filterChanged(textOnly: filter.text != oldValue.text && filter.chips == oldValue.chips) } }
    }
    /// The entry open in the detail (wide: nil = the first one).
    @Published var selected: String?
    /// Narrow window: the selected entry's detail is pushed in place of the list.
    @Published var pushed = false
    /// The Filter popover: nil closed, "" at the top, or the section a chip opened.
    @Published var panel: String?
    /// Distill's trash by trash id (no payloads).
    @Published var trash: [String: TrashItem] = [:]
    /// Restores by trash id (from `*.restored` entries), so "Restored" survives a relaunch.
    @Published var restores: [String: ActivityRestore] = [:]
    /// Restore in flight, by trash id.
    @Published var restoring: Set<String> = []
    /// Why a Restore didn't work, by trash id.
    @Published var restoreErrors: [String: String] = [:]
    /// A link was clicked (Open collector, Open run log, Open in History).
    @Published var navigate: ActivityNav?

    /// Snapshots: a fixed clock, and fixtures that never talk to a core.
    var fixtureNow: Date?
    var text = ActivityText()

    weak var engine: AppModel?
    private var reloadTask: Task<Void, Never>?
    private var loadToken = 0
    /// The screen asked for the log (possibly before the core was attached): the next connect loads it.
    private var wanted = false
    fileprivate static var stores: [ObjectIdentifier: ActivityStore] = [:]

    static let pageSize = 50

    static func of(_ engine: AppModel) -> ActivityStore {
        let key = ObjectIdentifier(engine)
        if let s = stores[key] { return s }
        let s = ActivityStore()
        s.engine = engine
        stores[key] = s
        return s
    }

    var now: Date { fixtureNow ?? Date() }
    private var client: CoreClient? { engine?.client }

    // MARK: Derived

    var groups: [ActivityText.Group] { text.groups(entries, now: now) }

    /// The entry in the detail: the chosen one, or the newest (wide window).
    var current: ActivityEntry? { entries.first { $0.id == selected } ?? entries.first }

    func recovery(_ e: ActivityEntry) -> ActivityRecoveryState? { text.recovery(e, trash: trash, restores: restores) }

    func tag(_ e: ActivityEntry) -> String { e.failed ? "" : text.tag(recovery(e)) }

    func vaultName(_ path: String) -> String {
        engine?.settings.vaults.first { $0.path == path }?.name ?? (path as NSString).lastPathComponent
    }

    // MARK: Loading

    /// Page 1 for the filter, with the trash and the restores.
    func load() {
        wanted = true
        guard let client else { return }
        loadToken += 1
        let token = loadToken
        if phase != .loaded { phase = .loading }
        let query = filter.query(now: now, limit: Self.pageSize)
        Task {
            do {
                async let page = client.activity(query)
                async let side: Void = loadRecovery(client)
                let (p, _) = try await (page, side)
                guard token == loadToken else { return }
                entries = p.entries
                nextCursor = p.nextCursor
                phase = .loaded
                if let s = selected, !entries.contains(where: { $0.id == s }) { selected = nil; pushed = false }
            } catch let e as CoreClientError where e.isNotAvailable {
                guard token == loadToken else { return }
                phase = .unavailable
            } catch {
                guard token == loadToken else { return }
                if phase != .loaded { phase = .failed("\(error)") }
            }
        }
    }

    /// The trash listing and the restore entries; a failure leaves what is known.
    private func loadRecovery(_ client: CoreClient) async {
        async let items = try? client.trash()
        async let restored = try? client.activity(ActivityQuery(types: ["chat.restored", "collector.restored"], limit: 500))
        let (t, r) = await (items, restored)
        if let t { trash = Dictionary(t.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }) }
        if let r { restores.merge(ActivityRestore.index(r.entries)) { a, b in a.at > b.at ? a : b } }
    }

    /// Older entries (the list's end came into view).
    func loadMore() {
        guard let client, let cursor = nextCursor, !loadingMore, phase == .loaded else { return }
        loadingMore = true
        let token = loadToken
        let query = filter.query(now: now, limit: Self.pageSize, cursor: cursor)
        Task {
            defer { loadingMore = false }
            guard let p = try? await client.activity(query), token == loadToken else { return }
            let known = Set(entries.map(\.id))
            entries.append(contentsOf: p.entries.filter { !known.contains($0.id) })
            nextCursor = p.nextCursor
        }
    }

    /// The core came back (start or restart): ask again if the screen was loaded.
    func reconnected() {
        if phase != .idle || wanted { load() }
    }

    private func filterChanged(textOnly: Bool) {
        selected = nil
        pushed = false
        reloadTask?.cancel()
        guard fixtureNow == nil else { return }
        // Typing waits a moment; a choice in the popover asks at once.
        reloadTask = Task { [weak self] in
            if textOnly { try? await Task.sleep(nanoseconds: 250_000_000) }
            guard !Task.isCancelled else { return }
            self?.load()
        }
    }

    // MARK: Live

    /// A new line in the log (the `activity` event).
    func received(_ e: ActivityEntry) {
        if case .trash(let id, let expiresAt) = e.recovery, trash[id] == nil {
            trash[id] = TrashItem(id: id, kind: e.family, objectID: e.object.id ?? "", name: e.object.name ?? "",
                                  deletedAt: e.at, expiresAt: expiresAt, source: e.source)
        }
        if e.verb == "restored", !e.failed, let id = e.string("trashId") {
            restores[id] = ActivityRestore(at: e.at, objectID: e.object.id)
            trash.removeValue(forKey: id)
        }
        guard phase == .loaded, !entries.contains(where: { $0.id == e.id }) else { return }
        switch filter.matches(e, now: now) {
        case true?:
            entries.insert(e, at: 0)
            entries.sort { $0.id > $1.id }
        case false?:
            break
        case nil:
            // Search is matched by the core (it reads details too): ask again, once things settle.
            reloadTask?.cancel()
            reloadTask = Task { [weak self] in
                try? await Task.sleep(nanoseconds: 400_000_000)
                guard !Task.isCancelled else { return }
                self?.load()
            }
        }
    }

    // MARK: Commands

    func select(_ e: ActivityEntry, narrow: Bool) {
        selected = e.id
        if narrow { pushed = true }
    }

    func back() { pushed = false }

    /// Show everything for this entry's object (a removable "For: …" chip).
    func showEverything(for e: ActivityEntry) {
        guard let id = e.object.id else { return }
        filter.object = ActivityFilter.Object(id: id, name: e.object.name ?? id)
    }

    func restore(_ e: ActivityEntry) {
        guard let client, let id = e.recovery?.trashID, !restoring.contains(id) else { return }
        restoring.insert(id)
        restoreErrors.removeValue(forKey: id)
        Task {
            defer { restoring.remove(id) }
            do {
                let result = try await client.restoreFromTrash(id)
                restores[id] = ActivityRestore(at: Date(), objectID: result.objectID.isEmpty ? e.object.id : result.objectID)
                trash.removeValue(forKey: id)
                if e.family == "collector" { engine?.collectors.load() }
            } catch let err as CoreClientError {
                if err.status == 404 {
                    trash.removeValue(forKey: id)
                    restoreErrors[id] = "It’s no longer in Distill’s trash (it may have expired)."
                } else {
                    restoreErrors[id] = err.description
                }
            } catch {
                restoreErrors[id] = "\(error)"
            }
        }
    }

    /// Open collector / Open chat after a restore; Open run log; Open in History.
    func open(_ e: ActivityEntry, objectID: String?, runs: Bool = false) {
        guard let id = objectID ?? e.object.id else { return }
        switch e.family {
        case "chat": engine?.ask.open(conversationID: id)
        case "collector": navigate = .collector(id: id, runs: runs)
        case "batch", "labels": navigate = .job(id: id)
        default: break
        }
    }

    /// Whether the thing a link points at is still there (a removed collector or job has nothing to open).
    func canOpen(_ e: ActivityEntry, objectID: String?) -> Bool {
        guard let id = objectID ?? e.object.id, let engine else { return false }
        switch e.family {
        case "chat": return true
        case "collector": return engine.collectors.collector(id) != nil
        case "batch", "labels": return engine.job(id) != nil
        default: return false
        }
    }

    func openAskSettings() { engine?.openSettings(section: "ask-history") }

    /// macOS Trash: the file if it is still there, else the Trash folder.
    func showInFinder(_ path: String) {
        let full = (path as NSString).expandingTildeInPath
        if FileManager.default.fileExists(atPath: full) {
            NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: full)])
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: (full as NSString).deletingLastPathComponent))
        }
    }
}

extension AppModel {
    var activity: ActivityStore { ActivityStore.of(self) }
}
