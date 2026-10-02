import AppKit
import SwiftUI
import DistillKit

// v2 sections of the Settings window (canvas: "Settings"): Sources, Labels,
// Ask history, Keyboard shortcuts, AI runners, Default model for each task.
// Each edit changes `engine.settings`; AppModel sends the changed top-level
// key to the core about 0.5 s later.

/// Section heading with an inline note.
struct SettingsHeading: View {
    let title: String
    var note: String? = nil

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(title).font(Theme.body(14, .bold))
            if let note { Text(note).font(Theme.body(12)).foregroundStyle(Theme.muted) }
        }
    }
}

/// Title + note on the left, a control on the right.
struct SettingsRow<Control: View>: View {
    let title: String
    var note: String? = nil
    var bold = false
    @ViewBuilder var control: Control

    var body: some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(13, bold ? .semibold : .regular))
                if let note {
                    Text(note).font(Theme.body(11)).foregroundStyle(Theme.muted).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            control
        }
    }
}

// MARK: Sources

struct SourcesSettings: View {
    @EnvironmentObject var engine: AppModel
    @State private var addingTo: String?
    @State private var newGroup = false

    private let inks: [Color] = [Theme.primary, Theme.limeInk, Theme.peachInk, Theme.pinkInk, Theme.skyInk]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 8) {
                let groups = SettingsEdits.taxonomy(engine.settings)
                ForEach(Array(groups.enumerated()), id: \.element.id) { index, group in
                    FlowRow(spacing: 8) {
                        Text(group.label).font(Theme.body(13, .bold)).foregroundStyle(inks[index % inks.count])
                            .frame(width: 92, height: 26, alignment: .leading)
                            .contextMenu {
                                Button("Remove group “\(group.label)”", role: .destructive) {
                                    SettingsEdits.removeGroup(group.id, in: &engine.settings)
                                }
                            }
                        ForEach(group.sources, id: \.id) { source in
                            SourceChip(label: source.label) {
                                SettingsEdits.removeSource(source.id, fromGroup: group.id, in: &engine.settings)
                            }
                        }
                        if addingTo == group.id {
                            AddLabelField(placeholder: "New source", width: 120) { name in
                                SettingsEdits.addSource(name, toGroup: group.id, in: &engine.settings)
                                addingTo = nil
                                return true
                            }
                        } else {
                            Button("+ Add") { addingTo = group.id }
                                .buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                                .frame(height: 26).padding(.horizontal, 8)
                        }
                    }
                    .padding(.horizontal, 12).padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
                }
                if newGroup {
                    AddLabelField(placeholder: "Group name", width: 160, height: 28) { name in
                        SettingsEdits.addGroup(name, in: &engine.settings)
                        newGroup = false
                        return true
                    }
                } else {
                    Button("+ New group") { newGroup = true }
                        .buttonStyle(.plain).font(Theme.body(13, .semibold)).foregroundStyle(Theme.primary)
                        .frame(height: 28).padding(.horizontal, 4)
                }
            }
        }
    }
}

private struct SourceChip: View {
    let label: String
    let remove: () -> Void
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 4) {
            Text(label).font(Theme.body(12, .semibold))
            if hovering {
                Button(action: remove) { Text("×").font(Theme.body(13)).foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain).accessibilityLabel("Remove \(label)")
            }
        }
        .padding(.horizontal, 10).frame(height: 26)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().strokeBorder(Theme.border))
        .onHover { hovering = $0 }
        .contextMenu { Button("Remove “\(label)”", role: .destructive, action: remove) }
    }
}

// MARK: Labels

