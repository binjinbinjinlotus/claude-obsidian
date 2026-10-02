import AppKit
import SwiftUI
import DistillKit

enum Section: Hashable {
    case queue, review, ask, labels, history
}

struct MainView: View {
    @EnvironmentObject var engine: AppModel
    var openSettings: () -> Void
    @State private var section: Section = .queue
    @State private var selectedJob: String?

    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: $section, selectedJob: $selectedJob, openSettings: openSettings)
                .layoutPriority(1)
            Group {
                switch section {
                case .queue: QueueView()
                case .review: ReviewSection(selectedJob: $selectedJob)
                case .ask: AskScreen()
                case .labels: LabelsSection()
                case .history: HistorySection(selectedJob: $selectedJob, openAsk: { section = .ask })
                }
            }
            // minWidth 0 + clipped: a screen that asks for more width than the
            // window has is squeezed to fit instead of pushing the sidebar off.
            .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity)
            .clipped()
            .background(Theme.window)
        }
        .environmentObject(engine.ask)
        .overlay(alignment: .bottom) { ErrorBanner() }
        .frame(minWidth: 900, minHeight: 600)
        .foregroundStyle(Theme.ink)
        .ignoresSafeArea()
        .onChange(of: engine.pendingApprovals.count) { old, new in
            // Jump to Review when something new needs the user.
            if new > old, section != .ask { section = .review; selectedJob = engine.pendingApprovals.first?.id }
        }
        .onReceive(engine.ask.$showAskRequest.dropFirst()) { _ in section = .ask }
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
    var openSettings: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 22) {
            Color.clear.frame(height: 26) // traffic lights sit here
            HStack(spacing: 9) {
                FlaskView(level: 0.45, bubbles: true, lineWidth: 1.8).frame(width: 24, height: 26)
                Text("distill").font(Theme.display(20))
            }
            .padding(.horizontal, 6)

            VStack(spacing: 2) {
                navItem(.queue, "Queue", "tray", count: engine.queued.count, highlight: false)
                navItem(.review, "Review", "checkmark.square", count: engine.pendingApprovals.count, highlight: true)
                navItem(.ask, "Ask", "questionmark.bubble", count: 0, highlight: false)
                navItem(.labels, "Labels", "tag", count: engine.labelsToReviewCount, highlight: false)
                navItem(.history, "History", "clock", count: 0, highlight: false)
            }

            if section == .ask { RecentQuestions(ask: engine.ask) }

            Spacer()
            VaultSwitcher(openSettings: openSettings)
        }
        .padding(.horizontal, 14)
        .padding(.bottom, 16)
        .frame(width: 220)
        .frame(maxHeight: .infinity)
        .background(Theme.panel)
    }

    private func navItem(_ s: Section, _ title: String, _ icon: String, count: Int, highlight: Bool) -> some View {
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
            .background(RoundedRectangle(cornerRadius: 10).fill(active ? Color.white : .clear)
                .shadow(color: .black.opacity(active ? 0.07 : 0), radius: 2, y: 1))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// "Recent questions" under the nav while Ask is open (canvas: "Ask").
struct RecentQuestions: View {
    @ObservedObject var ask: AskModel

    var body: some View {
        let recent = ask.conversations.prefix(5)
        if !recent.isEmpty {
            VStack(alignment: .leading, spacing: 0) {
                Text("RECENT QUESTIONS").font(Theme.body(11, .bold)).foregroundStyle(Theme.faint).kerning(0.6)
                    .padding(.horizontal, 12).padding(.bottom, 4)
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
                    Text(statusLine).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
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

    private var statusLine: String {
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
    @State private var targeted = false
    @AppStorage("distill.addMode") private var addMode: AddMode = .files

    var body: some View {
        if addMode == .note {
            ComposeScreen(mode: $addMode) // Write a note (ComposeView.swift)
        } else {
            Scrolling {
                VStack(alignment: .leading, spacing: 26) {
                    header
                    if let batch = engine.runningBatch { BatchBanner(job: batch) }
                    dropPanel
                    if engine.isStarting { StartingPlaceholder() } else { fileList }
                }
                .padding(.horizontal, 44).padding(.top, 44).padding(.bottom, 30)
            }
        }
    }

    /// Title, schedule, the add-mode switch and Process now. When the row is too
    /// narrow (a 900 pt window, a long "3 in this batch · 2 waiting"), the
    /// switch and the button move under the title instead of squeezing it.
    private var header: some View {
        ViewThatFits(in: .horizontal) {
            HStack(alignment: .top, spacing: 16) {
                titleBlock.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                headerControls
            }
            VStack(alignment: .leading, spacing: 16) {
                titleBlock
                HStack(spacing: 12) { headerControls }
            }
        }
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
            let inBatch = batch.files.filter { !$0.hasSuffix(QueueRows.manifestSuffix) }.count
            let waiting = rows.count
            return "\(inBatch) in this batch" + (waiting > 0 ? " · \(waiting) waiting" : "")
        }
        switch rows.count {
        case 0: return "All caught up"
        case 1: return "1 source in the queue"
        default: return "\(rows.count) sources in the queue"
        }
    }

    @ViewBuilder private var scheduleLine: some View {
        if engine.runningBatch != nil {
            Text("New drops wait for the next batch")
        } else if let holder = engine.jobs.first(where: { $0.vaultPath == engine.activeVault?.path && $0.state.holdsVault }) {
            Text(holder.state == .running
                 ? "Next batch starts after Claude finishes \(holder.displayTitle)"
                 : "Next batch waits until you review \(holder.displayTitle)")
        } else if let blocker = engine.batchBlocker {
            Text(blocker)
        } else if !engine.settings.autoProcessEnabled {
            Text("Automatic batching is off")
        } else if let next = engine.nextBatchAt {
            // A clock time: it changes only when the schedule does.
            let clock = QueueRows.clock(next)
            let every = BatchInterval(totalMinutes: engine.settings.batchIntervalMinutes).phrase
            Text("Next batch at \(Text(clock).fontWeight(.semibold).foregroundColor(Theme.ink)) · every \(every)")
        }
    }

    private var dropPanel: some View {
        HStack(spacing: 30) {
            FlaskView(level: min(1, Double(engine.queued.count) / 6 + (engine.queued.isEmpty ? 0.08 : 0.25)),
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
                ForEach(batch.files.filter { !$0.hasSuffix(QueueRows.manifestSuffix) }, id: \.self) { file in
                    let entry = Self.batchEntry(file, vaultPath: batch.vaultPath)
                    QueueRowView(title: QueueRows.title(entry), meta: QueueRows.meta(entry), tileName: entry.name,
                                 status: .inBatch, help: QueueRows.pillHelp(.inBatch, settleSeconds: engine.settings.settleSeconds),
                                 noteTile: entry.kind == .note && entry.name.hasSuffix(".md"),
                                 onReveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) })
                }
            }
            ForEach(rows) { entry in
                let status = QueueRows.status(entry, batchRunning: engine.runningBatch != nil)
                QueueRowView(title: QueueRows.title(entry), meta: QueueRows.meta(entry), tileName: entry.name, status: status,
                             help: QueueRows.pillHelp(status, settleSeconds: engine.settings.settleSeconds),
                             noteTile: entry.kind == .note && entry.name.hasSuffix(".md"),
                             onRemove: { engine.removeFromQueue(entry) },
                             onReveal: { NSWorkspace.shared.activateFileViewerSelecting([entry.url]) })
            }
            if rows.isEmpty && engine.runningBatch == nil {
                Text("Nothing waiting. New files will show up here.")
                    .font(Theme.body(13)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity).padding(.vertical, 20)
            }
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
        let pending = engine.pendingApprovals
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
    @State private var part: HistoryPart = .jobs

    enum HistoryPart: Hashable { case jobs, chats }

    var body: some View {
        let jobs = engine.jobs.filter { $0.state != .awaitingApproval }
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                HStack(alignment: .firstTextBaseline) {
                    Text("History").font(Theme.display(24))
                    Spacer()
                    if part == .jobs && engine.hasFinishedJobs {
                        Button("Clear") { engine.clearFinishedJobs() }
                            .buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                            .help("Remove finished jobs from this list (the vault keeps every change)")
                    }
                }
                Segmented(options: [(HistoryPart.jobs, "Jobs"), (.chats, "Ask chats")], selection: $part, height: 26)
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
                        case .chats:
                            AskChatList(ask: engine.ask, openAsk: openAsk)
                        }
                    }
                }
            }
            .padding(24)
            .frame(width: 300)
            .background(Theme.window)
            Divider().overlay(Theme.border)
            if part == .jobs, let id = selectedJob, jobs.contains(where: { $0.id == id }) {
                JobDetailView(jobID: id)
            } else if part == .chats {
                EmptyState(title: "Ask chats", message: engine.settings.resolvedAskPreferences.resolvedKeepHistory
                           ? "Chats are kept \(engine.settings.resolvedAskPreferences.resolvedHistoryDays) days after their last message. Pinned chats stay."
                           : "Keep history is off: a chat is deleted when you start a new one or leave Ask. Pinned chats stay.")
            } else {
                EmptyState(title: "Pick a job", message: "Select a job to see what Claude did.")
            }
        }
    }
}

