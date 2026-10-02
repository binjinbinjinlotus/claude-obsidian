import AppKit
import Combine
import DistillKit
import Foundation

/// One question and, once it lands, its answer.
struct AskEntry: Identifiable, Equatable {
    let id = UUID()
    var question: String
    var askedAt: Date
    var request: AskRequest
    var response: AskResponse
    /// Seconds the answer took, when it was asked in this session.
    var duration: TimeInterval?
}

/// The question in flight (or the one that was stopped or failed; it is kept so it can be sent again).
struct PendingQuestion: Equatable {
    enum Status: Equatable {
        case running
        case stopped
        case failed(String)
    }

    var question: String
    var startedAt: Date
    var request: AskRequest
    var status: Status
    var costSoFar: Double = 0
}

/// One chat as shown in a window: the Ask screen has one, the quick ask window another.
@MainActor
final class AskThread: ObservableObject {
    @Published var conversationID: String?
    @Published var entries: [AskEntry] = []
    @Published var pending: PendingQuestion?
    @Published var filter: AskFilter
    @Published var selection: ModelSelection?
    @Published var draft = ""
    /// Shown above the conversation (e.g. a chat that could not be loaded).
    @Published var note: String?
    /// The id the in-flight turn uses (client-chosen for a new chat, so Stop works early).
    var inFlightID: String?
    var task: Task<Void, Never>?
    /// Identifies the run this thread shows; a run moved to the background keeps its token.
    var runToken: UUID?
    var stopRequested = false
    /// Set when "Continue in Distill" moved this chat to the Ask screen.
    var handedOff = false

    init(filter: AskFilter) { self.filter = filter }

    var isRunning: Bool { pending?.status == .running }
    var isEmpty: Bool { entries.isEmpty && pending == nil }
    var lastResponse: AskResponse? { entries.last?.response }

    func reset(filter: AskFilter) {
        task?.cancel()
        task = nil
        runToken = nil
        conversationID = nil
        entries = []
        pending = nil
        self.filter = filter
        draft = ""
        note = nil
        inFlightID = nil
        stopRequested = false
        handedOff = false
    }
}

/// A question still being answered after its window moved on (New chat, another
/// chat opened, Continue in Distill, the quick ask window closed). It is never
/// stopped for that: it finishes, is saved to History, and can be reopened while it runs.
struct BackgroundAsk: Identifiable {
    enum Origin: Equatable { case main, quick }

    /// The conversation id the run uses (client-chosen for a new chat).
    let id: String
    let token: UUID
    var pending: PendingQuestion
    /// The chat has no saved turns yet (its first question is the one running).
    let isNew: Bool
    let task: Task<Void, Never>?
    /// The window it was asked in: the flask's green ring follows runs from quick ask.
    var origin: Origin = .main
}

enum BackgroundAskText {
    /// "Asked today at 3:40 PM · answering…" — a fixed time, never a counter.
    static func meta(_ run: BackgroundAsk, now: Date = Date()) -> String {
        let asked = HistoryTime.asked(run.pending.startedAt, now: now)
        if case .failed(let message) = run.pending.status { return "\(asked) · couldn't answer: \(message)" }
        return "\(asked) · answering…"
    }
}

/// Ask chats for the whole app: history, runners and labels for the pickers,
/// the Ask screen's thread and the quick ask window's thread.
@MainActor
final class AskModel: ObservableObject {
    unowned let engine: AppModel
    @Published var conversations: [AskConversationSummary] = []
    /// Questions still answering after their window moved on, by conversation id (History shows them).
    @Published var background: [String: BackgroundAsk] = [:]
    @Published var runners: [RunnerInfo] = []
    @Published var labels: [LabelCount] = []
    /// Bumped to ask the main window to show the Ask screen.
    @Published var showAskRequest = 0
    /// The quick ask window is open.
    @Published var quickVisible = false
    /// The quick ask answer arrived while its window was closed. Closing detaches the
    /// run (`closeQuick`), so this no longer drives the flask's ring.
    @Published var quickUnseen = false

    /// The Ask screen's chat. "Continue in Distill" hands the quick thread over (a run in flight keeps going).
    @Published private(set) var main: AskThread
    @Published private(set) var quick: AskThread
    private var quickObserver: AnyCancellable?
    private var settingsObserver: AnyCancellable?