struct LabelsSettings: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var notes: NotesStore
    @AppStorage(AppModel.suggestAfterQueueKey) private var suggestAfterQueue = true

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            FlowRow(spacing: 8) {
                ForEach(notes.labelCounts.sorted { $0.count > $1.count }.prefix(24), id: \.name) { label in
                    HStack(spacing: 6) {
                        Text("#\(label.name)").font(Theme.body(12, .semibold))
                        Text("\(label.count)").font(Theme.body(12, .medium)).foregroundStyle(Theme.faint)
                    }
                    .padding(.horizontal, 11).frame(height: 28)
                    .background(Capsule().fill(Color.white))
                    .overlay(Capsule().strokeBorder(Theme.border))
                }
                if notes.labelCounts.isEmpty {
                    Text(engine.isConnected ? "No labels in this vault yet." : "Labels appear once the core is connected.")
                        .font(Theme.body(12)).foregroundStyle(Theme.faint)
                }
            }
            SettingsRow(title: "Suggest labels after a note is queued") {
                HStack(spacing: 10) {
                    HStack(spacing: 6) {
                        Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.skyInk)
                            .frame(width: 18, height: 18).background(Circle().fill(Theme.skyTint))
                        Text("Uses “Label suggestions” default").font(Theme.body(12, .bold))
                    }
                    .padding(.leading, 6).padding(.trailing, 10).frame(height: 28)
                    .background(Capsule().fill(Color.white)).overlay(Capsule().strokeBorder(Theme.border))
                    .help("Set it under Default model for each task")
                    PillSwitch(isOn: $suggestAfterQueue, label: "Suggest labels")
                }
            }
            SettingsRow(title: "When Ask is limited to several labels, use notes with",
                        note: "The default for new chats. You can switch it per question in Ask.") {
                SegmentedPills(options: [(LabelMatch.any, "Any label"), (LabelMatch.all, "All labels")],
                               selection: Binding(get: { SettingsEdits.labelMatch(engine.settings) },
                                                  set: { v in SettingsEdits.setAsk(&engine.settings) { $0.labelMatch = v } }))
                    .fixedSize()
            }
            SettingsRow(title: "Include notes whose labels aren't confirmed yet",
                        note: "AI-applied labels still in Labels → To review. The default for new chats; switch it per question in Ask.") {
                PillSwitch(isOn: Binding(get: { SettingsEdits.includeUnconfirmed(engine.settings) },
                                         set: { v in SettingsEdits.setAsk(&engine.settings) { $0.includeUnconfirmed = v } }),
                           label: "Include unconfirmed labels by default")
            }
            VStack(alignment: .leading, spacing: 0) {
                SettingsRow(title: "In Distill: ask me to confirm",
                            note: "Notes written here show suggestions after Add to queue. Nothing is applied until you accept.", bold: true) {
                    Pill(text: "Always", fill: Theme.primaryTint, ink: Theme.primary)
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider().overlay(Theme.border)
                SettingsRow(title: "Queue folder: label automatically",
                            note: "Files dropped straight into the folder get AI labels, marked To review in Labels.", bold: true) {
                    PillSwitch(isOn: Binding(get: { SettingsEdits.autoLabelQueueFolder(engine.settings) },
                                             set: { SettingsEdits.setLabeling(&engine.settings, autoLabelQueueFolder: $0) }),
                               label: "Auto-label queue folder files")
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                Divider().overlay(Theme.border)
                SettingsRow(title: "CLI: use AI labels if none are sent back",
                            note: "The CLI returns suggestions and a request ID. If no labels arrive before the batch runs, the AI labels apply, marked To review.",
                            bold: true) {
                    PillSwitch(isOn: Binding(get: { SettingsEdits.cliFallbackToAI(engine.settings) },
                                             set: { SettingsEdits.setLabeling(&engine.settings, cliFallbackToAI: $0) }),
                               label: "Fall back to AI labels for CLI notes")
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        }
    }
}

// MARK: Ask history

struct AskHistorySettings: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var notes: NotesStore
    @State private var confirmClear = false

    var body: some View {
        let days = SettingsEdits.historyDays(engine.settings)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 12) {
                Text("Keep Ask history").font(Theme.body(13, .semibold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Keep").font(Theme.body(13)).foregroundStyle(Theme.muted)
                PillSwitch(isOn: Binding(get: { SettingsEdits.keepHistory(engine.settings) },
                                         set: { v in SettingsEdits.setAsk(&engine.settings) { $0.keepHistory = v } }),
                           label: "Keep Ask history")
            }
            HStack(spacing: 12) {
                IntervalCounter(label: "days", value: Binding(get: { days },
                                                              set: { v in SettingsEdits.setAsk(&engine.settings) { $0.historyDays = max(1, v) } }),
                                range: 1...365)
                    .frame(width: 220)
                VStack(alignment: .leading, spacing: 4) {
                    Text("Chats older than \(days) \(days == 1 ? "day" : "days") are deleted, counted from the last message. Pinned chats are kept. Turning Keep off deletes each chat when you close it.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted).lineSpacing(2)
                        .fixedSize(horizontal: false, vertical: true)
                    if let message = notes.historyMessage {
                        Text(message).font(Theme.body(11, .semibold)).foregroundStyle(Theme.limeInk)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                SmallButton(title: notes.clearingHistory ? "Clearing…" : "Clear now", ink: Theme.peachInk, height: 32, weight: .bold) {
                    confirmClear = true
                }
                .disabled(notes.clearingHistory || !engine.isConnected)
                .confirmationDialog("Delete every Ask chat that is not pinned?", isPresented: $confirmClear) {
                    Button("Delete chats", role: .destructive) { engine.clearAskHistory() }
                }
            }
        }
    }
}

// MARK: Keyboard shortcuts

struct ShortcutsSettingsSection: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 0) {
                row(.ask, "Ask a question", "Opens the quick-ask window by the flask", "bubble.left", Theme.primaryTint, Theme.primary)
                Divider().overlay(Theme.border)
                row(.addNote, "Add a note", "Opens the quick-note window by the flask", "plus", Theme.limeTint, Theme.limeInk)
            }
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        }
    }

    private func row(_ action: ShortcutAction, _ title: String, _ note: String, _ icon: String, _ tint: Color, _ ink: Color) -> some View {
        HStack(spacing: 12) {
            Image(systemName: icon).font(.system(size: 12, weight: .bold)).foregroundStyle(ink)
                .frame(width: 30, height: 30).background(Circle().fill(tint))
            VStack(alignment: .leading, spacing: 2) {
                Text(title).font(Theme.body(13, .semibold))
                Text(note).font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            ShortcutRecorder(shortcut: Binding(get: { SettingsEdits.shortcut(action, in: engine.settings) },
                                               set: { SettingsEdits.setShortcut(action, $0, in: &engine.settings) }),
                             label: title)
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }
}

/// "Record shortcut" → "Press keys…" → "⌃⌥N" with × to clear. Esc cancels.
struct ShortcutRecorder: View {
    @Binding var shortcut: KeyShortcut?
    let label: String
    @State private var recording: Bool
    @State private var monitor: Any?
    @State private var hint: String?

    /// `recording` / `hint` start set only in snapshots (no key monitor is installed).
    init(shortcut: Binding<KeyShortcut?>, label: String, recording: Bool = false, hint: String? = nil) {
        _shortcut = shortcut
        self.label = label
        _recording = State(initialValue: recording)
        _hint = State(initialValue: hint)
    }

    var body: some View {
        HStack(spacing: 4) {
            Button { recording ? stop() : start() } label: {
                Text(title).font(Theme.body(12, .semibold)).lineLimit(1)
                    .frame(minWidth: 126).padding(.horizontal, 12).frame(height: 32)
                    .foregroundStyle(recording ? Theme.primary : shortcut == nil ? Theme.muted : Theme.ink)
                    .background(RoundedRectangle(cornerRadius: 10).fill(recording ? Theme.primaryTint : Color.white))
                    .overlay(border)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(hint ?? "Click, then press the keys (with ⌃, ⌥ or ⌘). Esc cancels.")
            Button { shortcut = nil; stop() } label: {
                Text("×").font(Theme.body(14)).foregroundStyle(Theme.faint).frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .opacity(shortcut == nil || recording ? 0 : 1)
            .disabled(shortcut == nil || recording)
            .accessibilityLabel("Clear \(label) shortcut")
        }
        .onDisappear(perform: stop)
    }

    private var title: String {
        if recording { return hint ?? "Press keys…" }
        return shortcut?.displayString ?? "Record shortcut"
    }

    @ViewBuilder private var border: some View {
        if recording {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.primary, lineWidth: 2)
        } else if shortcut == nil {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Color(hex: 0xD6D3CC), style: StrokeStyle(lineWidth: 1.5, dash: [5, 4]))
        } else {
            RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border)
        }
    }

    private func start() {
        recording = true
        hint = nil
        GlobalShortcuts.shared.suspended = true
        monitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            if event.keyCode == 53 && event.modifierFlags.intersection([.command, .control, .option]).isEmpty { // Esc
                stop()
                return nil
            }
            if let recorded = KeyShortcut(event: event) {
                shortcut = recorded
                stop()
            } else {
                hint = "Add ⌃, ⌥ or ⌘"
            }
            return nil
        }
    }

    private func stop() {
        recording = false
        hint = nil
        if let monitor { NSEvent.removeMonitor(monitor) }
        monitor = nil
        GlobalShortcuts.shared.suspended = false
    }
}

