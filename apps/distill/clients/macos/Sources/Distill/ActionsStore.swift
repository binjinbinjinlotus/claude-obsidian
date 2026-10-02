import AppKit
import Combine
import DistillKit
import Foundation

/// A short message at the bottom of an Actions screen ("Completed “…” · Undo").
struct ActionToast: Identifiable {
    let id = UUID()
    var text: String
    var undo: (() -> Void)?
    var open: (() -> Void)?
    var openTitle = "Open"
    var history = false
}

/// AI or handler work the app is waiting on for one item.
enum ActionRun: Equatable {
    case drafting(Date)
    case improving(Date)
    case creating(Date)
    case refreshing

    var start: Date? {
        switch self {
        case .drafting(let d), .improving(let d), .creating(let d): return d
        case .refreshing: return nil
        }
    }
}

/// Actions for the whole app (canvas row 6): the type registry, every item the
/// core reported, what is running, the toast and navigation requests. The core
/// owns the items; this only mirrors them (GET + `action` events) and sends commands.
@MainActor
final class ActionsStore: ObservableObject {
    enum Phase: Equatable { case idle, loading, loaded, unavailable, failed(String) }

    @Published var types: [ActionTypeInfo] = []
    @Published var items: [String: ActionItem] = [:]
    @Published var phase: Phase = .idle
    @Published var historyLoaded = false
    /// The open Actions sub-item: "todo" or a type id.
    @Published var tab = "todo"
    /// Selected item per tab.
    @Published var selected: [String: String] = [:]
    @Published var toast: ActionToast?
    @Published var running: [String: ActionRun] = [:]
    /// "Copied at 3:52 PM": the button reads Copied for 2 s; the Mark as sent prompt stays.
    @Published var copiedAt: [String: Date] = [:]
    @Published var copiedFlash: Set<String> = []
    /// Improved bits stay tinted for a few seconds after an improve.
    @Published var justImproved: Set<String> = []
    /// Edits in progress by item id (ActionsTypes.swift).
    @Published var editing: [String: ActionEditDraft] = [:]
    /// Items whose "Show changes" is open.
    @Published var showingChanges: Set<String> = []
    /// Bumped to ask the main window to show Actions (Open from Ask, a toast).
    @Published var showRequest = 0
    /// Bumped to show History → Actions.
    @Published var historyRequest = 0
    /// Settings section to open ("connections", "actions/jira"); MainView opens Settings.
    @Published var settingsRequest: String?
    /// Ask: ids that detection said are already in Actions, per conversation.
    @Published var already: [String: Set<String>] = [:]
    /// Ask: conversations whose "Show" (confirmation off) is expanded.
    @Published var expandedAdded: Set<String> = []
    /// Ask: the summary line after Add all, per conversation and turn ("c1#0").
    @Published var addedAll: [String: [String]] = [:]

    private var tasks: [String: Task<Void, Never>] = [:]
    private var arrivals: [ActionItem] = []
    private var arrivalTask: Task<Void, Never>?
    private var toastTask: Task<Void, Never>?
    weak var engine: AppModel?

    fileprivate static var stores: [ObjectIdentifier: ActionsStore] = [:]

    static func of(_ engine: AppModel) -> ActionsStore {
        let key = ObjectIdentifier(engine)
        if let s = stores[key] { return s }
        let s = ActionsStore()
        s.engine = engine
        stores[key] = s
        return s
    }

    // MARK: Derived

    /// Types with a sub-item: on and not reserved (a type turned off has none).
    var listTypes: [ActionTypeInfo] {
        let usable = types.filter(\.isUsable)
        if usable.isEmpty { return [ActionTypeInfo(id: "todo", label: "To-do", pluralLabel: "To do")] }
        return usable
    }

    func type(_ id: String) -> ActionTypeInfo? { types.first { $0.id == id } }

    func label(_ id: String) -> String { id == "todo" ? "To do" : (type(id)?.pluralLabel ?? id) }

    var counts: [String: Int] { ActionCounts.byType(Array(items.values), types: listTypes.map(\.id)) }
    var total: Int { counts.values.reduce(0, +) }

    func items(type: String) -> [ActionItem] { items.values.filter { $0.type == type } }
    var pending: [ActionItem] { items.values.filter { $0.status == .pending }.sorted { $0.createdAt > $1.createdAt } }

    /// "last found today at 3:44 PM in Tea club planning".
    func lastFound(type: String) -> (Date, String?)? {
        let found = items.values.filter { $0.type == type && !$0.source.isManual }
        guard let latest = found.max(by: { $0.createdAt < $1.createdAt }) else { return nil }
        return (latest.createdAt, ActionList.noteTitle(latest))
    }

    // MARK: Loading

