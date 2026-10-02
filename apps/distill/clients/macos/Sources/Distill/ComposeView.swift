import AppKit
import SwiftUI
import DistillKit

/// Queue screen modes: the drop panel or the note composer.
enum AddMode: String { case files, note }

/// "Drop files | Write a note" switch in the Queue header.
struct AddModeSwitch: View {
    @Binding var mode: AddMode

    var body: some View {
        HStack(spacing: 0) {
            item(.files, "Drop files")
            item(.note, "Write a note")
        }
        .padding(4)
        .background(Capsule().fill(Theme.panel))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Add mode")
        .fixedSize() // never wraps: "Drop files | Write a note" keeps one line at any window width
    }

    private func item(_ m: AddMode, _ title: String) -> some View {
        let on = mode == m
        return Button { mode = m } label: {
            Text(title).font(Theme.body(13, .semibold)).lineLimit(1).fixedSize()
                .padding(.horizontal, 16).frame(height: 32)
                .foregroundStyle(on ? Theme.ink : Theme.muted)
                .background(Capsule().fill(on ? Color.white : .clear).shadow(color: .black.opacity(on ? 0.1 : 0), radius: 1.5, y: 1))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
    }
}

/// Write a note (canvas: "Write a note", "Write a note · loading").
struct ComposeScreen: View {
    @EnvironmentObject var engine: AppModel
    @Binding var mode: AddMode

    var body: some View {
        ComposeScreenBody(notes: engine.notes, mode: $mode)
    }
}

private struct ComposeScreenBody: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var notes: NotesStore
    @Binding var mode: AddMode
    @State private var window: NSWindow?
    @State private var pasteMonitor: Any?
    @State private var dropTargeted = false
    @Environment(\.snapshotMode) private var snapshot

    private let owner = ComposeOwner.compose
    private var draft: ComposeDraft { notes.draft(owner) }
    private var step: LabelStep? { notes.steps[owner] }

    var body: some View {
        VStack(alignment: .leading, spacing: 20) {
            HStack(spacing: 16) {
                Text("Add to your vault").font(Theme.display(30)).lineLimit(1).minimumScaleFactor(0.7)
                    .frame(maxWidth: .infinity, alignment: .leading)
                AddModeSwitch(mode: $mode)
            }
            card
            footer
        }
        .padding(.horizontal, 44).padding(.top, 30).padding(.bottom, 26)
        .background { if !snapshot { WindowReader(window: $window) } }
        .onAppear(perform: installPaste)
        .onDisappear(perform: removePaste)
    }

    // MARK: Card

    /// The card fills the space between the header and the footer. The note box
    /// takes the card's spare height (never a blank gap under the images); in a
    /// short window it keeps 4 lines and the whole card scrolls with an overlay
    /// bar and a fade (canvas: "Write a note: size and scrolling").
    private var card: some View {
        ComposeCardLayout(snapshot: snapshot, minEditor: ComposeSizing.minEditorHeight) {
            BareTextField(placeholder: "Title", text: binding(\.title),
                          font: .system(size: 22, weight: .semibold, design: .rounded))
                .disabled(step != nil)
        } editor: {
            Group {
                BareTextEditor(placeholder: "Write what you want to remember…", text: binding(\.text), font: Theme.body(15), minHeight: 52, maxHeight: .infinity, bar: .full, fillsHeight: true, textSize: 15,
                               images: engine.imageHost(owner))
                    .padding(0)
            }
            .disabled(step != nil)
        } bottom: {
            VStack(alignment: .leading, spacing: 16) {
                VStack(alignment: .leading, spacing: 10) {
                    SourcePickerRow(draft: binding(\.self))
                        .disabled(step != nil)
                    labelsRow
                }
                .padding(.horizontal, 14).padding(.vertical, 12)
                .background(RoundedRectangle(cornerRadius: 16).fill(Theme.panel))
                if let error = notes.addErrors[owner] {
                    Label(error, systemImage: "exclamationmark.circle.fill")
                        .font(Theme.body(12)).foregroundStyle(Theme.peachInk)
                }
            }
        }
        .background(RoundedRectangle(cornerRadius: 22).fill(dropTargeted ? Theme.primaryTint.opacity(0.4) : Color.white))
        .overlay(RoundedRectangle(cornerRadius: 22).strokeBorder(dropTargeted ? Theme.primary : Theme.border, lineWidth: 1.5))
        .clipShape(RoundedRectangle(cornerRadius: 22))
        .compositingGroup()
        .shadow(color: Color(hex: 0x1D1C1A).opacity(0.05), radius: 15, y: 10)
        .modifier(ComposeDropModifier(enabled: !snapshot, targeted: $dropTargeted) { providers in
            guard step == nil else { return false }
            return ComposeDrop.handle(providers) { images in engine.insertImages(owner, images) }
        })
    }