// MARK: AI runners

struct RunnersSettings: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var notes: NotesStore
    @State private var setup: RunnerInfo?

    private let tints: [(Color, Color)] = [(Theme.peachTint, Theme.peachInk), (Theme.border, Color(hex: 0x48463F)),
                                           (Theme.primaryTint, Theme.primary), (Theme.limeTint, Theme.limeInk),
                                           (Theme.pinkTint, Theme.pinkInk)]

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if notes.runners.isEmpty {
                if notes.runnersLoading {
                    LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                        ForEach(0..<4, id: \.self) { _ in Shimmer(height: 58, radius: 16) }
                    }
                } else {
                    Text(engine.isConnected ? "This core lists no runners." : "Runners appear once the core is connected.")
                        .font(Theme.body(12)).foregroundStyle(Theme.faint)
                }
            } else {
                LazyVGrid(columns: [GridItem(.flexible(), spacing: 10), GridItem(.flexible())], spacing: 10) {
                    ForEach(Array(notes.runners.enumerated()), id: \.element.id) { index, runner in
                        card(runner, tint: tints[index % tints.count])
                    }
                }
            }
        }
        .sheet(item: $setup) { runner in
            RunnerSetupSheet(runnerID: runner.id, done: { setup = nil }).environmentObject(engine)
        }
    }

    private func enabled(_ r: RunnerInfo) -> Bool { engine.settings.enabledRunners.contains(r.id) }

    private func needsSetup(_ r: RunnerInfo) -> Bool { r.secrets.contains { !$0.isSet } }

    private func hasSetup(_ r: RunnerInfo) -> Bool { !r.secrets.isEmpty || !SettingsEdits.optionFields(for: r.id).isEmpty }

    private func note(_ r: RunnerInfo) -> String {
        let kind = r.kind == "agent" ? "Agent" : "Model API"
        if let busy = notes.runnerBusy[r.id] {
            return busy == "Saving…" ? "\(kind) · saving key to Keychain…" : "\(kind) · checking…"
        }
        if let secret = r.secrets.first(where: { !$0.isSet }) { return "\(kind) · needs \(secret.label.lowercased())" }
        if enabled(r), let problem = r.problems.first { return "\(kind) · \(problem.message)" }
        if r.id == "claude-code" { return "\(kind) · \(enabled(r) ? "ready" : "off") · \(abbreviate(engine.settings.claudePath))" }
        if r.id == "ai-sdk" { return "\(kind) · via local bridge" }
        return "\(kind) · \(enabled(r) ? "ready" : "off")"
    }

    private func abbreviate(_ path: String) -> String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        let p = path.isEmpty ? "~/.local/bin/claude" : path
        return p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    private func card(_ r: RunnerInfo, tint: (Color, Color)) -> some View {
        let on = enabled(r)
        let busy = notes.runnerBusy[r.id]
        return HStack(spacing: 12) {
            Text(monogram(r)).font(Theme.body(13, .heavy)).foregroundStyle(tint.1)
                .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 10).fill(tint.0))
            VStack(alignment: .leading, spacing: 2) {
                Text(r.displayName).font(Theme.body(13, .bold))
                Text(note(r)).font(Theme.body(11)).foregroundStyle(Theme.muted)
                    .lineLimit(2).truncationMode(.tail).fixedSize(horizontal: false, vertical: true)
                    .help(note(r))
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .layoutPriority(-1)
            if hasSetup(r) && !needsSetup(r) {
                IconButton(systemImage: "gearshape", size: 16, tint: Theme.faint, iconSize: 13, weight: .regular,
                           help: "Set up \(r.displayName)") { setup = r }
            }
            Button {
                if busy != nil { return }
                if !on && needsSetup(r) { setup = r } else { engine.setRunner(r.id, enabled: !on) }
            } label: {
                HStack(spacing: 5) {
                    if busy != nil { Spinner(color: Theme.muted, size: 10) }
                    Text(busy ?? (on ? "On" : needsSetup(r) ? "Set up" : "Turn on")).font(Theme.body(12, .bold))
                        .lineLimit(1).fixedSize()
                }
                .fixedSize()
                .padding(.horizontal, 11).frame(height: 28)
                .foregroundStyle(on && busy == nil ? Color.white : Theme.ink)
                .background(Capsule().fill(on && busy == nil ? Theme.primary : Theme.panel))
            }
            .buttonStyle(.plain)
            .help(on ? "Turn \(r.displayName) off" : "")
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(on ? Theme.primary : Theme.border, lineWidth: on ? 2 : 1))
    }

    private func monogram(_ r: RunnerInfo) -> String {
        switch r.id {
        case "claude-code": return "CC"
        case "codex": return "CX"
        case "openrouter": return "OR"
        case "openai": return "AI"
        case "ai-sdk": return "V"
        default: return String(r.displayName.prefix(2)).uppercased()
        }
    }
}

