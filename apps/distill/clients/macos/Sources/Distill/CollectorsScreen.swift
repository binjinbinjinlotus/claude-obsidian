import AppKit
import SwiftUI
import DistillKit

/// Sidebar section Collectors (canvas row 7, boards Collectors, CollectorsScript and
/// CollectorsScriptFiles): the header, the list plus the detail, the empty state and
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
    /// The content is under 760 pt (an 890 pt window): a log takes the whole width.
    @State private var narrowWindow = false

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
                } else if store.logTarget != nil, let c = store.current, narrowWindow {
                    // v7, an 890 pt window: the log takes the whole window (‹ goes back).
                    CollectorLogView(store: store, collector: c, target: store.logTarget!)
                        .padding(.horizontal, 28).padding(.top, 26)
                } else {
                    VStack(spacing: 0) {
                        header(add: true)
                        GeometryReader { geo in
                            // The list narrows in a small window so the detail keeps room (890–900 pt).
                            let listWidth: CGFloat = geo.size.width < 760 ? 240 : 300
                            HStack(alignment: .top, spacing: 24) {
                                CollectorList(store: store).paneWidth(.collectorsList, automatic: listWidth, container: geo.size.width)
                                CollectorDetailPane(store: store).frame(maxWidth: .infinity, alignment: .topLeading)
                            }
                            .padding(.leading, 20).padding(.trailing, 28).padding(.top, 20)
                        }
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(GeometryReader { g in Color.clear.onAppear { narrowWindow = g.size.width < 760 }.onChange(of: g.size.width) { narrowWindow = g.size.width < 760 } })
        .onAppear {
            if store.phase == .idle { store.load() } else if let id = store.current?.id { store.refresh(id); store.loadRuns(id) }
        }
    }

    private func header(add: Bool) -> some View {
        HStack(alignment: .center, spacing: 12) {
            VStack(alignment: .leading, spacing: 6) {
                Text("Automations").font(Theme.display(30)).lineLimit(1)
                Text(subtitle).font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            Spacer(minLength: 0)
            if add {
                PrimaryButton(title: "Add automation", systemImage: "plus", size: .small) { store.startAdding() }
                    .fixedSize()
                    .keyboardShortcut("n", modifiers: .command)
            }
        }
        .padding(.horizontal, 32).padding(.top, 30)
    }

    private var subtitle: String {
        if let v = engine.activeVault { return "Fill \(v.name)’s queue on a schedule, and run commands from action buttons." }
        return "Fill a vault’s queue on a schedule, and run commands from action buttons."
    }
}

// MARK: - List

private struct CollectorList: View {
    @ObservedObject var store: CollectorsStore

    var body: some View {
        ScrollView(.vertical, showsIndicators: false) {
            VStack(alignment: .leading, spacing: 2) {
                let groups = CollectorGroups.split(store.collectors)
                ForEach(groups, id: \.title) { group in
                if groups.count > 1 {
                    SectionLabel(group.title).padding(.horizontal, 10).padding(.top, group.title == groups.first?.title ? 0 : 12).padding(.bottom, 4)
                }
                ForEach(group.items) { c in
                    let kind = store.text.statusKind(c)
                    CollectorRow(kind: c.kind.rawValue, title: c.name,
                                 summary: store.text.rowSummary(c, now: store.now, run: store.activeRun(c), latest: store.latestRun(c)),
                                 status: store.text.pill(c) ?? "", statusKind: kind.rawValue,
                                 selected: c.id == store.current?.id,
                                 runEnabled: c.script?.collects != false && !c.needsConsent && !c.isRunning && !c.isInstalling && !store.text.installFailed(c),
                                 onSelect: { store.select(c.id) },
                                 onRun: { store.runNow(c) }) {
                        CollectorMenuItems(store: store, collector: c)
                    }
                }
                }
            }
            .padding(.bottom, 20)
        }
    }
}

/// ⋯: Run now first (Stop while it runs or installs), Test run (scripts), Edit, the script's file and
/// packages (scripts Distill keeps), Rename, Duplicate, Show all runs, Turn on/off, Revoke, Delete.
struct CollectorMenuItems: View {
    @ObservedObject var store: CollectorsStore
    let collector: Collector

    var body: some View {
        let c = collector
        if c.isRunning || c.isInstalling {
            Button("Stop") { store.stop(c) }
        } else if !c.needsConsent {
            Button("Run now") { store.select(c.id); store.runNow(c) }
                .disabled(store.text.installFailed(c))
            if c.isScript { Button("Test run") { store.select(c.id); store.testRun(c) } }
        }
        Divider()
        Button("Edit settings") { store.startEdit(c) }
        if c.isScript, let path = c.scriptPath, !path.isEmpty {
            Button("Open script in editor") { store.openInEditor(path) }
            Button("Reveal in Finder") { store.reveal(path) }
        }
        if c.isScript, c.isManaged, let m = c.manifest, m.hasDependencies {
            Button("Install packages") { store.select(c.id); store.install(c) }
                .disabled(c.needsConsent || c.isRunning || c.isInstalling)
            Button("Clean reinstall…") { store.select(c.id); store.confirmCleanInstall(c) }
                .disabled(c.needsConsent || c.isRunning || c.isInstalling)
        }
        Divider()
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
            .disabled(collector.isRunning || collector.isInstalling)
    }
}

// MARK: - Detail

struct CollectorDetailPane: View {
    @ObservedObject var store: CollectorsStore

    var body: some View {
        if let c = store.current, let target = store.logTarget {
            // v7: the log scrolls itself (it follows the newest line).
            CollectorLogView(store: store, collector: c, target: target)
                .padding(.top, 8).padding(.leading, 10).padding(.trailing, 12)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        } else {
            pane
        }
    }

    private var pane: some View {
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
    @State private var width: CGFloat = 600

    private var c: Collector { collector }
    private var text: CollectorText { store.text }
    private var editing: Bool { store.editing != nil && store.current?.id == c.id }
    private var consentAsk: Bool { c.needsConsent && !text.scriptChanged(c) && !store.consentDeferred.contains(c.id) }
    /// A narrow pane (an 890 pt window): labels above values, short link titles.
    private var narrow: Bool { width < 470 }
    private var v6: Bool { c.status?.script != nil }

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
                if text.scriptChanged(c) { whatChanged }
                settingsBlock
                if c.isScript && v6 { ScriptCommandsBlock(store: store, collector: c) }
                if c.isScript { advanced }
                recentRuns
            }
        }
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
    }

    // MARK: Title row

    /// Name and controls on one row; in a narrow pane the controls move under the name instead of cutting it.
    @ViewBuilder private var titleRow: some View {
        // One row while the pane has room (the title line truncates, as on the boards); under the
        // name in a narrow pane (an 890 pt window) so the name is never cut.
        if width >= 520 {
            HStack(spacing: 12) {
                tile
                nameBlock.frame(maxWidth: .infinity, alignment: .leading)
                controls
            }
        } else {
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
            Text(titleLine).font(Theme.body(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
        }
    }

    private var titleLine: String {
        if editing, v6, c.isScript {
            let lang = c.script?.interpreter.language ?? ""
            return "Script · \(lang)\(c.isManaged ? "" : " · your own file") · editing"
        }
        return text.titleLine(c, now: store.now)
    }

    /// One slot for every kind and state: Run now; Stop while it runs or installs; Allow and run while a
    /// script waits for the OK. It stays while editing (it runs the saved version). Scripts add Test run.
    @ViewBuilder private var controls: some View {
        let active = c.isRunning || c.isInstalling
        PillSwitch(isOn: Binding(get: { c.enabled && !c.needsConsent }, set: { store.setEnabled(c, $0) }), label: "Collector on", width: 36, height: 22)
            .disabled(c.needsConsent)
            .help(c.needsConsent ? "Allow the script first" : c.enabled ? "Turn off" : "Turn on")
        if c.isScript, !c.needsConsent, !active {
            LinkButton(title: "Test run") { store.testRun(c) }
                .disabled(store.busy[c.id] != nil)
                .help("Run it into Distill’s test folder: nothing reaches the queue")
        }
        if active {
            SoftButton(title: "Stop", fill: .white, size: .small, stroke: true, systemImage: "xmark") { store.stop(c) }
                .fixedSize()
                .disabled(store.busy[c.id] == "stop")
        } else if c.needsConsent {
            let can = c.status?.currentSha256 != nil && store.busy[c.id] != "allow"
            SoftButton(title: "Allow and run", fill: .white, size: .small, stroke: true, systemImage: "play") { store.allowAndRun(c) }
                .fixedSize()
                .disabled(!can).opacity(can ? 1 : 0.45)
                .help("Allow the version shown, install its packages if needed, then run it once")
        } else {
            let blocked = text.installFailed(c)
            SoftButton(title: "Run now", fill: .white, size: .small, stroke: true, systemImage: "play") { store.runNow(c) }
                .fixedSize()
                .disabled(store.busy[c.id] == "run" || blocked).opacity(blocked ? 0.45 : 1)
                .help(blocked ? "Runs wait until the packages install" : "Run it now; the schedule doesn’t move")
        }
        Menu { CollectorMenuItems(store: store, collector: c) } label: {
            Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 28, height: 28).contentShape(Circle())
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
        .help(c.needsConsent ? "More: Edit, Rename, Duplicate, Delete" : "More: Run now, Edit, Rename, Duplicate, Delete")
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
            Text(deleteMessage).font(Theme.body(12.5)).foregroundStyle(CollectorsTheme.body).fixedSize(horizontal: false, vertical: true)
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

    private var deleteMessage: String {
        if c.isFolder { return "The files it collected stay in the queue, and Distill keeps remembering what it took." }
        if c.isManaged {
            return "Files it added stay in the queue. The collector and its script folder go to Distill’s trash for 30 days (without installed packages); restore it from History → Activity."
        }
        return "Files it added stay in the queue. Your script file stays where it is."
    }

    // MARK: Consent

    private var consent: some View {
        let s = c.script
        let sha = c.status?.currentSha256
        let short = sha.map { "sha256 " + Self.abbrev($0) } ?? ""
        let was = s?.allowedSha256.map { " (was " + Self.abbrev($0) + ")" } ?? ""
        let changed = text.scriptChanged(c)
        let manifestOnly = text.manifestOnlyChanged(c)
        let m = c.manifest
        let source: String = {
            if manifestOnly { return m?.name ?? "package.json" }
            if let code = s?.source.inlineCode { return "(inline, \(code.trimmingCharacters(in: .newlines).split(separator: "\n", omittingEmptySubsequences: false).count) lines)" }
            if c.isManaged, let p = c.scriptPath { return (p as NSString).lastPathComponent }
            return text.tilde(s?.source.filePath ?? "")
        }()
        let interpreter = manifestOnly ? (m?.name == "requirements.txt" ? "pip install ·" : "npm install ·") : (s?.interpreter.command ?? "zsh")
        let changes: String = {
            let ch = c.status?.script?.changes ?? []
            guard changed, ch.contains("manifest"), let name = m?.name else { return "" }
            return ch.contains("script") ? "the script and \(name)" : name
        }()
        let packages: String = {
            guard !changed, c.isManaged, let m, m.hasDependencies else { return "" }
            return "\(m.name) · \(m.packageCount == 1 ? "1 package" : "\(m.packageCount) packages")"
        }()
        return ScriptConsent(state: changed ? "changed" : "ask", interpreter: interpreter,
                             source: source, hash: short + (changed ? was : ""), changes: changes, packages: packages,
                             problem: sha == nil ? (c.status?.scriptProblem ?? "Distill can't read the script.") : nil,
                             busy: store.busy[c.id] == "allow",
                             onAllow: { store.allow(c) },
                             onSecond: {
                                 if changed { showCode.toggle() } else { store.consentDeferred.insert(c.id) }
                             })
    }

    /// "Not now": the collector stays off and the card folds to one quiet line until the user reviews it.
    private var deferredConsent: some View {
        HStack(spacing: 8) {
            Image(systemName: "pause.circle").foregroundStyle(Theme.muted)
            Text("Not allowed yet · it stays off until you allow it.").font(Theme.body(13)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
            LinkButton(title: "Review and allow") { store.consentDeferred.remove(c.id) }
        }
        .padding(.horizontal, 16).padding(.vertical, 12)
        .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
    }

    static func abbrev(_ sha: String) -> String { String(sha.prefix(4)) + "…" + String(sha.suffix(4)) }

    /// A first OK: the code, and a kept script's package manifest (both are covered by the OK).
    @ViewBuilder private var whatWillRun: some View {
        codeBlock(title: "WHAT WILL RUN", edit: true)
        if let m = c.manifest, c.isManaged, let files = store.consentScript(c), let mtext = files.manifest?.text, !mtext.isEmpty {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("PACKAGES")
                PackagesPanel(manifest: m.name, state: "needsOK", lines: mtext,
                              summary: "\(m.packageCount == 1 ? "1 package" : "\(m.packageCount) packages") · install when you allow the script")
            }
        }
    }

    /// A changed script: a changed manifest shows at once (WHAT CHANGED); the code with Show script / Show changes.
    @ViewBuilder private var whatChanged: some View {
        let ch = c.status?.script?.changes ?? []
        if ch.contains("manifest"), let m = c.manifest {
            VStack(alignment: .leading, spacing: 6) {
                SectionLabel("WHAT CHANGED")
                PackagesPanel(manifest: m.name, state: "needsOK", lines: store.consentScript(c)?.manifest?.text ?? "")
            }
        }
        if showCode { codeBlock(title: "WHAT WILL RUN") }
    }

    private func codeBlock(title: String, edit: Bool = false) -> some View {
        let code = store.consentScript(c)?.code ?? store.code(c) ?? ""
        let lines = code.components(separatedBy: "\n")
        let trimmed = lines.last == "" ? Array(lines.dropLast()) : lines
        return VStack(alignment: .leading, spacing: 6) {
            HStack {
                SectionLabel(title)
                Spacer()
                if edit { LinkButton(title: "Edit") { store.startEdit(c) } }
            }
            CodeLines(lines: trimmed.isEmpty || code.isEmpty ? ["(the script can't be read)"] : trimmed)
        }
    }

    // MARK: Settings

    private struct SettingRow {
        var label: String
        var value: String
        var quiet: String = ""
        var links: [(String, () -> Void)] = []
    }

    private var settingsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack {
                SectionLabel("SETTINGS")
                Spacer()
                LinkButton(title: "Edit") { store.startEdit(c) }
            }
            VStack(spacing: 0) {
                ForEach(Array(settingRows.enumerated()), id: \.offset) { i, row in
                    settingRow(row)
                        .padding(.vertical, 9)
                        .overlay(alignment: .top) { if i > 0 { Rectangle().fill(Theme.border).frame(height: 1) } }
                }
            }
        }
    }

    @ViewBuilder private func settingRow(_ row: SettingRow) -> some View {
        let value = (Text(row.value).foregroundColor(Theme.ink) + Text(row.quiet).foregroundColor(Theme.faint))
            .font(Theme.body(13)).lineLimit(1).truncationMode(.tail)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(row.value + row.quiet)
        let links = HStack(spacing: 10) {
            ForEach(Array(row.links.enumerated()), id: \.offset) { _, l in
                Button(action: l.1) { Text(l.0).font(Theme.body(11.5, .semibold)).foregroundStyle(Theme.primary).fixedSize() }
                    .buttonStyle(.plain)
            }
        }
        if narrow {
            VStack(alignment: .leading, spacing: 3) {
                Text(row.label).font(Theme.body(12)).foregroundStyle(Theme.muted)
                HStack(spacing: 10) { value; links }
            }
        } else {
            HStack(spacing: 14) {
                Text(row.label).font(Theme.body(12.5)).foregroundStyle(Theme.muted).frame(width: 120, alignment: .leading)
                value
                links
            }
        }
    }

    private var settingRows: [SettingRow] {
        let sched = text.schedule(c.schedule.cron)
        if let f = c.folder {
            let queue = store.queuePath(c.vaultPath).map { " · queue " + text.tilde($0) } ?? ""
            return [SettingRow(label: "From", value: text.tilde(f.source)),
                    SettingRow(label: "Subfolders", value: f.subfolders ? "Collected as folder items" : "Left alone"),
                    SettingRow(label: "After collecting", value: f.moves ? "Move it to the queue" : "Keep the original (copy)"),
                    SettingRow(label: "Into", value: store.vaultName(c.vaultPath), quiet: queue),
                    SettingRow(label: "Schedule", value: sched)]
        }
        guard let s = c.script else { return [SettingRow(label: "Schedule", value: sched)] }
        let changed = text.scriptChanged(c)
        guard v6 else {
            // An older core: no script files.
            let script: String = s.source.inlineCode.map { "Inline code (\($0.split(separator: "\n").count) lines)" } ?? text.tilde(s.source.filePath ?? "")
            if changed { return [SettingRow(label: "Script", value: script), SettingRow(label: "Schedule", value: sched, quiet: " · paused until you allow it")] }
            return [SettingRow(label: "Script", value: script), SettingRow(label: "Schedule", value: sched),
                    SettingRow(label: "Allowed", value: "this exact version", quiet: s.allowedAt.map { " · " + HistoryTime.phrase($0, now: store.now) } ?? "")]
        }
        let path = c.scriptPath ?? ""
        let fileLinks: [(String, () -> Void)] = path.isEmpty ? [] : [(narrow ? "Reveal" : "Reveal in Finder", { store.reveal(path) }),
                                                                      (narrow ? "Open" : "Open in editor", { store.openInEditor(path) })]
        var rows: [SettingRow] = []
        let lang = s.interpreter.language
        if c.isManaged {
            let unchanged = changed && !(c.status?.script?.changes ?? []).contains("script") && !(c.status?.script?.changes ?? []).isEmpty
            rows.append(SettingRow(label: "Script", value: (path as NSString).lastPathComponent, quiet: " · \(lang)" + (unchanged ? " · unchanged" : ""),
                                   links: fileLinks))
            if let m = c.manifest, !changed || m.exists {
                let line = text.packagesLine(m, now: store.now)
                rows.append(SettingRow(label: "Packages", value: line.0, quiet: line.1))
            }
        } else {
            rows.append(SettingRow(label: "Script", value: text.tilde(path), quiet: " · your own file", links: fileLinks))
            rows.append(SettingRow(label: "Language", value: lang))
            rows.append(SettingRow(label: "Packages", value: "Yours to install: Distill installs packages only for scripts it keeps."))
        }
        let quiet = changed ? " · paused until you allow it" : text.installFailed(c) ? " · runs wait for the packages" : ""
        rows.append(SettingRow(label: "Schedule", value: sched, quiet: quiet))
        if !c.needsConsent, s.allowedSha256 != nil {
            let covers = text.allowedCovers(c).map { " · " + $0 } ?? ""
            let when = s.allowedAt.map { " · " + HistoryTime.phrase($0, now: store.now) } ?? ""
            rows.append(SettingRow(label: "Allowed", value: "this exact version", quiet: covers + when))
        }
        return rows
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
                        Text("\(v6 ? text.runsWith(c) : c.script?.interpreter.rawValue ?? "") · timeout \(CollectorText.timeout(c.script?.timeoutSeconds ?? 300)) · what the script gets")
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
                    AdvancedRow(label: "Run with", stacked: narrow) { Text(v6 ? text.runsWith(c) : c.script?.interpreter.rawValue ?? "").font(Theme.body(13)) }
                    AdvancedRow(label: "Timeout", stacked: narrow) { Text(CollectorText.timeout(c.script?.timeoutSeconds ?? 300)).font(Theme.body(13)) }
                    AdvancedRow(label: "Cron", stacked: narrow) { Text(c.schedule.cron).font(.system(size: 12, design: .monospaced)) }
                    AdvancedRow(label: "It gets", stacked: narrow) { ScriptGets(vault: c.vaultPath, queue: store.queuePath(c.vaultPath) ?? "") }
                }
            }
        }
    }

    // MARK: Runs

    private var recentRuns: some View {
        let runs = Array(store.recentRuns(c).prefix(3))
        let waiting = store.activeRun(c).flatMap { $0.result == .queued && $0.waiting == "install" ? $0 : nil }
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                SectionLabel("RECENT RUNS")
                Spacer()
                LinkButton(title: "Show all runs") { store.page = .allRuns; store.loadRuns(c.id) }
            }
            if runs.isEmpty && waiting == nil {
                Text("No runs yet.").font(Theme.body(12)).foregroundStyle(Theme.faint).padding(.vertical, 6)
            } else {
                VStack(spacing: 2) {
                    if let waiting {
                        // The run Allow and run (or Run now) started during an install waits for it.
                        RunLogEntry(result: "running", time: text.runTime(waiting.startedAt, previous: nil, now: store.now),
                                    summary: text.runSummary(waiting, now: store.now), meta: "Stop")
                    }
                    ForEach(Array(runs.enumerated()), id: \.element.id) { i, run in
                        RunLine(store: store, collector: c, run: run, previous: i > 0 ? runs[i - 1].startedAt : (waiting?.startedAt))
                    }
                }
            }
        }
    }
}