    init(engine: AppModel) {
        self.engine = engine
        let prefs = engine.settings.resolvedAskPreferences
        main = AskThread(filter: AskFilter(preferences: prefs))
        quick = AskThread(filter: AskFilter(preferences: prefs))
        observeQuick()
        // The model is created before the core sends settings: an untouched
        // chat follows the Ask defaults as they arrive or change.
        settingsObserver = engine.$settings
            .map(\.resolvedAskPreferences)
            .removeDuplicates()
            .sink { [weak self] prefs in self?.reseedUntouched(prefs) }
    }

    private func reseedUntouched(_ prefs: AskPreferences) {
        for thread in [main, quick] where thread.isEmpty && thread.filter.labels.isEmpty {
            thread.filter.labelMatch = prefs.resolvedLabelMatch
            thread.filter.includeUnconfirmed = prefs.resolvedIncludeUnconfirmed
        }
    }

    /// The flask's ring follows the quick thread, so forward its changes.
    private func observeQuick() {
        quickObserver = quick.objectWillChange.sink { [weak self] _ in self?.objectWillChange.send() }
    }

    var preferences: AskPreferences { engine.settings.resolvedAskPreferences }
    var taxonomy: [SourceGroup] { engine.settings.resolvedSourceTaxonomy }
    var askRunners: [RunnerInfo] { AskSelection.runners(runners) }

    /// The green ring on the flask: a question from quick ask is still answering in the
    /// background after its window closed.
    var quickInBackground: Bool {
        !quickVisible && quickBackgroundRun != nil
    }

    /// The newest question from quick ask still answering in the background.
    var quickBackgroundRun: BackgroundAsk? {
        background.values.filter { $0.origin == .quick && $0.pending.status == .running }
            .max { $0.pending.startedAt < $1.pending.startedAt }
    }

    func selection(for thread: AskThread) -> ModelSelection {
        AskSelection.resolve(current: thread.selection, settings: engine.settings, runners: runners)
    }

    func runner(for selection: ModelSelection) -> RunnerInfo? { runners.first { $0.id == selection.runnerID } }

    func effortLevels(for thread: AskThread) -> [String] {
        let levels = runner(for: selection(for: thread))?.effortLevels ?? []
        return levels.isEmpty ? ["low", "medium", "high", "max"] : levels
    }

    // MARK: Loading

    func refresh() {
        guard let client = engine.client else { return }
        Task {
            if let list = try? await client.conversations() { conversations = AskHistoryPolicy.sorted(list) }
            if let list = try? await client.runners() { runners = list }
            await refreshLabels()
        }
    }

    func refreshLabels() async {
        guard let client = engine.client else { return }
        if let list = try? await client.labels(vaultPath: engine.activeVault?.path) {
            labels = list.sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
        }
    }

    /// `conversation` events: saves, pins and deletes from any client.
    func apply(_ summary: AskConversationSummary, deleted: Bool) {
        conversations.removeAll { $0.id == summary.id }
        if !deleted { conversations.append(summary) }
        conversations = AskHistoryPolicy.sorted(conversations)
        if deleted {
            for thread in [main, quick] where thread.conversationID == summary.id && !thread.isRunning {
                thread.reset(filter: AskFilter(preferences: preferences))
            }
        }
    }

    // MARK: Asking

    func send(_ thread: AskThread, question raw: String? = nil) {
        let question = (raw ?? thread.draft).trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !thread.isRunning else { return }
        guard let client = engine.client else { engine.lastError = "The Distill core is not connected."; return }
        let isNew = thread.conversationID == nil
        let id = thread.conversationID ?? UUID().uuidString.lowercased()
        var request = AskRequest(question: question, conversationID: id, selection: selection(for: thread),
                                 vaultPath: engine.activeVault?.path)
        thread.filter.apply(to: &request)
        thread.draft = ""
        thread.note = nil
        thread.inFlightID = id
        thread.stopRequested = false
        let started = Date()
        thread.pending = PendingQuestion(question: question, startedAt: started, request: request, status: .running)
        if thread === quick { quickUnseen = false }
        let token = UUID()
        thread.runToken = token
        thread.task = Task { [weak self] in
            let result: Result<AskResponse, Error>
            do {
                result = .success(isNew ? try await client.askNewChat(request) : try await client.ask(request))
            } catch {
                result = .failure(error)
            }
            self?.finish(token: token, conversationID: id, result: result)
        }
    }

