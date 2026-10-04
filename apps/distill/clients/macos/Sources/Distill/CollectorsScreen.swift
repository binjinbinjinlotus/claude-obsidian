import AppKit
import SwiftUI
import DistillKit

/// Sidebar section Collectors (canvas row 7, boards Collectors and
/// CollectorsScript): the header, the list plus the detail, the empty state and
/// the calm "Update the Distill core" state. Sheets are in CollectorsSheets.swift.
struct CollectorsScreen: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        CollectorsScreenContent(store: engine.collectors)
    }
}

private struct CollectorsScreenContent: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: CollectorsStore

    var body: some View {
        Group {
            switch store.phase {
            case .unavailable:
                ActionsEmpty(icon: "arrow.triangle.2.circlepath", title: "Update the Distill core",
                             message: "This core doesn't have Collectors yet. Update Distill (distill.sh update) and they show up here. Nothing else is affected.") {
                    EmptyView()
                }
            case .failed(let message):
                ActionsEmpty(icon: "exclamationmark.triangle", title: "Couldn't load collectors", message: message) {
                    ActionButton(title: "Try again", icon: "arrow.clockwise", kind: .primary) { store.load() }
                }
            case .idle, .loading:
                VStack(spacing: 0) {
                    header(add: false)
                    Spacer()
                    Spinner(size: 18)
                    Spacer()
                }
            case .loaded:
                if store.collectors.isEmpty {
                    VStack(spacing: 0) {
                        header(add: false)
                        CollectorsEmpty(store: store)
                        Spacer(minLength: 0)
                    }
                } else {
                    VStack(spacing: 0) {
                        header(add: true)
                        GeometryReader { geo in
                            // The list narrows in a small window so the detail keeps room (900 pt).
                            let listWidth: CGFloat = geo.size.width < 760 ? 240 : 300
                            HStack(alignment: .top, spacing: 24) {
                                CollectorList(store: store).frame(width: listWidth)
                                CollectorDetailPane(store: store).frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .padding(.leading, 20).padding(.trailing, 28).padding(.top, 20)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .onAppear {
            if store.phase == .idle { store.load() } else if let id = store.current?.id { store.refresh(id); store.loadRuns(id) }
        }
    }

    private func header(add: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Collectors").font(Theme.display(30)).lineLimit(1)
                Text(subtitle).font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if add {
                PrimaryButton(title: "Add collector", systemImage: "plus", size: .small) { store.startAdding() }
                    .fixedSize()
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .padding(.horizontal, 32).padding(.top, 30)
    }

    private var subtitle: String {
        if let v = engine.activeVault { return "Fill \(v.name)’s queue on a schedule." }
        return "Fill a vault’s queue on a schedule."
    }
}

// MARK: - List

private struct CollectorList: View {
    @ObservedObject var store: CollectorsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(spacing: 2) {
                ForEach(store.collectors) { c in
                    let kind = store.text.statusKind(c)
                    CollectorRow(kind: c.kind.rawValue, title: c.name,
                                 summary: store.text.rowSummary(c, now: store.now, run: store.activeRun(c)),
                                 status: store.text.pill(c) ?? "", statusKind: kind.rawValue,
                                 selected: c.id == store.current?.id,
                                 runEnabled: !c.needsConsent && !c.isRunning,
                                 onSelect: { store.select(c.id) },
                                 onRun: { store.runNow(c) }) {
                        CollectorMenuItems(store: store, collector: c)
                    }
                }
            }
            .padding(.bottom, 20)
        }
    }
}

/// ⋯: Edit, Rename, Duplicate, Show all runs, Turn on/off, Revoke (scripts), Delete.
struct CollectorMenuItems: View {
    @ObservedObject var store: CollectorsStore
    let collector: Collector

    var body: some View {
        Button("Edit settings") { store.startEdit(collector) }
        Button("Rename…") { store.select(collector.id); store.renaming = collector.name }
        Button("Duplicate") { store.duplicate(collector) }
        Button("Show all runs") { store.select(collector.id); store.page = .allRuns }
        if !collector.needsConsent {
            Button(collector.enabled ? "Turn off" : "Turn on") { store.setEnabled(collector, !collector.enabled) }
        }
        if collector.isScript, collector.script?.allowedSha256 != nil, !collector.needsConsent {
            Button("Revoke permission") { store.revoke(collector) }
        }
        Divider()
        Button("Delete collector…", role: .destructive) { store.select(collector.id); store.confirmDelete = collector.id }
            .disabled(collector.isRunning)
    }
}

// MARK: - Detail

struct CollectorDetailPane: View {
    @ObservedObject var store: CollectorsStore

    var body: some View {
        ScrollView(.vertical) {
            Group {
                if let c = store.current {
                    if store.page == .allRuns {
                        CollectorAllRuns(store: store, collector: c)
                    } else {
                        CollectorDetail(store: store, collector: c).id(c.id)
                    }
                }
            }
            .padding(.top, 8).padding(.leading, 10).padding(.trailing, 12).padding(.bottom, 24)
            .frame(maxWidth: .infinity, alignment: .topLeading)
        }
        .scrollIndicators(.automatic)
    }
}

struct CollectorDetail: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: CollectorsStore
    let collector: Collector
    @State private var showCode = false
    @State private var newName = ""

    private var c: Collector { collector }
    private var text: CollectorText { store.text }
    private var editing: Bool { store.editing != nil && store.current?.id == c.id }
    private var consentAsk: Bool { c.needsConsent && !text.scriptChanged(c) && !store.consentDeferred.contains(c.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 18) {
            titleRow
            if store.renaming != nil { renameRow }
            if store.confirmDelete == c.id { deleteRow }
            if c.needsConsent && store.consentDeferred.contains(c.id) {
                deferredConsent
            } else if c.needsConsent {
                consent
            } else if !editing {
                CollectorStatusCard(store: store, collector: c)
            }
            if consentAsk {
                whatWillRun
            } else if editing {
                CollectorEditForm(store: store, collector: c)
            } else {
                if text.scriptChanged(c), showCode { codeBlock(title: "WHAT WILL RUN") }
                settingsBlock
                if c.isScript { advanced }
                recentRuns
            }
        }
    }

    // MARK: Title row

    /// Name and controls on one row; in a narrow pane the controls move under the name instead of cutting it.
    private var titleRow: some View {
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 12) {
                tile
                nameBlock.fixedSize(horizontal: true, vertical: false)
                Spacer(minLength: 0)
                controls
            }
            VStack(alignment: .leading, spacing: 10) {
                HStack(spacing: 12) {
                    tile
                    nameBlock.frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 12) {
                    Spacer(minLength: 0)
                    controls
                }
            }
        }
    }

    private var tile: some View {
        let k = CollectorsTheme.kind(c.kind.rawValue)
        return Image(systemName: k.2).font(.system(size: 16, weight: .semibold)).foregroundStyle(k.1)
            .frame(width: 38, height: 38).background(RoundedRectangle(cornerRadius: 11).fill(k.0))
    }

    private var nameBlock: some View {
        VStack(alignment: .leading, spacing: 3) {
            Text(c.name).font(Theme.display(22)).lineLimit(1).truncationMode(.tail)
            Text(text.titleLine(c, now: store.now)).font(Theme.body(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }

    @ViewBuilder private var controls: some View {
        PillSwitch(isOn: Binding(get: { c.enabled && !c.needsConsent }, set: { store.setEnabled(c, $0) }), label: "Collector on", width: 36, height: 22)
            .disabled(c.needsConsent)
            .help(c.needsConsent ? "Allow the script first" : c.enabled ? "Turn off" : "Turn on")
        if !c.needsConsent && !editing {
            if c.isRunning {
                SoftButton(title: "Stop", fill: .white, size: .small, stroke: true, systemImage: "xmark") { store.stop(c) }
                    .fixedSize()
            } else {
                SoftButton(title: "Run now", fill: .white, size: .small, stroke: true, systemImage: "play") { store.runNow(c) }
                    .fixedSize()
                    .disabled(store.busy[c.id] == "run")
            }
        }
        Menu { CollectorMenuItems(store: store, collector: c) } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help("More: Edit, Rename, Duplicate, Delete")
    }

    private var renameRow: some View {
        HStack(spacing: 8) {
            TextField("Name", text: Binding(get: { store.renaming ?? "" }, set: { store.renaming = $0 }))
                .textFieldStyle(.plain).font(Theme.body(13))
                .padding(.horizontal, 10).frame(height: 30)
                .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(CollectorsTheme.selectedStroke, lineWidth: 1.5))
                .onSubmit { store.rename(c, to: store.renaming ?? "") }
            SoftButton(title: "Cancel", fill: .white, size: .small, stroke: true) { store.renaming = nil }.fixedSize()
            PrimaryButton(title: "Rename", size: .small) { store.rename(c, to: store.renaming ?? "") }.fixedSize()
        }
        .onExitCommand { store.renaming = nil }
    }

    private var deleteRow: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Delete \(c.name)?").font(Theme.body(14, .bold))
            Text(c.isFolder ? "The files it collected stay in the queue, and Distill keeps remembering what it took." : "Files it added stay in the queue.")
                .font(Theme.body(12.5)).foregroundStyle(CollectorsTheme.body)
            HStack(spacing: 8) {
                SoftButton(title: "Cancel", fill: .white, size: .small, stroke: true) { store.confirmDelete = nil }.fixedSize()
                    .keyboardShortcut(.cancelAction)
                SoftButton(title: "Delete collector", tint: .white, fill: Theme.peachInk, size: .small) { store.delete(c) }.fixedSize()
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(CollectorsTheme.errorFill))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CollectorsTheme.errorStroke))
    }

    // MARK: Consent

    private var consent: some View {
        let s = c.script
        let sha = c.status?.currentSha256
        let short = sha.map { "sha256 " + Self.abbrev($0) } ?? ""
        let was = s?.allowedSha256.map { " (was " + Self.abbrev($0) + ")" } ?? ""
        let source: String = {
            if let code = s?.source.inlineCode { return "(inline, \(code.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).count) lines)" }
            return text.tilde(s?.source.filePath ?? "")
        }()
        return ScriptConsent(state: text.scriptChanged(c) ? "changed" : "ask", interpreter: s?.interpreter.rawValue ?? "zsh",
                             source: source, hash: short + (text.scriptChanged(c) ? was : ""),
                             problem: sha == nil ? (c.status?.scriptProblem ?? "Distill can't read the script.") : nil,
                             busy: store.busy[c.id] == "allow",
                             onAllow: { store.allow(c) },
                             onSecond: {
                                 if text.scriptChanged(c) { showCode.toggle() } else { store.consentDeferred.insert(c.id) }
                             })
    }

    /// "Not now": the collector stays off and the card folds to one quiet line until the user reviews it.
    private var deferredConsent: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(Theme.muted)
            Text("Not allowed yet · it stays off until you allow it.").font(Theme.body(13)).foregroundStyle(Theme.muted)
            Spacer(minLength: 8)
            LinkButton(title: "Review and allow") { store.consentDeferred.remove(c.id) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
    }

    static func abbrev(_ sha: String) -> String { String(sha.prefix(4)) + "…" + String(sha.suffix(4)) }

    private var whatWillRun: some View { codeBlock(title: "WHAT WILL RUN", edit: true) }

    private func codeBlock(title: String, edit: Bool = false) -> some View {
        let lines = (store.code(c) ?? "").components(separatedBy: "\n")
        let trimmed = lines.last == "" ? Array(lines.dropLast()) : lines
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(title)
                Spacer()
                if edit { LinkButton(title: "Edit") { store.startEdit(c) } }
            }
            CodeLines(lines: trimmed.isEmpty ? ["(the script can't be read)"] : trimmed)
        }
    }

    // MARK: Settings

    private var settingsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel("SETTINGS")
                Spacer()
                LinkButton(title: "Edit") { store.startEdit(c) }
            }
            VStack(spacing: 0) {
                ForEach(Array(settingRows.enumerated()), id: \.offset) { i, row in
                    HStack(spacing: 14) {
                        Text(row.0).font(Theme.body(12.5)).foregroundStyle(Theme.muted).frame(width: 120, alignment: .leading)
                        (Text(row.1).foregroundColor(Theme.ink) + Text(row.2).foregroundColor(Theme.faint))
                            .font(Theme.body(13)).lineLimit(1).truncationMode(.tail)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .help(row.1 + row.2)
                    }
                    .padding(.vertical, 9)
                    .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
        }
    }

    private var settingRows: [(String, String, String)] {
        let sched = text.schedule(c.schedule.cron)
        if let f = c.folder {
            let queue = store.queuePath(c.vaultPath).map { " · queue " + text.tilde($0) } ?? ""
            return [("From", text.tilde(f.source), ""),
                    ("After collecting", f.moves ? "Move it to the queue" : "Keep the original (copy)", ""),
                    ("Into", store.vaultName(c.vaultPath), queue),
                    ("Schedule", sched, "")]
        }
        guard let s = c.script else { return [("Schedule", sched, "")] }
        let script: String = s.source.inlineCode.map { "Inline code (\($0.split(separator: "\n").count) lines)" } ?? text.tilde(s.source.filePath ?? "")
        if text.scriptChanged(c) { return [("Script", script, ""), ("Schedule", sched, " · paused until you allow it")] }
        let allowed: (String, String) = s.allowedAt.map { ("this exact version", " · " + HistoryTime.phrase($0, now: store.now)) }
            ?? ("this exact version", "")
        return [("Script", script, ""), ("Schedule", sched, ""), ("Allowed", allowed.0, allowed.1)]
    }

    // MARK: Advanced (scripts)

    private var advanced: some View {
        VStack(alignment: .leading, spacing: 10) {
            Button { store.advancedOpen.toggle() } label: {
                HStack(spacing: 8) {
                    Image(systemName: store.advancedOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                        .frame(width: 12)
                    Text("Advanced").font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.ink)
                    if !store.advancedOpen {
                        Text("\(c.script?.interpreter.rawValue ?? "") · timeout \(CollectorText.timeout(c.script?.timeoutSeconds ?? 300)) · what the script gets")
                            .font(Theme.body(12.5)).foregroundStyle(Theme.faint).lineLimit(1)
                    }
                    Spacer(minLength: 0)
                }
                .padding(.vertical, 10)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
            if store.advancedOpen {
                VStack(alignment: .leading, spacing: 10) {
                    AdvancedRow(label: "Run with") { Text(c.script?.interpreter.rawValue ?? "").font(Theme.body(13)) }
                    AdvancedRow(label: "Timeout") { Text(CollectorText.timeout(c.script?.timeoutSeconds ?? 300)).font(Theme.body(13)) }
                    AdvancedRow(label: "Cron") { Text(c.schedule.cron).font(.system(size: 12, design: .monospaced)) }
                    AdvancedRow(label: "It gets") { ScriptGets(vault: c.vaultPath, queue: store.queuePath(c.vaultPath) ?? "") }
                }
            }
        }
    }

    // MARK: Runs

    private var recentRuns: some View {
        let runs = Array(store.recentRuns(c).prefix(3))
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel("RECENT RUNS")
                Spacer()
                LinkButton(title: "Show all runs") { store.page = .allRuns; store.loadRuns(c.id) }
            }
            if runs.isEmpty {
                Text("No runs yet.").font(Theme.body(12)).foregroundStyle(Theme.faint).padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    ForEach(Array(runs.enumerated()), id: \.element.id) { i, run in
                        RunLine(store: store, collector: c, run: run, previous: i > 0 ? runs[i - 1].startedAt : nil)
                    }
                }
            }
        }
    }
}