    private var client: CoreClient? { engine?.client }

    func load() {
        guard let client, phase != .loading else { return }
        if phase != .loaded { phase = .loading }
        Task {
            do {
                async let t = client.actionTypes()
                async let a = client.actions()
                let (types, items) = try await (t, a)
                self.types = types
                var map = self.items.filter { $0.value.status.isHistory || $0.value.status == .dismissed }
                for item in items { map[item.id] = item }
                self.items = map
                phase = .loaded
            } catch let e as CoreClientError where e.isNotAvailable {
                phase = .unavailable
            } catch {
                if phase != .loaded { phase = .failed("\(error)") }
            }
        }
    }

    func loadHistory() {
        guard let client else { return }
        Task {
            do {
                let list = try await client.actions(ActionQuery(status: ActionStatus.history, history: true))
                for item in list { items[item.id] = item }
                historyLoaded = true
            } catch let e as CoreClientError where e.isNotAvailable {
                phase = .unavailable
            } catch {
                engine?.report(error)
            }
        }
    }

    /// `action` event (wired in AppModel.apply).
    func apply(_ item: ActionItem, deleted: Bool) {
        if deleted { items[item.id] = nil; return }
        let isNew = items[item.id] == nil
        items[item.id] = item
        if item.status != .drafting, case .drafting? = running[item.id] { running[item.id] = nil }
        if item.status != .drafting, case .improving? = running[item.id] { running[item.id] = nil }
        if item.status != .creating, case .creating? = running[item.id] { running[item.id] = nil }
        if isNew, phase == .loaded, case .note = item.source { noteArrival(item) }
    }

