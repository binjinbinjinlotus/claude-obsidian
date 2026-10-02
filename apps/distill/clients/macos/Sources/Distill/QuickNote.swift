import AppKit
import SwiftUI
import DistillKit

/// The quick-note window beside the floating flask (canvas: "Quick actions",
/// panels 3 and 5). Opened by `distill.openQuickNote` (hover menu, shortcut).
/// Same rules as the composer; after Add to queue it turns into the label
/// step in place and closes once labels are applied or skipped.
@MainActor
final class QuickNoteController: NSObject, NSWindowDelegate {
    static let shared = QuickNoteController()

    private var panel: QuickNotePanel?
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
        if panel == nil {
            let panel = QuickNotePanel(
                contentRect: NSRect(x: 0, y: 0, width: 400, height: 300),
                styleMask: [.titled, .closable, .fullSizeContentView, .nonactivatingPanel],
                backing: .buffered, defer: false)
            panel.titleVisibility = .hidden
            panel.titlebarAppearsTransparent = true
            panel.standardWindowButton(.closeButton)?.isHidden = true
            panel.standardWindowButton(.miniaturizeButton)?.isHidden = true
            panel.standardWindowButton(.zoomButton)?.isHidden = true
            panel.isFloatingPanel = true
            panel.level = .floating
            panel.hidesOnDeactivate = false
            panel.isReleasedWhenClosed = false
            panel.isMovableByWindowBackground = true
            panel.backgroundColor = .white
            panel.appearance = NSAppearance(named: .aqua)
            panel.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            panel.delegate = self
            panel.engine = engine
            let host = NSHostingController(rootView: QuickNoteView(close: { [weak self] in self?.close() })
                .environmentObject(engine))
            host.sizingOptions = [.preferredContentSize]
            panel.contentViewController = host
            self.panel = panel
        }
        guard let panel else { return }
        position(panel)
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    func close() {
        panel?.orderOut(nil)
        finishStep()
    }

    func windowWillClose(_ notification: Notification) { finishStep() }

    /// Closing (Esc, ×) during the label step is a Skip: the note stays queued, unlabeled.
    private func finishStep() {
        guard let engine, let step = engine.notes.steps[.quick] else { return }
        if step.phase == .applying { return }
        engine.closeLabelStep(.quick)
    }

    /// Beside the flask, toward the screen center; bottom-right of the screen without one.
    private func position(_ panel: NSPanel) {
        let size = panel.frame.size
        let flask = NSApp.windows.first { $0.contentView is FloatingIconView && $0.isVisible }?.frame
        let screen = (flask.flatMap { f in NSScreen.screens.first { $0.frame.intersects(f) } } ?? NSScreen.main)?.visibleFrame
            ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        var origin: NSPoint
        if let f = flask {
            let left = f.midX > screen.midX
            origin = NSPoint(x: left ? f.minX - size.width - 4 : f.maxX + 4, y: f.minY + 12)
        } else {
            origin = NSPoint(x: screen.maxX - size.width - 24, y: screen.minY + 110)
        }
        origin.x = min(max(origin.x, screen.minX + 8), screen.maxX - size.width - 8)
        origin.y = min(max(origin.y, screen.minY + 8), screen.maxY - size.height - 8)
        panel.setFrameOrigin(origin)
    }
}

/// Key handling for the quick note: ⌘V adds an image, ⌘↩ saves or applies, Esc closes.
final class QuickNotePanel: NSPanel {
    weak var engine: AppModel?

    override var canBecomeKey: Bool { true }

    override func cancelOperation(_ sender: Any?) { close() }

