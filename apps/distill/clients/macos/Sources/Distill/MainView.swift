import AppKit
import SwiftUI
import DistillKit

enum Section: Hashable {
    case queue, collectors, review, actions, ask, labels, history
}

/// History’s sub-items in the sidebar (Jobs, Ask chats, Actions, Activity).
enum HistoryPart: Hashable { case jobs, chats, actions, activity }

struct MainView: View {
    @EnvironmentObject var engine: AppModel
    var openSettings: () -> Void
    @State private var section: Section = .queue
    @State private var selectedJob: String?
    @State private var historyPart: HistoryPart = .jobs

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section, selectedJob: $selectedJob, historyPart: $historyPart, openSettings: openSettings)
                .layoutPriority(1)
            Group {
                switch section {
                case .queue: QueueView()
                case .collectors: CollectorsScreen()
                case .review: ReviewSection(selectedJob: $selectedJob)
                case .actions: ActionsScreen()
                case .ask: AskScreen()
                case .labels: LabelsSection()
                case .history: HistorySection(selectedJob: $selectedJob, part: $historyPart, openAsk: { section = .ask })
                }
            }
            // minWidth 0 + clipped: a screen that asks for more width than the
            // window has is squeezed to fit instead of pushing the sidebar off.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Theme.window)
        }
        .paneContainer() // resizable panes: the sidebar keeps the screen's 580 pt
        .environmentObject(engine.ask)
        .overlay { if section == .collectors { CollectorsOverlay(store: engine.collectors) } }
        .overlay(alignment: .bottom) { ErrorBanner() }
        .overlay(alignment: .bottom) {
            if let toast = engine.queueToast, engine.lastError == nil {
                QueueToastView(toast: toast) { engine.queueToast = nil }
            }
        }
        .animation(.easeOut(duration: 0.2), value: engine.queueToast)
        .frame(minWidth: 900, minHeight: 600)
        .foregroundStyle(Theme.ink)
        .ignoresSafeArea()
        .onChange(of: engine.pendingApprovals.count) { old, new in
            // Jump to Review when something new needs the user.
            if new > old, section != .ask { section = .review; selectedJob = engine.pendingApprovals.first?.id }
        }
        .onReceive(engine.ask.$showAskRequest.dropFirst()) { _ in section = .ask }
        .onReceive(engine.actions.$showRequest.dropFirst()) { _ in section = .actions }
        .onReceive(engine.actions.$historyRequest.dropFirst()) { _ in section = .history; historyPart = .actions }
        .onReceive(engine.activity.$navigate.compactMap { $0 }) { nav in
            // A link in an Activity detail: Open collector / Open run log, Open in History.
            engine.activity.navigate = nil
            switch nav {
            case .collector(let id, let runs):
                section = .collectors
                engine.collectors.select(id)
                if runs { engine.collectors.page = .allRuns }
            case .job(let id):
                historyPart = .jobs
                selectedJob = id
            }
        }
        .onChange(of: section) { old, _ in
            // Keep history off: leaving the Ask screen deletes its finished chat.
            if old == .ask { engine.ask.leave(engine.ask.main) }
        }
    }
}

// MARK: Sidebar

struct Sidebar: View {
    @EnvironmentObject var engine: AppModel
    @Binding var section: Section
    @Binding var selectedJob: String?
    var historyPart: Binding<HistoryPart> = .constant(.jobs)
    var openSettings: () -> Void
    /// The peach count on Collectors (collectors that failed or wait for your OK); nil = the store's count.
    var collectorsAlert: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Color.clear.frame(height: 26) // traffic lights sit here
            HStack(spacing: 9) {
                FlaskView(level: 0.45, bubbles: true, lineWidth: 1.8).frame(width: 24, height: 26)
                Text("distill").font(Theme.display(20))
            }
            .padding(.horizontal, 6)

            VStack(spacing: 2) {
                navItem(.queue, "Queue", "tray", count: QueueRows.count(engine.queued) + engine.heldCount, highlight: false)
                SidebarCollectors(store: engine.collectors, section: $section, alert: collectorsAlert)
                navItem(.review, "Review", "checkmark.square", count: engine.pendingApprovals.count, highlight: true)
                SidebarActions(section: $section)
                navItem(.ask, "Ask", "questionmark.bubble", count: 0, highlight: false)
                navItem(.labels, "Labels", "tag", count: engine.labelsToReviewCount, highlight: false)
                navItem(.history, "History", "clock", count: 0, highlight: false, open: section == .history)
                if section == .history {
                    ForEach([(HistoryPart.jobs, "Jobs"), (.chats, "Ask chats"), (.actions, "Actions"), (.activity, "Activity")], id: \.0) { part, title in
                        SidebarSubItem(title: title, count: 0, selected: historyPart.wrappedValue == part) { historyPart.wrappedValue = part }
                    }
                }
            }

            if section == .ask { RecentQuestions(ask: engine.ask) }