/// The command a script run line starts with: "python3 collector.py" (kept) or the user's path.
func collectorCommand(_ c: Collector, text: CollectorText) -> String? {
    guard let s = c.script else { return nil }
    if c.isManaged, let p = c.scriptPath { return "\(s.interpreter.command) " + (p as NSString).lastPathComponent }
    if let p = s.source.filePath { return "\(s.interpreter.command) " + text.tilde(p) }
    return "\(s.interpreter.command) collector.\(s.interpreter == .python3 ? "py" : s.interpreter == .node ? "mjs" : s.interpreter.fileExtension)"
}

/// One RunLogEntry for a run, opened and closed in the store.
struct RunLine: View {
    @ObservedObject var store: CollectorsStore
    let collector: Collector
    let run: CollectorRun
    var previous: Date?

    var body: some View {
        let text = store.text
        let (kind, lines) = text.runLines(run, command: collectorCommand(collector, text: text))
        RunLogEntry(result: CollectorText.runKind(run.result).rawValue,
                    time: text.runTime(run.startedAt, previous: previous, now: store.now),
                    summary: text.runSummary(run, now: store.now), meta: text.runMeta(run),
                    outputKind: kind, lines: lines, expanded: store.openRuns.contains(run.id),
                    runtime: run.runtime?.line() ?? "",
                    onToggle: {
                        if store.openRuns.contains(run.id) { store.openRuns.remove(run.id) } else { store.openRuns.insert(run.id) }
                    },
                    onOpenLog: collector.isScript ? { store.openLog(.run(collectorId: collector.id, runId: run.id)) } : nil)
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

/// Automations list groups (action-buttons.md, "The name"): what collects first, then commands-only scripts.
enum CollectorGroups {
    struct Group { var title: String; var items: [Collector] }
    static func split(_ list: [Collector]) -> [Group] {
        let commandsOnly = list.filter { $0.isScript && $0.script?.collects == false }
        let collect = list.filter { !($0.isScript && $0.script?.collects == false) }
        return [Group(title: "COLLECT ON A SCHEDULE", items: collect), Group(title: "COMMANDS FOR BUTTONS", items: commandsOnly)].filter { !$0.items.isEmpty }
    }
}
