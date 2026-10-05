import SwiftUI
import DistillKit

// The parts of the v6 Review (canvas: "Review rows"): a group that folds, a new or updated page, and a
// source merged with the page it produced and its labels. Review and History share them.

/// A group that folds: chevron, title, count, a one-line summary, an optional action (canvas: ReviewGroupHeader).
struct ReviewGroupHeader: View {
    let title: String
    var count: Int
    var summary: String = ""
    var expanded = true
    /// A spinner before the summary (labels being suggested).
    var busy = false
    /// "Show all 22", "Fold", "Pick all"; nil = none.
    var action: String? = nil
    var actionDisabled = false
    var onToggle: () -> Void = {}
    var onAction: () -> Void = {}

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onToggle) {
                HStack(spacing: 8) {
                    Image(systemName: expanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted).frame(width: 12)
                    Text(title).font(Theme.body(14, .bold)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                    Text("\(count)").font(Theme.body(12, .bold)).foregroundStyle(Theme.muted)
                        .padding(.horizontal, 8).padding(.vertical, 1)
                        .background(Capsule().fill(Color(hex: 0xF1EFEB))).fixedSize()
                    if busy { Spinner(color: Theme.primary, size: 11).padding(.leading, 4) }
                    Text(summary).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail)
                        .padding(.leading, 4)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("\(title), \(count)")
            .accessibilityValue(expanded ? "open" : "folded")
            if let action {
                Button(action: onAction) {
                    Text(action).font(Theme.body(12, .semibold)).foregroundStyle(actionDisabled ? Color(hex: 0xB5B1A9) : Theme.primary)
                        .padding(.horizontal, 6).frame(height: 26).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .disabled(actionDisabled)
                .fixedSize()
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 8)
    }
}

/// A new or updated page that is not a source page (entity, concept, index, overview, log, ledgers);
/// a click opens it (canvas: ReviewChangeRow).
struct ReviewChangeRow: View {
    enum Change: String { case new, updated }

    let title: String
    var change: Change = .new
    /// entity | concept | "" (a tag after the title).
    var kind: String = ""
    var note: String = ""
    var directory: String = ""
    /// v8: the page is in the vault now (Review after Approve): an Open link opens it.
    var openable = false
    /// Snapshots: drawn hovered.
    var hover = false
    var onOpen: (() -> Void)? = nil
    @State private var hovering = false

    var body: some View {
        let isNew = change == .new
        Button { onOpen?() } label: {
            HStack(spacing: 12) {
                Text(isNew ? "+" : "•").font(Theme.body(13, .bold))
                    .foregroundStyle(isNew ? Theme.limeInk : Theme.primary)
                    .frame(width: 22, height: 22)
                    .background(Circle().fill(isNew ? Theme.limeTint : Theme.primaryTint))
                Text(title).font(Theme.body(14, isNew ? .semibold : .medium)).lineLimit(1).truncationMode(.middle)
                    .layoutPriority(1)
                if !kind.isEmpty {
                    Text(kind).font(Theme.body(10.5, .bold)).foregroundStyle(kindInk)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 8).fill(kindFill)).fixedSize()
                }
                Text(note).font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 8)
                Text(directory).font(Theme.body(12)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
                if openable {
                    Text("Open").font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary).padding(.horizontal, 8).fixedSize()
                        .accessibilityLabel("Open \(title)")
                }
            }
            .padding(.horizontal, 10).padding(.vertical, 7)
            .background(RoundedRectangle(cornerRadius: 12).fill(hover || hovering ? Theme.panel : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(openable ? "Open the page in Obsidian" : "Open the page as it will be")
    }

    private var kindFill: Color { kind == "entity" ? Color(hex: 0xFFF4D6) : kind == "concept" ? Color(hex: 0xEFE9FF) : Theme.panel }
    private var kindInk: Color { kind == "entity" ? Color(hex: 0x8A5A00) : kind == "concept" ? Color(hex: 0x5B3DB8) : Theme.muted }
}

/// One source merged with the page it produced: the page title, "from" the file and its labels (a LabelLine).
/// Hover shows Open page and Remove, and Edit on the labels; rows can be picked (canvas: ReviewSourceRow).
struct ReviewSourceRow: View {
    let title: String
    /// The input file's name ("tea-club-sync-2026-09-28.md").
    var file: String
    var labels: [LabelSuggestion] = []
    /// `.editing` turns the chips removable with an Add field, Done and Cancel.
    var labelState: LabelLineState = .suggested
    /// Snapshots: drawn hovered.
    var hover = false
    var selectable = false
    var selected = true
    var removed = false
    var onSelect: ((Bool) -> Void)? = nil
    var onOpen: (() -> Void)? = nil
    var onRemove: (() -> Void)? = nil
    var onUndo: (() -> Void)? = nil
    /// Edit (or + Add on a source without labels): start editing with these labels.
    var onEdit: (([String]) -> Void)? = nil
    /// While editing.
    var onRemoveLabel: ((String) -> Void)? = nil
    var onAddLabel: ((String) -> Void)? = nil
    var onDone: (() -> Void)? = nil
    var onCancel: (() -> Void)? = nil
    @State private var hovering = false

    private var hot: Bool { (hover || hovering) && !removed }
    private var editing: Bool { labelState == .editing }

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if selectable && !removed {
                ReviewCheckbox(checked: selected) { onSelect?(!selected) }.padding(.top, 3)
            } else {
                Text("+").font(Theme.body(13, .bold)).foregroundStyle(Theme.limeInk)
                    .frame(width: 22, height: 22).background(Circle().fill(Theme.limeTint)).padding(.top, 1)
            }
            VStack(alignment: .leading, spacing: 5) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(title).font(Theme.body(14, .semibold)).strikethrough(removed).lineLimit(1).truncationMode(.tail)
                        .layoutPriority(1)
                    Text("from \(file)").font(Theme.body(12)).foregroundStyle(Theme.faint).lineLimit(1).truncationMode(.middle)
                }
                if removed {
                    HStack(spacing: 8) {
                        Text("Removed from this batch: it won’t be added to the vault. The file stays in inbox/.")
                            .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                        Button("Undo") { onUndo?() }.buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary)
                    }
                    .frame(minHeight: 26)
                } else {
                    labelLine
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if hot && !editing {
                HStack(spacing: 12) {
                    Button("Open page") { onOpen?() }.buttonStyle(.plain).foregroundStyle(Theme.primary)
                    if onRemove != nil {
                        Button("Remove") { onRemove?() }.buttonStyle(.plain).foregroundStyle(Theme.peachInk)
                            .help("Take this source out of the batch: it won’t be added to the vault, and its inbox file stays")
                    }
                }
                .font(Theme.body(12, .semibold)).fixedSize().padding(.top, 2)
            }
        }
        .padding(.horizontal, 10).padding(.vertical, 9)
        .background(RoundedRectangle(cornerRadius: 12).fill(editing ? Color(hex: 0xF2F7FF) : hot ? Theme.panel : .clear))
        .opacity(removed ? 0.72 : 1)
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }

    private var labelLine: some View {
        let names = labels.map(\.name)
        // A source without labels gets the line's own + Add on hover; the others Edit.
        let action: String = (hot || editing) && [.suggested, .confirmed, .own].contains(labelState) ? "Edit" : ""
        return LabelLine(labels: labels, state: labelState,
                         lead: labelState == .suggested ? "" : nil,
                         action: action, quiet: !(hot || editing),
                         onRemove: { name in editing ? onRemoveLabel?(name) : onEdit?(names.filter { $0 != name }) },
                         onAdd: { name in editing ? onAddLabel?(name) : onEdit?(names.contains(name) ? names : names + [name]) },
                         onAction: { onEdit?(names) },
                         onDone: onDone, onCancel: onCancel)
    }
}

