import AppKit
import Combine
import DistillKit
import Foundation

/// Where a note is being written.
enum ComposeOwner: Hashable { case compose, quick }

/// State for Write a note, the quick-note window, the Labels screen and the
/// v2 Settings sections. It lives beside `AppModel` (one per model) because
/// extensions cannot add stored properties; the core still owns everything.
@MainActor
final class NotesStore: ObservableObject {
    // Composer + quick note
    @Published var drafts: [ComposeOwner: ComposeDraft] = [:]
    @Published var steps: [ComposeOwner: LabelStep] = [:]
    @Published var adding: Set<ComposeOwner> = []
    @Published var addErrors: [ComposeOwner: String] = [:]
    /// labelSuggestions that arrived before addNote answered.
    var earlySuggestions: [String: (labels: [LabelSuggestion], error: String?)] = [:]

    // Labels screen
    @Published var review: LabelReview?
    @Published var labelCounts: [LabelCount] = []
    @Published var reviewLoading = false
    @Published var reviewError: String?
    /// Label edits per page path, until confirmed.
    @Published var edits: [String: [String]] = [:]
    @Published var deselected: Set<String> = []
    @Published var confirmJobID: String?
    @Published var suggestJobID: String?
    @Published var suggestTotal = 0
    @Published var suggestSelection: ModelSelection?

    // Settings
    @Published var runners: [RunnerInfo] = []
    @Published var runnersLoading = false
    /// Per runner: "Checking…" / "Saving…" while a call is out.
    @Published var runnerBusy: [String: String] = [:]
    @Published var historyMessage: String?
    @Published var clearingHistory = false

    /// Snapshot fixtures only (see LabelsProgress).
    var fixtureProgress: [String: LabelsProgress] = [:]
    fileprivate var cancellables: Set<AnyCancellable> = []
    fileprivate var installed = false

    fileprivate static var stores: [ObjectIdentifier: NotesStore] = [:]

    static func of(_ engine: AppModel) -> NotesStore {
        let key = ObjectIdentifier(engine)
        if let s = stores[key] { return s }
        let s = NotesStore()
        stores[key] = s
        return s
    }

    func draft(_ owner: ComposeOwner) -> ComposeDraft { drafts[owner] ?? AppModel.freshDraft() }
}

extension AppModel {
    var notes: NotesStore { NotesStore.of(self) }

    /// Pages whose AI labels are not confirmed (sidebar badge).
    var labelsToReviewCount: Int { notes.review?.toReview.count ?? 0 }

    /// App-local: suggest labels after Add to queue (there is no core setting;
    /// off sends `suggest: none`).
    static let suggestAfterQueueKey = "distill.suggestLabelsAfterQueue"
    var suggestLabelsAfterQueue: Bool {
        get { UserDefaults.standard.object(forKey: Self.suggestAfterQueueKey) as? Bool ?? true }
        set { UserDefaults.standard.set(newValue, forKey: Self.suggestAfterQueueKey); objectWillChange.send() }
    }

    // MARK: Install

    /// Quick note window, global shortcuts, and keeping the Labels count fresh.
    /// Called once at launch (AppDelegate).
    func installNotesFeatures() {
        let store = notes
        guard !store.installed else { return }
        store.installed = true
        QuickNoteController.shared.install(engine: self)
        GlobalShortcuts.shared.observe(self)

        // Reload the review when the core connects, the vault changes, or a
        // job finishes (batches add pages, labels jobs confirm or suggest).
        let jobsSignature = $jobs.map { jobs in jobs.map { "\($0.id):\($0.state.rawValue)" }.joined(separator: ",") }
            .removeDuplicates().map { _ in () }
        let connected = $connection.filter { $0 == .connected }.map { _ in () }
        let vault = $settings.map(\.activeVaultPath).removeDuplicates().map { _ in () }
        Publishers.Merge3(jobsSignature, connected, vault)
            .debounce(for: .milliseconds(600), scheduler: RunLoop.main)
            .sink { [weak self] in self?.refreshLabels() }
            .store(in: &store.cancellables)
    }

    // MARK: Events

    /// `labelSuggestions` event from the core (wired in `AppModel.apply`).
    func noteLabelSuggestions(requestID: String, notePath: String, labels: [LabelSuggestion], error: String?) {
        let store = notes
        var matched = false
        for (owner, var step) in store.steps where step.requestID == requestID {
            step.received(requestID: requestID, labels: labels, error: error)
            store.steps[owner] = step
            matched = true
        }
        if !matched { store.earlySuggestions[requestID] = (labels, error) }
    }

    // MARK: Write a note

