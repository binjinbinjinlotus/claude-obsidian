import SwiftUI
import DistillKit

// The Settings window (canvas: SettingsNav, Settings): a section list on the
// left (General, AI, Actions) with search on top, and on the right one page per
// section: its title and note, then only that section's content. Each action
// type has its own page too. Search results and "No settings match" replace
// the page. Every edit changes `engine.settings`; AppModel sends the changed
// top-level key about 0.5 s later.

struct SettingsView: View {
    @EnvironmentObject var engine: AppModel
    private let showAdvanced: Bool

    /// `showAdvanced` starts expanded only in snapshots.
    init(showAdvanced: Bool = false) { self.showAdvanced = showAdvanced }

    var body: some View {
        SettingsWindowContent(ui: engine.settingsUI, showAdvanced: showAdvanced)
    }
}

private struct SettingsWindowContent: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore
    @State private var showAdvanced: Bool
    @State private var editingVault: VaultProfile?
    @State private var scroller = SettingsScroller()
    @Environment(\.snapshotMode) private var snapshot

    init(ui: SettingsStore, showAdvanced: Bool) {
        self.ui = ui
        _showAdvanced = State(initialValue: showAdvanced)
    }

    private var searching: Bool { !ui.query.trimmingCharacters(in: .whitespaces).isEmpty }
    private var results: [SettingsEntry] { SettingsIndex.search(ui.query, in: SettingsIndex.all(types: ui.actionTypes)) }

    var body: some View {
        HStack(spacing: 0) {
            SettingsSectionNav(selected: ui.target.section, query: $ui.query,
                               matches: searching ? SettingsIndex.counts(results) : nil) { ui.select(SettingsTarget($0)) }
                .frame(width: SettingsWindowSize.nav)
            // minWidth 0 + clipped: a page that asks for more width than the window
            // has is squeezed (rows reflow) instead of pushing the nav off the left.
            content
                .frame(minWidth: 0, maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
                .clipped()
                .background(Theme.window)
        }
        .onAppear {
            engine.loadRunners()
            engine.refreshLabels()
            engine.loadActionTypes()
            engine.loadConnections()
        }
        .onDisappear { ui.promptUndo = [:] }
        .frame(minWidth: SettingsWindowSize.minimum.width, minHeight: SettingsWindowSize.minimum.height)
        .background(Theme.panel)
        .foregroundStyle(Theme.ink)
        .ignoresSafeArea()
        .sheet(item: $editingVault) { vault in
            VaultEditor(vault: vault) { editingVault = nil }.environmentObject(engine)
        }
    }

    @ViewBuilder private var content: some View {
        if searching {
            Scrolling {
                SettingsSearchResults(ui: ui, results: results)
                    .padding(.horizontal, 36).padding(.vertical, 30)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        } else {
            page(ui.target)
        }
    }

    /// How far above a search result's row the page stops, so the row isn't flush with the edge.
    static let rowMargin: CGFloat = 12

    /// One page per section and per action type, each with its own scroll view.
    /// `.id(target)` builds it fresh when shown, so no offset carries over from another page.
    private func page(_ target: SettingsTarget) -> some View {
        let ui = ui
        return Scrolling {
            SettingsPage(ui: ui, target: target, editingVault: $editingVault, showAdvanced: $showAdvanced)
                .padding(.horizontal, SettingsPage.sidePadding).padding(.top, 30).padding(.bottom, 40)
                .frame(maxWidth: .infinity, alignment: .leading)
            // Rows report their distance from here: the top of the scroll view's document.
            .coordinateSpace(name: SettingsAnchor.space)
            .onPreferenceChange(SettingsAnchor.Positions.self) { positions in
                MainActor.assumeIsolated { ui.anchors[target] = positions }
            }
            .background(SettingsScrollProbe(scroller: scroller, page: target.id))
        }
        .onAppear { land() }
        .onChange(of: ui.scrollRequest) { land() }
        .id(target)
    }

    /// Scrolls the shown page to where it should open (see SettingsStore's scroll
    /// memory), then records the user's scrolling for the current page. Both the
    /// page being replaced and the new one may call this; the target decides.
    private func land() {
        let landing = ui.landing ?? ui.landing(for: ui.target)
        ui.landing = landing // nothing is recorded until the page is there
        let request = ui.scrollRequest
        let target = ui.target
        scroller.page = target.id
        scroller.onScroll = { [weak ui] y in ui?.remember(y) }
        if landing == .row(SettingsAnchor.key("Advanced")) { showAdvanced = true }
        // The page may have just been built: wait until its scroll view is in the
        // window and laid out, and a searched row has reported where it is (at most
        // about a second), then scroll.
        func attempt(_ tries: Int) {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.05) {
                guard ui.scrollRequest == request, ui.target == target else { return }
                guard let scroll = scroller.scrollView else {
                    if tries > 0 { attempt(tries - 1) } else { ui.landing = nil }
                    return
                }
                scroll.layoutSubtreeIfNeeded()
                switch landing {
                case .top:
                    scroller.set(0)
                case .offset(let y):
                    scroller.set(y)
                case .row(let key):
                    if let y = ui.anchors[target]?[key] {
                        scroller.set(y - Self.rowMargin)
                    } else if tries > 0 {
                        return attempt(tries - 1)
                    } else {
                        scroller.set(0) // a result without its own row (the section itself): the page's top
                    }
                }
                DispatchQueue.main.async {
                    guard ui.scrollRequest == request, ui.target == target else { return }
                    ui.landing = nil
                    if let y = scroller.offset { ui.remember(y) }
                }
            }
        }
        attempt(20)
    }
}

