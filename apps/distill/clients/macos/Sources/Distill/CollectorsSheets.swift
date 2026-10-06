import AppKit
import SwiftUI
import DistillKit

// Collectors: the empty state, the settings form (Edit), the three-step Add
// sheet and the Already collected sheet. The sheets are drawn in the window
// (a dimmed backdrop over the whole window, as on the boards), so snapshots
// capture them like the app shows them.

// MARK: - Empty

struct CollectorsEmpty: View {
    @ObservedObject var store: CollectorsStore

    var body: some View {
        VStack(spacing: 16) {
            Image(systemName: "tray.and.arrow.down").font(.system(size: 24, weight: .medium)).foregroundStyle(Theme.flaskLine)
                .frame(width: 60, height: 60).background(RoundedRectangle(cornerRadius: 18).fill(Theme.panel))
            Text("Fill the queue automatically").font(Theme.display(24))
            Text("A collector checks a folder, or runs your script, on a schedule. What it brings waits in the queue and goes into your vault after your review.")
                .font(Theme.body(13.5)).foregroundStyle(Theme.muted).multilineTextAlignment(.center).lineSpacing(3)
                .frame(maxWidth: 460).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 10) {
                PrimaryButton(title: "Add a folder", systemImage: "plus", size: .small) { store.startAdding(kind: .folder) }.fixedSize()
                SoftButton(title: "Add a script", fill: .white, size: .small, stroke: true) { store.startAdding(kind: .script) }.fixedSize()
            }
            .padding(.top, 6)
        }
        .padding(.horizontal, 40).padding(.top, 110)
        .frame(maxWidth: .infinity)
    }
}

// MARK: - Edit form