    func updateDraft(_ owner: ComposeOwner, _ edit: (inout ComposeDraft) -> Void) {
        var d = notes.draft(owner)
        edit(&d)
        notes.drafts[owner] = d
    }

    func discardDraft(_ owner: ComposeOwner) {
        notes.draft(owner).cleanUpTemporaryImages()
        notes.drafts[owner] = nil
        notes.addErrors[owner] = nil
    }

    /// Queues the draft (`POST /v1/notes`, origin app, suggest background),
    /// then shows the label step.
    func addNote(_ owner: ComposeOwner) {
        let store = notes
        let draft = store.draft(owner)
        guard draft.blocker == nil, !store.adding.contains(owner) else { return }
        guard let client else { lastError = "The Distill core is not connected."; return }
        let suggest = suggestLabelsAfterQueue
        let request = draft.request(suggest: suggest, vaultPath: activeVault?.path)
        store.adding.insert(owner)
        store.addErrors[owner] = nil
        UserDefaults.standard.set(draft.source, forKey: "distill.lastSource")
        UserDefaults.standard.set(draft.group, forKey: "distill.lastSourceGroup")
        Task {
            defer { store.adding.remove(owner) }
            do {
                // The core has copied the images; the draft stays on screen
                // (read-only) under the label step and is cleared when it closes.
                let result = try await client.addNote(request)
                var step = LabelStep(requestID: result.requestID, title: request.title, suggesting: suggest)
                if let early = store.earlySuggestions.removeValue(forKey: result.requestID) {
                    step.received(requestID: result.requestID, labels: early.labels, error: early.error)
                } else if let labels = result.suggestedLabels {
                    step.received(requestID: result.requestID, labels: labels, error: result.suggestError)
                }
                store.steps[owner] = step
            } catch {
                store.addErrors[owner] = LabelStep.message(for: error)
            }
        }
    }

    /// An empty draft with the last source pre-filled.
    static func freshDraft() -> ComposeDraft {
        var d = ComposeDraft()
        d.source = UserDefaults.standard.string(forKey: "distill.lastSource")
        d.group = UserDefaults.standard.string(forKey: "distill.lastSourceGroup")
        return d
    }

    func editStep(_ owner: ComposeOwner, _ edit: (inout LabelStep) -> Void) {
        guard var step = notes.steps[owner] else { return }
        edit(&step)
        notes.steps[owner] = step
    }

    /// Apply: confirms the chosen labels (`labelNote`). Never sent on its own.
    func applyLabels(_ owner: ComposeOwner) {
        guard var step = notes.steps[owner], step.canApply else { return }
        guard let client else { lastError = "The Distill core is not connected."; return }
        step.applyStarted()
        notes.steps[owner] = step
        let labels = step.chosen, id = step.requestID
        Task {
            do {
                let result = try await client.labelNote(requestID: id, labels: labels)
                self.editStep(owner) { $0.applySucceeded(labels: result.labels) }
            } catch {
                self.editStep(owner) { $0.applyFailed(error) }
            }
        }
    }

    /// Skip / close: nothing is sent; the note stays unlabeled.
    func skipLabels(_ owner: ComposeOwner) {
        editStep(owner) { $0.skip() }
        closeLabelStep(owner)
    }

    /// Ends the label step and starts a fresh note (the queued one is done).
    func closeLabelStep(_ owner: ComposeOwner) {
        notes.steps[owner] = nil
        notes.draft(owner).cleanUpTemporaryImages()
        notes.drafts[owner] = Self.freshDraft()
        notes.addErrors[owner] = nil
    }

    // MARK: Labels screen

    func refreshLabels() {
        guard let client else { return }
        let store = notes
        let vault = activeVault?.path
        store.reviewLoading = store.review == nil
        Task {
            defer { store.reviewLoading = false }
            do {
                async let r = client.labelReview(vaultPath: vault)
                async let c = client.labels(vaultPath: vault)
                let (review, counts) = try await (r, c)
                store.review = review
                store.labelCounts = counts
                store.reviewError = nil
                // Edits for pages that left the list are dropped.
                let paths = Set(review.toReview.map(\.path) + review.unlabeled.map(\.path))
                store.edits = store.edits.filter { paths.contains($0.key) }
            } catch let e as CoreClientError where e.isNotAvailable {
                store.reviewError = "This Distill core has no Labels API yet."
            } catch {
                store.reviewError = LabelStep.message(for: error)
            }
        }
    }

    /// The labels a row will confirm (edits win over what the page has).
    func reviewLabels(path: String, original: [String]) -> [String] {
        notes.edits[path] ?? original
    }

