import AppKit
import SwiftUI
import DistillKit

/// The quick-note window (canvas: "Quick actions" panels 3 and 5, "Quick
/// windows: size, growth and scrolling"). Opened by `distill.openQuickNote`
/// (hover menu, shortcut). Opens centered like Spotlight, grows with the note,
/// and after Add to queue turns into the label step in place; it closes once
/// labels are applied or skipped. × and Esc during the label step are Skip.
@MainActor
final class QuickNoteController: NSObject {
    static let shared = QuickNoteController()
    /// Set by the hover menu: open on the flask's screen instead of the pointer's.
    static var anchor: NSRect?

    private var sizer: QuickWindowSizer?
    private weak var engine: AppModel?
    private var observer: NSObjectProtocol?

    func install(engine: AppModel) {
        self.engine = engine
        guard observer == nil else { return }
        observer = NotificationCenter.default.addObserver(forName: ShortcutAction.openQuickNote, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { QuickNoteController.shared.show() }
        }
    }

    func show() {
        guard let engine else { return }
        if sizer == nil {
            let panel = QuickNotePanel(width: QuickWindowGeometry.defaultWidth)
            panel.engine = engine
            panel.onCancel = { [weak self] in self?.close() }
            let sizer = QuickWindowSizer(window: panel, sizeKey: "distill.quickNote.size")
            sizer.setContent(QuickNoteView(close: { [weak self] in self?.close() },
                                           onDesiredHeight: { [weak sizer] h in sizer?.contentHeight(h) },
                                           focusText: { [weak panel] in NoteEditorFocus.focus(in: panel) })
                .environmentObject(engine))
            self.sizer = sizer
        }
        guard let sizer else { return }
        let anchor = Self.anchor
        Self.anchor = nil
        if !sizer.window.isVisible {
            sizer.window.contentView?.layoutSubtreeIfNeeded()
            sizer.open(on: QuickWindowSizer.screen(near: anchor))
        }
        NSApp.activate(ignoringOtherApps: true)
        sizer.window.makeKeyAndOrderFront(nil)
    }

    /// × and Esc: during the label step this is Skip (the note stays queued, unlabeled).
    func close() {
        sizer?.window.orderOut(nil)
        finishStep()
    }

    private func finishStep() {
        guard let engine, let step = engine.notes.steps[.quick] else { return }
        if step.phase == .applying { return }
        engine.closeLabelStep(.quick)
    }
}

/// Key handling for the quick note: ⌘V adds an image, ⌘↩ saves or applies, Esc closes.
final class QuickNotePanel: QuickWindow {
    weak var engine: AppModel?

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let engine {
            if event.charactersIgnoringModifiers == "v", engine.notes.steps[.quick] == nil,
               ComposeImageIntake.hasImage(NSPasteboard.general),
               !(firstResponder is NSText && NSPasteboard.general.string(forType: .string) != nil) {
                MainActor.assumeIsolated { engine.insertImages(.quick, ComposeImageIntake.images(from: NSPasteboard.general)) }
                return true
            }
            if event.keyCode == 36 { // Return
                MainActor.assumeIsolated {
                    if engine.notes.steps[.quick] != nil { engine.applyLabels(.quick) } else { engine.addNote(.quick) }
                }
                return true
            }
        }
        return super.performKeyEquivalent(with: event)
    }
}

struct QuickNoteView: View {
    @EnvironmentObject var engine: AppModel
    let close: () -> Void
    var onDesiredHeight: (CGFloat) -> Void = { _ in }
    var focusText: () -> Void = {}
    /// Snapshots only (see QuickShell).
    var snapshotHeight: CGFloat? = nil

    var body: some View {
        QuickNoteBody(notes: engine.notes, close: close, onDesiredHeight: onDesiredHeight, focusText: focusText,
                      snapshotHeight: snapshotHeight)
    }
}