    /// New items from a processed note: one toast for the batch ("5 actions to
    /// confirm from Tea club planning · Open", or "Added … · Undo" when confirm is off).
    private func noteArrival(_ item: ActionItem) {
        arrivals.append(item)
        arrivalTask?.cancel()
        arrivalTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 1_200_000_000)
            guard let self, !Task.isCancelled else { return }
            let batch = self.arrivals
            self.arrivals = []
            let note = batch.compactMap(ActionList.noteTitle).first
            let pending = batch.filter { $0.status == .pending }
            if !pending.isEmpty {
                let n = pending.count
                self.show(ActionToast(text: "\(n) \(n == 1 ? "action" : "actions") to confirm" + (note.map { " from \($0)" } ?? ""),
                                      open: { [weak self] in self?.open(tab: "todo") }))
            } else {
                let added = batch.filter { [.open, .ready, .drafting].contains($0.status) }
                guard !added.isEmpty else { return }
                let todos = added.filter { $0.type == "todo" }.count
                self.show(ActionToast(text: ActionCounts.addedPhrase(todos: todos, drafts: added.count - todos) + (note.map { " from \($0)" } ?? ""),
                                      undo: { [weak self] in self?.dismiss(added.map(\.id)) }))
            }
        }
    }

    // MARK: Navigation

    func open(tab: String, select id: String? = nil) {
        self.tab = tab
        if let id { selected[tab] = id }
        showRequest += 1
    }

    /// Opens an item where it lives now.
    func open(_ item: ActionItem) {
        let current = items[item.id] ?? item
        if current.status.isHistory { historyRequest += 1; selectedHistory = current.id; return }
        open(tab: listTypes.contains { $0.id == current.type } ? current.type : "todo", select: current.id)
    }

    @Published var selectedHistory: String?
    /// "Review them" on a job: To do filtered to that job's notes.
    @Published var jobFilter: String?

    func openJob(_ jobID: String) {
        jobFilter = jobID
        open(tab: "todo")
    }

    func openSettings(_ section: String) { settingsRequest = section }

    // MARK: Toast

    func show(_ toast: ActionToast) {
        self.toast = toast
        toastTask?.cancel()
        let id = toast.id
        toastTask = Task { [weak self] in
            try? await Task.sleep(nanoseconds: 6_000_000_000)
            guard let self, !Task.isCancelled, self.toast?.id == id else { return }
            self.toast = nil
        }
    }

    // MARK: Commands

    private func call(_ id: String? = nil, _ work: @escaping (CoreClient) async throws -> ActionItem?) {
        guard let client else { engine?.lastError = "The Distill core is not connected."; return }
        Task {
            do {
                if let item = try await work(client) { self.items[item.id] = item }
            } catch is CancellationError {
            } catch let e as CoreClientError where e.isNotAvailable {
                self.phase = .unavailable
            } catch {
                self.engine?.report(error)
            }
            if let id, self.running[id] == .refreshing { self.running[id] = nil }
        }
    }

    func create(_ input: NewActionInput, then: ((ActionItem) -> Void)? = nil) {
        call { client in
            let item = try await client.createAction(input)
            await MainActor.run { then?(item) }
            return item
        }
    }

    func update(_ id: String, _ patch: ActionPatch) {
        guard !patch.isEmpty else { return }
        if var local = items[id] {
            if let t = patch.title { local.title = t }
            if let b = patch.body { local.body = b }
            if let f = patch.fields { for (k, v) in f { local.fields[k] = v } }
            if let l = patch.labels { local.labels = l }
            items[id] = local
        }
        call { try await $0.updateAction(id, patch) }
    }

    func complete(_ item: ActionItem) {
        call { try await $0.performAction(item.id, handler: "complete") }
        show(ActionToast(text: "Completed “\(item.title)”", undo: { [weak self] in self?.restore(item.id) }))
    }

    func remove(_ item: ActionItem) {
        call { try await $0.removeAction(item.id) }
        let what = item.type == "todo" ? "“\(item.title)”" : (item.external?.key.map { "\($0) from Distill (it stays in \(typeName(item.type)))" }
            ?? "the \(ActionCounts.noun(item.type, count: 1, types: types).lowercased()) draft")
        show(ActionToast(text: "Removed \(what)", undo: { [weak self] in self?.restore(item.id) }, history: true))
    }

    func markSent(_ item: ActionItem) {
        call { try await $0.performAction(item.id, handler: "markSent") }
        copiedAt[item.id] = nil
        show(ActionToast(text: "\(item.title) marked as sent", undo: { [weak self] in self?.restore(item.id) }, history: true))
    }

    func markDone(_ item: ActionItem) {
        call { try await $0.performAction(item.id, handler: "complete") }
        show(ActionToast(text: "\(item.external?.key ?? item.title) marked done. Moved to History.", undo: { [weak self] in self?.restore(item.id) }, history: true))
    }

    func restore(_ id: String, toast: String? = nil) {
        call { try await $0.restoreAction(id) }
        if let toast { show(ActionToast(text: toast, open: { [weak self] in if let i = self?.items[id] { self?.open(i) } })) }
    }

    func deleteForever(_ id: String) {
        guard let client else { return }
        items[id] = nil
        Task {
            do { try await client.deleteActionForever(id) } catch { engine?.report(error) }
        }
    }

    func confirm(_ ids: [String]) {
        guard let client, !ids.isEmpty else { return }
        Task {
            do {
                for item in try await client.confirmActions(ids) { items[item.id] = item }
            } catch { engine?.report(error) }
        }
    }

    func dismiss(_ ids: [String]) {
        guard let client, !ids.isEmpty else { return }
        for id in ids { items[id]?.status = .dismissed }
        Task {
            do { try await client.dismissActions(ids) } catch { engine?.report(error); load() }
        }
    }

    func sendTo(_ item: ActionItem, type: String) {
        guard let client else { return }
        Task {
            do {
                let made = try await client.sendAction(item.id, to: type)
                items[made.id] = made
                items[item.id]?.status = .sent
                show(ActionToast(text: "Moved to \(label(type)) as a draft", undo: { [weak self] in self?.restore(item.id) },
                                 open: { [weak self] in self?.open(tab: type, select: made.id) }))
            } catch { engine?.report(error) }
        }
    }

    func copy(_ item: ActionItem) {
        let text = ActionText.slack(item.body ?? "")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        copiedAt[item.id] = Date()
        copiedFlash.insert(item.id)
        Task { [weak self] in
            try? await Task.sleep(nanoseconds: 2_000_000_000)
            self?.copiedFlash.remove(item.id)
        }
        call { try await $0.performAction(item.id, handler: "copy") }
    }

    func perform(_ item: ActionItem, handler: String) {
        if handler == "create" { running[item.id] = .creating(Date()) }
        if handler == "refresh" { running[item.id] = .refreshing }
        call(item.id) { client in
            let result = try await client.performAction(item.id, handler: handler)
            await MainActor.run { if case .creating? = self.running[item.id] { self.running[item.id] = nil } }
            return result
        }
    }

    /// Create message / Write draft; Cancel keeps what was there.
    func draft(_ item: ActionItem) { longRun(item, .drafting(Date())) { try await $0.draftAction(item.id) } }

    /// Done after an edit: the type's improve pass, with Undo.
    func improve(_ item: ActionItem) {
        longRun(item, .improving(Date())) { try await $0.improveAction(item.id) } done: { [weak self] result in
            guard let self, result.previousBody != nil else { return }
            self.justImproved.insert(item.id)
            Task { [weak self] in
                try? await Task.sleep(nanoseconds: 4_000_000_000)
                self?.justImproved.remove(item.id)
            }
        }
    }

    func undoImprove(_ item: ActionItem) {
        justImproved.remove(item.id)
        showingChanges.remove(item.id)
        call { try await $0.undoImprove(item.id) }
    }

    func cancelRun(_ id: String) {
        tasks[id]?.cancel()
        tasks[id] = nil
        running[id] = nil
        // The core returns the item as it was; fetch it so the card shows that.
        call { try await $0.action(id) }
    }

    private func longRun(_ item: ActionItem, _ run: ActionRun, _ work: @escaping (CoreClient) async throws -> ActionItem,
                         done: ((ActionItem) -> Void)? = nil) {
        guard let client else { return }
        running[item.id] = run
        tasks[item.id]?.cancel()
        tasks[item.id] = Task {
            defer { if running[item.id] == run { running[item.id] = nil }; tasks[item.id] = nil }
            do {
                let result = try await work(client)
                items[result.id] = result
                done?(result)
            } catch is CancellationError {
            } catch {
                if !Task.isCancelled { engine?.report(error) }
            }
        }
    }

    /// Try again for a batch whose Finding actions step failed.
    func findAgain(jobID: String) {
        guard let client else { return }
        Task {
            do { engine?.upsert(try await client.findJobActions(jobID)) } catch { engine?.report(error) }
        }
    }

    /// Detection by hand (Add to to-do ▾ → "Find actions in this answer"); the core also runs it after each answer.
    func detect(conversationID: String, turnIndex: Int?) {
        guard let client else { return }
        Task {
            do {
                let found = try await client.detectAskActions(conversationID: conversationID, turnIndex: turnIndex)
                var dupes = already[conversationID] ?? []
                for item in found {
                    items[item.id] = item
                    if item.source.conversationID != conversationID { dupes.insert(item.id) }
                }
                already[conversationID] = dupes
            } catch { engine?.report(error) }
        }
    }

    func typeName(_ id: String) -> String {
        (type(id)?.label ?? id).components(separatedBy: " ").first ?? id
    }

    // MARK: Snapshot fixtures

    func loadFixture(types: [ActionTypeInfo], items: [ActionItem]) {
        self.types = types
        self.items = Dictionary(uniqueKeysWithValues: items.map { ($0.id, $0) })
        phase = .loaded
        historyLoaded = true
    }
}