/// One RunLogEntry for a run, opened and closed in the store.
struct RunLine: View {
    @ObservedObject var store: CollectorsStore
    let collector: Collector
    let run: CollectorRun
    var previous: Date?

    var body: some View {
        let text = store.text
        let command = collector.script.map { s in
            "\(s.interpreter.rawValue) " + (s.source.filePath.map(text.tilde) ?? "collector.\(s.interpreter == .python3 ? "py" : s.interpreter == .node ? "mjs" : "zsh")")
        }
        let (kind, lines) = text.runLines(run, command: command)
        RunLogEntry(result: CollectorText.runKind(run.result).rawValue,
                    time: text.runTime(run.startedAt, previous: previous, now: store.now),
                    summary: text.runSummary(run, now: store.now), meta: text.runMeta(run),
                    outputKind: kind, lines: lines, expanded: store.openRuns.contains(run.id),
                    onToggle: {
                        if store.openRuns.contains(run.id) { store.openRuns.remove(run.id) } else { store.openRuns.insert(run.id) }
                    })
    }
}

struct CollectorAllRuns: View {
    @ObservedObject var store: CollectorsStore
    let collector: Collector

    var body: some View {
        let runs = store.recentRuns(collector)
        let rows = CollectorText.collapse(runs)
        VStack(alignment: .leading, spacing: 18) {
            Button { store.page = .overview } label: {
                Text("‹ \(collector.name)").font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary)
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.cancelAction)
            Text("All runs").font(Theme.display(22))
            VStack(spacing: 2) {
                ForEach(Array(rows.enumerated()), id: \.offset) { i, row in
                    switch row {
                    case .run(let run):
                        RunLine(store: store, collector: collector, run: run, previous: previousDate(rows, i))
                    case .quiet(let count, let newest):
                        RunLogEntry(result: "nothing", time: store.text.runTime(newest, previous: previousDate(rows, i), now: store.now)
                                        .replacingOccurrences(of: #" \d{1,2}:\d{2}.*$"#, with: "", options: .regularExpression),
                                    summary: "\(count) runs with nothing new", meta: "")
                    }
                }
            }
            if runs.isEmpty { Text("No runs yet.").font(Theme.body(12)).foregroundStyle(Theme.faint) }
            Text(collector.isScript ? "Runs from the last 30 days. Click a run to see its output (the last 64 KB of stdout and stderr)."
                                    : "Runs from the last 30 days. Click a run to see each file.")
                .font(Theme.body(12)).foregroundStyle(Theme.faint)
        }
    }