/// The 18 pt checkbox a source row is picked with.
struct ReviewCheckbox: View {
    let checked: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            ZStack {
                RoundedRectangle(cornerRadius: 5).fill(checked ? Theme.primary : Color.white)
                if !checked { RoundedRectangle(cornerRadius: 5).strokeBorder(Color(hex: 0xB5B1A9), lineWidth: 1.5) }
                if checked { Image(systemName: "checkmark").font(.system(size: 10, weight: .heavy)).foregroundStyle(.white) }
            }
            .frame(width: 18, height: 18)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(checked ? "Picked" : "Not picked")
        .accessibilityAddTraits(.isButton)
    }
}

/// A group's surface: a soft panel holding the header and its rows.
struct ReviewGroup<Content: View>: View {
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: 0, content: content)
            .padding(.horizontal, 6).padding(.top, 4).padding(.bottom, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color(hex: 0xFBFAF8)))
    }
}

/// The split Approve button: the title approves; the chevron opens the options (drawn in the view, so it
/// shows in snapshots too).
struct ApproveSplitButton: View {
    let title: String
    var enabled = true
    /// The chevron's menu items: (title, detail, action).
    var options: [(String, String, () -> Void)] = []
    @Binding var menuOpen: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 1) {
            Button(action: action) {
                HStack(spacing: 7) {
                    Image(systemName: "checkmark").font(.system(size: 12, weight: .bold))
                    Text(title).font(Theme.body(14, .semibold)).lineLimit(1)
                }
                .padding(.leading, 20).padding(.trailing, options.isEmpty ? 20 : 14)
                .frame(height: 40)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            if !options.isEmpty {
                Button { menuOpen.toggle() } label: {
                    Image(systemName: "chevron.down").font(.system(size: 11, weight: .bold))
                        .frame(width: 34, height: 40)
                        .background(Color.white.opacity(0.12))
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .accessibilityLabel("More ways to approve")
            }
        }
        .foregroundStyle(.white)
        .background(Capsule().fill(Theme.primary))
        .clipShape(Capsule())
        .shadow(color: Theme.primary.opacity(enabled ? 0.28 : 0), radius: 8, y: 4)
        .fixedSize()
        .disabled(!enabled)
        .opacity(enabled ? 1 : 0.45)
        .overlay(alignment: .bottomTrailing) {
            if menuOpen && enabled && !options.isEmpty {
                VStack(alignment: .leading, spacing: 2) {
                    ForEach(Array(options.enumerated()), id: \.offset) { i, option in
                        Button { menuOpen = false; option.2() } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(option.0).font(Theme.body(13, .semibold)).foregroundStyle(Theme.ink)
                                Text(option.1).font(Theme.body(11.5)).foregroundStyle(Theme.muted)
                                    .fixedSize(horizontal: false, vertical: true)
                            }
                            .padding(.horizontal, 12).padding(.vertical, 9)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 10).fill(i == 0 ? Theme.primaryTint.opacity(0.6) : .clear))
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
                .padding(6)
                .frame(width: 300)
                .background(RoundedRectangle(cornerRadius: 14).fill(Color.white).shadow(color: .black.opacity(0.14), radius: 16, y: 6))
                .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
                .offset(y: -52)
                .fixedSize(horizontal: false, vertical: true)
            }
        }
    }
}

/// The dark two-line toast after Process now (canvas: queue-card-process-now, queue-card-nothing-yet).
struct QueueToastView: View {
    let toast: QueueToast
    var dismiss: () -> Void = {}

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            if toast.started {
                Image(systemName: "checkmark").font(.system(size: 13, weight: .bold)).foregroundStyle(Theme.lime).padding(.top, 2)
            }
            VStack(alignment: .leading, spacing: 3) {
                Text(toast.title).font(Theme.body(13, .bold)).foregroundStyle(.white)
                Text(toast.detail).font(Theme.body(12)).foregroundStyle(Color(hex: 0xD6D3CC))
                    .fixedSize(horizontal: false, vertical: true)
            }
            Spacer(minLength: 0)
            Button(action: dismiss) {
                Image(systemName: "xmark").font(.system(size: 10, weight: .bold)).foregroundStyle(Color(hex: 0x9B978F))
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss")
        }
        .padding(.horizontal, 16).padding(.vertical, 14)
        .frame(width: 460)
        .background(RoundedRectangle(cornerRadius: 16).fill(Theme.ink).shadow(color: .black.opacity(0.2), radius: 12, y: 6))
        .padding(.bottom, 22)
        .transition(.opacity)
    }
}
