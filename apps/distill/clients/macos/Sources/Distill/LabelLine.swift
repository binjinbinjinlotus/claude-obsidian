import SwiftUI
import DistillKit

/// One line of labels for one source (canvas: LabelLine), used by a Queue row and by a source in Review.
/// Suggested labels are dashed chips (green = in the vault, peach = new): × drops one, + Add types one,
/// Accept all confirms. Waiting shows "Labels next · 3 at a time", suggesting a spinner, a failed suggestion
/// Retry (and Send without labels after 3 tries); editing shows removable chips, an Add field, Done and Cancel.
struct LabelLine: View {
    var labels: [LabelSuggestion] = []
    var state: LabelLineState = .suggested
    /// nil = the state's own lead ("Suggested", "Couldn’t suggest labels"…); "" hides it.
    var lead: String? = nil
    /// nil = the state's own action (Accept all, Edit, Retry); "" hides it.
    var action: String? = nil
    /// After the chips ("from the file", "tried 3 times").
    var note: String? = nil
    /// No × and no + Add (Review: Approve confirms what is shown; hover offers Edit).
    var quiet = false
    /// Send without labels, after 3 failed tries.
    var allowSkip = false
    var onRemove: ((String) -> Void)? = nil
    var onAdd: ((String) -> Void)? = nil
    var onAction: (() -> Void)? = nil
    var onSkip: (() -> Void)? = nil
    var onDone: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    /// + Add was pressed: an inline field takes the label.
    @State private var adding = false
    @State private var draft = ""

    var body: some View {
        FlowLayout(spacing: 6, lineSpacing: 6) {
            if state == .suggesting { Spinner(color: Theme.primary, size: 11) }
            if state == .suggested && !resolvedLead.isEmpty {
                Image(systemName: "sparkle").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.limeInk)
            }
            if state == .waiting { Image(systemName: "clock").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.faint) }
            if !resolvedLead.isEmpty {
                Text(resolvedLead).font(Theme.body(11.5, .bold)).foregroundStyle(leadInk).lineLimit(1).fixedSize()
            }
            ForEach(chips, id: \.name) { chip in
                LabelChip(name: chip.name, style: chipStyle(chip), onRemove: removable ? { onRemove?(chip.name) } : nil)
                    .fixedSize()
            }
            if state == .editing || adding {
                addField
            }
            if let note = resolvedNote {
                Text(note).font(Theme.body(11.5)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
            }
            if showAdd && !adding { link("+ Add", ink: Theme.muted) { adding = true } }
            if !resolvedAction.isEmpty && !adding { link(resolvedAction, ink: Theme.primary) { onAction?() } }
            if allowSkip && state == .failed && !adding { link("Send without labels", ink: Theme.muted) { onSkip?() } }
            if state == .editing {
                HStack(spacing: 2) {
                    Button { onDone?() } label: {
                        Text("Done").font(Theme.body(12, .bold)).foregroundStyle(.white)
                            .padding(.horizontal, 12).frame(height: 26).background(Capsule().fill(Theme.primary)).contentShape(Capsule())
                    }
                    .buttonStyle(.plain)
                    link("Cancel", ink: Theme.muted) { onCancel?() }
                }
                .fixedSize()
            } else if adding {
                link("Cancel", ink: Theme.muted) { adding = false; draft = "" }
            }
        }
        .frame(minHeight: 26, alignment: .leading)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: derived (the canvas template's logic)

    private var chips: [LabelSuggestion] {
        [.waiting, .suggesting, .none].contains(state) ? [] : labels
    }

    private var removable: Bool { (state == .suggested && !quiet) || state == .editing }

    private func chipStyle(_ chip: LabelSuggestion) -> LabelChip.Style {
        guard state == .suggested else { return .plain }
        return chip.existing ? .suggestedExisting : .suggestedNew
    }

    private var resolvedLead: String {
        if let lead { return lead }
        switch state {
        case .waiting: return "Labels next · 3 at a time"
        case .suggesting: return "Suggesting labels…"
        case .suggested: return "Suggested"
        case .failed: return "Couldn’t suggest labels"
        case .none: return "No labels"
        case .confirmed, .own, .editing: return ""
        }
    }

    private var leadInk: Color {
        switch state {
        case .waiting, .none: return Theme.faint
        case .failed: return Theme.peachInk
        default: return Theme.muted
        }
    }

    private var resolvedAction: String {
        if let action { return action }
        switch state {
        case .suggested: return "Accept all"
        case .confirmed, .own: return "Edit"
        case .failed: return "Retry"
        default: return ""
        }
    }

    private var resolvedNote: String? {
        if let note, !note.isEmpty { return note }
        return state == .own ? "from the file" : nil
    }

    private var showAdd: Bool { !quiet && [.suggested, .failed, .none].contains(state) && onAdd != nil }

    // MARK: parts

    private var addField: some View {
        BareTextField(placeholder: "Add a label…", text: $draft, font: Theme.body(12)) {
            let name = LabelLineText.clean(draft)
            guard !name.isEmpty else { return }
            onAdd?(name)
            draft = ""
            if state != .editing { adding = false }
        }
        .padding(.horizontal, 10)
        .frame(width: 130, height: 26)
        .background(Capsule().fill(Color.white))
        .overlay(Capsule().strokeBorder(Theme.primary, lineWidth: 1.5))
    }

    private func link(_ title: String, ink: Color, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(title).font(Theme.body(12, .semibold)).foregroundStyle(ink)
                .padding(.horizontal, 6).frame(height: 26).contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .fixedSize()
    }
}

enum LabelLineText {
    /// Trimmed, leading # dropped, spaces as dashes ("#Tea club" → "Tea-club").
    static func clean(_ raw: String) -> String {
        var s = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        while s.hasPrefix("#") { s.removeFirst() }
        return s.trimmingCharacters(in: .whitespaces).replacingOccurrences(of: " ", with: "-")
    }
}