struct CollectorEditForm: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: CollectorsStore
    let collector: Collector
    /// The form's width: below 460 pt the labels go above the fields.
    @State private var width: CGFloat = 600

    private var draft: Binding<CollectorDraft> {
        Binding(get: { store.editing ?? CollectorDraft() }, set: { store.editing = $0 })
    }

    var body: some View {
        if collector.isScript, (store.editing ?? CollectorDraft()).v6 {
            ScriptEditForm(store: store, collector: collector)
        } else {
            classic
        }
    }

    @ViewBuilder private var classic: some View {
        let c = collector
        let d = store.editing ?? CollectorDraft()
        let valid = store.scheduleValid(d.schedule)
        let labelWidth: CGFloat = c.isScript ? 100 : 120
        VStack(alignment: .leading, spacing: c.isScript ? 13 : 14) {
            SectionLabel("EDIT SETTINGS", color: Theme.primary)
            if c.isFolder {
                AdvancedRow(label: "From", labelWidth: labelWidth, stacked: width < 460) {
                    HStack(spacing: 8) {
                        CollectorPathField(text: draft.folderPath, systemImage: "folder", width: 240)
                        SoftButton(title: "Choose…", fill: .white, size: .small, stroke: true) {
                            store.chooseFolder(start: d.folderPath) { store.editing?.folderPath = $0 }
                        }.fixedSize()
                    }
                    Hint("Files in the folder, including Google Docs (.gdoc), which wait in the queue until Google Drive access exists. Hidden files and anything still changing are left alone.")
                }
                AdvancedRow(label: "Subfolders", labelWidth: labelWidth, stacked: width < 460) {
                    SubfoldersSwitch(isOn: draft.includeSubfolders, title: "Include subfolders")
                    Hint("Each subfolder becomes one folder item in the queue, with its structure. Collected again when a file inside is new or changed.")
                }
                AdvancedRow(label: "After collecting", labelWidth: labelWidth, stacked: width < 460) {
                    ViewThatFits(in: .horizontal) {
                        SegmentedPills(options: [("copy", "Keep the original (copy)"), ("move", "Move it to the queue")],
                                       selection: draft.afterCollect, height: 28)
                        DropdownButton(title: d.afterCollect == "move" ? "Move it to the queue" : "Keep the original (copy)", height: 30) {
                            Button("Keep the original (copy)") { store.editing?.afterCollect = "copy" }
                            Button("Move it to the queue") { store.editing?.afterCollect = "move" }
                        }
                    }
                }
                AdvancedRow(label: "Into", labelWidth: labelWidth, stacked: width < 460) {
                    VaultDropdown(vaults: engine.settings.vaults, selection: draft.vaultPath)
                    if let q = store.queuePath(d.vaultPath) { QueuePath(path: q, size: "compact") }
                }
            } else {
                AdvancedRow(label: "Script", labelWidth: labelWidth, stacked: width < 460) {
                    SegmentedPills(options: [(false, "File"), (true, "Inline code")], selection: draft.scriptInline, height: 28)
                    if d.scriptInline {
                        CodeEditor(text: draft.code)
                    } else {
                        HStack(spacing: 8) {
                            CollectorPathField(text: draft.scriptFile, systemImage: "doc", width: 260)
                            SoftButton(title: "Choose…", fill: .white, size: .small, stroke: true) {
                                store.chooseFile { store.editing?.scriptFile = $0 }
                            }.fixedSize()
                        }
                    }
                }
            }
            AdvancedRow(label: "Schedule", labelWidth: labelWidth, stacked: width < 460) {
                ScheduleField(draft: draft.schedule, preview: preview(d.schedule, valid: valid), next: next(d.schedule, valid: valid),
                              invalid: valid == false)
            }
            if c.isScript {
                Button { store.editing?.advancedOpen.toggle() } label: {
                    HStack(spacing: 8) {
                        Image(systemName: d.advancedOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Theme.faint).frame(width: 12)
                        Text("Advanced").font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.ink)
                        Spacer()
                    }
                    .padding(.top, 10).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
                if d.advancedOpen {
                    AdvancedRow(label: "Run with", labelWidth: labelWidth, stacked: width < 460) { InterpreterDropdown(selection: draft.interpreter) }
                    AdvancedRow(label: "Timeout", labelWidth: labelWidth, stacked: width < 460) {
                        DropdownButton(title: Self.timeoutTitle(d.timeoutSeconds), width: 130, height: 30) {
                            ForEach(Self.timeouts, id: \.self) { s in Button(Self.timeoutTitle(s)) { store.editing?.timeoutSeconds = s } }
                        }
                        Hint("Stopped after this. Files it wrote stay in the queue.")
                    }
                    AdvancedRow(label: "Cron", labelWidth: labelWidth, stacked: width < 460) {
                        TextField("m h dom mon dow", text: Binding(get: { d.schedule.cron }, set: { store.editing?.schedule.setCron($0) }))
                            .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                            .padding(.horizontal, 10).frame(width: 140, height: 30)
                            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(valid == false ? Color(hex: 0xFF9A6B) : Theme.border))
                        Hint("The schedule above as cron. Editing it switches the schedule to Custom.")
                    }
                    AdvancedRow(label: "It gets", labelWidth: labelWidth, stacked: width < 460) {
                        ScriptGets(vault: c.vaultPath, queue: store.queuePath(c.vaultPath) ?? "")
                    }
                }
                if d.asksAgain(from: c, text: store.text) {
                    Hint("Saving a new script asks for your OK again before it runs.")
                }
            }
            HStack(spacing: 8) {
                Spacer()
                SoftButton(title: "Cancel", fill: .white, size: .small, stroke: true) { store.editing = nil }.fixedSize()
                    .keyboardShortcut(.cancelAction)
                PrimaryButton(title: "Save", size: .small, enabled: valid == true && store.busy[c.id] != "save" && canSave(d)) { store.save(c) }.fixedSize()
            }
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CollectorsTheme.selectedStroke))
    }

    private func canSave(_ d: CollectorDraft) -> Bool {
        if collector.isFolder { return !d.folderPath.trimmingCharacters(in: .whitespaces).isEmpty }
        return d.scriptInline ? !d.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !d.scriptFile.isEmpty
    }

    private func preview(_ s: ScheduleDraft, valid: Bool?) -> String {
        if valid == false { return "Not a schedule" }
        return store.text.preview(s.cron) ?? (store.checks[s.cron] != nil ? "Custom schedule" : "Checking…")
    }

    private func next(_ s: ScheduleDraft, valid: Bool?) -> String {
        if valid == false { return store.checks[s.cron]?.error ?? "use 5 fields: minute hour day month weekday" }
        return store.nextPhrase(s)
    }

    static let timeouts = [60, 300, 900, 1800, 3600]
    static func timeoutTitle(_ s: Int) -> String {
        switch s {
        case 60: return "1 minute"
        case 3600: return "1 hour"
        default: return s % 60 == 0 ? "\(s / 60) minutes" : "\(s) seconds"
        }
    }
}

// MARK: - Script edit form (v6)