            Spacer()
            VaultSwitcher(openSettings: openSettings)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .paneWidth(.sidebar, automatic: 220)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    private func navItem(_ s: Section, _ title: String, _ icon: String, count: Int, highlight: Bool, open: Bool = false) -> some View {
        let active = section == s
        return Button {
            section = s
            if s == .review { selectedJob = engine.pendingApprovals.first?.id }
        } label: {
            HStack(spacing: 10) {
                Image(systemName: icon)
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? Theme.primary : Theme.muted)
                    .frame(width: 18)
                Text(title).font(Theme.body(14, active ? .semibold : .regular))
                Spacer()
                if count > 0 {
                    if highlight {
                        Pill(text: "\(count)", fill: Theme.peachTint, ink: Theme.peachInk)
                    } else {
                        Text("\(count)").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            .padding(.horizontal, 12).frame(height: 36)
            // An open parent with sub-items is not a card: its selected sub-item is.
            .background(RoundedRectangle(cornerRadius: 10).fill(active && !open ? Color.white : .clear)
                .shadow(color: .black.opacity(active && !open ? 0.07 : 0), radius: 2, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Actions in the sidebar (canvas: SidebarStates): the parent with the total
/// while closed; open, a sub-item per enabled type with its own count.
struct SidebarActions: View {
    @EnvironmentObject var engine: AppModel
    @Binding var section: Section

    var body: some View {
        SidebarActionsContent(store: engine.actions, section: $section)
    }
}

private struct SidebarActionsContent: View {
    @ObservedObject var store: ActionsStore
    @Binding var section: Section

    var body: some View {
        let open = section == .actions
        let counts = store.counts
        Button { section = .actions } label: {
            HStack(spacing: 10) {
                Image(systemName: "checklist")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(open ? Theme.primary : Theme.muted)
                    .frame(width: 18)
                Text("Actions").font(Theme.body(14, open ? .semibold : .regular))
                Spacer()
                let total = counts.values.reduce(0, +)
                if !open && total > 0 { Pill(text: "\(total)", fill: Theme.primaryTint, ink: Theme.primary) }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        if open {
            ForEach(store.listTypes) { t in
                SidebarSubItem(title: t.id == "todo" ? "To do" : t.pluralLabel, count: counts[t.id] ?? 0, selected: store.tab == t.id) {
                    store.tab = t.id
                }
            }
        }
    }
}

/// Collectors in the sidebar, under Queue: a peach count only when collectors
/// need the user (the last run failed, or a script waits for consent).
private struct SidebarCollectors: View {
    @ObservedObject var store: CollectorsStore
    @Binding var section: Section
    var alert: String?

    var body: some View {
        let active = section == .collectors
        let count = alert ?? (store.alertCount > 0 ? "\(store.alertCount)" : "")
        Button { section = .collectors } label: {
            HStack(spacing: 10) {
                Image(systemName: "tray.and.arrow.down")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(active ? Theme.primary : Theme.muted)
                    .frame(width: 18)
                Text("Collectors").font(Theme.body(14, active ? .semibold : .regular))
                Spacer()
                if !count.isEmpty { Pill(text: count, fill: Theme.peachTint, ink: Theme.peachInk) }
            }
            .padding(.horizontal, 12).frame(height: 36)
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.white : .clear)
                .shadow(color: .black.opacity(active ? 0.07 : 0), radius: 2, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// A sub-item under an open sidebar parent.
struct SidebarSubItem: View {
    let title: String
    let count: Int
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Text(title).font(Theme.body(12.5, selected ? .semibold : .medium)).foregroundStyle(selected ? Theme.ink : Theme.softInk)
                    .lineLimit(1)
                Spacer(minLength: 0)
                if count > 0 {
                    Text("\(count)").font(Theme.body(11, .semibold)).foregroundStyle(selected ? Theme.primary : Theme.faint)
                }
            }
            .padding(.horizontal, 10).frame(height: 28)
            .background(RoundedRectangle(cornerRadius: 8).fill(selected ? Color.white : .clear)
                .shadow(color: .black.opacity(selected ? 0.07 : 0), radius: 2, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.leading, 30)
    }
}

/// "Recent questions" under the nav while Ask is open (canvas: "Ask").
struct RecentQuestions: View {
    @ObservedObject var ask: AskModel

    var body: some View {
        let recent = ask.conversations.prefix(max(0, 5 - ask.backgroundNew.count))
        if !recent.isEmpty || !ask.backgroundNew.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT QUESTIONS").font(Theme.body(11, .bold)).foregroundStyle(Theme.faint).kerning(0.6)
                    .padding(.horizontal, 12).padding(.bottom, 4)
                ForEach(ask.backgroundNew.prefix(5)) { run in
                    Button { ask.open(conversationID: run.id) } label: {
                        HStack(spacing: 6) {
                            Text(run.pending.question).font(Theme.body(13)).foregroundStyle(Theme.softInk)
                                .lineLimit(1).truncationMode(.tail)
                            Spacer(minLength: 0)
                            if run.pending.status == .running { Spinner(size: 10) }
                        }
                        .padding(.horizontal, 12).padding(.vertical, 6)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                    .help(run.pending.status == .running ? "Still answering — open it" : "Couldn't answer — open it")
                }
                ForEach(Array(recent)) { c in
                    Button { ask.open(conversationID: c.id) } label: {
                        Text(c.title).font(Theme.body(13)).foregroundStyle(c.id == ask.main.conversationID ? Theme.primary : Theme.softInk)
                            .lineLimit(1).truncationMode(.tail)
                            .padding(.horizontal, 12).padding(.vertical, 6)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct VaultSwitcher: View {
    @EnvironmentObject var engine: AppModel
    var openSettings: () -> Void

    var body: some View {
        Menu {
            ForEach(engine.settings.vaults) { vault in
                Button {
                    engine.settings.activeVaultPath = vault.path
                } label: {
                    if vault.path == engine.activeVault?.path { Label(vault.name, systemImage: "checkmark") } else { Text(vault.name) }
                }
            }
            Divider()
            Button("Add Vault…") { VaultPicker.addVault(engine: engine) }
            Button("Settings…", action: openSettings)
        } label: {
            HStack(spacing: 10) {
                let chip = VaultChip.colors(for: engine.activeVault)
                Tile(text: engine.activeVault.map { String($0.name.prefix(1)).uppercased() } ?? "?",
                     fill: chip.0, ink: chip.1, size: 30, display: true)
                VStack(alignment: .leading, spacing: 1) {
                    Text(engine.activeVault?.name ?? "Choose a vault").font(Theme.body(13, .semibold)).lineLimit(1)
                    if let statusLine {
                        Text(statusLine).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(8)
            .card(12)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
    }

    /// nil with no vault: the name line already says "Choose a vault".
    private var statusLine: String? {
        if engine.activeVault == nil { return nil }
        if engine.isStarting { return "Starting…" }
        let model = ModelChoice.shortName(engine.settings.model)
        if !engine.runningJobs.isEmpty { return "\(model) · working" }
        if !engine.pendingApprovals.isEmpty { return "\(model) · waiting on you" }
        return engine.problems.isEmpty ? "\(model) · ready" : "Needs setup"
    }
}

enum VaultChip {
    static func colors(for vault: VaultProfile?, in vaults: [VaultProfile] = []) -> (Color, Color) {
        guard let vault else { return (Theme.panel, Theme.muted) }
        // Stable across launches (String.hashValue is seeded per process).
        let index = vault.path.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF } % Theme.vaultChips.count
        return Theme.vaultChips[index]
    }
}

// MARK: Queue

struct QueueView: View {
    @EnvironmentObject var engine: AppModel
    @Environment(\.snapshotMode) private var snapshot
    @State private var targeted: Bool
    @AppStorage("distill.addMode") private var addMode: AddMode = .files
    /// A folder row's × asks first: the whole folder goes to the Trash.
    @State private var confirmRemoval: QueueEntry?
    /// Snapshots: folder rows whose tree starts open.
    private let expandedPaths: Set<String>
    /// v7: the running batch's steps, open in place of the queue (‹ Queue).
    @State private var stepsJob: String?
    private let stepsOptions: StepsSnapshot

    /// `targeted` starts true only in snapshots (the drop hover state).
    init(targeted: Bool = false, expandedPaths: Set<String> = [], stepsJob: String? = nil, stepsOptions: StepsSnapshot = StepsSnapshot()) {
        _targeted = State(initialValue: targeted)
        self.expandedPaths = expandedPaths
        _stepsJob = State(initialValue: stepsJob)
        self.stepsOptions = stepsOptions
    }

    var body: some View {
        if addMode == .note {
            ComposeScreen(mode: $addMode) // Write a note (ComposeView.swift)
        } else if let id = stepsJob, let job = engine.job(id) {
            JobStepsView(store: engine.jobSteps, job: job, back: "Queue", title: stepsTitle(job), startDetails: stepsOptions.details,
                         startFollowing: stepsOptions.following, startExpanded: stepsOptions.expanded) { stepsJob = nil }
                .padding(.horizontal, 44).padding(.top, 30)
        } else {
            Scrolling {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if let batch = engine.runningBatch { BatchBanner(job: batch, onShowSteps: { stepsJob = batch.id }) }
                    dropPanel
                    if engine.isStarting { StartingPlaceholder() } else { fileList }
                    // v10: sources that couldn't be read in full stay in inbox/ until Try again reads them.
                    HeldSection(store: engine.heldSources)
                }
                .padding(.horizontal, 44).padding(.top, 44).padding(.bottom, 30)
            }
            .onAppear { engine.heldSources.load() }
            .onChange(of: engine.heldCount) { engine.heldSources.load() }
            .confirmationDialog(removalTitle, isPresented: Binding(get: { confirmRemoval != nil }, set: { if !$0 { confirmRemoval = nil } }),
                                titleVisibility: .visible, presenting: confirmRemoval) { entry in
                Button("Move to Trash", role: .destructive) { engine.removeFromQueue(entry); confirmRemoval = nil }
                Button("Cancel", role: .cancel) { confirmRemoval = nil }
            } message: { entry in
                Text("The whole folder (\(QueueRows.count(entry.fileCount ?? 0, "file"))) leaves the queue. You can put it back from the Trash.")
            }
        }
    }

    private func stepsTitle(_ job: Job) -> String {
        let n = job.files.count
        return "Batch · \(n == 1 ? "1 file" : "\(n) files")"
    }

    private var removalTitle: String {
        confirmRemoval.map { "Move “\($0.name)” to the Trash?" } ?? ""
    }

    /// Title, schedule, the add-mode switch and Process now. When the row is too
    /// narrow (a 900 pt window, a long "3 in this batch · 2 waiting"), the
    /// switch and the button move under the title instead of squeezing it.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top, spacing: 16) {
                    titleBlock.fixedSize(horizontal: true, vertical: false)
                    Spacer(minLength: 0)
                    headerControls
                }
                queuePath
            }
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 6) {
                    titleBlock
                    queuePath
                }
                HStack(spacing: 12) { headerControls }
            }
        }
    }

    /// The active vault's queue folder under the schedule line (QueuePath): `~`, Copy path, Reveal in
    /// Finder, then Refresh (QueueRefresh). When the line is too narrow, Refresh moves under the path.
    @ViewBuilder private var queuePath: some View {
        if !engine.isStarting, let vault = engine.activeVault {
            let path = QueuePath(path: vault.queueDirectory, onCreate: {
                try? FileManager.default.createDirectory(atPath: vault.queueDirectory, withIntermediateDirectories: true)
                engine.objectWillChange.send()
            })
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 8) { path.fixedSize(); refresh }
                VStack(alignment: .leading, spacing: 2) { path; refresh }
            }
            .padding(.top, -2)
        }
    }

    private var refresh: some View {
        QueueRefresh(state: engine.refreshState, checked: QueueRefreshState.checked(engine.queueCheckedAt),
                     onRefresh: { engine.refreshQueueNow() })
    }

    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            if engine.isStarting {
                Shimmer(width: 320, height: 30, radius: 10).padding(.vertical, 4)
                Shimmer(width: 220, height: 12)
            } else {
                Text(title).font(Theme.display(32)).lineLimit(2)
                scheduleLine.font(Theme.body(15)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        }
    }

    @ViewBuilder private var headerControls: some View {
        AddModeSwitch(mode: $addMode)
        if engine.isProcessing {
            ProcessingButton().fixedSize()
        } else {
            PrimaryButton(title: "Process now", systemImage: "play.fill") { engine.processNowTracked() }
                .fixedSize()
                .disabled(rows.isEmpty || engine.isStarting)
                .opacity(rows.isEmpty || engine.isStarting ? 0.5 : 1)
        }
    }

    /// Queue rows to show (a note's .distill.json sidecar is hidden).
    private var rows: [QueueEntry] { QueueRows.visible(engine.queued) }

    private var title: String {
        if let batch = engine.runningBatch {
            let inBatch = batch.sources.count // a folder counts once
            return FullReadWords.queueTitle(inBatch: inBatch, waiting: rows.count, of: batch.batchOf)
        }
        switch rows.count {
        case 0: return "All caught up"
        case 1: return "1 item in the queue"
        default: return "\(rows.count) items in the queue"
        }
    }

    @ViewBuilder private var scheduleLine: some View {
        if let held = QueueLabelText.held(engine.heldForLabelsCount) {
            scheduleBase + Text(" · \(held)")
        } else {
            scheduleBase
        }
    }

    private var scheduleBase: Text {
        if engine.runningBatch != nil {
            return Text("New drops wait for the next batch")
        } else if let holder = engine.jobs.first(where: { $0.vaultPath == engine.activeVault?.path && $0.state.holdsVault }) {
            return Text(holder.state == .running
                 ? "Next batch starts after Claude finishes \(holder.displayTitle)"
                 : "Next batch waits until you review \(holder.displayTitle)")
        } else if let blocker = engine.batchBlocker {
            return Text(blocker)
        } else if !engine.settings.autoProcessEnabled {
            return Text("Automatic batching is off")
        } else if let next = engine.nextBatchAt {
            // A clock time: it changes only when the schedule does.
            let when = QueueRows.at(next) // "at 5:30 AM", or "Oct 3 at 5:30 AM" on another day
            let lead = when.hasPrefix("at ") ? "at " : ""
            let every = BatchInterval(totalMinutes: engine.settings.batchIntervalMinutes).phrase
            return Text("Next batch \(lead)\(Text(String(when.dropFirst(lead.count))).fontWeight(.semibold).foregroundColor(Theme.ink)) · every \(every)")
        }
        return Text("")
    }

    private var dropPanel: some View {
        HStack(spacing: 30) {
            FlaskView(level: min(1, Double(rows.count) / 6 + (engine.queued.isEmpty ? 0.08 : 0.25)),
                      bubbles: !engine.queued.isEmpty, lineWidth: 2.6)
                .frame(width: 96, height: 106)
            VStack(alignment: .leading, spacing: 8) {
                Text(targeted ? "Let go to add it" : "Drop anything here").font(.system(size: 22, weight: .semibold, design: .rounded))
                Text("Files, PDFs and screenshots. Paste with ⌘V. They wait here and go into your vault together.")
                    .font(Theme.body(14)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            SoftButton(title: "Choose files", fill: .white) { chooseFiles() }
                .overlay(Capsule().strokeBorder(Theme.border))
        }
        .padding(.horizontal, 34).padding(.vertical, 28)
        .background(RoundedRectangle(cornerRadius: 24).fill(targeted ? Theme.primaryTint : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 24).strokeBorder(Theme.primary, style: StrokeStyle(lineWidth: 2, dash: [8, 6])).opacity(targeted ? 1 : 0))
        .overlay { if !snapshot { DropZone(isTargeted: $targeted) } }
        .animation(.easeOut(duration: 0.15), value: targeted)
    }

    private var fileList: some View {
        VStack(spacing: 4) {
            if let batch = engine.runningBatch {
                ForEach(batch.sources, id: \.self) { source in
                    let entry = MainQueueEntries.entry(source, vaultPath: batch.vaultPath)
                    QueueRowView(title: QueueRows.title(entry), meta: QueueRows.meta(entry, inBatch: true), tileName: entry.name,
                                 status: .inBatch, help: QueueRows.pillHelp(.inBatch, settleSeconds: engine.settings.settleSeconds),
                                 noteTile: entry.kind == .note && entry.name.hasSuffix(".md"),
                                 kind: entry.kind, tree: QueueTree.lines(entry.tree ?? [], truncated: entry.treeTruncated),
                                 onReveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) })
                }
            }
            ForEach(rows) { entry in
                let running = engine.runningBatch != nil
                let status = QueueRows.status(entry, batchRunning: running)
                let labelState = LabelLineState(queue: entry.labels) ?? .none
                QueueRowView(title: QueueRows.title(entry), meta: QueueRows.meta(entry, batchRunning: running), tileName: entry.name, status: status,
                             help: status == .labeling && labelState == .failed ? (entry.labels?.error ?? QueueLabelText.heldHelp)
                                : QueueRows.pillHelp(status, settleSeconds: engine.settings.settleSeconds),
                             noteTile: entry.kind == .note && entry.name.hasSuffix(".md"),
                             kind: entry.kind, expanded: expandedPaths.contains(entry.path),
                             tree: QueueTree.lines(entry.tree ?? [], truncated: entry.treeTruncated),
                             hint: QueueRows.hint(entry, batchRunning: running),
                             flash: engine.flashingPaths.contains(entry.path),
                             labels: entry.labels?.labels ?? [], labelState: labelState,
                             labelNote: QueueLabelText.note(entry.labels), allowSkip: entry.labels?.allowsSkip ?? false,
                             onLabels: { engine.labelQueueItem(entry.path, labels: $0) },
                             onRetryLabels: { engine.retryQueueLabels(entry.path) },
                             onSkipLabels: { engine.skipQueueLabels(entry.path) },
                             onRemove: { if entry.kind == .folder { confirmRemoval = entry } else { engine.removeFromQueue(entry) } },
                             onReveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) },
                             onOpenLink: QueueRows.googleDocURL(entry).map { url in { NSWorkspace.shared.open(url) } })
                    .id(entry.path)
            }
            if rows.isEmpty && engine.runningBatch == nil && engine.heldSources.held.isEmpty {
                Text("Nothing waiting. New files will show up here.")
                    .font(Theme.body(13)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
        }
    }

    /// A source a running batch took (`inbox/...` in the vault), described like a queue entry: a folder
    /// is read from the vault (counts and tree), a file as before.
    static func batchEntry(_ source: BatchSource, vaultPath: String) -> QueueEntry {
        switch source {
        case .file(let file): return batchEntry(file, vaultPath: vaultPath)
        case .folder(let path, let files):
            let url = URL(fileURLWithPath: vaultPath).appendingPathComponent(path)
            return QueueFolderWalk.entry(at: url)
                ?? QueueEntry(path: url.path, modified: Date(), size: 0, settled: true, kind: .folder, fileCount: files.count)
        }
    }

    /// A file a running batch took (`inbox/...` in the vault), described like a queue entry.
    static func batchEntry(_ file: String, vaultPath: String) -> QueueEntry {
        let url = URL(fileURLWithPath: vaultPath).appendingPathComponent(file)
        let values = try? url.resourceValues(forKeys: [.contentModificationDateKey, .fileSizeKey])
        let stem = url.deletingPathExtension().lastPathComponent
        let manifest = url.deletingLastPathComponent().appendingPathComponent(stem + QueueRows.manifestSuffix)
        let isNote = url.pathExtension == "md" && FileManager.default.fileExists(atPath: manifest.path)
        return QueueEntry(path: url.path, modified: values?.contentModificationDate ?? Date(), size: values?.fileSize ?? 0,
                          settled: true, kind: isNote ? .note : .file)
    }

    private func chooseFiles() {
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK { engine.enqueue(files: panel.urls) }
    }
}

// MARK: Review & history

struct ReviewSection: View {
    @EnvironmentObject var engine: AppModel
    @Binding var selectedJob: String?

    var body: some View {
        // Oldest first: the oldest batch was built against the oldest vault and should go in first.
        let pending = engine.reviewJobs
        if pending.isEmpty {
            EmptyState(title: "Nothing to review", message: "When Claude finishes a batch, it will wait here for your OK.")
        } else {
            let id = pending.contains { $0.id == selectedJob } ? selectedJob! : pending[0].id
            VStack(spacing: 0) {
                if pending.count > 1 { JobTabs(jobs: pending, selected: id) { selectedJob = $0 } }
                JobDetailView(jobID: id)
            }
        }
    }
}

struct HistorySection: View {
    @EnvironmentObject var engine: AppModel
    @Binding var selectedJob: String?
    var openAsk: () -> Void = {}
    /// Picked in the sidebar (History's sub-items).
    @Binding var part: HistoryPart

    init(selectedJob: Binding<String?>, part: Binding<HistoryPart>, openAsk: @escaping () -> Void = {}) {
        _selectedJob = selectedJob
        _part = part
        self.openAsk = openAsk
    }

    /// Snapshots: a fixed part.
    init(selectedJob: Binding<String?>, openAsk: @escaping () -> Void = {}, part: HistoryPart = .jobs) {
        self.init(selectedJob: selectedJob, part: .constant(part), openAsk: openAsk)
    }

    var body: some View {
        if part == .actions {
            ActionsHistoryView()
        } else if part == .activity {
            ActivityScreen()
        } else {
            jobsAndChats
        }
    }

    private var jobsAndChats: some View {
        let jobs = engine.jobs.filter { $0.state != .awaitingApproval }
        return HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text(part == .jobs ? "Jobs" : "Ask chats").font(Theme.display(24))
                    Spacer()
                    if part == .jobs && engine.hasFinishedJobs {
                        Button("Clear") { engine.clearFinishedJobs() }
                            .buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                            .help("Remove finished jobs from this list (the vault keeps every change)")
                    }
                }
                Scrolling {
                    VStack(alignment: .leading, spacing: 4) {
                        switch part {
                        case .jobs:
                            if engine.isStarting {
                                ForEach(0..<4, id: \.self) { _ in Shimmer(height: 44, radius: 12).padding(.vertical, 2) }
                            }
                            ForEach(jobs) { job in
                                Button { selectedJob = job.id } label: {
                                    JobRow(job: job, selected: job.id == selectedJob)
                                }
                                .buttonStyle(.plain)
                            }
                            if jobs.isEmpty && !engine.isStarting {
                                Text("No jobs yet.").font(Theme.body(13)).foregroundStyle(Theme.faint).padding(.top, 8)
                            }
                        case .chats, .actions, .activity:
                            AskChatList(ask: engine.ask, openAsk: openAsk)
                        }
                    }
                }
            }
            .padding(.vertical, 24).padding(.horizontal, 18)
            .paneWidth(.historyList, automatic: 320)
            .background(Theme.window)
            Divider().overlay(Theme.border)
            if part == .jobs, let id = selectedJob, jobs.contains(where: { $0.id == id }) {
                JobDetailView(jobID: id, collapsesConversation: false)
            } else if part == .chats {
                EmptyState(title: "Ask chats", message: engine.settings.resolvedAskPreferences.resolvedKeepHistory
                           ? "Chats are kept \(engine.settings.resolvedAskPreferences.resolvedHistoryDays) days after their last message. Pinned chats stay."
                           : "Keep history is off: a chat is deleted when you start a new one or leave Ask. Pinned chats stay.")
            } else {
                EmptyState(title: "Pick a job", message: "Select a job to see what Claude did.")
            }
        }
        .paneContainer()
    }
}

/// Ask conversations in History: open in Ask, pin, delete.
struct AskChatList: View {
    @ObservedObject var ask: AskModel
    var openAsk: () -> Void

    var body: some View {
        if ask.conversations.isEmpty && ask.backgroundNew.isEmpty {
            Text("No Ask chats yet.").font(Theme.body(13)).foregroundStyle(Theme.faint).padding(.top, 8)
        }
        // A new chat still answering after you moved on: it is saved here when the answer lands.
        ForEach(ask.backgroundNew) { run in
            HStack(alignment: .top, spacing: 10) {
                Group {
                    if case .failed = run.pending.status {
                        Image(systemName: "exclamationmark").font(.system(size: 11, weight: .bold)).foregroundStyle(Theme.peachInk)
                    } else {
                        Spinner(size: 12)
                    }
                }
                .frame(width: 24, height: 24).background(Circle().fill(Theme.primaryTint))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(run.pending.question).font(Theme.body(13, .semibold))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        if case .failed = run.pending.status {
                            IconButton(systemImage: "xmark", size: 14, tint: Theme.faint, iconSize: 10, weight: .regular,
                                       help: "Dismiss") { ask.dismissBackground(run.id) }
                        } else {
                            IconButton(systemImage: "stop.fill", size: 14, tint: Theme.faint, iconSize: 10, weight: .regular,
                                       help: "Stop this question") { ask.stopBackground(run.id) }
                        }
                    }
                    Text(BackgroundAskText.meta(run))
                        .font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                ask.open(conversationID: run.id)
                openAsk()
            }
            .help("Open in Ask")
            .accessibilityAddTraits(.isButton)
            .padding(.horizontal, 12).padding(.vertical, 9)
        }
        ForEach(ask.conversations) { c in
            // Pin and delete sit beside the title so the meta line gets the full width.
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bubble.left.fill").font(.system(size: 11)).foregroundStyle(Theme.primary)
                    .frame(width: 24, height: 24).background(Circle().fill(Theme.primaryTint))
                VStack(alignment: .leading, spacing: 2) {
                    HStack(alignment: .firstTextBaseline, spacing: 10) {
                        Text(c.title.isEmpty ? "Untitled chat" : c.title).font(Theme.body(13, .semibold))
                            .lineLimit(2).fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        IconButton(systemImage: c.pinned ? "pin.fill" : "pin", size: 13, tint: c.pinned ? Theme.primary : Theme.faint,
                                   iconSize: 11, weight: .regular,
                                   help: c.pinned ? "Unpin (it can then expire)" : "Pin (kept until you delete it)") { ask.setPinned(c.id, !c.pinned) }
                        IconButton(systemImage: "trash", size: 13, tint: Theme.faint, iconSize: 11, weight: .regular,
                                   help: "Delete this chat") { ask.delete(c.id) }
                    }
                    Text("\(c.turnCount == 1 ? "1 question" : "\(c.turnCount) questions") · \(HistoryTime.asked(c.updatedAt))\(ask.background[c.id]?.pending.status == .running ? " · answering…" : "")")
                        .font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                ask.open(conversationID: c.id)
                openAsk()
            }
            .help("Open in Ask")
            .accessibilityAddTraits(.isButton)
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(c.id == ask.main.conversationID ? Theme.panel : .clear))
        }
    }
}

struct JobTabs: View {
    let jobs: [Job]
    let selected: String
    let pick: (String) -> Void

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 8) {
                ForEach(jobs) { job in // already in Review's order (waiting first, then approved)
                    let on = job.id == selected
                    Button { pick(job.id) } label: {
                        HStack(spacing: 6) {
                            Text(job.displayTitle).font(Theme.body(12, .semibold)).lineLimit(1)
                            Text(ReviewBatches.tabSubtitle(job)).font(Theme.body(11)).opacity(0.7).lineLimit(1)
                        }
                        .padding(.horizontal, 12).frame(height: 28)
                        .background(Capsule().fill(on ? Theme.ink : Theme.panel))
                        .foregroundStyle(on ? Color.white : Theme.ink)
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 44).padding(.top, 28)
        }
    }
}

struct JobRow: View {
    let job: Job
    var selected = false

    var body: some View {
        HStack(spacing: 12) {
            Circle().fill(StateStyle.of(job.state).dot).frame(width: 9, height: 9)
            VStack(alignment: .leading, spacing: 2) {
                Text(job.displayTitle).font(Theme.body(13, .semibold)).lineLimit(1)
                Text("\(StateStyle.of(job.state).label) · \(job.historyTime)")
                    .font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.panel : .clear))
        .contentShape(Rectangle())
    }
}

struct StateStyle {
    let label: String
    let fill: Color
    let ink: Color
    let dot: Color

    static func of(_ state: JobState) -> StateStyle {
        switch state {
        case .running: return .init(label: "Working", fill: Theme.primaryTint, ink: Theme.primary, dot: Theme.primary)
        case .awaitingApproval: return .init(label: "Ready for your OK", fill: Theme.peachTint, ink: Theme.peachInk, dot: Theme.peach)
        case .completed: return .init(label: "Applied", fill: Theme.limeTint, ink: Theme.limeInk, dot: Theme.lime)
        case .failed: return .init(label: "Didn't finish", fill: Theme.peachTint, ink: Theme.peachInk, dot: Theme.peachInk)
        case .rejected: return .init(label: "Rejected", fill: Theme.panel, ink: Theme.muted, dot: Theme.faint)
        case .cancelled: return .init(label: "Cancelled", fill: Theme.panel, ink: Theme.muted, dot: Theme.faint)
        }
    }
}

extension Job {
    /// "Started today at 3:04 AM" while open, "Finished …" / "Ended …" after.
    var historyTime: String {
        switch state {
        case .running, .awaitingApproval: return "Started \(HistoryTime.phrase(createdAt))"
        case .completed: return "Finished \(HistoryTime.phrase(updatedAt))"
        case .failed, .rejected, .cancelled: return "Ended \(HistoryTime.phrase(updatedAt))"
        }
    }

    /// "Tea brewing session"-style title from the first source (a folder counts once).
    var displayTitle: String {
        let sources = self.sources
        guard let first = sources.first else {
            guard let file = files.first else { return kind.prefix(1).uppercased() + kind.dropFirst() }
            return Self.pretty((file as NSString).lastPathComponent)
        }
        let name: String
        if case .folder = first { name = first.name } else { name = (first.name as NSString).deletingPathExtension }
        let pretty = Self.pretty(name)
        return sources.count > 1 ? "\(pretty) +\(sources.count - 1)" : pretty
    }

    private static func pretty(_ name: String) -> String {
        let base = name.replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        return base.prefix(1).uppercased() + base.dropFirst()
    }
}

struct EmptyState: View {
    let title: String
    let message: String

    var body: some View {
        VStack(spacing: 14) {
            FlaskView(level: 0.1, lineWidth: 2.2).frame(width: 60, height: 66).opacity(0.8)
            Text(title).font(.system(size: 20, weight: .semibold, design: .rounded))
            Text(message).font(Theme.body(14)).foregroundStyle(Theme.muted).multilineTextAlignment(.center)
        }
        .frame(maxWidth: 360)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: Job detail

struct JobDetailView: View {
    @EnvironmentObject var engine: AppModel
    let jobID: String
    @State private var reply: String
    @State private var allowed: Set<String>
    /// Snapshots: source folders that start open.
    var openFolders: Set<String> = []
    /// Snapshots: a source row drawn hovered.
    var hoverPage: String? = nil
    /// Sources not picked (all are picked at first), for this job.
    @State private var unpicked: Set<String>
    /// The source whose labels are being edited, and the chips so far.
    @State private var editingPage: String?
    @State private var editDraft: [String]
    /// The core refused a label edit (409): its message; nothing changed.
    @State private var labelError: String?
    @State private var groupOverrides: [String: Bool]
    @State private var menuOpen: Bool
    @State private var showConversation = false
    /// History keeps the conversation beside the details (its job list takes the width); Review moves it
    /// behind a button below `narrowWidth`.
    var collapsesConversation = true
    @State private var summaryOpen = false
    /// v7: the batch's steps, open in place of the detail (‹ the batch).
    @State private var showSteps: Bool
    private let stepsOptions: StepsSnapshot

    /// `reply` / `allowed` / the review state start non-empty only in snapshots.
    init(jobID: String, reply: String = "", allowed: Set<String> = [], openFolders: Set<String> = [],
         unpicked: Set<String> = [], editing: (page: String, labels: [String])? = nil, labelError: String? = nil,
         openGroups: [String: Bool] = [:], menuOpen: Bool = false, hoverPage: String? = nil, collapsesConversation: Bool = true,
         showSteps: Bool = false, stepsOptions: StepsSnapshot = StepsSnapshot()) {
        self.jobID = jobID
        self.collapsesConversation = collapsesConversation
        self.openFolders = openFolders
        self.hoverPage = hoverPage
        _reply = State(initialValue: reply)
        _allowed = State(initialValue: allowed)
        _unpicked = State(initialValue: unpicked)
        _editingPage = State(initialValue: editing?.page)
        _editDraft = State(initialValue: editing?.labels ?? [])
        _labelError = State(initialValue: labelError)
        _groupOverrides = State(initialValue: openGroups)
        _menuOpen = State(initialValue: menuOpen)
        _showSteps = State(initialValue: showSteps)
        self.stepsOptions = stepsOptions
    }

    var body: some View {
        if showSteps, let job = engine.job(jobID) {
            JobStepsView(store: engine.jobSteps, job: job, back: job.displayTitle, title: "Steps", startDetails: stepsOptions.details,
                         startFollowing: stepsOptions.following, startExpanded: stepsOptions.expanded) { showSteps = false }
                .padding(.horizontal, Self.sidePadding).padding(.top, 26)
                .onChange(of: jobID) { showSteps = false }
        } else if let job = engine.job(jobID) {
            VStack(spacing: 0) {
                GeometryReader { geo in
                    // The details keep at least ~360 pt; the conversation takes what is left, between 220
                    // and 300 pt. Below ~780 pt (a window under ~1000 pt) it moves behind a button.
                    let narrow = collapsesConversation && geo.size.width < Self.narrowWidth
                    let pad = narrow ? Self.narrowPadding : Self.sidePadding
                    let inner = geo.size.width - 2 * pad - Self.gap
                    let talk = min(300, max(220, inner - 360))
                    HStack(alignment: .top, spacing: Self.gap) {
                        Scrolling {
                            VStack(alignment: .leading, spacing: 18) {
                                heading(job, narrow: narrow)
                                content(job)
                            }
                            .padding(.top, 30).padding(.bottom, 24)
                            .frame(maxWidth: .infinity, alignment: .leading)
                        }
                        if !narrow {
                            conversation(job)
                                .paneWidth(collapsesConversation ? PaneSpec.reviewConversation : PaneSpec.historyConversation,
                                           automatic: talk, container: geo.size.width)
                                .padding(.top, 30).padding(.bottom, 20)
                        }
                    }
                    .padding(.horizontal, pad)
                }
                // Session continuity: the batch's AI session is gone; ask before a new one is used.
                let sessionPrompt = engine.sessionPrompt(for: job)
                if let p = sessionPrompt {
                    SessionReplaceConfirm(p.info, runner: SessionReplaceText.runnerName(job.runnerID), place: "batch",
                                          carries: p.info.reason == "neverStarted" ? "The new session starts with this batch’s sources and labels, then reads them as usual." : "",
                                          onContinue: { engine.continueInNewSession(job) }, onCancel: { engine.cancelSessionPrompt(job) })
                        .padding(.horizontal, Self.sidePadding).padding(.bottom, 14)
                }
                footer(job)
                    .disabled(sessionPrompt != nil)
                    .opacity(sessionPrompt != nil ? 0.45 : 1)
            }
            .onChange(of: jobID) {
                reply = ""; allowed = []; unpicked = []; editingPage = nil; editDraft = []; labelError = nil
                groupOverrides = [:]; menuOpen = false; summaryOpen = false
            }
            .onChange(of: engine.returnedReply) {
                if let r = engine.returnedReply, r.jobID == job.id, reply.isEmpty { reply = r.text }
            }
        }
    }

    private static let sidePadding: CGFloat = 32
    private static let narrowPadding: CGFloat = 28
    private static let gap: CGFloat = 24
    static let narrowWidth: CGFloat = 780

    private func summary(_ job: Job) -> ReviewSummary {
        let completed = job.state == .completed
        let paths = completed ? job.changedPaths : (job.approval?.plan?.changedPaths ?? [])
        let vault = URL(fileURLWithPath: job.vaultPath)
        return ReviewSummary.make(changedPaths: paths, sources: job.approval?.sources,
                                  exists: completed ? nil : { FileManager.default.fileExists(atPath: vault.appendingPathComponent($0).path) })
    }

    private func pill(_ job: Job) -> StateStyle {
        let style = StateStyle.of(job.state)
        // v8 Review after Approve: "Adding to your vault" while the approved change goes in.
        if ApplyTimeline.isApplying(job) {
            return StateStyle(label: "Adding to your vault", fill: Theme.primaryTint, ink: Theme.primary, dot: Theme.primary)
        }
        if job.state == .completed, ApplyTimeline.showsInReview(job), job.operationID == job.approvedChange?.operationID {
            return StateStyle(label: "Added", fill: style.fill, ink: style.ink, dot: style.dot)
        }
        if job.state == .completed, let parts = job.parts, parts.count > 1 {
            return StateStyle(label: "Applied in \(parts.count) parts", fill: style.fill, ink: style.ink, dot: style.dot)
        }
        return style
    }

    private func heading(_ job: Job, narrow: Bool) -> some View {
        let style = pill(job)
        let parts = summary(job).parts
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 10) {
                Pill(text: style.label, fill: style.fill, ink: style.ink)
                Text(job.historyTime).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                if job.kind != "labels" {
                    Text("·").font(Theme.body(12)).foregroundStyle(Theme.faint)
                    LinkButton(title: "Show steps") { showSteps = true }.fixedSize()
                }
                Spacer(minLength: 0)
                if narrow {
                    SoftButton(title: "Conversation · \(job.turns.count)", size: .small) { showConversation.toggle() }
                        .fixedSize()
                        .popover(isPresented: $showConversation, arrowEdge: .bottom) {
                            conversation(job).frame(width: 320, height: 480).padding(18)
                        }
                }
            }
            Text(job.displayTitle).font(Theme.display(28)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
            if engine.isApplying(job.id) && job.approvedChange == nil {
                ApplyingLine(vault: URL(fileURLWithPath: job.vaultPath).lastPathComponent, start: engine.applyingSince(job.id) ?? Date())
            }
            if !parts.isEmpty {
                parts.enumerated().reduce(Text("")) { t, item in
                    t + Text(item.offset == 0 ? "" : " · ") + Text("\(item.element.0)").fontWeight(.bold) + Text(" \(item.element.1)")
                }
                .font(Theme.body(15)).foregroundStyle(Theme.ink).lineLimit(2).padding(.top, 2)
            }
            if let text = job.approval?.summary ?? job.turns.last(where: { $0.author == .worker })?.text {
                if summaryOpen || parts.isEmpty {
                    Markdown(text).font(Theme.body(parts.isEmpty ? 15 : 13)).foregroundStyle(parts.isEmpty ? Color(hex: 0x48463F) : Theme.muted)
                } else {
                    HStack(alignment: .firstTextBaseline, spacing: 6) {
                        Text(text.replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\n", with: " "))
                            .font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                        Button("Claude’s full summary") { summaryOpen = true }
                            .buttonStyle(.plain).font(Theme.body(13, .semibold)).foregroundStyle(Theme.primary).fixedSize()
                    }
                }
            }
            if let error = job.error {
                Text(error).font(Theme.body(13)).foregroundStyle(Theme.peachInk).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func content(_ job: Job) -> some View {
        let summary = summary(job)
        // v8: the steps after Approve, until every approved file is in the knowledge base (and why not).
        if collapsesConversation { // Review (History has Show steps in the heading, and less width)
            ApplyProgressCard(store: engine.jobSteps, job: job, onShowSteps: { showSteps = true })
        }
        InboxCleanupResultLine(store: engine.inboxCleanup, jobID: job.id)
        // What needs the user (plan error, questions, blocked tools with
        // "Allow & continue") comes first, so it is visible without scrolling
        // even at the 900 × 600 minimum window.
        if let approval = job.approval, job.state == .awaitingApproval {
            if let error = approval.planError {
                Callout(icon: "exclamationmark.triangle", title: "Can't apply this plan yet", text: error)
            }
            if !approval.questions.isEmpty {
                Callout(icon: "questionmark.bubble", title: "Claude has questions",
                        text: approval.questions.map { "• \($0)" }.joined(separator: "\n"))
            }
            if !approval.denials.isEmpty { blocked(job, approval) }
            // v10: sources one session couldn't finish are read next, in a fresh session (the covered part).
            if let later = job.coverage?.later, !later.isEmpty { LaterNotice(later: later) }
            if let rebuilt = approval.rebuilt, rebuilt.reason != .covered {
                rebuiltNotice(rebuilt)
            }
            if approval.needsRebuild == true {
                ReviewNotice(tone: .calm, title: "These sources wait for their change",
                             text: "Nothing was applied. They stay in this batch: Rebuild asks this batch’s session for their change again, or Reject batch ends it.",
                             systemImage: "arrow.uturn.backward")
            }
            if let labelError {
                ReviewNotice(tone: .peach, title: "Couldn’t save your label edit",
                             text: labelError + " Your edit was not kept; the labels are as before.", systemImage: "exclamationmark.circle")
            }
            if let labels = approval.labels, labels.state == .unconfirmed, let message = labels.message {
                ReviewNotice(tone: .calm, title: "Labels go in unconfirmed", text: message, systemImage: "info.circle")
            }
        }
        if job.state == .running {
            if let part = job.pendingPart, part.reason == .unread {
                let n = job.sources.count
                ReviewNotice(tone: .blue, title: "Reading \(n == 1 ? "1 source" : "\(n) sources") again, in a fresh session…",
                             text: "This session ran out of room before their last lines, so Claude reads them again from the start. They come back here as the next part.",
                             busy: true)
            } else if let part = job.pendingPart {
                let n = part.expected.count
                ReviewNotice(tone: .blue, title: "Rebuilding the change for your \(n == 1 ? "source" : "\(n) sources")…",
                             text: "In this batch’s own \(runnerName(job)) session (the one that read these notes). Your source pages and their labels stay exactly as you saw them; the index, log, hot cache, overview and ledgers are written again for just these.",
                             busy: true)
            } else if !ApplyTimeline.isApplying(job) {
                BatchBanner(job: job, showsCancel: false, onShowSteps: { showSteps = true })
            }
        }
        if job.state == .completed, let parts = job.parts, !parts.isEmpty {
            JobPartsList(parts: parts, removed: (job.approval?.sources ?? []).filter(\.removed))
        }
        if job.state == .awaitingApproval, job.actionsFound == nil, job.kind == "ingest" || job.kind == "batch" {
            let n = job.approval?.sources.map { ReviewPicking.active($0).count } ?? job.sources.count // a folder counts once
            HStack(spacing: 8) {
                Image(systemName: "checklist").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("After you apply, Distill looks for actions in \(n == 1 ? "this note" : "these \(n) notes") with Sonnet and asks you to confirm them.")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            }
        }
        if let summary = job.actionsFound { JobActionsLine(job: job, summary: summary) }
        // v10: what the session read, counted by the core (information, no buttons).
        if let coverage = job.coverage, coverage.of > 0, coverage.state != "reading" {
            CoverageBlock(coverage: coverage, stopped: job.stopped.count)
        }
        ReviewGroupsView(job: job, summary: summary, unpicked: $unpicked, editingPage: $editingPage, editDraft: $editDraft,
                         labelError: $labelError, overrides: $groupOverrides, hoverPage: hoverPage,
                         openable: collapsesConversation && job.state == .completed && job.approvedChange != nil && job.operationID == job.approvedChange?.operationID,
                         open: { open(job: job, path: $0) })
        if job.approval?.sources == nil || !(job.folders ?? []).isEmpty, !job.files.isEmpty || !(job.folders ?? []).isEmpty {
            // A folder shows once (QueueItems cards 2 and 3): its files and their pages on Review, its tree in History.
            JobSourcesView(job: job, mode: job.state == .awaitingApproval ? .review : .history, openFolders: openFolders)
        }
    }

    @ViewBuilder private func rebuiltNotice(_ rebuilt: RebuiltPlan) -> some View {
        let n = rebuilt.pages.count
        let pages = n == 1 ? "source page is" : "\(n) source pages are"
        if rebuilt.reason == .stale {
            ReviewNotice(tone: .blue, title: "Rebuilt for your vault as it is now",
                         text: "Another batch changed your vault after this one was prepared, so this batch’s change was rebuilt in its own session and checked again.",
                         systemImage: "info.circle")
        } else {
            ReviewNotice(tone: .green, title: "Rebuilt and checked by the vault core",
                         text: "Distill compared it with what you approved: the \(pages) the same, byte for byte, and nothing else from this batch is in it.")
        }
    }

    private func runnerName(_ job: Job) -> String {
        switch job.runnerID ?? "claude-code" {
        case "claude-code": return "Claude"
        case "codex": return "Codex"
        default: return "AI"
        }
    }

    private func blocked(_ job: Job, _ approval: ApprovalRequest) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("Claude asked to run", systemImage: "lock").font(Theme.body(13, .bold))
            ForEach(approval.denials, id: \.self) { denial in
                if let rule = denial.suggestedRule {
                    Toggle(isOn: Binding(get: { allowed.contains(rule) },
                                         set: { on in if on { allowed.insert(rule) } else { allowed.remove(rule) } })) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(denial.display).font(.system(size: 12, design: .monospaced)).lineLimit(3)
                            if denial.bypassesApproval(jobDirectory: (job.vaultPath as NSString).appendingPathComponent(".vault-meta/worker/\(job.id)")) {
                                Text("Allowing this lets Claude change files without your review.")
                                    .font(Theme.body(12)).foregroundStyle(Theme.peachInk)
                            }
                        }
                    }
                    .toggleStyle(.checkbox)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        Text(denial.display).font(.system(size: 12, design: .monospaced)).lineLimit(3)
                        Text("Combined command: reply with guidance instead.").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                }
            }
            if !allowed.isEmpty {
                SoftButton(title: "Allow & continue", tint: Theme.peachInk, fill: .white) {
                    engine.allow(job.id, rules: Array(allowed)); allowed = []
                }
            }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF4EE)))
    }

    private func conversation(_ job: Job) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("Conversation").font(Theme.body(14, .bold))
                Spacer()
                IconButton(systemImage: "terminal", size: 16, iconSize: 13, weight: .regular,
                           help: "Open this session in Terminal") { engine.openInTerminal(job) }
                    .disabled(job.state == .running)
                    .popover(isPresented: Binding(get: { engine.terminalSessionPrompt?.jobID == job.id },
                                                  set: { if !$0 { engine.terminalSessionPrompt = nil } }),
                             arrowEdge: .bottom) {
                        if let p = engine.terminalSessionPrompt {
                            SessionReplaceConfirm(p.info, runner: SessionReplaceText.runnerName(job.runnerID), place: "terminal", width: 404,
                                                  onContinue: { engine.continueTerminalInNewSession(job) },
                                                  onCancel: { engine.terminalSessionPrompt = nil })
                                .padding(8)
                        }
                    }
            }
            ChatScrolling {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(job.turns) { turn in
                        VStack(alignment: .leading, spacing: 4) {
                            Text("\(name(turn.author)) · \(Text(turn.date, style: .time))")
                                .font(Theme.body(11, .bold)).foregroundStyle(Theme.muted)
                            Markdown(turn.text).font(Theme.body(13)).lineLimit(12)
                        }
                        .padding(.horizontal, 14).padding(.vertical, 12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(UnevenRoundedRectangle(topLeadingRadius: 16, bottomLeadingRadius: 4, bottomTrailingRadius: 16, topTrailingRadius: 16)
                            .fill(bubble(turn.author)))
                    }
                }
            }
            if canReply(job) {
                Text("Reply to Claude").font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
                ReplyEditor(text: $reply)
            }
            Text("Model \(ModelChoice.shortName(job.model)) · $\(job.totalCostUSD, specifier: "%.2f")")
                .font(Theme.body(11)).foregroundStyle(Theme.faint)
        }
    }