    /// A run ended: it lands in whichever thread shows it now, else in History.
    private func finish(token: UUID, conversationID id: String, result: Result<AskResponse, Error>) {
        if let thread = [main, quick].first(where: { $0.runToken == token }) {
            guard !thread.stopRequested, let pending = thread.pending else { return }
            thread.runToken = nil
            thread.inFlightID = nil
            thread.task = nil
            switch result {
            case .success(let response):
                thread.conversationID = response.conversationID
                if let s = response.selection { thread.selection = s }
                var applied = pending.request
                applied.conversationID = response.conversationID
                thread.entries.append(AskEntry(question: pending.question, askedAt: pending.startedAt, request: applied,
                                               response: response, duration: Date().timeIntervalSince(pending.startedAt)))
                thread.pending = nil
                if thread === quick, !quickVisible { quickUnseen = true }
            case .failure(let error):
                thread.pending?.status = .failed(Self.message(for: error))
            }
            return
        }
        guard var run = background[id], run.token == token else { return }
        switch result {
        case .success:
            background[id] = nil
            refresh() // the core's conversation event usually arrives first; this covers a missed one
        case .failure(let error):
            run.pending.status = .failed(Self.message(for: error))
            background[id] = run
        }
    }

    /// Moves the thread's running question to the background without stopping it.
    private func detach(_ thread: AskThread) {
        guard thread.isRunning, let id = thread.inFlightID, let token = thread.runToken, let pending = thread.pending else { return }
        background[id] = BackgroundAsk(id: id, token: token, pending: pending, isNew: thread.conversationID == nil,
                                       task: thread.task, origin: thread === quick ? .quick : .main)
        thread.task = nil // reset() must not cancel it
        thread.runToken = nil
        thread.inFlightID = nil
        thread.pending = nil
    }

    /// New chats still answering in the background (not in History yet), newest first.
    var backgroundNew: [BackgroundAsk] {
        background.values.filter { run in run.isNew && !conversations.contains { $0.id == run.id } }
            .sorted { $0.pending.startedAt > $1.pending.startedAt }
    }

    /// Stops a question that is answering in the background (History's Stop).
    func stopBackground(_ id: String) {
        guard let run = background[id] else { return }
        run.task?.cancel()
        background[id] = nil
        if let client = engine.client { Task { try? await client.cancelAsk(conversationID: id) } }
    }

    /// Dismisses a failed background question.
    func dismissBackground(_ id: String) { background[id] = nil }

    /// Stop: cancels the request here (so the UI frees up even on a core
    /// without `cancelAsk`) and asks the core to stop the run.
    func stop(_ thread: AskThread) {
        guard thread.isRunning else { return }
        thread.stopRequested = true
        thread.task?.cancel()
        thread.task = nil
        thread.runToken = nil
        thread.pending?.status = .stopped
        if let id = thread.inFlightID, let client = engine.client {
            Task { try? await client.cancelAsk(conversationID: id) }
        }
        thread.inFlightID = nil
    }

    /// Sends the kept question again (Ask again / Retry).
    func retry(_ thread: AskThread) {
        guard let pending = thread.pending, pending.status != .running else { return }
        thread.pending = nil
        send(thread, question: pending.question)
    }

    /// New chat: leaves the current one (deleted when Keep history is off) and starts empty.
    /// A question still answering keeps going in the background and lands in History.
    func newChat(_ thread: AskThread) {
        leave(thread)
        detach(thread)
        thread.reset(filter: AskFilter(preferences: preferences))
    }

    /// The user left a chat (New chat, closed the Ask screen). With Keep history
    /// off the chat is deleted, unless it is pinned, still answering, or was
    /// handed to the Ask screen.
    func leave(_ thread: AskThread) {
        let pinned = conversations.first { $0.id == thread.conversationID }?.pinned ?? false
        guard let id = AskHistoryPolicy.conversationToDelete(
            leaving: thread.conversationID, keepHistory: preferences.resolvedKeepHistory, pinned: pinned,
            isRunning: thread.isRunning, handedOff: thread.handedOff),
              let client = engine.client else { return }
        // The other window may show the same chat.
        if (thread === main ? quick : main).conversationID == id { return }
        Task {
            try? await client.deleteConversation(id)
            conversations.removeAll { $0.id == id }
        }
        thread.reset(filter: AskFilter(preferences: preferences))
    }