    @ViewBuilder private var labelsRow: some View {
        HStack(alignment: .center, spacing: 8) {
            Text("Labels").font(Theme.body(12, .bold)).foregroundStyle(Theme.muted).frame(width: 58, alignment: .leading)
            if let step {
                LabelStepChips(engine: engine, owner: owner, step: step, inline: true)
            } else {
                Image(systemName: "sparkle").font(.system(size: 11)).foregroundStyle(Theme.faint)
                Text(engine.suggestLabelsAfterQueue
                     ? "Suggested from the note's text and images after you add it to the queue."
                     : "Add your own after you add it to the queue.")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 12) {
            if let step {
                Text(footerText(step)).font(Theme.body(13)).foregroundStyle(Theme.muted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                switch step.phase {
                case .suggesting:
                    SoftButton(title: "Skip labels") { engine.skipLabels(owner) }
                    if step.canApply {
                        PrimaryButton(title: applyTitle(step), systemImage: "checkmark") { engine.applyLabels(owner) }
                    } else {
                        queuedBadge
                    }
                case .choosing, .applying:
                    SoftButton(title: "Skip labels") { engine.skipLabels(owner) }
                    PrimaryButton(title: step.phase == .applying ? "Applying…" : applyTitle(step), systemImage: "checkmark") {
                        engine.applyLabels(owner)
                    }
                    .disabled(!step.canApply).opacity(step.canApply || step.phase == .applying ? 1 : 0.5)
                    .keyboardShortcut(.return, modifiers: .command)
                case .applied, .skipped:
                    PrimaryButton(title: "Write another", systemImage: "plus") { engine.closeLabelStep(owner) }
                        .keyboardShortcut(.return, modifiers: .command)
                }
            } else {
                Text(draft.blocker ?? draft.summary + (engine.suggestLabelsAfterQueue ? " Labels are suggested once it is queued." : ""))
                    .font(Theme.body(13)).foregroundStyle(Theme.muted).lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)
                SoftButton(title: "Discard") { engine.discardDraft(owner) }
                    .disabled(draft.isEmpty)
                PrimaryButton(title: notes.adding.contains(owner) ? "Adding…" : "Add to queue", systemImage: "plus") {
                    engine.addNote(owner)
                }
                .disabled(draft.blocker != nil || notes.adding.contains(owner))
                .opacity(draft.blocker == nil ? 1 : 0.5)
                .keyboardShortcut(.return, modifiers: .command)
            }
        }
    }

    private var queuedBadge: some View {
        Text("✓ Queued").font(Theme.body(14, .bold))
            .padding(.horizontal, 20).frame(height: 40)
            .foregroundStyle(Theme.limeInk)
            .background(Capsule().fill(Color(hex: 0xF3FDE4)))
    }

    private func applyTitle(_ step: LabelStep) -> String {
        "Apply \(step.chosen.count) \(step.chosen.count == 1 ? "label" : "labels")"
    }

    private func footerText(_ step: LabelStep) -> String {
        switch step.phase {
        case .suggesting: return "Saved to the queue. Pick labels when the suggestions land, or close — the note stays queued."
        case .choosing, .applying: return "Saved to the queue. Apply confirms these labels; Skip leaves the note unlabeled."
        case .applied: return "Queued and labeled. It goes into your vault with the next batch."
        case .skipped: return "Queued without labels. It shows in Labels → Unlabeled."
        }
    }

    private func binding<T>(_ path: WritableKeyPath<ComposeDraft, T>) -> Binding<T> {
        Binding(get: { notes.draft(owner)[keyPath: path] },
                set: { value in engine.updateDraft(owner) { $0[keyPath: path] = value } })
    }

    // MARK: Paste

    /// ⌘V while composing adds images to the note (at the cursor) instead of the queue.
    private func installPaste() {
        guard !snapshot else { return }
        PasteboardIntake.composeTarget = { pb in
            guard let window, NSApp.keyWindow === window, mode == .note, engine.notes.steps[owner] == nil else { return false }
            let images = ComposeImageIntake.images(from: pb)
            if !images.isEmpty {
                engine.insertImages(owner, images)
                return true
            }
            if let text = pb.string(forType: .string), !text.isEmpty {
                engine.updateDraft(owner) { $0.text += ($0.text.isEmpty ? "" : "\n") + text }
                return true
            }
            return false
        }
        // A text field is editing: an image-only clipboard still becomes an image.
        pasteMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { event in
            guard event.modifierFlags.intersection(.deviceIndependentFlagsMask) == .command,
                  event.charactersIgnoringModifiers == "v",
                  let window, NSApp.keyWindow === window, window.firstResponder is NSText,
                  engine.notes.steps[owner] == nil,
                  NSPasteboard.general.string(forType: .string) == nil,
                  ComposeImageIntake.hasImage(NSPasteboard.general) else { return event }
            engine.insertImages(owner, ComposeImageIntake.images(from: NSPasteboard.general))
            return nil
        }
    }

    private func removePaste() {
        PasteboardIntake.composeTarget = nil
        if let pasteMonitor { NSEvent.removeMonitor(pasteMonitor) }
        pasteMonitor = nil
    }
}

// MARK: Source picker

/// Source row: the group chip (menu of groups), the group's sources, and a
/// free-text link/channel/person field. Groups come from Settings → Sources.
struct SourcePickerRow: View {
    @EnvironmentObject var engine: AppModel
    @Binding var draft: ComposeDraft
    private var groups: [SourceGroup] { SettingsEdits.taxonomy(engine.settings) }