/// What one Settings page shows inside its scroll view: setup problems, then
/// the section's title and note and only that section's content (Advanced at
/// the end of its page), or an action type's page.
struct SettingsPage: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore
    let target: SettingsTarget
    @Binding var editingVault: VaultProfile?
    @Binding var showAdvanced: Bool

    /// The page's left and right padding inside the window's right column.
    static let sidePadding: CGFloat = 36

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            SettingsStatusBanner()
            if let typeID = target.actionType {
                ActionTypeSettingsPage(ui: ui, typeID: typeID, confirmingReset: ui.fixtureConfirmReset)
            } else {
                SettingsPageHeader(section: target.section)
                content(target.section)
                if target.section == .advancedHome { advanced.padding(.top, 8) }
            }
        }
    }

    @ViewBuilder private func content(_ section: SettingsSection) -> some View {
        switch section {
        case .vaults: VaultsSettings(editingVault: $editingVault)
        case .batching: BatchingSettings()
        case .sources: SourcesSettings()
        case .labels: LabelsSettings(notes: engine.notes)
        case .askHistory: AskHistorySettings(notes: engine.notes)
        case .shortcuts: ShortcutsSettingsSection()
        case .runners: RunnersSettings(notes: engine.notes)
        case .models: TaskDefaultsSettings(notes: engine.notes)
        case .actions: ActionsSettings(ui: ui, notes: engine.notes)
        case .todo: TodoDefaultsSettings()
        case .connections: ConnectionsSettings(ui: ui)
        }
    }

    // MARK: Advanced (end of the AI runners page)

    private var advanced: some View {
        DisclosureGroup(isExpanded: $showAdvanced) {
            AdvancedSettings().padding(.top, 12)
        } label: {
            Text("Advanced").font(Theme.body(14, .bold))
        }
        .tint(Theme.primary)
        .settingsAnchor("Advanced")
    }
}


/// The page header (canvas `sh1`): the section's title and its note.
struct SettingsPageHeader: View {
    let section: SettingsSection

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(section.title).font(Theme.display(26))
            Text(section.note).font(Theme.body(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }
}

/// Setup problems or an unreachable core, at the top of every page.
struct SettingsStatusBanner: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        let problems = engine.problems
        if case .unreachable(let problem) = engine.connection {
            VStack(alignment: .leading, spacing: 8) {
                Label(problem, systemImage: "bolt.horizontal.circle.fill")
                    .font(Theme.body(13)).foregroundStyle(Theme.peachInk).textSelection(.enabled)
                SoftButton(title: "Retry", fill: .white, size: .small, stroke: true) { engine.connect() }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF4EE)))
        } else if !problems.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                ForEach(problems, id: \.description) { problem in
                    Label(problem.description, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.body(13)).foregroundStyle(Theme.peachInk)
                }
            }
            .padding(14)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFFF4EE)))
        }
    }
}