/// Ask conversations in History: open in Ask, pin, delete.
struct AskChatList: View {
    @ObservedObject var ask: AskModel
    var openAsk: () -> Void

    var body: some View {
        if ask.conversations.isEmpty {
            Text("No Ask chats yet.").font(Theme.body(13)).foregroundStyle(Theme.faint).padding(.top, 8)
        }
        ForEach(ask.conversations) { c in
            HStack(spacing: 10) {
                Button {
                    ask.open(conversationID: c.id)
                    openAsk()
                } label: {
                    HStack(spacing: 10) {
                        Image(systemName: "bubble.left.fill").font(.system(size: 11)).foregroundStyle(Theme.primary)
                            .frame(width: 24, height: 24).background(Circle().fill(Theme.primaryTint))
                        VStack(alignment: .leading, spacing: 2) {
                            Text(c.title.isEmpty ? "Untitled chat" : c.title).font(Theme.body(13, .semibold)).lineLimit(1)
                            Text("\(c.turnCount == 1 ? "1 question" : "\(c.turnCount) questions") · \(Text(c.updatedAt, style: .relative)) ago")
                                .font(Theme.body(11)).foregroundStyle(Theme.muted)
                        }
                        Spacer(minLength: 0)
                    }
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Open in Ask")
                Button { ask.setPinned(c.id, !c.pinned) } label: {
                    Image(systemName: c.pinned ? "pin.fill" : "pin").font(.system(size: 11))
                        .foregroundStyle(c.pinned ? Theme.primary : Theme.faint)
                }
                .buttonStyle(.plain).help(c.pinned ? "Unpin (it can then expire)" : "Pin (kept until you delete it)")
                Button { ask.delete(c.id) } label: {
                    Image(systemName: "trash").font(.system(size: 11)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain).help("Delete this chat")
            }
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
                ForEach(jobs) { job in
                    Button { pick(job.id) } label: {
                        Text(job.displayTitle).font(Theme.body(12, .semibold)).lineLimit(1)
                            .padding(.horizontal, 12).frame(height: 28)
                            .background(Capsule().fill(job.id == selected ? Theme.primaryTint : Theme.panel))
                            .foregroundStyle(job.id == selected ? Theme.primary : Theme.ink)
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
                Text("\(StateStyle.of(job.state).label) · \(Text(job.createdAt, style: .relative)) ago")
                    .font(Theme.body(11)).foregroundStyle(Theme.muted)
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
    /// "Tea brewing session"-style title from the first input file.
    var displayTitle: String {
        guard let first = files.first else { return kind.prefix(1).uppercased() + kind.dropFirst() }
        let base = ((first as NSString).lastPathComponent as NSString).deletingPathExtension
            .replacingOccurrences(of: "-", with: " ").replacingOccurrences(of: "_", with: " ")
        let pretty = base.prefix(1).uppercased() + base.dropFirst()
        return files.count > 1 ? "\(pretty) +\(files.count - 1)" : pretty
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
    @State private var reply = ""
    @State private var allowed: Set<String> = []

    var body: some View {
        if let job = engine.job(jobID) {
            VStack(spacing: 0) {
                HStack(alignment: .top, spacing: 32) {
                    Scrolling {
                        VStack(alignment: .leading, spacing: 22) {
                            heading(job)
                            content(job)
                        }
                        .padding(.top, 34).padding(.bottom, 24)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    conversation(job)
                        .frame(width: 290)
                        .padding(.top, 34).padding(.bottom, 20)
                }
                .padding(.horizontal, 44)
                footer(job)
            }
            .onChange(of: jobID) { reply = ""; allowed = [] }
        }
    }

    private func heading(_ job: Job) -> some View {
        let style = StateStyle.of(job.state)
        return VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Pill(text: style.label, fill: style.fill, ink: style.ink)
                if job.state == .running { Spinner(size: 14) }
            }
            Text(job.displayTitle).font(Theme.display(30)).lineLimit(2)
            if engine.isApplying(job.id) {
                ApplyingLine(vault: URL(fileURLWithPath: job.vaultPath).lastPathComponent, start: engine.applyingSince(job.id) ?? Date())
            }
            if let summary = job.approval?.summary ?? job.turns.last(where: { $0.author == .worker })?.text {
                Markdown(summary).font(Theme.body(15)).foregroundStyle(Color(hex: 0x48463F))
            }
            if let error = job.error {
                Text(error).font(Theme.body(13)).foregroundStyle(Theme.peachInk).textSelection(.enabled)
            }
        }
    }

    @ViewBuilder
    private func content(_ job: Job) -> some View {
        let changes = changeList(job)
        if !changes.isEmpty {
            HStack(spacing: 10) {
                StatTile(n: changes.filter(\.isNew).count, label: plural(changes.filter(\.isNew).count, "new page", "new pages"), fill: Theme.limeTint, ink: Theme.limeInk)
                StatTile(n: changes.filter { !$0.isNew }.count, label: plural(changes.filter { !$0.isNew }.count, "file updated", "files updated"), fill: Theme.primaryTint, ink: Theme.primary)
                if let attention = attentionCount(job), attention > 0 {
                    StatTile(n: attention, label: plural(attention, "needs a look", "need a look"), fill: Theme.peachTint, ink: Theme.peachInk)
                }
            }
            VStack(alignment: .leading, spacing: 4) {
                HStack(alignment: .firstTextBaseline) {
                    Text("Changes").font(Theme.body(14, .bold))
                    Text(job.state == .completed ? "applied" : "verified by the vault core").font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                .padding(.bottom, 4)
                ForEach(changes, id: \.path) { change in
                    Button { open(job: job, path: change.path) } label: {
                        HStack(spacing: 12) {
                            Text(change.isNew ? "+" : "•").font(Theme.body(14, .bold))
                                .foregroundStyle(change.isNew ? Theme.limeInk : Theme.primary)
                                .frame(width: 24, height: 24)
                                .background(Circle().fill(change.isNew ? Theme.limeTint : Theme.primaryTint))
                            Text(change.name).font(Theme.body(14)).lineLimit(1)
                            Spacer()
                            Text(change.directory).font(Theme.body(12)).foregroundStyle(Theme.faint)
                        }
                        .padding(.vertical, 6).padding(.horizontal, 4)
                        .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        if let approval = job.approval, job.state == .awaitingApproval {
            if let error = approval.planError {
                Callout(icon: "exclamationmark.triangle", title: "Can't apply this plan yet", text: error)
            }
            if !approval.questions.isEmpty {
                Callout(icon: "questionmark.bubble", title: "Claude has questions",
                        text: approval.questions.map { "• \($0)" }.joined(separator: "\n"))
            }
            if !approval.denials.isEmpty { blocked(job, approval) }
        }
        DisclosureGroup("Inputs (\(job.files.count))") {
            ForEach(job.files, id: \.self) { file in
                Button(file) {
                    NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.vaultPath).appendingPathComponent(file)])
                }
                .buttonStyle(.link)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .font(Theme.body(13))
        .foregroundStyle(Theme.muted)
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
                            if denial.bypassesApproval {
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
                Button {
                    engine.openInTerminal(job)
                } label: { Image(systemName: "terminal") }
                .buttonStyle(.plain).foregroundStyle(Theme.muted)
                .help("Open this session in Terminal")
                .disabled(job.state == .running)
            }
            Scrolling {
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
            .defaultScrollAnchor(.bottom)
            if canReply(job) {
                Text("Reply to Claude").font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
                ReplyEditor(text: $reply)
                    .frame(height: 76)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
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
                SoftButton(title: "Reject", tint: Theme.peachInk, fill: .clear) { engine.reject(job.id) }
                    .disabled(applying).opacity(applying ? 0.35 : 1)
                Spacer()
                SoftButton(title: "Send reply") { send(job) }
                    .disabled(applying || reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                    .opacity(applying ? 0.35 : 1)
                if applying {
                    ApplyingButton(count: changeList(job).count)
                } else if job.approval?.canApplyPlan == true {
                    PrimaryButton(title: "Approve & apply", systemImage: "checkmark") { engine.approveTracked(job.id) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            case .running:
                Text("Claude is working on it…").font(Theme.body(13)).foregroundStyle(Theme.muted)
                Spacer()
                SoftButton(title: "Cancel") { engine.cancel(job.id) }
            case .failed, .cancelled:
                Spacer()
                SoftButton(title: "Send reply") { send(job) }
                    .disabled(reply.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            case .completed, .rejected:
                if let op = job.operationID {
                    Text("Operation \(op)").font(Theme.body(12)).foregroundStyle(Theme.faint).textSelection(.enabled)
                }
                Spacer()
            }
        }
        .padding(.horizontal, 44).padding(.vertical, 18)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
    }

    // MARK: helpers

    private struct Change { let path: String; let isNew: Bool
        var name: String { ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
        var directory: String { (path as NSString).deletingLastPathComponent }
    }

    private func changeList(_ job: Job) -> [Change] {
        let paths = job.state == .completed ? job.changedPaths : (job.approval?.plan?.changedPaths ?? [])
        let vault = URL(fileURLWithPath: job.vaultPath)
        return paths
            .filter { !$0.hasPrefix(".vault-meta/") && !$0.hasPrefix(".raw/") }
            .map { Change(path: $0, isNew: job.state != .completed && !FileManager.default.fileExists(atPath: vault.appendingPathComponent($0).path)) }
    }

    private func attentionCount(_ job: Job) -> Int? {
        guard let a = job.approval, job.state == .awaitingApproval else { return nil }
        return a.questions.count + a.denials.count + (a.planError == nil ? 0 : 1)
    }

    private func plural(_ n: Int, _ one: String, _ many: String) -> String { n == 1 ? one : many }

    private func canReply(_ job: Job) -> Bool {
        [.awaitingApproval, .failed, .cancelled].contains(job.state)
    }

    private func send(_ job: Job) {
        engine.reply(job.id, text: reply)
        reply = ""
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
            Text(label).font(Theme.body(13, .semibold))
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

struct ReplyEditor: View {
    @Environment(\.snapshotMode) private var snapshot
    @Binding var text: String

    var body: some View {
        if snapshot {
            Text("e.g. Add this to the Green tea page instead")
                .font(Theme.body(13)).foregroundStyle(Theme.faint)
                .padding(12).frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            TextEditor(text: $text)
                .font(Theme.body(13))
                .scrollContentBackground(.hidden)
                .padding(8)
        }
    }
}