    func editReviewLabels(path: String, original: [String], _ edit: (inout [String]) -> Void) {
        var labels = reviewLabels(path: path, original: original)
        edit(&labels)
        notes.edits[path] = LabelName.dedupe(labels)
    }

    /// Writes exactly these labels (`confirmLabels`); the job goes to Review.
    func confirmLabels(_ items: [LabeledPage]) {
        guard !items.isEmpty else { return }
        guard let client else { lastError = "The Distill core is not connected."; return }
        let store = notes
        let vault = activeVault?.path
        store.confirmJobID = "pending"
        Task {
            do {
                let job = try await client.confirmLabels(items, vaultPath: vault)
                store.confirmJobID = job.id // the core's `job` event adds it to engine.jobs
            } catch {
                store.confirmJobID = nil
                self.lastError = LabelStep.message(for: error)
            }
        }
    }

    /// AI labels for unlabeled pages (`suggestLabelsForPages`): a job that runs,
    /// then waits in Review.
    func suggestLabels(paths: [String], selection: ModelSelection?) {
        guard !paths.isEmpty else { return }
        guard let client else { lastError = "The Distill core is not connected."; return }
        let store = notes
        let vault = activeVault?.path
        store.suggestJobID = "pending"
        store.suggestTotal = paths.count
        Task {
            do {
                let job = try await client.suggestLabels(paths: paths, vaultPath: vault, selection: selection)
                store.suggestJobID = job.id
            } catch {
                store.suggestJobID = nil
                self.lastError = LabelStep.message(for: error)
            }
        }
    }

    func stopSuggesting() {
        guard let id = notes.suggestJobID, id != "pending" else { return }
        cancel(id)
    }

    // MARK: Runners

    func loadRunners() {
        guard let client else { return }
        let store = notes
        store.runnersLoading = store.runners.isEmpty
        Task {
            defer { store.runnersLoading = false }
            if let list = try? await client.runners() { store.runners = list }
        }
    }

    func setRunner(_ id: String, enabled: Bool) {
        SettingsEdits.setRunner(id, enabled: enabled, in: &settings)
        guard client != nil else { return }
        let store = notes
        store.runnerBusy[id] = enabled ? "Checking…" : nil
        Task {
            await flushSettings()
            if let list = try? await client?.runners() { store.runners = list }
            store.runnerBusy[id] = nil
        }
    }

    /// Stores (or with nil clears) a runner secret in the Keychain through the
    /// core. The value is never logged or kept here.
    func setRunnerSecret(runnerID: String, name: String, value: String?, done: @escaping (String?) -> Void) {
        guard let client else { done("The Distill core is not connected."); return }
        let store = notes
        store.runnerBusy[runnerID] = "Saving…"
        Task {
            defer { store.runnerBusy[runnerID] = nil }
            do {
                try await client.setRunnerSecret(runnerID: runnerID, name: name, value: value)
                if let list = try? await client.runners() { store.runners = list }
                done(nil)
            } catch {
                done(LabelStep.message(for: error))
            }
        }
    }

    // MARK: Ask history

    /// Clear now: deletes every chat that is not pinned.
    func clearAskHistory() {
        guard let client else { return }
        let store = notes
        store.clearingHistory = true
        store.historyMessage = nil
        Task {
            defer { store.clearingHistory = false }
            do {
                let chats = try await client.conversations().filter { !$0.pinned }
                for chat in chats { try await client.deleteConversation(chat.id) }
                store.historyMessage = chats.isEmpty ? "Nothing to clear." : "Deleted \(chats.count) \(chats.count == 1 ? "chat" : "chats")."
            } catch let e as CoreClientError where e.isNotAvailable {
                store.historyMessage = "This Distill core has no Ask history yet."
            } catch {
                store.historyMessage = LabelStep.message(for: error)
            }
        }
    }

    // MARK: Obsidian

    /// `obsidian://open?vault=<folder name>&file=<vault-relative path>`.
    nonisolated static func obsidianURL(vaultPath: String, page: String) -> URL? {
        var c = URLComponents()
        c.scheme = "obsidian"
        c.host = "open"
        c.queryItems = [URLQueryItem(name: "vault", value: URL(fileURLWithPath: vaultPath).lastPathComponent),
                        URLQueryItem(name: "file", value: page)]
        return c.url
    }

    func openInObsidian(_ page: String) {
        guard let vault = activeVault, let url = Self.obsidianURL(vaultPath: vault.path, page: page) else { return }
        if NSWorkspace.shared.urlForApplication(toOpen: url) != nil {
            NSWorkspace.shared.open(url)
        } else {
            NSWorkspace.shared.open(vault.url.appendingPathComponent(page))
        }
    }
}