/// Window content (also rendered by `--snapshot`).
struct QuickNoteBody: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var notes: NotesStore
    let close: () -> Void
    var onDesiredHeight: (CGFloat) -> Void = { _ in }
    var focusText: () -> Void = {}
    var snapshotHeight: CGFloat? = nil
    private let owner = ComposeOwner.quick

    var body: some View {
        Group {
            if let step = notes.steps[owner] {
                QuickShell(title: "Quick note", close: close, onDesiredHeight: onDesiredHeight, snapshotHeight: snapshotHeight) {
                    EmptyView()
                } top: {
                    VStack(alignment: .leading, spacing: 12) { labelStep(step) }
                } bottom: {
                    EmptyView()
                } footer: {
                    labelFooter(step)
                }
            } else {
                QuickShell(title: "Quick note", close: close, onDesiredHeight: onDesiredHeight, onSpareTap: focusText,
                           snapshotHeight: snapshotHeight) {
                    EmptyView()
                } top: {
                    composerTop
                } bottom: {
                    composerBottom
                } footer: {
                    composerFooter
                }
            }
        }
        .onChange(of: notes.steps[owner]?.phase) { _, phase in
            if phase == .applied {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { close() }
            }
        }
    }

    // MARK: Before queueing (panel 3)

    /// Title (wraps to 2 lines, then scrolls in its field), the note text and the source.
    @ViewBuilder private var composerTop: some View {
        VStack(alignment: .leading, spacing: 10) {
            QuickTitleField(text: binding(\.title))
            BareTextEditor(placeholder: "Write a note…", text: binding(\.text), font: Theme.body(13), minHeight: 40, maxHeight: .infinity,
                           images: engine.imageHost(owner))
                .padding(0)
            SourcePickerRow(draft: binding(\.self), compact: true)
        }
    }

    /// The error line (images sit inside the text).
    @ViewBuilder private var composerBottom: some View {
        if let error = notes.addErrors[owner] {
            HStack(alignment: .top, spacing: 6) {
                Text("!").font(Theme.body(11, .heavy))
                Text(error).fixedSize(horizontal: false, vertical: true)
            }
            .font(Theme.body(11)).foregroundStyle(Theme.peachInk)
            .padding(.horizontal, 10).padding(.vertical, 7)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xFFF4EE)))
        }
    }

    private var composerFooter: some View {
        let draft = notes.draft(owner)
        return HStack(spacing: 10) {
            QuickMarkdownBarToggle()
            Text("⌘V adds an image · ⌘↩ saves").font(Theme.body(11)).foregroundStyle(Theme.faint).lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { engine.addNote(owner) } label: {
                HStack(spacing: 6) {
                    if notes.adding.contains(owner) { Spinner(color: .white, size: 12) }
                    Text(notes.addErrors[owner] != nil ? "Try again" : "Add to queue").font(Theme.body(13, .semibold)).lineLimit(1)
                }
                .padding(.horizontal, 16).frame(height: 34)
                .foregroundStyle(.white)
                .background(Capsule().fill(Theme.primary))
            }
            .buttonStyle(.plain)
            .fixedSize()
            .disabled(draft.blocker != nil || notes.adding.contains(owner))
            .opacity(draft.blocker == nil ? 1 : 0.5)
        }
    }

    // MARK: After queueing (panel 5, loading panel 3)

    @ViewBuilder private func labelStep(_ step: LabelStep) -> some View {
        HStack(spacing: 10) {
            Text("✓").font(Theme.body(13, .heavy)).foregroundStyle(.white)
                .frame(width: 24, height: 24).background(Circle().fill(Theme.limeInk))
            VStack(alignment: .leading, spacing: 1) {
                Text("Queued “\(step.title)”").font(Theme.body(13, .bold)).lineLimit(1)
                Text("Goes into \(engine.activeVault?.name ?? "your vault") with the next batch")
                    .font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xF3FDE4)))

        if step.phase == .suggesting {
            HStack(spacing: 8) {
                Text("Suggesting labels…").font(Theme.body(12, .bold)).frame(maxWidth: .infinity, alignment: .leading)
                HStack(spacing: 4) {
                    Text(LabelsModelName.labelSuggest(engine))
                    Text("·")
                    ElapsedText(start: step.startedAt, font: Theme.body(11))
                }
                .font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
        } else if let error = step.suggestError {
            HStack(alignment: .top, spacing: 10) {
                Text("!").font(Theme.body(12, .heavy)).foregroundStyle(.white)
                    .frame(width: 20, height: 20).background(Circle().fill(Theme.peachInk))
                VStack(alignment: .leading, spacing: 2) {
                    Text("Couldn't get labels").font(Theme.body(13, .bold))
                    Text("\(error) The note is still queued; add your own below.").font(Theme.body(11)).foregroundStyle(Theme.muted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color(hex: 0xFFF4EE)))
        } else {
            HStack(spacing: 8) {
                Text(step.phase == .applied ? "Labels applied" : "Suggested labels").font(Theme.body(12, .bold))
                    .frame(maxWidth: .infinity, alignment: .leading)
                Text(LabelsModelName.labelSuggest(engine)).font(Theme.body(11, .bold))
                    .padding(.horizontal, 8).frame(height: 22)
                    .background(Capsule().fill(Theme.panel))
                    .help("Change it in Settings → Default model for each task")
            }
        }

        LabelStepChips(engine: engine, owner: owner, step: step, inline: false)
    }

    @ViewBuilder private func labelFooter(_ step: LabelStep) -> some View {
        HStack(spacing: 10) {
            QuickMarkdownBarToggle()
            if step.phase == .suggesting {
                AddLabelField(placeholder: "Type a label while you wait", width: 200, height: 28) { raw in
                    var ok = false
                    engine.editStep(owner) { ok = $0.add(raw) }
                    return ok
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Skip leaves it unlabeled → Labels").font(Theme.body(11)).foregroundStyle(Theme.faint).lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SmallButton(title: "Skip", height: 32) { engine.skipLabels(owner); close() }
            if step.phase != .suggesting || step.canApply {
                SmallButton(title: step.phase == .applying ? "Applying…" : "Apply \(step.chosen.count) \(step.chosen.count == 1 ? "label" : "labels")",
                            fill: Theme.primary, ink: .white, height: 32, weight: .bold) { engine.applyLabels(owner) }
                    .disabled(!step.canApply).opacity(step.canApply || step.phase == .applying ? 1 : 0.5)
            }
        }
    }

    private func binding<T>(_ path: WritableKeyPath<ComposeDraft, T>) -> Binding<T> {
        Binding(get: { notes.draft(owner)[keyPath: path] },
                set: { value in engine.updateDraft(owner) { $0[keyPath: path] = value } })
    }
}

/// The quick note's title: wraps to 2 lines, then scrolls inside its own field.
struct QuickTitleField: View {
    @Binding var text: String
    @Environment(\.snapshotMode) private var snapshot
    private let font = Font.system(size: 17, weight: .semibold, design: .rounded)

    var body: some View {
        if snapshot {
            Text(text.isEmpty ? "Title" : text).font(font).lineLimit(2)
                .foregroundStyle(text.isEmpty ? Theme.faint : Theme.ink)
                .fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: .infinity, alignment: .leading)
        } else {
            TextField("Title", text: $text, axis: .vertical)
                .textFieldStyle(.plain).font(font).lineLimit(1...2)
                .frame(maxWidth: .infinity, alignment: .leading) // wraps instead of widening the window
        }
    }
}

/// "Haiku" for the label-suggestion (or image-reading) model in status lines.
enum LabelsModelName {
    @MainActor
    static func labelSuggest(_ engine: AppModel) -> String { title(.labelSuggest, engine) }

    @MainActor
    static func imageText(_ engine: AppModel) -> String { title(.imageText, engine) }

    @MainActor
    private static func title(_ task: AITask, _ engine: AppModel) -> String {
        let sel = SettingsEdits.selection(task, settings: engine.settings)
        let runner = engine.notes.runners.first { $0.id == sel.runnerID }
        return SettingsEdits.modelTitle(sel.model, runner: runner)
    }
}
