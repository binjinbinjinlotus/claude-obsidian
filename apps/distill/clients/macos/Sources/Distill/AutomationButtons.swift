import AppKit
import SwiftUI
import DistillKit

// Automations on action items (action-buttons.md, canvas row 15, board ScriptActions): the buttons a type
// adds to an item's footer, the run sheet (preview → Run → live output), and the Last run block.

struct ButtonRunSheetState: Identifiable, Equatable {
    enum Phase: Equatable { case loading, confirm, starting, running, finished }
    var itemID: String
    var buttonID: String
    var label: String
    var runs: String
    var phase: Phase = .loading
    var preview: ActionButtonPreview?
    /// The first run of this button (or of a changed one): offer "Ask me every time".
    var firstRun = false
    var askEveryTime = true
    var runID: String?
    var message: String?
    var id: String { itemID + "/" + buttonID }
}

/// The button editor sheet: a type, the button (nil = a new one), the item its preview uses.
struct ButtonEditorTarget: Identifiable, Equatable {
    var typeID: String
    var button: AutomationButton?
    var itemID: String?
    var id: String { typeID + "/" + (button?.id ?? "new") }
}

extension ActionsStore {
    func buttonInfo(_ item: ActionItem, _ buttonID: String) -> ActionButtonInfo? {
        type(item.type)?.buttons.first { $0.id == buttonID }
    }

    /// Press: asks first (the sheet) when the button says so; otherwise starts, and opens the sheet only
    /// when the core says this exact command hasn't been approved.
    func press(_ item: ActionItem, _ info: ActionButtonInfo) {
        guard info.available else {
            // The automation's OK (or its fix) is on its page; the list may not be loaded yet.
            if engine?.collectors.phase == .idle { engine?.collectors.load() }
            engine?.activity.navigate = .collector(id: info.button.scriptId, runs: false)
            return
        }
        let runs = [info.scriptName, info.commandLabel].compactMap { $0 }.joined(separator: " › ")
        if info.button.confirm {
            openSheet(ButtonRunSheetState(itemID: item.id, buttonID: info.id, label: info.button.label, runs: runs))
            return
        }
        startButton(item.id, info.id, label: info.button.label, runs: runs, approve: false)
    }

    private func openSheet(_ state: ButtonRunSheetState) {
        buttonSheet = state
        guard let client else { return }
        Task {
            do {
                let preview = try await client.previewActionButton(state.itemID, button: state.buttonID)
                guard buttonSheet?.id == state.id else { return }
                buttonSheet?.preview = preview
                buttonSheet?.firstRun = preview.needsApproval
                buttonSheet?.phase = .confirm
            } catch {
                buttonSheet?.phase = .confirm
                buttonSheet?.message = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
            }
        }
    }

    func startButton(_ itemID: String, _ buttonID: String, label: String, runs: String, approve: Bool) {
        guard let client else { engine?.lastError = "The Distill core is not connected."; return }
        let key = itemID + "/" + buttonID
        buttonStarting.insert(key)
        if approve { buttonSheet?.phase = .starting }
        Task {
            defer { buttonStarting.remove(key) }
            do {
                let item = try await client.runActionButton(itemID, button: buttonID, approve: approve)
                items[item.id] = item
                if buttonSheet?.id == key {
                    buttonSheet?.runID = item.activeRun?.runId
                    buttonSheet?.phase = item.activeRun == nil ? .finished : .running
                }
            } catch let refusal as ActionButtonRefusal {
                if refusal.needsConsent {
                    buttonSheet = nil
                    show(ActionToast(text: "\(runs.isEmpty ? "The automation" : runs) needs your OK first."))
                    if let id = type(items[itemID]?.type ?? "")?.buttons.first(where: { $0.id == buttonID })?.button.scriptId {
                        engine?.activity.navigate = .collector(id: id, runs: false)
                    }
                } else {
                    var state = buttonSheet?.id == key ? buttonSheet! : ButtonRunSheetState(itemID: itemID, buttonID: buttonID, label: label, runs: runs)
                    state.preview = refusal.preview ?? state.preview
                    state.firstRun = true
                    state.phase = .confirm
                    buttonSheet = state
                }
            } catch {
                if buttonSheet?.id == key {
                    buttonSheet?.phase = .confirm
                    buttonSheet?.message = (error as? CustomStringConvertible)?.description ?? error.localizedDescription
                } else {
                    engine?.report(error)
                }
            }
        }
    }