/// A custom script's Edit form on a core with script files (board CollectorsScriptFiles, frames U and
/// Z2): kept by Distill or your own file, the ScriptEditor, the PackagesPanel for a kept script, and
/// "Schedule and Advanced" folded to one line. Code and manifest save through PUT …/script against the
/// hashes the editor loaded; a file changed on disk since then is not overwritten.
struct ScriptEditForm: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: CollectorsStore
    let collector: Collector
    @State private var width: CGFloat = 600

    private var draft: Binding<CollectorDraft> {
        Binding(get: { store.editing ?? CollectorDraft() }, set: { store.editing = $0 })
    }
    private var stacked: Bool { width < 470 }

    var body: some View {
        let c = collector
        let d = store.editing ?? CollectorDraft()
        let valid = store.scheduleValid(d.schedule)
        VStack(alignment: .leading, spacing: 13) {
            SectionLabel("EDIT SETTINGS", color: Theme.primary)
            AdvancedRow(label: "Script", labelWidth: 100, stacked: stacked) {
                SegmentedPills(options: [(true, "Kept by Distill"), (false, "Your own file")],
                               selection: Binding(get: { d.managed }, set: { m in
                                   store.editing?.managed = m
                                   // Switching to kept by Distill starts from the loaded code, or a template.
                                   if m, store.editing?.code.isEmpty ?? true { store.editing?.code = d.loaded?.code ?? ScriptTemplates.code(d.interpreter) }
                               }), height: 28)
                if d.managed, c.isManaged, d.loaded == nil {
                    HStack(spacing: 8) { Spinner(size: 12); Text("Reading the script…").font(Theme.body(12)).foregroundStyle(Theme.muted) }
                        .frame(height: 60)
                } else {
                    editor(c, d)
                }
            }
            if d.managed, let name = d.interpreter.manifestName {
                AdvancedRow(label: "Packages", labelWidth: 100, stacked: stacked) { packages(c, d, name: name) }
            }
            if let message = store.conflict[c.id] { conflictBanner(c, message) }
            scheduleAndAdvanced(c, d, valid: valid)
            footer(c, d, valid: valid)
        }
        .padding(16)
        .frame(maxWidth: .infinity, alignment: .leading)
        .onGeometryChange(for: CGFloat.self, of: { $0.size.width }) { width = $0 }
        .background(RoundedRectangle(cornerRadius: 14).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(CollectorsTheme.selectedStroke))
    }

    private func editor(_ c: Collector, _ d: CollectorDraft) -> some View {
        let managedPath: String = {
            if c.isManaged, let p = d.loaded?.path ?? c.scriptPath, !p.isEmpty {
                return ((p as NSString).deletingPathExtension as NSString).appendingPathExtension(
                    d.interpreter == c.script?.interpreter ? (p as NSString).pathExtension : d.interpreter.fileExtension) ?? p
            }
            let state = store.stateDir ?? StatePaths.resolve().dir.path
            return state + "/collectors/scripts/\(c.id)/collector.\(d.interpreter.fileExtension)"
        }()
        let path = d.managed ? managedPath : store.text.expand(d.scriptFile)
        let exists = d.managed ? (c.isManaged && d.interpreter == c.script?.interpreter) : !d.scriptFile.isEmpty
        return ScriptEditor(language: ScriptLanguage.of(d.interpreter), source: d.managed ? "managed" : "external", path: path,
                            code: draft.code, compact: stacked, fileExists: exists,
                            onLanguage: { store.editing?.setLanguage(ScriptLanguage.interpreter($0)) },
                            onReveal: { store.reveal(path) }, onOpen: { store.openInEditor(path) },
                            onChoose: { store.chooseFile { store.editing?.scriptFile = $0 } })
    }

    private func packages(_ c: Collector, _ d: CollectorDraft, name: String) -> some View {
        let m = c.manifest
        let sameKind = m?.name == name && c.isManaged
        let empty = d.manifest.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let state: String = {
            if !sameKind { return empty ? "none" : "needsOK" }
            if c.needsConsent && (c.status?.script?.changes ?? []).contains("manifest") { return "needsOK" }
            if empty && !(m?.hasDependencies ?? false) { return "none" }
            return m?.state == "none" && !empty ? "needsInstall" : (m?.state ?? "none")
        }()
        let summary: String = {
            if d.manifestChanged || !sameKind {
                if empty { return "" }
                let n = ManifestCount.count(name, d.manifest)
                return (sameKind && (m?.packageCount ?? 0) > 0 ? "\(m?.packageCount ?? 0) installed · " : "")
                    + "the change installs after you allow it" + (sameKind ? "" : " (\(n == 1 ? "1 package" : "\(n) packages"))")
            }
            return store.text.packagesStatus(m, state: state, now: store.now)
        }()
        let path = m?.path ?? ""
        return PackagesPanel(manifest: name, state: state, output: state == "installing" || state == "failed" ? store.installLines(c) : [],
                             summary: summary, text: draft.manifest,
                             onInstall: sameKind ? { store.install(c) } : nil,
                             installEnabled: !d.manifestChanged && !c.needsConsent && !c.isRunning && store.busy[c.id] == nil,
                             onStop: { store.stop(c) },
                             onCleanInstall: sameKind && (m?.hasDependencies ?? false) ? { store.confirmCleanInstall(c) } : nil,
                             onOpen: sameKind && (m?.exists ?? false) ? { store.openInEditor(path) } : nil)
    }

    private func conflictBanner(_ c: Collector, _ message: String) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: "exclamationmark.triangle").font(.system(size: 12, weight: .bold)).foregroundStyle(Theme.peachInk)
                Text("Changed on disk since you opened it").font(Theme.body(13, .bold)).foregroundStyle(Theme.peachInk)
            }
            Text("\(message) Reload shows the file as it is now (your edits here are dropped). Keep editing keeps your text; Save then replaces the file.")
                .font(Theme.body(12)).foregroundStyle(CollectorsTheme.body).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 8) {
                SoftButton(title: "Reload", fill: .white, size: .small, stroke: true, systemImage: "arrow.clockwise") {
                    store.conflict[c.id] = nil
                    store.loadEditorFiles(c)
                }.fixedSize()
                SoftButton(title: "Keep editing", fill: .white, size: .small, stroke: true) {
                    store.conflict[c.id] = nil
                    store.loadEditorFiles(c, keepText: true)
                }.fixedSize()
            }
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(CollectorsTheme.errorFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(CollectorsTheme.errorStroke))
    }

    @ViewBuilder private func scheduleAndAdvanced(_ c: Collector, _ d: CollectorDraft, valid: Bool?) -> some View {
        Button { store.editing?.scheduleOpen.toggle() } label: {
            HStack(spacing: 8) {
                Image(systemName: d.scheduleOpen ? "chevron.down" : "chevron.right").font(.system(size: 10, weight: .bold))
                    .foregroundStyle(Theme.faint).frame(width: 12)
                Text("Schedule and Advanced").font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.ink).fixedSize()
                if !d.scheduleOpen {
                    Text("\(store.text.lowerSchedule(d.schedule.cron)) · timeout \(CollectorText.timeout(d.timeoutSeconds))")
                        .font(Theme.body(12.5)).foregroundStyle(Theme.faint).lineLimit(1)
                }
                Spacer(minLength: 0)
            }
            .padding(.top, 10).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1) }
        if d.scheduleOpen {
            AdvancedRow(label: "Schedule", labelWidth: 100, stacked: stacked) {
                ScheduleField(draft: draft.schedule, preview: valid == false ? "Not a schedule" : (store.text.preview(d.schedule.cron) ?? (store.checks[d.schedule.cron] != nil ? "Custom schedule" : "Checking…")),
                              next: valid == false ? (store.checks[d.schedule.cron]?.error ?? "use 5 fields: minute hour day month weekday") : store.nextPhrase(d.schedule),
                              invalid: valid == false)
            }
            AdvancedRow(label: "Into", labelWidth: 100, stacked: stacked) {
                VaultDropdown(vaults: engine.settings.vaults, selection: draft.vaultPath)
            }
            AdvancedRow(label: "Timeout", labelWidth: 100, stacked: stacked) {
                DropdownButton(title: CollectorEditForm.timeoutTitle(d.timeoutSeconds), width: 130, height: 30) {
                    ForEach(CollectorEditForm.timeouts, id: \.self) { s in Button(CollectorEditForm.timeoutTitle(s)) { store.editing?.timeoutSeconds = s } }
                }
                Hint("Stopped after this. Files it wrote stay in the queue.")
            }
            AdvancedRow(label: "Cron", labelWidth: 100, stacked: stacked) {
                TextField("m h dom mon dow", text: Binding(get: { d.schedule.cron }, set: { store.editing?.schedule.setCron($0) }))
                    .textFieldStyle(.plain).font(.system(size: 12, design: .monospaced))
                    .padding(.horizontal, 10).frame(width: 140, height: 30)
                    .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
                    .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(valid == false ? Color(hex: 0xFF9A6B) : Theme.border))
                Hint("The schedule above as cron. Editing it switches the schedule to Custom.")
            }
            AdvancedRow(label: "It gets", labelWidth: 100, stacked: stacked) {
                ScriptGets(vault: c.vaultPath, queue: store.queuePath(c.vaultPath) ?? "")
            }
        }
    }

    private func footer(_ c: Collector, _ d: CollectorDraft, valid: Bool?) -> some View {
        let canSave: Bool = {
            if d.managed { return !d.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty && (d.loaded != nil || !c.isManaged) }
            return !d.scriptFile.isEmpty
        }()
        let enabled = valid == true && store.busy[c.id] != "save" && canSave && store.conflict[c.id] == nil
        let manifest = d.interpreter.manifestName.map { " or \($0)" } ?? ""
        let hint = d.asksAgain(from: c, text: store.text)
            ? "Saving a change to the script\(d.managed ? manifest : "") asks for your OK again; Allow and run then tries it at once."
            : "Saving a change to the script\(d.managed ? manifest : "") asks for your OK again."
        let buttons = HStack(spacing: 8) {
            SoftButton(title: "Cancel", fill: .white, size: .small, stroke: true) { store.editing = nil; store.conflict[c.id] = nil }.fixedSize()
                .keyboardShortcut(.cancelAction)
            PrimaryButton(title: "Save", size: .small, enabled: enabled) { store.save(c) }.fixedSize()
        }
        return ViewThatFits(in: .horizontal) {
            HStack(spacing: 8) {
                Hint(hint).frame(minWidth: 160, maxWidth: .infinity, alignment: .leading)
                buttons
            }
            VStack(alignment: .trailing, spacing: 8) {
                Hint(hint).frame(maxWidth: .infinity, alignment: .leading)
                buttons
            }
        }
    }
}

