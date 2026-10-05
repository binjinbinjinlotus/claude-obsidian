import SwiftUI
import DistillKit

/// The canvas ActivityRow (components.json): one calm line per entry in History →
/// Activity. A neutral tile for the kind of thing, the summary the core wrote,
/// then "time · source" in faint text. Only a failure gets colour (a peach tile
/// and a Failed pill); a delete kept in Distill's trash carries "In trash", and
/// "Restored" after Restore.
struct ActivityRow: View {
    /// chat, collector, action, batch, queue, note, connection, settings, runner (others: a neutral dot).
    var family: String
    var summary: String
    var time: String
    /// Mac app, CLI, Agent, Automatic, Other app, Distill.
    var source: String
    /// "ok" or "failed".
    var outcome = "ok"
    /// "", "In trash" or "Restored".
    var tag = ""
    var selected = false
    /// Snapshots draw the hover; in the app the pointer does.
    var hover = false
    /// nil: the width it is given.
    var width: CGFloat? = nil
    var onSelect: () -> Void = {}

    @State private var hovering = false

    static let height: CGFloat = 40

    var body: some View {
        let failed = outcome == "failed"
        let lit = hover || hovering
        Button(action: onSelect) {
            HStack(spacing: 10) {
                Image(systemName: Self.icon(family))
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(failed ? Theme.peachInk : Theme.muted)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(failed ? Theme.peachTint : Theme.panel))
                Text(summary).font(Theme.body(13)).foregroundStyle(Theme.ink)
                    .lineLimit(1).truncationMode(.tail)
                    .frame(maxWidth: .infinity, alignment: .leading)
                if failed {
                    Pill(text: "Failed", fill: Theme.peachTint, ink: Theme.peachInk, size: .small).fixedSize()
                } else if !tag.isEmpty {
                    let restored = tag == "Restored"
                    Text(tag).font(Theme.body(11, .semibold))
                        .foregroundStyle(restored ? Theme.limeInk : Theme.muted)
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 9).fill(restored ? ActionsTheme.doneFill : Theme.panel))
                        .fixedSize()
                }
                Text([time, source].filter { !$0.isEmpty }.joined(separator: " · "))
                    .font(Theme.body(11.5)).monospacedDigit().foregroundStyle(Theme.faint)
                    .lineLimit(1).fixedSize()
            }
            .padding(.leading, 8).padding(.trailing, 10)
            .frame(width: width, height: Self.height)
            .frame(maxWidth: width == nil ? .infinity : nil)
            .background(RoundedRectangle(cornerRadius: 10).fill(selected ? ActionsTheme.selectedFill : (lit ? Theme.panel : .clear)))
            .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(selected ? ActionsTheme.selectedStroke : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    /// The tile's symbol per family (the board's icons, as SF Symbols).
    static func icon(_ family: String) -> String {
        switch family {
        case "chat": "bubble.left"
        case "collector": "square.and.arrow.down"
        case "action": "checklist"
        case "batch": "checkmark.square"
        case "queue": "tray"
        case "note": "doc.text"
        case "connection": "link"
        case "settings": "slider.horizontal.3"
        case "runner": "key"
        case "labels": "tag"
        default: "circle.dashed"
        }
    }
}