    /// Run from the sheet: approves this exact command; "Ask me every time" off saves confirm: false.
    func runFromSheet() {
        guard let s = buttonSheet else { return }
        if s.firstRun && !s.askEveryTime, let item = items[s.itemID] { setButtonConfirm(type: item.type, buttonID: s.buttonID, false) }
        buttonSheet?.message = nil
        startButton(s.itemID, s.buttonID, label: s.label, runs: s.runs, approve: true)
    }

    func stopButton(_ itemID: String) {
        guard let client else { return }
        Task { do { try await client.stopActionButtonRun(itemID) } catch { engine?.report(error) } }
    }

    func setButtonConfirm(type typeID: String, buttonID: String, _ on: Bool) {
        guard let engine else { return }
        SettingsEdits.setActions(&engine.settings) { prefs in
            var list = prefs.buttons(typeID)
            if let i = list.firstIndex(where: { $0.id == buttonID }) { list[i].confirm = on; prefs.setButtons(typeID, list) }
        }
    }
}

// MARK: - Footer buttons

/// The custom buttons on an item's footer: `primary` ones as soft buttons, `more` in a ⋯ menu, and a quiet
/// ＋ Button that opens the editor. The `send` slot is drawn by the card (it replaces Send in Slack).
struct ItemAutomationButtons: View {
    @ObservedObject var store: ActionsStore
    let type: ActionTypeInfo
    let item: ActionItem
    var showAdd = true

    var body: some View {
        let slots = AutomationText.slots(type.buttons, for: item)
        HStack(spacing: 8) {
            ForEach(slots.primary) { info in AutomationItemButton(store: store, item: item, info: info, primary: false) }
            if !slots.more.isEmpty {
                Menu {
                    ForEach(slots.more) { info in
                        Button(info.button.label) { store.press(item, info) }
                            .disabled(!info.available || item.activeRun != nil || store.slackBlock(item, info.button) != nil)
                    }
                } label: {
                    Image(systemName: "ellipsis").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.muted)
                        .frame(width: 30, height: 30).background(Circle().fill(Theme.panel))
                }
                .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
                .help("More buttons")
            }
            if showAdd {
                Button { store.buttonEditor = ButtonEditorTarget(typeID: type.id, button: nil, itemID: item.id) } label: {
                    Text("＋ Button").font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 10).frame(height: 26)
                        .overlay(Capsule().strokeBorder(Theme.border, style: StrokeStyle(lineWidth: 1, dash: [3, 3])))
                }
                .buttonStyle(.plain).fixedSize()
                .help("Add a button that runs an automation")
            }
        }
    }
}

/// One custom button: a spinner while its run starts or runs; the reason as its tooltip when it can't run.
struct AutomationItemButton: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    let info: ActionButtonInfo
    var primary: Bool

    var body: some View {
        let running = item.activeRun?.buttonId == info.id || store.buttonStarting.contains(item.id + "/" + info.id)
        let busy = item.activeRun != nil
        // A Slack message whose To row doesn't resolve: off, with the reason (the core refuses it too).
        let blocked = running ? nil : store.slackBlock(item, info.button)
        let icon = running ? nil : (info.button.icon ?? (primary ? "paperplane" : "play"))
        Group {
            if primary {
                PrimaryButton(title: running ? "Running…" : info.button.label, systemImage: icon, size: .small, enabled: (!busy || running) && blocked == nil) {
                    if !running { store.press(item, info) }
                }
            } else {
                SoftButton(title: running ? "Running…" : info.button.label, size: .small, stroke: true, systemImage: icon) {
                    if !running { store.press(item, info) }
                }
                .disabled((busy && !running) || blocked != nil).opacity((busy && !running) || blocked != nil ? 0.45 : info.available ? 1 : 0.6)
            }
        }
        .fixedSize()
        .help(blocked ?? (info.available ? "Runs \([info.scriptName, info.commandLabel].compactMap { $0 }.joined(separator: " › "))" : (info.reason ?? "Can’t run now")))
        .contextMenu {
            Button("Edit button…") { store.buttonEditor = ButtonEditorTarget(typeID: item.type, button: info.button, itemID: item.id) }
        }
    }
}

// MARK: - Last run

