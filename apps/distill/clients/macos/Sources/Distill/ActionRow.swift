import SwiftUI
import DistillKit

/// The canvas ActionRow (components.json): one item in the Slack, Jira,
/// Confluence and History → Actions lists. Type tile, title, source line and
/// a status pill; on hover ✓ Complete and ⋯ (list), or Restore and ⋯ (history).
/// To do keeps its own checkbox row (TodoRow) and has no hover Complete.
struct ActionRow<MoreMenu: View>: View {
    typealias Mode = ActionRowMode
    typealias StatusKind = ActionRowStatusKind

    let type: String
    let title: String
    let source: String
    let status: String
    var statusKind: StatusKind = .draft
    var selected = false
    /// Forces the hover look (snapshots); the row also shows it while the pointer is over it.
    var hover = false
    var mode: Mode = .list
    /// Just completed: struck through and faded while it leaves the list.
    var faded = false
    var width: CGFloat? = nil
    var select: () -> Void = {}
    /// ✓ Complete (list mode); nil hides it (busy rows).
    var complete: (() -> Void)? = nil
    /// Restore (history mode); nil hides it (a to-do sent on lives elsewhere).
    var restore: (() -> Void)? = nil
    @ViewBuilder var more: MoreMenu
    @State private var hovering = false

    var body: some View {
        let style = ActionsTheme.typeStyle(type)
        let showActions = (hover || hovering) && !faded
        HStack(spacing: 10) {
            Image(systemName: style.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(style.2)
                .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(style.1))
            VStack(alignment: .leading, spacing: 3) {
                Text(title).font(Theme.body(13, .semibold)).lineLimit(1)
                    .strikethrough(faded, color: Theme.faint)
                Text(source).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if showActions {
                HStack(spacing: 2) {
                    if mode == .history, let restore {
                        IconButton(systemImage: "clock.arrow.circlepath", tint: Theme.primary, help: "Restore", action: restore)
                    }
                    if mode == .list, let complete {
                        IconButton(systemImage: "checkmark.circle", tint: Theme.limeInk, help: "Complete (you’ve handled it)", action: complete)
                    }
                    more
                }
            }
            StatusBadge(text: status, fill: colors.0, ink: colors.1, busy: statusKind == .busy)
        }
        .padding(.leading, 12).padding(.trailing, 10).padding(.vertical, 10)
        .frame(width: width)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected ? ActionsTheme.selectedFill : (showActions ? Theme.panel : .clear)))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? ActionsTheme.selectedStroke : .clear, lineWidth: 1.5))
        .opacity(faded ? 0.4 : 1)
        .contentShape(Rectangle())
        .onTapGesture(perform: select)
        .onHover { hovering = $0 }
        .accessibilityElement(children: .contain)
        .accessibilityLabel("\(title), \(status)")
    }

    private var colors: (Color, Color) {
        switch statusKind {
        case .draft: (Theme.panel, Theme.softInk)
        case .ready, .completed: (Theme.limeTint, Theme.limeInk)
        case .busy, .sent: (Theme.primaryTint, Theme.primary)
        case .created: (Theme.skyTint, Theme.skyInk)
        case .error, .removed: (Theme.peachTint, Theme.peachInk)
        case .muted, .dismissed: (Theme.panel, Theme.muted)
        }
    }
}

enum ActionRowMode: String { case list, history }
/// The pill's colours: (fill, ink) per kind, as on the canvas.
enum ActionRowStatusKind: String { case draft, ready, busy, created, error, muted, completed, removed, sent, dismissed }

/// The ⋯ on a row: a menu of the item's other commands.
struct ActionRowMore<Items: View>: View {
    @ViewBuilder var items: Items
    var body: some View {
        Menu { items } label: {
            Image(systemName: "ellipsis").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                .frame(width: 26, height: 26).contentShape(Circle())
        }
        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        .help("More")
    }
}