/// A calm note for a section an older core can't serve yet.
struct CoreUpdateNote: View {
    let text: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 8) {
            Image(systemName: "arrow.down.circle").foregroundStyle(Theme.muted)
            Text(text).font(Theme.body(12)).foregroundStyle(Color(hex: 0x48463F))
                .fixedSize(horizontal: false, vertical: true)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }
}

// MARK: Vaults

struct VaultsSettings: View {
    @EnvironmentObject var engine: AppModel
    @Binding var editingVault: VaultProfile?

    var body: some View {
        LazyVGrid(columns: Array(repeating: GridItem(.flexible(), spacing: 12), count: 3), spacing: 12) {
            ForEach(engine.settings.vaults) { vault in
                let active = vault.path == engine.activeVault?.path
                let chip = VaultChip.colors(for: vault)
                Button { engine.settings.activeVaultPath = vault.path } label: {
                    VStack(alignment: .leading, spacing: 12) {
                        HStack {
                            Tile(text: String(vault.name.prefix(1)).uppercased(), fill: chip.0, ink: chip.1, size: 34, display: true)
                            Spacer()
                            if !VaultProfile.isVault(vault.path) {
                                Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(Theme.peachInk)
                                    .help("Missing .claude-obsidian.json")
                                    .padding(.trailing, 30) // clear of the edit button
                            }
                        }
                        VStack(alignment: .leading, spacing: 3) {
                            Text(vault.name).font(Theme.body(14, .semibold))
                            Text(queueLabel(vault)).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                        }
                    }
                    .padding(16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .card(18, selected: active)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .contextMenu {
                    Button("Edit…") { editingVault = vault }
                    Button("Remove", role: .destructive) { engine.settings.removeVault(vault.path) }
                }
                .overlay(alignment: .topTrailing) {
                    IconButton(systemImage: "ellipsis", size: 28, iconSize: 13, weight: .regular, help: "Edit vault") { editingVault = vault }
                        .padding(8)
                }
            }
            Button { VaultPicker.addVault(engine: engine) } label: {
                VStack(spacing: 4) {
                    Image(systemName: "plus").font(.system(size: 18))
                    Text("Add vault").font(Theme.body(13, .semibold))
                }
                .foregroundStyle(Theme.primary)
                .frame(maxWidth: .infinity, minHeight: 112)
                .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color(hex: 0xD6D3CC), style: StrokeStyle(lineWidth: 1.5, dash: [6, 5])))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    private func queueLabel(_ vault: VaultProfile) -> String {
        vault.queueURL.standardizedFileURL.path == vault.inboxURL.standardizedFileURL.path
            ? "Queue: vault inbox"
            : "Queue: \(vault.queueURL.lastPathComponent)"
    }
}

// MARK: Batching

struct BatchingSettings: View {
    @EnvironmentObject var engine: AppModel

    private let presets: [(String, Int)] = [("5 min", 5), ("15 min", 15), ("1 hour", 60), ("Daily", 1440)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            SettingsRow(title: "Batch every", note: "Automatic: runs on this schedule. Off: only when you press Process now.", bold: true) {
                PillSwitch(isOn: $engine.settings.autoProcessEnabled, label: "Automatic batching")
            }
            HStack(spacing: 12) {
                IntervalCounter(label: "days", value: intervalPart(.days), range: BatchInterval.Part.days.range)
                IntervalCounter(label: "hours", value: intervalPart(.hours), range: BatchInterval.Part.hours.range)
                IntervalCounter(label: "minutes", value: intervalPart(.minutes), range: BatchInterval.Part.minutes.range)
            }
            HStack(spacing: 8) {
                ForEach(presets, id: \.1) { preset in
                    chip(preset.0, selected: engine.settings.batchIntervalMinutes == preset.1) {
                        engine.settings.batchIntervalMinutes = preset.1
                    }
                }
                if !presets.contains(where: { $0.1 == engine.settings.batchIntervalMinutes }) {
                    chip(BatchInterval(totalMinutes: engine.settings.batchIntervalMinutes).description, selected: true) {}
                }
            }
            // The two counters sit beside the text when it keeps 240 pt; below it otherwise.
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 12) {
                    settleText.frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
                    settleCounters
                }
                VStack(alignment: .leading, spacing: 10) {
                    settleText
                    settleCounters
                }
            }
            .padding(.top, 6)
            .settingsAnchor("Wait before picking up a file")
            HStack(spacing: 8) {
                ForEach(SettleWait.presets, id: \.1) { preset in
                    chip(preset.0, selected: SettleWait.clamp(engine.settings.settleSeconds) == preset.1) {
                        engine.settings.settleSeconds = preset.1
                    }
                }
            }
            Text("Text files also wait for their labels: a batch takes a file once its labels are suggested, confirmed or come from its own tags. PDFs and images don’t wait, and neither does anything when “Suggest labels for queue files” is off.")
                .font(Theme.body(11)).foregroundStyle(Theme.faint).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
            // The queue check (v5): the core rescans the queue folder this often; Off leaves Refresh and the window check.
            SettingsRow(title: "Check the queue folder for changes",
                        note: "Finds files and folders added outside Distill (Finder, sync apps). Refresh on the Queue checks at once.", bold: true) {
                DropdownButton(title: QueueScanInterval.label(engine.settings.resolvedQueueScanMinutes), height: 30) {
                    ForEach(QueueScanInterval.options, id: \.self) { minutes in
                        Button(QueueScanInterval.label(minutes) + (minutes == 0 ? " (only Refresh and when the window opens)" : "")) {
                            engine.settings.queueScanMinutes = minutes
                        }
                    }
                }
                .fixedSize()
                .accessibilityLabel("Check the queue folder for changes")
            }
            .padding(.top, 6)
        }
    }