/// Under the body: the newest run's label, result, exit, duration and time, its last 3 lines, and the stored key or URL.
struct ButtonLastRun: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let item: ActionItem

    var body: some View {
        if let run = item.runs.last {
            let live = item.activeRun?.runId == run.runId
            let lines = live ? AutomationText.lastLines(liveText(run.runId)) : AutomationText.lastLines(run.succeeded ? run.stdoutTail : (run.stderrTail ?? run.stdoutTail))
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 7) {
                    if live { Spinner(size: 11) } else {
                        Image(systemName: run.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                            .font(.system(size: 11)).foregroundStyle(run.succeeded ? Theme.limeInk : Theme.peachInk)
                    }
                    Text("LAST RUN").font(Theme.body(10.5, .heavy)).kerning(0.5).foregroundStyle(Theme.muted)
                    Text(AutomationText.runLine(run, time: ActionsClock.time(run.endedAt ?? run.startedAt)))
                        .font(Theme.body(11.5)).foregroundStyle(Theme.softInk).lineLimit(1)
                    Spacer(minLength: 4)
                    if live {
                        Button("Stop") { store.stopButton(item.id) }.buttonStyle(.plain).font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.peachInk)
                    }
                    Button("Show log") {
                        store.buttonSheet = ButtonRunSheetState(itemID: item.id, buttonID: run.buttonId, label: run.label, runs: "",
                                                                phase: live ? .running : .finished, runID: run.runId)
                    }
                    .buttonStyle(.plain).font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary)
                }
                if !lines.isEmpty {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { _, l in
                            Text(l).font(.system(size: 11, design: .monospaced)).foregroundStyle(run.succeeded || live ? Theme.softInk : Theme.peachInk)
                                .lineLimit(1).truncationMode(.tail)
                        }
                    }
                }
                if let key = run.externalKey ?? item.external?.key, run.succeeded {
                    HStack(spacing: 6) {
                        Text("Saved").font(Theme.body(11)).foregroundStyle(Theme.muted)
                        Text(key).font(.system(size: 11, design: .monospaced)).textSelection(.enabled)
                        if let url = run.externalURL, let u = URL(string: url) {
                            Button("Open") { NSWorkspace.shared.open(u) }.buttonStyle(.plain).font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary)
                        }
                    }
                }
            }
            .padding(10)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        }
    }

    private func liveText(_ runID: String) -> String {
        (engine.collectors.ordered[runID] ?? []).map(\.text).joined()
    }
}

// MARK: - Run sheet