    override func performKeyEquivalent(with event: NSEvent) -> Bool {
        let flags = event.modifierFlags.intersection(.deviceIndependentFlagsMask)
        if flags == .command, let engine {
            if event.charactersIgnoringModifiers == "v", engine.notes.steps[.quick] == nil,
               ComposeImageIntake.hasImage(NSPasteboard.general),
               !(firstResponder is NSText && NSPasteboard.general.string(forType: .string) != nil) {
                let images = MainActor.assumeIsolated { ComposeImageIntake.images(from: NSPasteboard.general) }
                MainActor.assumeIsolated { engine.updateDraft(.quick) { $0.images += images } }
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

    var body: some View {
        QuickNoteBody(notes: engine.notes, close: close)
    }
}

/// Panel content (also rendered by `--snapshot`).
struct QuickNoteBody: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var notes: NotesStore
    let close: () -> Void
    private let owner = ComposeOwner.quick

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let step = notes.steps[owner] { labelStep(step) } else { composer }
        }
        .padding(16)
        .frame(width: 400)
        .background(Color.white)
        .foregroundStyle(Theme.ink)
        .onChange(of: notes.steps[owner]?.phase) { _, phase in
            if phase == .applied {
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.8) { close() }
            }
        }
    }

    // MARK: Before queueing (panel 3)

    @ViewBuilder private var composer: some View {
        let draft = notes.draft(owner)
        BareTextField(placeholder: "Title", text: binding(\.title), font: .system(size: 17, weight: .semibold, design: .rounded))
        BareTextEditor(placeholder: "Write a note…", text: binding(\.text), font: Theme.body(13), minHeight: 40)
            .padding(0)
        SourcePickerRow(draft: binding(\.self), compact: true)
        ForEach(draft.images) { image in
            HStack(spacing: 10) {
                ComposeImagePreview(image: image, mode: image.mode)
                    .frame(width: 44, height: 44).clipShape(RoundedRectangle(cornerRadius: 10))
                Text(image.name).font(Theme.body(12, .semibold)).lineLimit(1).frame(maxWidth: .infinity, alignment: .leading)
                ImageModeSwitch(mode: image.mode, height: 26, font: Theme.body(11, .bold), compact: true) { mode in
                    engine.updateDraft(owner) { d in if let i = d.images.firstIndex(where: { $0.id == image.id }) { d.images[i].mode = mode } }
                }
                .fixedSize()
                Button { engine.updateDraft(owner) { $0.images.removeAll { $0.id == image.id } } } label: {
                    Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint)
                }
                .buttonStyle(.plain).accessibilityLabel("Remove \(image.name)")
            }
            .padding(8)
            .background(RoundedRectangle(cornerRadius: 14).fill(Theme.panel))
        }
        if let error = notes.addErrors[owner] {
            Text(error).font(Theme.body(11)).foregroundStyle(Theme.peachInk)
        }
        HStack(spacing: 10) {
            Text("⌘V adds an image · ⌘↩ saves").font(Theme.body(11)).foregroundStyle(Theme.faint)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button { engine.addNote(owner) } label: {
                HStack(spacing: 6) {
                    if notes.adding.contains(owner) { Spinner(color: .white, size: 12) }
                    Text("Add to queue").font(Theme.body(13, .semibold))
                }
                .padding(.horizontal, 16).frame(height: 34)
                .foregroundStyle(.white)
                .background(Capsule().fill(Theme.primary))
            }
            .buttonStyle(.plain)
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

        HStack(spacing: 10) {
            if step.phase == .suggesting {
                AddLabelField(placeholder: "Type a label while you wait", width: 240, height: 28) { raw in
                    var ok = false
                    engine.editStep(owner) { ok = $0.add(raw) }
                    return ok
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            } else {
                Text("Skip leaves it unlabeled → Labels").font(Theme.body(11)).foregroundStyle(Theme.faint)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            SmallButton(title: "Skip", height: 32) { engine.skipLabels(owner); close() }
            if step.phase != .suggesting || step.canApply {
                SmallButton(title: step.phase == .applying ? "Applying…" : "Apply \(step.chosen.count) \(step.chosen.count == 1 ? "label" : "labels")",
                            fill: Theme.primary, ink: .white, height: 32, weight: .bold) { engine.applyLabels(owner) }
                    .disabled(!step.canApply).opacity(step.canApply || step.phase == .applying ? 1 : 0.5)
            }
        }
        .padding(.top, 4)
        .overlay(alignment: .top) { Rectangle().fill(Theme.border).frame(height: 1).offset(y: -4) }
    }

    private func binding<T>(_ path: WritableKeyPath<ComposeDraft, T>) -> Binding<T> {
        Binding(get: { notes.draft(owner)[keyPath: path] },
                set: { value in engine.updateDraft(owner) { $0[keyPath: path] = value } })
    }
}

/// "Haiku" for the label-suggestion model in status lines.
enum LabelsModelName {
    @MainActor
    static func labelSuggest(_ engine: AppModel) -> String {
        let sel = SettingsEdits.selection(.labelSuggest, settings: engine.settings)
        let runner = engine.notes.runners.first { $0.id == sel.runnerID }
        return SettingsEdits.modelTitle(sel.model, runner: runner)
    }
}