    private var group: SourceGroup? {
        if let id = draft.group, let g = groups.first(where: { $0.id == id }) { return g }
        if let s = draft.source, let g = groups.first(where: { $0.sources.contains { $0.id == s } }) { return g }
        return groups.first
    }

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            Text("Source").font(Theme.body(12, .bold)).foregroundStyle(Theme.muted).frame(width: 58, height: 28, alignment: .leading)
            FlowRow(spacing: 8) {
                groupMenu
                ForEach(group?.sources ?? [], id: \.id) { source in
                    sourceChip(source, height: 28)
                }
                refField.frame(width: 210)
            }
        }
    }

    private var groupMenu: some View {
        Menu {
            ForEach(groups, id: \.id) { g in Button(g.label) { draft.group = g.id } }
        } label: {
            HStack(spacing: 5) {
                Text(group?.label ?? "Source").font(Theme.body(12, .bold))
                Image(systemName: "chevron.right").font(.system(size: 8, weight: .heavy))
            }
            .padding(.horizontal, 10).frame(height: 28)
            .foregroundStyle(Theme.primary)
            .background(Capsule().fill(Theme.primaryTint))
        }
        .menuStyle(.button).buttonStyle(.plain).menuIndicator(.hidden).fixedSize()
    }

    private func sourceChip(_ source: SourceDefinition, height: CGFloat) -> some View {
        let on = draft.source == source.id
        return Button { draft.toggleSource(source.id); draft.group = group?.id } label: {
            Text(source.label).font(Theme.body(12, .semibold)).lineLimit(1)
                .padding(.horizontal, 10).frame(height: height)
                .foregroundStyle(on ? Color.white : Color(hex: 0x48463F))
                .background(Capsule().fill(on ? Theme.primary : Color.white))
                .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }

    private var refField: some View {
        HStack(spacing: 6) {
            Image(systemName: "link").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint)
            BareTextField(placeholder: "Link, channel or person", text: $draft.sourceRef, font: Theme.body(12))
        }
        .padding(.horizontal, 10).frame(height: 28)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().strokeBorder(Theme.border))
    }
}

// MARK: Label step chips

/// The chips of the label step: shimmer while suggesting, then the
/// suggestions (green existing, peach new) and the user's own, with
/// remove and add. Used inline by the composer and stacked by the quick note.
struct LabelStepChips: View {
    let engine: AppModel
    let owner: ComposeOwner
    let step: LabelStep
    var inline: Bool