    private func previousDate(_ rows: [CollectorText.RunRow], _ i: Int) -> Date? {
        guard i > 0 else { return nil }
        switch rows[i - 1] {
        case .run(let r): return r.startedAt
        case .quiet(_, let d): return d
        }
    }
}

// MARK: - Status card

struct CollectorStatusCard: View {
    @ObservedObject var store: CollectorsStore
    let collector: Collector

    private enum Tone { case calm, running, error }

    var body: some View {
        let c = collector
        let content = describe(c)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                if content.tone == .running { Spinner(size: 13) }
                if content.tone == .error { Image(systemName: "exclamationmark.triangle").font(.system(size: 13, weight: .bold)) }
                Text(content.title).font(Theme.body(15, .bold)).lineLimit(2)
            }
            .foregroundStyle(content.tone == .error ? Theme.peachInk : Theme.ink)
            ForEach(content.lines, id: \.self) { line in
                Text(line).font(Theme.body(12.5)).foregroundStyle(CollectorsTheme.body).lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            if !content.terminal.isEmpty {
                TerminalLines(lines: content.terminal, stderr: content.stderr).padding(.top, 6)
            }
            actions(c)
            if c.isFolder, let n = c.status?.collectedCount, n > 0 {
                HStack(spacing: 0) {
                    Text("Already collected: ").font(Theme.body(12.5)).foregroundStyle(Theme.muted)
                    Button { store.openCollected(c) } label: {
                        Text(CollectorText.files(n)).font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 14).fill(content.tone == .error ? CollectorsTheme.errorFill : content.tone == .running ? CollectorsTheme.runningFill : Theme.panel))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(content.tone == .error ? CollectorsTheme.errorStroke : .clear))
    }