    private var settleText: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("Wait before picking up a file").font(Theme.body(13, .semibold))
            Text("A file must stay unchanged this long before a batch takes it. 0 = no wait. Up to 24 hours. Process now ignores it.")
                .font(Theme.body(11)).foregroundStyle(Theme.muted).lineSpacing(2)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private var settleCounters: some View {
        HStack(spacing: 12) {
            IntervalCounter(label: "hours", value: settlePart(\.hours), range: SettleWait.hoursRange, compact: true)
                .frame(width: 170)
            IntervalCounter(label: "minutes", value: settlePart(\.minutes), range: SettleWait.minutesRange, compact: true)
                .frame(width: 170)
        }
    }

    private func settlePart(_ part: WritableKeyPath<SettleWait, Int>) -> Binding<Int> {
        Binding(
            get: { SettleWait(totalSeconds: engine.settings.settleSeconds)[keyPath: part] },
            set: { value in
                var wait = SettleWait(totalSeconds: engine.settings.settleSeconds)
                wait[keyPath: part] = value
                engine.settings.settleSeconds = wait.totalSeconds
            })
    }

    private func chip(_ title: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.body(13, .semibold))
                .padding(.horizontal, 14).frame(height: 30)
                .foregroundStyle(selected ? Color.white : Theme.ink)
                .background(Capsule().fill(selected ? Theme.primary : Theme.panel))
        }
        .buttonStyle(.plain)
    }

    private func intervalPart(_ part: BatchInterval.Part) -> Binding<Int> {
        Binding(
            get: { BatchInterval(totalMinutes: engine.settings.batchIntervalMinutes)[part] },
            set: { value in
                var interval = BatchInterval(totalMinutes: engine.settings.batchIntervalMinutes)
                interval[part] = value
                engine.settings.batchIntervalMinutes = interval.totalMinutes
            })
    }
}

// MARK: Advanced

struct AdvancedSettings: View {
    @EnvironmentObject var engine: AppModel
    @State private var extraTools = ""

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            LabeledField(title: "Specific model") {
                Picker("", selection: $engine.settings.model) {
                    ForEach(ModelChoice.presets, id: \.id) { Text($0.label).tag($0.id) }
                    if !ModelChoice.presets.contains(where: { $0.id == engine.settings.model }) {
                        Text(engine.settings.model).tag(engine.settings.model)
                    }
                }
                .labelsHidden()
            }
            LabeledField(title: "Custom model ID") { TextField("", text: $engine.settings.model).textFieldStyle(.roundedBorder) }
            PathField(title: "claude CLI", path: $engine.settings.claudePath, directory: false)
            PathField(title: "python3", path: $engine.settings.pythonPath, directory: false)
            PathField(title: "node (empty = find it: nvm, Homebrew, /usr/local, /usr/bin)", path: nodePath, directory: false)
            PathField(title: "Product root", path: $engine.settings.productRoot, directory: true)
            LabeledField(title: "Extra allowed tools (one rule per line)") {
                TextEditor(text: $extraTools)
                    .font(.system(size: 12, design: .monospaced))
                    .frame(minHeight: 60)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                    .onAppear { extraTools = engine.settings.extraAllowedTools.joined(separator: "\n") }
                    .onChange(of: extraTools) {
                        engine.settings.extraAllowedTools = extraTools
                            .split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
                    }
            }
        }
    }

    private var nodePath: Binding<String> {
        Binding(get: { engine.settings.nodePath ?? "" },
                set: { engine.settings.nodePath = $0.trimmingCharacters(in: .whitespaces).isEmpty ? nil : $0 })
    }
}