/// API keys (Keychain, through the core) and non-secret options for one runner.
struct RunnerSetupSheet: View {
    @EnvironmentObject var engine: AppModel
    let runnerID: String
    let done: () -> Void
    @State private var values: [String: String] = [:]
    @State private var errors: [String: String]
    @State private var saving: String?

    /// `saving` / `errors` start set only in snapshots.
    init(runnerID: String, done: @escaping () -> Void, saving: String? = nil, errors: [String: String] = [:]) {
        self.runnerID = runnerID
        self.done = done
        _saving = State(initialValue: saving)
        _errors = State(initialValue: errors)
    }

    private var runner: RunnerInfo? { engine.notes.runners.first { $0.id == runnerID } }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Set up \(runner?.displayName ?? runnerID)").font(Theme.display(22))
            if let runner {
                ForEach(runner.secrets, id: \.name) { secret in
                    LabeledField(title: secret.label + (secret.isSet ? " · saved in Keychain" : "")) {
                        HStack {
                            SecureField(secret.isSet ? "•••••••• (enter a new one to replace it)" : "Paste the key",
                                        text: Binding(get: { values[secret.name] ?? "" }, set: { values[secret.name] = $0 }))
                                .textFieldStyle(.roundedBorder)
                            Button(saving == secret.name ? "Saving…" : "Save") { save(secret.name, values[secret.name]) }
                                .disabled((values[secret.name] ?? "").trimmingCharacters(in: .whitespaces).isEmpty || saving != nil)
                            if secret.isSet {
                                Button("Remove") { save(secret.name, nil) }.disabled(saving != nil)
                            }
                        }
                    }
                    if let error = errors[secret.name] {
                        Text(error).font(Theme.body(12)).foregroundStyle(Theme.peachInk)
                    }
                }
                ForEach(SettingsEdits.optionFields(for: runnerID), id: \.name) { field in
                    LabeledField(title: field.label) {
                        TextField(field.placeholder, text: Binding(
                            get: { engine.settings.runnerOptions?[runnerID]?[field.name] ?? "" },
                            set: { SettingsEdits.setRunnerOption(runnerID, field.name, $0, in: &engine.settings) }))
                            .textFieldStyle(.roundedBorder)
                    }
                }
                ForEach(runner.problems, id: \.message) { problem in
                    Label(problem.message, systemImage: "exclamationmark.triangle.fill")
                        .font(Theme.body(12)).foregroundStyle(Theme.peachInk)
                }
            }
            HStack {
                Toggle("Use \(runner?.displayName ?? runnerID)", isOn: Binding(
                    get: { engine.settings.enabledRunners.contains(runnerID) },
                    set: { engine.setRunner(runnerID, enabled: $0) }))
                    .toggleStyle(.switch).tint(Theme.primary)
                Spacer()
                PrimaryButton(title: "Done") { values = [:]; done() }
            }
        }
        .padding(28)
        .frame(width: 480)
        .foregroundStyle(Theme.ink)
    }

    private func save(_ name: String, _ value: String?) {
        saving = name
        errors[name] = nil
        let trimmed = value?.trimmingCharacters(in: .whitespacesAndNewlines)
        engine.setRunnerSecret(runnerID: runnerID, name: name, value: trimmed) { error in
            saving = nil
            values[name] = nil // never keep the key around
            errors[name] = error
        }
    }
}