    @ViewBuilder private func actions(_ c: Collector) -> some View {
        let code = c.isRunning ? nil : c.lastRun?.error?.code
        let buttons: [(String, () -> Void)] = {
            switch code {
            case .sourceMissing?: return [("Choose folder…", { store.chooseSource(c) }), ("Create it", { store.createFolder(c, which: "source") })]
            case .noPermission?: return [("Choose again…", { store.chooseSource(c) })]
            case .queueMissing?: return [("Create folder", { store.createFolder(c, which: "queue") })]
            default: return []
            }
        }()
        if !buttons.isEmpty {
            HStack(spacing: 8) {
                ForEach(buttons, id: \.0) { b in
                    SoftButton(title: b.0, fill: .white, size: .small, stroke: true, action: b.1).fixedSize()
                }
                if code == .noPermission {
                    LinkButton(title: "Open Privacy settings") {
                        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_FilesAndFolders") { NSWorkspace.shared.open(url) }
                    }
                }
            }
            .padding(.top, 6)
        }
    }

    private struct Content {
        var tone: Tone = .calm
        var title = ""
        var lines: [String] = []
        var terminal: [String] = []
        var stderr = false
    }

    private func describe(_ c: Collector) -> Content {
        let text = store.text, now = store.now
        if c.isRunning {
            let run = store.activeRun(c)
            var lines: [String] = []
            if let run {
                if run.result == .queued {
                    lines.append(run.waiting == "batch" ? "It starts when the batch applying to this vault finishes." : "It starts when a slot is free (two collectors run at once).")
                } else if c.isScript {
                    let how = run.trigger == "now" ? "Started with Run now" : run.trigger == "catchup" ? "Started to catch up" : "Started"
                    let stop = run.startedAt.addingTimeInterval(TimeInterval(c.script?.timeoutSeconds ?? 300))
                    lines.append("\(how) at \(text.clock(run.startedAt)) · stops at \(text.clock(stop))")
                } else {
                    lines.append("Started at \(text.clock(run.startedAt))")
                }
            }
            var terminal: [String] = []
            if c.isScript, let run, let out = store.output[run.id] {
                terminal = (out.stdout + out.stderr).split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
                while terminal.last == "" { terminal.removeLast() }
                terminal = Array(terminal.suffix(8))
            }
            return Content(tone: .running, title: text.runningLine(c, run: run, now: now), lines: lines, terminal: terminal)
        }
        guard let r = c.lastRun else {
            let next = c.status?.nextRunAt.map { text.next($0, now: now) }
            return Content(title: "Not run yet", lines: [c.enabled ? (next.map { "First run: " + $0.replacingOccurrences(of: "next ", with: "") + "." } ?? "Run now runs it at once.") : "It's off. Run now still works."])
        }
        let when = text.at(r.startedAt, now: now)
        let nextLine = c.status?.nextRunAt.map { "It stays on schedule and tries again " + text.next($0, now: now).replacingOccurrences(of: "next ", with: "") + "." }
        switch r.result {
        case .success, .nothing:
            var lines: [String] = []
            let title: String
            if c.isScript {
                title = r.counts.added == 0 ? "Nothing new \(when)" : "Added \(CollectorText.files(r.counts.added)) \(when)"
                lines.append("Exit 0" + (CollectorText.duration(r.durationMs).map { " after \($0)" } ?? "") + ".")
            } else if r.result == .nothing {
                title = "Nothing new \(when)"
                if r.counts.skipped > 0 { lines.append("Skipped \(r.counts.skipped) that \(r.counts.skipped == 1 ? "was" : "were") already collected.") }
            } else {
                let moved = r.counts.moved > 0
                title = "\(moved ? "Moved" : "Copied") \(CollectorText.files(moved ? r.counts.moved : r.counts.copied)) \(when)"
                var bits: [String] = []
                if r.counts.skipped > 0 { bits.append("Skipped \(r.counts.skipped) that \(r.counts.skipped == 1 ? "was" : "were") already collected.") }
                if r.counts.waiting > 0 { bits.append("\(r.counts.waiting) still changing; the next run takes \(r.counts.waiting == 1 ? "it" : "them").") }
                if r.counts.errors > 0 { bits.append("\(r.counts.errors) couldn't be \(moved ? "moved" : "copied"); open the run to see why.") }
                if !bits.isEmpty { lines.append(bits.joined(separator: " ")) }
            }
            if !c.enabled { lines.append("It's off. Run now still works.") }
            return Content(title: title, lines: lines)
        case .stopped:
            return Content(title: "Stopped \(when)", lines: [r.counts.added > 0 ? "It added \(CollectorText.files(r.counts.added)) before you stopped it." : "You stopped it. It runs again on schedule."])
        case .skipped:
            return Content(title: "Skipped \(when)", lines: [r.skipReason.map { "The \($0)." } ?? ""].filter { !$0.isEmpty })
        case .timedout:
            let after = CollectorText.timeout(c.script?.timeoutSeconds ?? 300)
            return Content(tone: .error, title: "Stopped after \(after) \(when)",
                           lines: [(r.counts.added > 0 ? "It added \(CollectorText.files(r.counts.added)); they stay in the queue." : "Added nothing.") + (nextLine.map { " " + $0 } ?? "")],
                           terminal: tail(r.stderrTail ?? r.stdoutTail), stderr: r.stderrTail != nil)
        default:
            switch r.error?.code {
            case .sourceMissing?:
                return Content(tone: .error, title: "\(text.tilde(c.folder?.source ?? "The folder")) is missing",
                               lines: ["It was moved, renamed or deleted, so the \(text.clock(r.startedAt)) run collected nothing."])
            case .noPermission?:
                return Content(tone: .error, title: "Distill can’t open \(text.tilde(c.folder?.source ?? "the folder"))",
                               lines: ["macOS hasn’t given Distill access to this folder. Choose it again so macOS asks you."])
            case .queueMissing?:
                return Content(tone: .error, title: "The queue folder is missing",
                               lines: ["\(store.queuePath(c.vaultPath).map(text.tilde) ?? "It") was moved or deleted, so the \(text.clock(r.startedAt)) run collected nothing."])
            case .interrupted?:
                return Content(tone: .error, title: "Interrupted \(when)", lines: ["Distill quit while it ran. It runs again on schedule."])
            default:
                let exit = r.exitCode.map { " · exit \($0)" } ?? ""
                var lines: [String] = []
                if c.isScript {
                    lines.append((r.counts.added > 0 ? "Added \(CollectorText.files(r.counts.added)); they stay in the queue." : "Added nothing.") + (nextLine.map { " " + $0 } ?? ""))
                }
                if let m = r.error?.message, !m.isEmpty, r.error?.code != .scriptFailed { lines.append(m) }
                return Content(tone: .error, title: "Failed \(when)\(exit)", lines: lines, terminal: tail(r.stderrTail), stderr: true)
            }
        }
    }