/// Header (label, the item, Runs X › command), the command line and argv with any problems, Cancel and Run;
/// after Run the same sheet streams the output with Stop; a success closes after 1.5 s.
struct ButtonRunSheet: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let state: ButtonRunSheetState

    private var item: ActionItem? { store.items[state.itemID] }
    private var run: ActionButtonRun? {
        guard let item else { return nil }
        if let id = state.runID { return item.runs.first { $0.runId == id } }
        return nil
    }
    private var finished: Bool { state.phase == .finished || (state.phase == .running && item?.activeRun == nil && run != nil) }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if state.phase == .running || finished { output } else { preview }
            if let m = state.message {
                Text(m).font(Theme.body(12)).foregroundStyle(Theme.peachInk).fixedSize(horizontal: false, vertical: true)
            }
            footer
        }
        .padding(22)
        .frame(width: 560)
        .onChange(of: finished) { _, done in
            guard done, run?.succeeded == true, state.phase == .running else { return }
            Task {
                try? await Task.sleep(nanoseconds: 1_500_000_000)
                if store.buttonSheet?.id == state.id { store.buttonSheet = nil }
            }
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "play.fill").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.primary)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9).fill(Theme.primaryTint))
            VStack(alignment: .leading, spacing: 2) {
                Text(state.label).font(Theme.body(15, .bold))
                Text("for “\(item?.title ?? "")”").font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                if !state.runs.isEmpty { Text("Runs \(state.runs)").font(Theme.body(12)).foregroundStyle(Theme.muted) }
            }
        }
    }

    @ViewBuilder private var preview: some View {
        if let p = state.preview {
            VStack(alignment: .leading, spacing: 8) {
                Text(state.firstRun ? "First run: check the exact command." : "The command").font(Theme.body(12.5, .semibold))
                ScrollView {
                    Text(p.display).font(.system(size: 11.5, design: .monospaced)).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 120)
                .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
                DisclosureGroup("Each argument (\(p.argv.count))") {
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(Array(p.argv.enumerated()), id: \.offset) { i, a in
                            HStack(alignment: .top, spacing: 8) {
                                Text("\(i)").font(.system(size: 10.5, design: .monospaced)).foregroundStyle(Theme.faint).frame(width: 18, alignment: .trailing)
                                Text(a).font(.system(size: 11, design: .monospaced)).lineLimit(3).textSelection(.enabled)
                            }
                        }
                    }
                    .padding(.top, 4)
                }
                .font(Theme.body(12))
                ForEach(p.problems, id: \.self) { problem in
                    Label(problem, systemImage: "exclamationmark.triangle").font(Theme.body(12)).foregroundStyle(Theme.peachInk)
                }
                Text("Each argument is passed as it is, never through a shell.").font(Theme.body(11)).foregroundStyle(Theme.faint)
            }
        } else {
            HStack(spacing: 8) { Spinner(size: 14); Text("Building the command…").font(Theme.body(12)).foregroundStyle(Theme.muted) }
        }
    }

    private var output: some View {
        let chunks = state.runID.flatMap { engine.collectors.ordered[$0] } ?? []
        let saved = run.map { [($0.stdoutTail ?? "", "stdout"), ($0.stderrTail ?? "", "stderr")] } ?? []
        let lines: [(String, String)] = chunks.isEmpty
            ? saved.flatMap { text, stream in text.split(separator: "\n").map { (String($0), stream) } }
            : chunks.flatMap { c in c.text.split(separator: "\n").map { (String($0), c.stream) } }
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 7) {
                if finished, let run {
                    Image(systemName: run.succeeded ? "checkmark.circle.fill" : "xmark.circle.fill")
                        .foregroundStyle(run.succeeded ? Theme.limeInk : Theme.peachInk)
                    Text(AutomationText.runLine(run, time: ActionsClock.time(run.endedAt ?? run.startedAt))).font(Theme.body(12.5, .semibold))
                } else {
                    Spinner(size: 12)
                    Text("Running…").font(Theme.body(12.5, .semibold))
                }
            }
            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 1) {
                        ForEach(Array(lines.enumerated()), id: \.offset) { i, l in
                            Text(l.0).font(.system(size: 11, design: .monospaced))
                                .foregroundStyle(l.1 == "stderr" ? Theme.peachInk : Theme.ink)
                                .frame(maxWidth: .infinity, alignment: .leading).textSelection(.enabled).id(i)
                        }
                        if lines.isEmpty { Text("No output yet.").font(Theme.body(11.5)).foregroundStyle(Theme.faint) }
                    }
                }
                .onChange(of: lines.count) { _, n in if n > 0 { proxy.scrollTo(n - 1, anchor: .bottom) } }
            }
            .frame(height: 200)
            .padding(10).background(RoundedRectangle(cornerRadius: 9).fill(Theme.panel))
        }
    }

    private var footer: some View {
        HStack(spacing: 10) {
            if state.firstRun && !(state.phase == .running || finished) {
                Toggle("Ask me every time", isOn: Binding(get: { state.askEveryTime }, set: { store.buttonSheet?.askEveryTime = $0 }))
                    .toggleStyle(.checkbox).font(Theme.body(12))
            }
            Spacer()
            if state.phase == .running && !finished {
                ActionButton(title: "Stop", icon: "stop.fill", kind: .soft) { store.stopButton(state.itemID) }
                ActionButton(title: "Hide", kind: .plain) { store.buttonSheet = nil }
            } else if finished {
                if run?.succeeded == false, let item, let info = store.buttonInfo(item, state.buttonID) {
                    ActionButton(title: "Try again", icon: "arrow.clockwise", kind: .soft) {
                        store.buttonSheet = nil
                        store.press(item, info)
                    }
                }
                ActionButton(title: "Close", kind: .primary) { store.buttonSheet = nil }
                    .keyboardShortcut(.defaultAction)
            } else {
                ActionButton(title: "Cancel", kind: .plain) { store.buttonSheet = nil }
                    .keyboardShortcut(.cancelAction)
                let canRun = state.phase == .confirm && (state.preview?.problems.isEmpty ?? false)
                ActionButton(title: state.phase == .starting ? "Starting…" : "Run", icon: "play.fill", kind: .primary) { store.runFromSheet() }
                    .disabled(!canRun).opacity(canRun ? 1 : 0.45)
                    .keyboardShortcut(.defaultAction)
            }
        }
    }
}