/// How many packages a manifest lists (for the panel's line before the core has read it).
enum ManifestCount {
    static func count(_ name: String, _ text: String) -> Int {
        if name == "requirements.txt" {
            return text.split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty && !$0.hasPrefix("#") && !$0.hasPrefix("-") }.count
        }
        guard let data = text.data(using: .utf8),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any] else { return 0 }
        return ["dependencies", "devDependencies", "optionalDependencies"].reduce(0) { $0 + ((obj[$1] as? [String: Any])?.count ?? 0) }
    }
}

struct Hint: View {
    let text: String
    init(_ text: String) { self.text = text }
    var body: some View {
        Text(text).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
    }
}

/// An editable path with a leading icon (accepts `~`).
struct CollectorPathField: View {
    @Binding var text: String
    var systemImage = "folder"
    var width: CGFloat = 300
    var placeholder = "~/Folder"

    var body: some View {
        HStack(spacing: 7) {
            Image(systemName: systemImage).font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
            TextField(placeholder, text: $text).textFieldStyle(.plain).font(Theme.body(12.5)).lineLimit(1)
        }
        .padding(.horizontal, 10).frame(height: 30)
        .frame(maxWidth: width)
        .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
    }
}

struct VaultDropdown: View {
    let vaults: [VaultProfile]
    @Binding var selection: String

