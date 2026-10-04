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
                    Hint("Every file at the top of the folder. Hidden files, subfolders and files still changing are left alone.")
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
                if d.scriptInline != (c.script?.source.inlineCode != nil) || (d.scriptInline && d.code != c.script?.source.inlineCode)
                    || (!d.scriptInline && store.text.expand(d.scriptFile) != c.script?.source.filePath) || d.interpreter != c.script?.interpreter {
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
            TextEditor(text: $text)
                .font(Font(Self.font))
                .scrollContentBackground(.hidden)
                .autocorrectionDisabled()
                .frame(height: height)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(CollectorsTheme.selectedStroke, lineWidth: 1.5))
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
                    AddCollectorSheet(store: store).padding(.top, 110)
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
        SheetCard(width: d.step == 2 && d.kind == .script ? 600 : 520) {
            steps(d.step)
            switch d.step {
            case 1: kindStep(d)
            case 2: if d.kind == .script { scriptStep(d) } else { folderStep(d) }
            default: scheduleStep(d)
            }
        }
        .onExitCommand { store.adding = nil }
    }

    private func steps(_ current: Int) -> some View {
        HStack(spacing: 16) {
            ForEach(Array(["Kind", "Source", "Schedule"].enumerated()), id: \.offset) { i, title in
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
            title("Add a collector")
            VStack(spacing: 8) {
                choice(.folder, "Folder", "Collect files from a folder you choose. Built in, no code.", d)
                choice(.script, "Custom script", "Run your own zsh, Python or Node script on a schedule.", d)
            }
            footer(back: false, next: "Continue") { store.adding?.step = 2 }
        }
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
            }
            VStack(alignment: .leading, spacing: 8) {
                Text("After collecting").font(Theme.body(12.5, .semibold))
                SegmentedPills(options: [("copy", "Keep the original (copy)"), ("move", "Move it to the queue")],
                               selection: draft.afterCollect, height: 28)
                Hint("Distill remembers what it collected, so it never takes the same file twice.")
            }
            footer(back: true, next: "Continue", enabled: !d.folderPath.trimmingCharacters(in: .whitespaces).isEmpty) { store.adding?.step = 3 }
        }
    }

    private func scriptStep(_ d: AddDraft) -> some View {
        VStack(alignment: .leading, spacing: 16) {
            title("Your script")
            HStack(spacing: 8) {
                SegmentedPills(options: [(false, "File"), (true, "Inline code")], selection: draft.scriptInline, height: 28)
                Spacer()
                Text("Run with").font(Theme.body(12)).foregroundStyle(Theme.muted)
                InterpreterDropdown(selection: draft.interpreter, width: 110)
            }
            if d.scriptInline {
                CodeEditor(text: draft.code)
            } else {
                HStack(spacing: 8) {
                    CollectorPathField(text: draft.scriptFile, systemImage: "doc", width: 360, placeholder: "~/Scripts/collect.sh")
                    SoftButton(title: "Choose…", fill: .white, size: .small, stroke: true) { store.chooseFile { store.adding?.scriptFile = $0 } }.fixedSize()
                }
            }
            Hint("It gets the vault and queue folder paths as $1 and $2 (and DISTILL_VAULT, DISTILL_QUEUE_DIR). Nothing runs until you allow it.")
            footer(back: true, next: "Continue",
                   enabled: d.scriptInline ? !d.code.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty : !d.scriptFile.isEmpty) {
                store.adding?.step = 3
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
            footer(back: true, next: d.kind == .folder ? "Add and turn on" : "Add", icon: "checkmark",
                   enabled: valid == true && !d.vaultPath.isEmpty && store.busy["add"] == nil) { store.finishAdding() }
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