    var body: some View {
        FlowRow(spacing: 6) {
            switch step.phase {
            case .suggesting:
                if inline {
                    Text("Suggesting labels…").font(Theme.body(12, .bold)).fixedSize()
                }
                ForEach(step.chips, id: \.name) { chip($0) }
                Shimmer(width: 64, height: 24, radius: 12)
                Shimmer(width: 84, height: 24, radius: 12)
                Shimmer(width: 72, height: 24, radius: 12)
                if inline {
                    Text("Queued ✓ · type your own or Skip").font(Theme.body(11)).foregroundStyle(Theme.muted).fixedSize()
                    AddLabelField { raw in add(raw) }
                }
            case .choosing, .applying:
                if let error = step.suggestError, inline {
                    Text("Couldn't get labels: \(error). The note is still queued; add your own.")
                        .font(Theme.body(11)).foregroundStyle(Theme.peachInk).fixedSize(horizontal: false, vertical: true)
                }
                ForEach(step.chips, id: \.name) { chip($0) }
                if step.phase == .choosing { AddLabelField { raw in add(raw) } }
                if step.phase == .applying { Spinner(size: 14) }
            case .applied:
                ForEach(step.chosen, id: \.self) { LabelChip(name: $0, style: .plain) }
                Text("Applied ✓").font(Theme.body(11, .bold)).foregroundStyle(Theme.limeInk)
            case .skipped:
                Text("Skipped: the note stays unlabeled.").font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
            if let error = step.applyError {
                Text(error).font(Theme.body(11)).foregroundStyle(Theme.peachInk).fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private func chip(_ s: LabelSuggestion) -> some View {
        let chosen = step.isChosen(s.name)
        let suggested = step.suggestions.contains { $0.name == s.name }
        let style: LabelChip.Style = !chosen ? .muted : !suggested ? .plain : s.existing ? .suggestedExisting : .suggestedNew
        return LabelChip(name: s.name, style: style, sparkle: suggested && !inline,
                         onRemove: chosen && step.phase != .applying ? { engine.editStep(owner) { $0.remove(s.name) } } : nil,
                         onTap: chosen ? nil : { engine.editStep(owner) { $0.toggle(s.name) } })
            .help(chosen ? "" : "Click to use this label again")
    }

    private func add(_ raw: String) -> Bool {
        var ok = false
        engine.editStep(owner) { ok = $0.add(raw) }
        return ok
    }
}

/// Left-to-right wrapping layout for chips.
struct FlowRow: Layout {
    var spacing: CGFloat = 6
    var lineSpacing: CGFloat = 6

    private struct Item { let index: Int; let x: CGFloat; let size: CGSize }
    private struct Line { var items: [Item] = []; var height: CGFloat = 0 }

    /// Lines of items; an item wider than the row is measured at the row width.
    private func lines(width: CGFloat, subviews: Subviews) -> [Line] {
        var lines = [Line()]
        var x: CGFloat = 0
        for (i, v) in subviews.enumerated() {
            var s = v.sizeThatFits(.unspecified)
            if s.width > width { s = v.sizeThatFits(ProposedViewSize(width: width, height: nil)); s.width = min(s.width, width) }
            if x > 0, x + s.width > width { lines.append(Line()); x = 0 }
            lines[lines.count - 1].items.append(Item(index: i, x: x, size: s))
            lines[lines.count - 1].height = max(lines[lines.count - 1].height, s.height)
            x += s.width + spacing
        }
        return lines
    }

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? .infinity
        let ls = lines(width: width, subviews: subviews)
        let height = ls.reduce(0) { $0 + $1.height } + lineSpacing * CGFloat(max(0, ls.count - 1))
        let used = ls.map { ($0.items.last.map { $0.x + $0.size.width }) ?? 0 }.max() ?? 0
        return CGSize(width: proposal.width ?? used, height: height)
    }

    /// Items are centered vertically within their line.
    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var y = bounds.minY
        for line in lines(width: bounds.width, subviews: subviews) {
            for item in line.items {
                subviews[item.index].place(at: CGPoint(x: bounds.minX + item.x, y: y + (line.height - item.size.height) / 2),
                                           anchor: .topLeading, proposal: ProposedViewSize(item.size))
            }
            y += line.height + lineSpacing
        }
    }
}

// MARK: Drop + window helpers

/// `.onDrop` only outside snapshots (ImageRenderer cannot draw its platform view).
struct ComposeDropModifier: ViewModifier {
    let enabled: Bool
    @Binding var targeted: Bool
    let perform: ([NSItemProvider]) -> Bool

    func body(content: Content) -> some View {
        if enabled {
            content.onDrop(of: [.fileURL, .image], isTargeted: $targeted, perform: perform)
        } else {
            content
        }
    }
}

enum ComposeDrop {
    /// Image files (or raw images) dropped on the composer.
    static func handle(_ providers: [NSItemProvider], add: @escaping ([DraftImage]) -> Void) -> Bool {
        var handled = false
        for provider in providers where provider.hasItemConformingToTypeIdentifier("public.file-url") {
            handled = true
            _ = provider.loadObject(ofClass: URL.self) { url, _ in
                guard let url, DraftImage.isImage(url) else { return }
                DispatchQueue.main.async { add([DraftImage(url: url)]) }
            }
        }
        return handled
    }
}

/// Reports the hosting NSWindow.
struct WindowReader: NSViewRepresentable {
    @Binding var window: NSWindow?

    func makeNSView(context: Context) -> NSView {
        let view = NSView()
        DispatchQueue.main.async { window = view.window }
        return view
    }

    func updateNSView(_ view: NSView, context: Context) {
        if view.window !== window { DispatchQueue.main.async { window = view.window } }
    }
}