    var body: some View {
        let name = vaults.first { $0.path == selection }?.name ?? (selection.isEmpty ? "Choose a vault" : (selection as NSString).lastPathComponent)
        DropdownButton(title: name, width: 150, height: 30, systemImage: "tray") {
            ForEach(vaults) { v in Button(v.name) { selection = v.path } }
        }
    }
}

struct InterpreterDropdown: View {
    @Binding var selection: CollectorInterpreter
    var width: CGFloat = 120

    var body: some View {
        DropdownButton(title: selection.rawValue, width: width, height: 30) {
            ForEach(CollectorInterpreter.all, id: \.self) { i in Button(i.rawValue) { selection = i } }
        }
    }
}

/// Inline script code (monospaced, line numbers in the margin).
struct CodeEditor: View {
    @Binding var text: String
    var minLines = 5
    var maxHeight: CGFloat = 320
    /// The ring: blue for the script, grey for a manifest, amber for a manifest waiting for the OK.
    var stroke: Color = CollectorsTheme.selectedStroke
    var strokeWidth: CGFloat = 1.5
    /// Shown faint while the text is empty ("# one package per line, e.g. requests>=2.32").
    var placeholder = ""

    private static let font = NSFont.monospacedSystemFont(ofSize: 11.5, weight: .regular)
    private static var lineHeight: CGFloat { NSLayoutManager().defaultLineHeight(for: font) }

    var body: some View {
        let count = max(1, text.components(separatedBy: "\n").count)
        let height = min(maxHeight, CGFloat(max(count, minLines)) * Self.lineHeight + 4)
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .trailing, spacing: 0) {
                ForEach(1...min(count, 999), id: \.self) { i in
                    Text("\(i)").font(Font(Self.font)).foregroundStyle(Color(hex: 0xC2BEB6)).frame(height: Self.lineHeight)
                }
                Spacer(minLength: 0)
            }
            .frame(height: height, alignment: .top)
            .clipped()
            ZStack(alignment: .topLeading) {
                if text.isEmpty && !placeholder.isEmpty {
                    Text(placeholder).font(Font(Self.font)).foregroundStyle(Theme.faint).padding(.leading, 5).allowsHitTesting(false)
                }
                // Plain code: no smart quotes or dashes (they would break package.json and shell quoting).
                PlainCodeView(text: $text, font: Self.font)
                    .frame(height: height)
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(stroke, lineWidth: strokeWidth))
    }
}

// MARK: - Overlay host

/// The Add and Already collected sheets over the whole window.
struct CollectorsOverlay: View {
    @ObservedObject var store: CollectorsStore

    var body: some View {
        if store.adding != nil || store.collected != nil {
            ZStack(alignment: .top) {
                Color(red: 29 / 255, green: 28 / 255, blue: 26 / 255).opacity(0.28)
                    .contentShape(Rectangle())
                    .onTapGesture {}
                if store.adding != nil {
                    // Scrolls when a script with packages is taller than the window (an 890 × 700 window).
                    ScrollView(.vertical, showsIndicators: false) {
                        AddCollectorSheet(store: store).padding(.top, (store.adding?.stage == "Source" && store.adding?.kind == .script) ? 60 : 110)
                            .padding(.bottom, 40)
                            .frame(maxWidth: .infinity)
                    }
                } else {
                    CollectedSheetView(store: store).padding(.top, 90)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .ignoresSafeArea()
        }
    }
}

private struct SheetCard<Content: View>: View {
    var width: CGFloat
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: 16) { content }
            .padding(.horizontal, 24).padding(.vertical, 22)
            .frame(width: width, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 18).fill(Color.white).shadow(color: Color.black.opacity(0.25), radius: 30, y: 24))
            .overlay(RoundedRectangle(cornerRadius: 18).strokeBorder(Color.black.opacity(0.06)))
    }
}