/// Text helpers for drafts.
enum ActionText {
    /// Markdown → Slack's marks for Copy: **bold** → *bold*, ~~strike~~ → ~strike~, [t](u) → <u|t>.
    static func slack(_ markdown: String) -> String {
        var s = markdown
        s = s.replacingOccurrences(of: #"(?<!\*)\*(?!\*)([^*\n]+)(?<!\*)\*(?!\*)"#, with: "_$1_", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\*\*([^*\n]+)\*\*"#, with: "*$1*", options: .regularExpression)
        s = s.replacingOccurrences(of: #"~~([^~\n]+)~~"#, with: "~$1~", options: .regularExpression)
        s = s.replacingOccurrences(of: #"\[([^\]\n]+)\]\(([^)\s]+)\)"#, with: "<$2|$1>", options: .regularExpression)
        return s
    }

    /// Initials for a person chip: "Mei Tanaka" → "MT", "You (Jin Liu)" → "JL".
    static func initials(_ name: String) -> String {
        var n = name
        if let open = n.firstIndex(of: "("), let close = n.lastIndex(of: ")"), open < close {
            n = String(n[n.index(after: open)..<close])
        }
        let words = n.split(whereSeparator: { $0 == " " || $0 == "-" }).filter { $0.first?.isLetter == true }
        return String(words.prefix(2).compactMap(\.first)).uppercased()
    }

    /// Changed words between two texts (for the tint and Show changes): simple word diff.
    static func changes(from old: String, to new: String) -> [(removed: String, added: String)] {
        let a = old.split(separator: " ").map(String.init), b = new.split(separator: " ").map(String.init)
        let diff = b.difference(from: a)
        var removed: [String] = [], added: [String] = []
        for change in diff {
            switch change {
            case .remove(_, let w, _): removed.append(w)
            case .insert(_, let w, _): added.append(w)
            }
        }
        if removed.isEmpty && added.isEmpty { return [] }
        return [(removed.joined(separator: " "), added.joined(separator: " "))]
    }

    /// Words of `new` that are not in `old` (tinted after an improve).
    static func addedWords(from old: String, to new: String) -> Set<Int> {
        let a = old.split(separator: " ").map(String.init), b = new.split(separator: " ").map(String.init)
        var out = Set<Int>()
        for change in b.difference(from: a) { if case .insert(let i, _, _) = change { out.insert(i) } }
        return out
    }
}

extension AppModel {
    var actions: ActionsStore { ActionsStore.of(self) }
}