    private func tail(_ s: String?) -> [String] {
        guard let s, !s.isEmpty else { return [] }
        var lines = s.split(separator: "\n", omittingEmptySubsequences: false).map(String.init)
        while lines.last == "" { lines.removeLast() }
        return Array(lines.suffix(6))
    }
}

// MARK: - Small parts

struct SectionLabel: View {
    let text: String
    var color: Color = Theme.faint
    init(_ text: String, color: Color = Theme.faint) { self.text = text; self.color = color }
    var body: some View { Text(text).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(color) }
}

struct AdvancedRow<Content: View>: View {
    let label: String
    var labelWidth: CGFloat = 100
    /// The label above the field (a narrow pane).
    var stacked = false
    @ViewBuilder var content: Content

    var body: some View {
        if stacked {
            VStack(alignment: .leading, spacing: 6) {
                Text(label).font(Theme.body(12.5)).foregroundStyle(Theme.muted)
                content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            HStack(alignment: .firstTextBaseline, spacing: 14) {
                Text(label).font(Theme.body(12.5)).foregroundStyle(Theme.muted).frame(width: labelWidth, alignment: .leading)
                VStack(alignment: .leading, spacing: 6) { content }.frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }
}

/// What a script gets ($1, $2, env, working dir).
struct ScriptGets: View {
    let vault: String
    let queue: String

    var body: some View {
        VStack(alignment: .leading, spacing: 5) {
            row("$1 · vault", vault)
            row("$2 · queue", queue)
            row("env", "DISTILL_VAULT, DISTILL_QUEUE_DIR (same paths)")
            row("working dir", "a new temporary folder each run")
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        Text("It should write files only into the queue folder.").font(Theme.body(11.5)).foregroundStyle(Theme.faint)
    }

    private func row(_ k: String, _ v: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 10) {
            Text(k).font(Theme.body(11, .semibold)).foregroundStyle(CollectorsTheme.scriptInk).frame(width: 96, alignment: .leading)
            Text(v).font(.system(size: 11, design: .monospaced)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                .textSelection(.enabled)
        }
    }
}

/// Read-only code with line numbers (the consent's "What will run").
struct CodeLines: View {
    let lines: [String]

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(Array(lines.prefix(400).enumerated()), id: \.offset) { i, _ in
                    Text("\(i + 1)").font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Color(hex: 0xC2BEB6)).frame(height: 18)
                }
            }
            VStack(alignment: .leading, spacing: 0) {
                ForEach(Array(lines.prefix(400).enumerated()), id: \.offset) { _, line in
                    Text(line.isEmpty ? " " : line).font(.system(size: 11.5, design: .monospaced)).foregroundStyle(Theme.ink)
                        .lineLimit(1).frame(height: 18, alignment: .leading)
                }
            }
            .textSelection(.enabled)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        .clipped()
    }
}