// MARK: - Add sheet

struct AddCollectorSheet: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: CollectorsStore

    private var draft: Binding<AddDraft> { Binding(get: { store.adding ?? AddDraft() }, set: { store.adding = $0 }) }

    var body: some View {
        let d = store.adding ?? AddDraft()
        SheetCard(width: d.stage == "Source" && d.kind == .script ? 600 : 520) {
            steps(d)
            switch d.stage {
            case "What it does": roleStep(d)
            case "Kind": kindStep(d)
            case "Source": if d.kind == .script { scriptStep(d) } else { folderStep(d) }
            case "Commands": commandsStep(d)
            default: scheduleStep(d)
            }
        }
        .onExitCommand { store.adding = nil }
    }

    private func steps(_ d: AddDraft) -> some View {
        let current = d.step
        return HStack(spacing: 16) {
            ForEach(Array(d.role.steps.enumerated()), id: \.offset) { i, title in
                let n = i + 1
                HStack(spacing: 6) {
                    Text("\(n)").font(Theme.body(10, .bold))
                        .foregroundStyle(n == current ? Color.white : n < current ? Theme.primary : Theme.faint)
                        .frame(width: 18, height: 18)
                        .background(Circle().fill(n == current ? Theme.primary : n < current ? Theme.primaryTint : Theme.panel))
                    Text(title).font(Theme.body(11.5, n == current ? .bold : .medium))
                        .foregroundStyle(n == current ? Theme.primary : n < current ? Theme.ink : Theme.faint)
                }
            }
        }
    }

    private func title(_ t: String) -> some View { Text(t).font(Theme.display(22)) }

    private func footer(back: Bool, next: String, icon: String? = nil, enabled: Bool = true, action: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            if back {
                SoftButton(title: "Back", fill: .white, size: .small, stroke: true) { store.adding?.step -= 1 }.fixedSize()
            }
            Spacer()
            if !back {
                SoftButton(title: "Cancel", fill: .white, size: .small, stroke: true) { store.adding = nil }.fixedSize()
                    .keyboardShortcut(.cancelAction)
            }
            PrimaryButton(title: next, systemImage: icon, size: .small, enabled: enabled, action: action).fixedSize()
                .keyboardShortcut(.defaultAction)
        }
        .padding(.top, 4)
    }

    private func kindStep(_ d: AddDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            title("What does it collect from?")
            VStack(spacing: 8) {
                choice(.folder, "Folder", "Collect files from a folder you choose. Built in, no code.", d)
                choice(.script, "Custom script", "Run your own zsh, Python, JavaScript or TypeScript script on a schedule.", d)
            }
            footer(back: true, next: "Continue") { store.adding?.step += 1 }
        }
    }

    /// Step 1 (action-buttons.md, frame sa-card-add): what the automation does. Collect keeps today's steps.
    private func roleStep(_ d: AddDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Add automation")
            VStack(spacing: 8) {
                ForEach(AutomationRole.allCases, id: \.self) { role in
                    pick(on: d.role == role, icon: role == .collect ? "tray.and.arrow.down" : role == .commands ? "command" : "square.stack.3d.up",
                         name: role.title, detail: role.detail) { store.adding?.setRole(role) }
                }
            }
            footer(back: false, next: "Continue") { store.adding?.step += 1 }
        }
    }

    /// The last step for Commands and Both: commands are declared on the saved script (its COMMANDS block).
    private func commandsStep(_ d: AddDraft) -> some View {
        VStack(alignment: .leading, spacing: 14) {
            title("Its commands")
            Text("After you add it, open the script and choose Add command under COMMANDS: the name, the arguments it takes, and how to read its result. Buttons on your actions then run those commands.")
                .font(Theme.body(13)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
            Hint(d.role == .commands ? "It is saved off and never runs on its own. Allow shows you the code first." : "It is saved off. Allow shows you the code first; then it collects on its schedule.")
            footer(back: true, next: "Add", icon: "checkmark", enabled: store.busy["add"] == nil) { store.finishAdding() }
        }
    }

    private func pick(on: Bool, icon: String, name: String, detail: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 12) {
                Image(systemName: icon).font(.system(size: 15, weight: .semibold)).foregroundStyle(Theme.primary)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 10).fill(Theme.primaryTint))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.body(14, .bold)).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    if on {
                        Circle().fill(Theme.primary)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(Color(hex: 0xB5B1A9), lineWidth: 1.5)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? CollectorsTheme.selectedFill : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? CollectorsTheme.selectedStroke : Theme.border, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func choice(_ kind: CollectorKind, _ name: String, _ detail: String, _ d: AddDraft) -> some View {
        let on = d.kind == kind
        let k = CollectorsTheme.kind(kind.rawValue)
        return Button { store.adding?.kind = kind } label: {
            HStack(spacing: 12) {
                Image(systemName: k.2).font(.system(size: 15, weight: .semibold)).foregroundStyle(k.1)
                    .frame(width: 34, height: 34).background(RoundedRectangle(cornerRadius: 10).fill(k.0))
                VStack(alignment: .leading, spacing: 2) {
                    Text(name).font(Theme.body(14, .bold)).foregroundStyle(Theme.ink)
                    Text(detail).font(Theme.body(12)).foregroundStyle(Theme.muted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                ZStack {
                    if on {
                        Circle().fill(Theme.primary)
                        Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(.white)
                    } else {
                        Circle().strokeBorder(Color(hex: 0xB5B1A9), lineWidth: 1.5)
                    }
                }
                .frame(width: 18, height: 18)
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 12).fill(on ? CollectorsTheme.selectedFill : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(on ? CollectorsTheme.selectedStroke : Theme.border, lineWidth: on ? 1.5 : 1))
            .contentShape(RoundedRectangle(cornerRadius: 12))
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(on ? .isSelected : [])
    }

    private func folderStep(_ d: AddDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Which folder?")
            VStack(alignment: .leading, spacing: 8) {
                Text("Folder").font(Theme.body(12.5, .semibold))
                HStack(spacing: 8) {
                    CollectorPathField(text: draft.folderPath, width: 300)
                    SoftButton(title: "Choose…", fill: .white, size: .small, stroke: true) {
                        store.chooseFolder(start: d.folderPath) { store.adding?.folderPath = $0 }
                    }.fixedSize()
                }
                Hint("Distill creates it if it doesn’t exist.")
                SubfoldersSwitch(isOn: draft.includeSubfolders, title: "Include subfolders, each as one folder item")
                    .padding(.top, 4)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("After collecting").font(Theme.body(12.5, .semibold))
                SegmentedPills(options: [("copy", "Keep the original (copy)"), ("move", "Move it to the queue")],
                               selection: draft.afterCollect, height: 28)
                Hint("Distill remembers what it collected, so it never takes the same file twice.")
            }
            footer(back: true, next: "Continue", enabled: !d.folderPath.trimmingCharacters(in: .whitespaces).isEmpty) { store.adding?.step += 1 }
        }
    }

    /// Step 2 for a script: kept by Distill (a real file in the collector's folder, written from this
    /// code, with its package manifest) or your own file. Packages install when the user allows it.
    private func scriptStep(_ d: AddDraft) -> some View {
        let path = d.managed ? store.newScriptPath(d.interpreter) : d.scriptFile
        let manifestText = d.manifest.trimmingCharacters(in: .whitespacesAndNewlines)
        return VStack(alignment: .leading, spacing: 14) {
            title("Your script")
            SegmentedPills(options: [(true, "Kept by Distill"), (false, "Your own file")], selection: draft.managed, height: 28)
            ScriptEditor(language: ScriptLanguage.of(d.interpreter), source: d.managed ? "managed" : "external", path: path,
                         code: draft.code, fileExists: !d.managed && !d.scriptFile.isEmpty,
                         onLanguage: { store.adding?.setLanguage(ScriptLanguage.interpreter($0)) },
                         onReveal: { store.reveal(store.text.expand(d.scriptFile)) },
                         onOpen: { store.openInEditor(store.text.expand(d.scriptFile)) },
                         onChoose: { store.chooseFile { store.adding?.scriptFile = $0 } })
            if d.managed, let name = d.interpreter.manifestName {
                let n = ManifestCount.count(name, d.manifest)
                PackagesPanel(manifest: name, state: manifestText.isEmpty ? "none" : "needsOK",
                              summary: manifestText.isEmpty ? "" : "\(n == 1 ? "1 package" : "\(n) packages") · install when you allow the script",
                              text: draft.manifest)
            }
            Hint("It gets the vault and queue folder paths as $1 and $2 (and DISTILL_VAULT, DISTILL_QUEUE_DIR). Nothing runs until you allow it.")
            footer(back: true, next: "Continue",
                   enabled: d.scriptInline ? !d.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !d.scriptFile.isEmpty) {
                store.adding?.step += 1
            }
        }
    }

    private func scheduleStep(_ d: AddDraft) -> some View {
        let valid = store.scheduleValid(d.schedule)
        return VStack(alignment: .leading, spacing: 16) {
            title("When should it run?")
            VStack(alignment: .leading, spacing: 8) {
                Text("How often").font(Theme.body(12.5, .semibold))
                ScheduleField(draft: draft.schedule,
                              preview: valid == false ? "Not a schedule" : (store.text.preview(d.schedule.cron) ?? "Custom schedule"),
                              next: valid == false ? (store.checks[d.schedule.cron]?.error ?? "use 5 fields: minute hour day month weekday")
                                                   : store.nextPhrase(d.schedule, first: true),
                              invalid: valid == false)
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("Into").font(Theme.body(12.5, .semibold))
                HStack(spacing: 8) {
                    VaultDropdown(vaults: engine.settings.vaults, selection: draft.vaultPath)
                    Text("the vault’s queue").font(Theme.body(12)).foregroundStyle(Theme.faint)
                }
            }
            if d.isLastStep {
                footer(back: true, next: d.kind == .folder ? "Add and turn on" : "Add", icon: "checkmark",
                       enabled: valid == true && !d.vaultPath.isEmpty && store.busy["add"] == nil) { store.finishAdding() }
            } else {
                footer(back: true, next: "Continue", enabled: valid == true && !d.vaultPath.isEmpty) { store.adding?.step += 1 }
            }
        }
    }
}

// MARK: - Already collected

struct CollectedSheetView: View {
    @ObservedObject var store: CollectorsStore
    @State private var hovered: String?

    var body: some View {
        let sheet = store.collected ?? CollectedSheet(collectorID: "")
        let c = store.collector(sheet.collectorID)
        let total = c?.status?.collectedCount ?? sheet.files.count
        SheetCard(width: 560) {
            HStack {
                Text("Already collected").font(Theme.display(22)).frame(maxWidth: .infinity, alignment: .leading)
                IconButton(systemImage: "xmark", size: 28, help: "Close") { store.collected = nil }
                    .keyboardShortcut(.cancelAction)
            }
            Text("\(CollectorText.files(total)) from \(store.text.tilde(c?.folder?.source ?? "this folder")). Distill skips these, even under another name. Forget one to collect it again.")
                .font(Theme.body(12.5)).foregroundStyle(Theme.muted).lineSpacing(2).fixedSize(horizontal: false, vertical: true)
            HStack(spacing: 7) {
                Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
                TextField("Search", text: Binding(get: { store.collected?.query ?? "" }, set: { store.collected?.query = $0; store.loadCollected() }))
                    .textFieldStyle(.plain).font(Theme.body(12.5))
            }
            .padding(.horizontal, 10).frame(height: 30)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.border))
            ScrollView {
                VStack(spacing: 2) {
                    if sheet.loading && sheet.files.isEmpty {
                        Spinner(size: 14).padding(20)
                    } else if sheet.files.isEmpty {
                        Text(sheet.query.isEmpty ? "Nothing collected yet." : "No collected file matches “\(sheet.query)”.")
                            .font(Theme.body(12.5)).foregroundStyle(Theme.faint).padding(.vertical, 16)
                    }
                    ForEach(sheet.files) { f in row(f, sheet: sheet) }
                }
            }
            .frame(maxHeight: 340)
            .fixedSize(horizontal: false, vertical: true)
            if sheet.confirmForgetAll {
                VStack(alignment: .leading, spacing: 8) {
                    Text("Forget all \(CollectorText.files(total))?").font(Theme.body(13, .bold))
                    Text("The next run collects every file still in the folder again.").font(Theme.body(12)).foregroundStyle(CollectorsTheme.body)
                    HStack(spacing: 8) {
                        Spacer()
                        SoftButton(title: "Cancel", fill: .white, size: .small, stroke: true) { store.collected?.confirmForgetAll = false }.fixedSize()
                        SoftButton(title: "Forget all", tint: .white, fill: Theme.peachInk, size: .small) { store.forgetAll() }.fixedSize()
                    }
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12).fill(CollectorsTheme.errorFill))
            } else {
                HStack {
                    Spacer()
                    LinkButton(title: "Forget all…") { store.collected?.confirmForgetAll = true }
                        .disabled(sheet.files.isEmpty)
                }
            }
        }
    }

    @ViewBuilder private func row(_ f: CollectedFile, sheet: CollectedSheet) -> some View {
        if sheet.forgotten[f.sha256] != nil {
            HStack(spacing: 10) {
                Text(f.name).font(Theme.body(12.5)).foregroundStyle(Theme.muted).strikethrough().lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text("Will be collected again").font(Theme.body(12)).foregroundStyle(CollectorsTheme.amberInk)
                LinkButton(title: "Undo") { store.undoForget(f.sha256) }
            }
            .padding(.horizontal, 10).padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 9).fill(Color(hex: 0xFFF8E6)))
        } else {
            let hot = hovered == f.id || sheet.hover == f.id
            HStack(spacing: 10) {
                Text(f.name).font(Theme.body(12.5, .semibold)).lineLimit(1).truncationMode(.middle)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .help(f.sourcePath)
                Text(f.collectedDate.map { store.text.runTime($0, previous: nil, now: store.now) } ?? "")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: 110, alignment: .leading)
                ZStack(alignment: .trailing) {
                    if hot {
                        SoftButton(title: "Forget", fill: .white, size: .small, stroke: true) { store.forget(f) }.fixedSize()
                    }
                }
                .frame(width: 78, height: 30, alignment: .trailing)
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 9).fill(hot ? Theme.panel : .clear))
            .contentShape(Rectangle())
            .onHover { hovered = $0 ? f.id : (hovered == f.id ? nil : hovered) }
        }
    }
}