    /// Opens a stored chat on the Ask screen.
    func open(conversationID id: String) {
        guard let client = engine.client else { return }
        if main.conversationID == id, main.isRunning { showAskRequest += 1; return }
        if quick.conversationID == id || quick.inFlightID == id, quick.isRunning { detach(quick); quick.reset(filter: AskFilter(preferences: preferences)) }
        if main.conversationID != id { leave(main) }
        detach(main)
        main.reset(filter: AskFilter(preferences: preferences))
        let run = background.removeValue(forKey: id)
        if let run {
            // Reattach: the answer keeps arriving here.
            main.pending = run.pending
            main.runToken = run.pending.status == .running ? run.token : nil
            main.inFlightID = run.pending.status == .running ? id : nil
            main.task = run.task
        }
        showAskRequest += 1
        if run?.isNew == true { return } // nothing saved yet: its first question is the one running
        main.conversationID = id
        Task {
            do {
                let conversation = try await client.conversation(id)
                guard main.conversationID == id else { return }
                main.entries = conversation.turns.map {
                    AskEntry(question: $0.request.question, askedAt: $0.askedAt, request: $0.request, response: $0.response)
                }
                if let last = conversation.turns.last {
                    main.filter = AskFilter(request: last.request, preferences: preferences)
                    main.selection = last.response.selection ?? last.request.selection
                }
                if conversation.turns.isEmpty { main.note = "This earlier chat has no saved turns. Follow-ups continue it." }
            } catch {
                main.note = "Couldn't load this chat: \(Self.message(for: error))"
            }
        }
    }

    /// "Continue in Distill": the quick chat becomes the Ask screen's chat; a run in flight keeps going.
    func continueInMain() {
        if main.conversationID != quick.conversationID || main.conversationID == nil { leave(main) }
        detach(main)
        main = quick
        quick = AskThread(filter: AskFilter(preferences: preferences))
        observeQuick()
        quickUnseen = false
        showAskRequest += 1
    }

    /// Opening the quick ask window: always a fresh chat (empty question, Settings
    /// defaults). Pass `alreadyOpen` when the window is showing (the shortcut fired
    /// again): the chat on screen stays.
    func prepareQuickAsk(alreadyOpen: Bool = false) {
        if !alreadyOpen && !quick.isEmpty { newChat(quick) }
        quickUnseen = false
    }

    /// × or Esc on quick ask (canvas: "Close, then open again"): a question still
    /// answering moves to the background without being stopped, so it finishes and
    /// lands in History; the quick chat starts over.
    func closeQuick() {
        quickVisible = false
        newChat(quick)
        quickUnseen = false
    }

    // MARK: History

    func setPinned(_ id: String, _ pinned: Bool) {
        guard let client = engine.client else { return }
        Task {
            do {
                let summary = try await client.setConversationPinned(id, pinned: pinned)
                apply(summary, deleted: false)
            } catch { engine.report(error) }
        }
    }

    func delete(_ id: String) {
        guard let client = engine.client else { return }
        Task {
            do {
                try await client.deleteConversation(id)
                conversations.removeAll { $0.id == id }
                for thread in [main, quick] where thread.conversationID == id && !thread.isRunning {
                    thread.reset(filter: AskFilter(preferences: preferences))
                }
            } catch { engine.report(error) }
        }
    }

    // MARK: Answer actions

    /// "Save answer to vault": a normal note (origin app) that goes through Review.
    func save(_ entry: AskEntry) {
        guard let client = engine.client else { return }
        var text = entry.response.answer
        if !entry.response.citations.isEmpty {
            text += "\n\n## Sources\n\n" + entry.response.citations.map { c in
                let page = (c.path as NSString).deletingPathExtension
                return "\(c.n). [[\(page)|\(c.title)]]"
            }.joined(separator: "\n")
        }
        let title = String(entry.question.prefix(80))
        Task {
            do {
                _ = try await client.addNote(AddNoteRequest(title: title, text: "Question: \(entry.question)\n\n\(text)",
                                                            vaultPath: engine.activeVault?.path, origin: .app))
                engine.lastError = nil
                savedEntries.insert(entry.id)
            } catch { engine.report(error) }
        }
    }

    @Published var savedEntries: Set<UUID> = []

    func copy(_ entry: AskEntry) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(entry.response.answer, forType: .string)
    }

    func openCitation(_ citation: AskCitation) {
        guard let vault = engine.activeVault?.path ?? conversations.first?.vaultPath,
              let url = ObsidianLink.url(vaultPath: vault, page: citation.path) else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(URL(fileURLWithPath: vault).appendingPathComponent(citation.path))
        }
    }

    static func message(for error: Error) -> String {
        if let e = error as? CoreClientError { return e.description }
        return error.localizedDescription
    }
}