/// −  N  + counter for one unit of the batch interval.
struct IntervalCounter: View {
    let label: String
    @Binding var value: Int
    let range: ClosedRange<Int>
    /// Smaller variant (the settle wait row).
    var compact = false
    @Environment(\.snapshotMode) private var snapshot

    var body: some View {
        HStack(spacing: 6) {
            round("minus") { value = max(range.lowerBound, value - 1) }
            VStack(spacing: 1) {
                if snapshot {
                    Text("\(value)").font(Theme.display(compact ? 22 : 28)).frame(width: compact ? 44 : 56)
                } else {
                    TextField("", value: $value, format: .number)
                        .textFieldStyle(.plain)
                        .multilineTextAlignment(.center)
                        .font(Theme.display(compact ? 22 : 28))
                        .frame(width: compact ? 44 : 56)
                }
                Text(label).font(Theme.body(compact ? 11 : 12)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity)
            round("plus") { value = min(range.upperBound, value + 1) }
        }
        .padding(compact ? 8 : 10)
        .background(RoundedRectangle(cornerRadius: compact ? 14 : 16).fill(Theme.panel))
    }

    private func round(_ icon: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: icon).font(.system(size: compact ? 11 : 12, weight: .bold))
                .frame(width: compact ? 28 : 32, height: compact ? 28 : 32)
                .background(Circle().fill(Color.white).shadow(color: .black.opacity(0.1), radius: 1, y: 1))
        }
        .buttonStyle(.plain)
        .accessibilityLabel(icon == "plus" ? "More \(label)" : "Fewer \(label)")
    }
}

struct LabeledField<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title).font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
            content
        }
    }
}

struct PathField: View {
    let title: String
    @Binding var path: String
    let directory: Bool

    var body: some View {
        LabeledField(title: title) {
            HStack {
                TextField("", text: $path).textFieldStyle(.roundedBorder)
                Button("Choose…") {
                    let panel = NSOpenPanel()
                    panel.canChooseDirectories = directory
                    panel.canChooseFiles = !directory
                    panel.showsHiddenFiles = true
                    if panel.runModal() == .OK, let url = panel.url { path = url.path }
                }
            }
        }
    }
}

struct VaultEditor: View {
    @EnvironmentObject var engine: AppModel
    @State var vault: VaultProfile
    var done: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            Text(vault.name).font(Theme.display(22))
            Text(vault.path).font(Theme.body(12)).foregroundStyle(Theme.muted).textSelection(.enabled)
            LabeledField(title: "Queue folder") {
                HStack {
                    Text(vault.queueDirectory).font(Theme.body(12)).lineLimit(1).truncationMode(.middle)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Button("Change…") {
                        if let url = VaultPicker.chooseDirectory(title: "Choose the queue folder for \(vault.name)") {
                            vault.queueDirectory = url.standardizedFileURL.path
                        }
                    }
                }
            }
            Button { vault.queueDirectory = vault.inboxURL.path } label: {
                Text("Use the vault's inbox/ as the queue").font(Theme.body(13, .semibold)).foregroundStyle(Theme.primary)
            }
            .buttonStyle(.plain)
            HStack {
                Button("Remove vault", role: .destructive) {
                    engine.settings.vaults.removeAll { $0.path == vault.path }
                    if engine.settings.activeVaultPath == vault.path {
                        engine.settings.activeVaultPath = engine.settings.vaults.first?.path
                    }
                    done()
                }
                .buttonStyle(.plain).foregroundStyle(Theme.peachInk)
                Spacer()
                SoftButton(title: "Cancel", action: done)
                PrimaryButton(title: "Save") { engine.settings.upsert(vault); done() }
            }
        }
        .padding(28)
        .frame(width: 480)
        .foregroundStyle(Theme.ink)
    }
}