    private func footer(_ job: Job) -> some View {
        HStack(spacing: 10) {
            switch job.state {
            case .awaitingApproval:
                let applying = engine.isApplying(job.id)
                let approval = job.approval
                let blocker = ReviewPicking.blocker(approval, unpicked: unpicked)
                if ReviewPicking.offersDiscardPart(job) {
                    // Discards only this rebuilt change: its sources stay in this batch (decision 2026-10-05).
                    SoftButton(title: "Discard this part", tint: Theme.peachInk, fill: .clear) { engine.reject(job.id) }
                        .disabled(applying).opacity(applying ? 0.35 : 1)
                        .help("Nothing is applied; these sources go back to this batch's Review.")
                }
                SoftButton(title: ReviewPicking.rejectTitle(job), tint: Theme.peachInk, fill: .clear) {
                    engine.reject(job.id, batch: true)
                }
                .disabled(applying).opacity(applying ? 0.35 : 1)
                Spacer()
                if !applying { footerStatus(approval, blocker: blocker, stopped: job.stopped.count) }
                SoftButton(title: "Send reply") { send(job) }
                    .disabled(applying || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(applying ? 0.35 : 1)
                if applying {
                    let s = summary(job)
                    ApplyingButton(count: s.sourcePages.count + s.newPages.count + s.updated.count)
                } else if approval?.canApplyPlan == true {
                    approveButton(job, approval: approval, enabled: blocker == nil && editingPage == nil)
                } else if approval?.needsRebuild == true {
                    let n = approval?.sources?.count ?? 0
                    PrimaryButton(title: n == 1 ? "Rebuild 1 source" : "Rebuild \(n) sources", systemImage: "arrow.clockwise",
                                  enabled: true) { engine.approve(job.id) }
                }
            case .running:
                if let part = job.pendingPart {
                    let n = part.reason == .unread ? job.sources.count : part.expected.count
                    Spacer()
                    HStack(spacing: 6) {
                        Spinner(color: Theme.muted, size: 11)
                        Text(part.reason == .unread ? "Reading with \(ModelChoice.shortName(job.model))…" : "Rebuilding with \(ModelChoice.shortName(job.model))…")
                            .font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    PrimaryButton(title: n == 1 ? "Approve 1 source" : "Approve \(n) sources",
                                  systemImage: "checkmark", enabled: false) {}
                } else if ApplyTimeline.isApplying(job) {
                    // v8: nothing needs you while the approved change goes in (Show steps is in the heading and the card).
                    Spacer()
                    HStack(spacing: 6) {
                        Spinner(color: Theme.muted, size: 11)
                        Text("Adding to \(URL(fileURLWithPath: job.vaultPath).lastPathComponent) · you can leave this screen")
                            .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                } else {
                    Text("Claude is working on it…").font(Theme.body(13)).foregroundStyle(Theme.muted)
                    Spacer()
                    SoftButton(title: "Cancel") { engine.cancel(job.id) }
                }
            case .failed, .cancelled:
                Spacer()
                SoftButton(title: "Send reply") { send(job) }
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                if collapsesConversation && ApplyTimeline.showsInReview(job) {
                    PrimaryButton(title: "Done") { engine.finishReview(job.id) }
                        .help("Take this batch out of Review; it stays in History")
                }
            case .completed, .rejected:
                if let parts = job.parts, parts.count > 1 {
                    Text("\(parts.count) operations · \(parts.map(\.operationID).joined(separator: ", "))")
                        .font(Theme.body(12)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                } else if let op = job.operationID {
                    Text("Operation \(op)").font(Theme.body(12)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle).textSelection(.enabled)
                }
                Spacer()
                // v8: Clean up inbox, only when you ask (never automatic).
                if InboxCleanupButton.applies(to: job) {
                    InboxCleanupButton(store: engine.inboxCleanup, job: job)
                }
                if collapsesConversation && ApplyTimeline.showsInReview(job) {
                    PrimaryButton(title: "Done") { engine.finishReview(job.id) }
                        .help("Take this batch out of Review; it stays in History")
                }
            }
        }
        .padding(.horizontal, Self.sidePadding).padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    /// "Approving also confirms the labels shown", or why Approve waits (labels being saved or suggested).
    @ViewBuilder private func footerStatus(_ approval: ApprovalRequest?, blocker: String?, stopped: Int = 0) -> some View {
        if let labels = approval?.labels, labels.state == .confirming {
            HStack(spacing: 6) {
                Spinner(color: Theme.muted, size: 11)
                Text("Saving your labels into the change and checking it again…").font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
        } else if let blocker, !blocker.isEmpty {
            Text(blocker).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
        } else if stopped > 0 {
            // v10: a source that couldn't be read is never in the change, and nothing here approves it.
            Text(FullReadWords.stoppedFooter(stopped)).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
        } else if let sources = approval?.sources, sources.contains(where: { !$0.labels.isEmpty && !$0.removed }),
                  approval?.labels?.state != .unconfirmed {
            Text("Approving also confirms the labels shown").font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }

    private func approveButton(_ job: Job, approval: ApprovalRequest?, enabled: Bool) -> some View {
        let title = ReviewPicking.approveTitle(approval, unpicked: unpicked)
        let approve = { engine.approveTracked(job.id, options: ReviewPicking.options(approval?.sources, unpicked: unpicked)) }
        var options: [(String, String, () -> Void)] = []
        if ReviewPicking.offersLater(approval, unpicked: unpicked) {
            options = [
                (ReviewPicking.menuApproveTitle(approval, unpicked: unpicked), "Adds them to your vault and confirms the labels shown.", approve),
                ("Approve, review labels later", "Adds them with their labels unconfirmed. They wait in Labels → To review.",
                 { engine.approveTracked(job.id, options: ReviewPicking.options(approval?.sources, unpicked: unpicked, later: true)) }),
            ]
        }
        return ApproveSplitButton(title: title, enabled: enabled, options: options, menuOpen: $menuOpen, action: approve)
    }

    // MARK: helpers

    private func canReply(_ job: Job) -> Bool {
        [.awaitingApproval, .failed, .cancelled].contains(job.state)
    }

    private func send(_ job: Job) {
        let text = reply
        // Cleared only once the core took it; a refused reply stays in the box (and the error shows).
        engine.reply(job.id, text: text) { if reply == text { reply = "" } }
    }

    private func name(_ author: TurnRecord.Author) -> String {
        switch author { case .worker: "Claude"; case .user: "You"; case .app: "Distill" }
    }

    private func bubble(_ author: TurnRecord.Author) -> Color {
        switch author { case .worker: Theme.primaryTint; case .user: Theme.limeTint; case .app: Theme.panel }
    }

    private func open(job: Job, path: String) {
        let full = URL(fileURLWithPath: job.vaultPath).appendingPathComponent(path).path
        var components = URLComponents(string: "obsidian://open")!
        components.queryItems = [URLQueryItem(name: "path", value: full)]
        if let url = components.url, NSWorkspace.shared.urlForApplication(toOpen: url) != nil, FileManager.default.fileExists(atPath: full) {
            NSWorkspace.shared.open(url)
        } else if FileManager.default.fileExists(atPath: full) {
            NSWorkspace.shared.open(URL(fileURLWithPath: full))
        }
    }
}

struct StatTile: View {
    let n: Int
    let label: String
    let fill: Color
    let ink: Color

    var body: some View {
        HStack(spacing: 12) {
            Text("\(n)").font(Theme.display(28)).foregroundStyle(ink)
            Text(label).font(Theme.body(13, .semibold)).lineLimit(1).fixedSize()
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 16).fill(fill))
    }
}

struct Callout: View {
    let icon: String
    let title: String
    let text: String

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Label(title, systemImage: icon).font(Theme.body(13, .bold))
            Text(text).font(Theme.body(13)).foregroundStyle(Color(hex: 0x48463F)).textSelection(.enabled)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF4EE)))
    }
}

struct ErrorBanner: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        if case .unreachable(let problem) = engine.connection {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: "bolt.horizontal.circle.fill").foregroundStyle(Theme.peachInk)
                VStack(alignment: .leading, spacing: 3) {
                    Text("Distill's core isn't running").font(Theme.body(13, .bold))
                    Text(problem).font(Theme.body(12)).lineLimit(6).textSelection(.enabled)
                }
                Spacer()
                PrimaryButton(title: "Retry", systemImage: "arrow.clockwise") { engine.connect() }
            }
            .padding(14)
            .card(14)
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .padding(20)
            .frame(maxWidth: 720)
        } else if engine.connection == .connecting {
            HStack(spacing: 10) {
                ProgressView().controlSize(.small)
                Text("Connecting to Distill's core…").font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            .padding(12)
            .card(14)
            .padding(20)
        } else if let error = engine.lastError {
            HStack(spacing: 10) {
                Image(systemName: "exclamationmark.circle.fill").foregroundStyle(Theme.peachInk)
                Text(error).font(Theme.body(13)).lineLimit(3).textSelection(.enabled)
                Spacer()
                Button("Dismiss") { engine.lastError = nil }.buttonStyle(.plain).foregroundStyle(Theme.primary)
            }
            .padding(14)
            .card(14)
            .shadow(color: .black.opacity(0.08), radius: 12, y: 4)
            .padding(20)
            .frame(maxWidth: 640)
        }
    }
}

struct Markdown: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        Text((try? AttributedString(markdown: text, options: options)) ?? AttributedString(text))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

@MainActor
enum VaultPicker {
    static func chooseDirectory(title: String, prompt: String = "Choose") -> URL? {
        let panel = NSOpenPanel()
        panel.title = title
        panel.prompt = prompt
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        return panel.runModal() == .OK ? panel.url : nil
    }

    static func addVault(engine: AppModel) {
        guard let url = chooseDirectory(title: "Choose a claude-obsidian vault root") else { return }
        let path = url.standardizedFileURL.path
        guard VaultProfile.isVault(path) else {
            engine.lastError = "\(path) is not a claude-obsidian vault (no .claude-obsidian.json). Run `python3 scripts/claude-obsidian.py init \(path)` or `adopt` first."
            return
        }
        let existing = engine.settings.vaults.first { $0.path == path }
        engine.settings.upsert(existing ?? VaultProfile(path: path, queueDirectory: VaultProfile.defaultQueueDirectory(forVault: path)))
        engine.settings.activeVaultPath = path
    }
}

// ReplyEditor (Markdown reply box) lives in MarkdownEditor.swift.
