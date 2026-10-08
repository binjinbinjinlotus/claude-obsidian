import AppKit
import SwiftUI
import DistillKit

/// History → Actions (canvas: ActionsHistory): completed, removed, sent and done
/// items by day; the selected one with its timeline, Restore and Delete forever.
struct ActionsHistoryView: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        ActionsHistoryContent(store: engine.actions)
    }
}

/// What the History screen shows besides the items (snapshots set it).
struct ActionsHistoryUI {
    /// Search and the Filter panel's TYPE, OUTCOME, DATE and SOURCE.
    var filter = FacetFilter()
    var panel: String?
    var inlinePanel = false
    var panelHeight: CGFloat = 480
    /// Snapshots: the row drawn hovered (Restore and ⋯).
    var hover: String?
    var menu: String?
    var confirmDelete: String?
    /// After Restore: "Restored to Slack messages · Open", or the missing-note / type-off notes.
    var notice: HistoryNotice?
}

enum HistoryNotice: Equatable {
    case restored(id: String, to: String)
    case noteGone(note: String)
    case typeOff(id: String, type: String)
}

struct ActionsHistoryContent: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    @State var ui: ActionsHistoryUI
    var now = Date()

    init(store: ActionsStore, ui: ActionsHistoryUI = ActionsHistoryUI(), now: Date = Date()) {
        self.store = store
        _ui = State(initialValue: ui)
        self.now = now
    }

    /// Every item that left a list: completed, sent, created (done in Jira / Confluence), removed, dismissed.
    private var all: [ActionItem] { store.items.values.filter { ActionHistory.outcome($0) != nil } }

    private var items: [ActionItem] {
        all.filter { ActionFacets.matches("history", ui.filter, $0, now: now, types: store.types) }
    }

    private func groups(_ list: [ActionItem]) -> [ActionGroup] {
        var out: [ActionGroup] = []
        for item in list.sorted(by: { ActionHistory.whenOutcome($0) > ActionHistory.whenOutcome($1) }) {
            let title = HistoryDay.title(ActionHistory.whenOutcome(item), now: now)
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].items.append(item) }
            else { out.append(ActionGroup(id: title, title: title, items: [item])) }
        }
        return out
    }

    var body: some View {
        let list = items
        let grouped = groups(list)
        let selected = store.selectedHistory.flatMap { id in list.first { $0.id == id } } ?? grouped.first?.items.first
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HISTORY").font(Theme.body(11, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                    Text("Actions").font(Theme.display(24))
                }
                ActionsToolbar(search: $ui.filter.text, placeholder: "Search history", searchWidth: 200,
                               chips: ActionFacets.chips("history", ui.filter, types: store.types), right: .none,
                               panel: $ui.panel, inlinePanel: ui.inlinePanel,
                               removeChip: { ui.filter.remove($0.section, $0.value) },
                               sortItems: { EmptyView() },
                               panelContent: { section in
                                   FilterPanel(kind: "history", sections: ActionFacets.sections("history", items: all, filter: ui.filter, now: now, types: store.types),
                                               scrollTo: section, focus: section.isEmpty ? nil : section, height: ui.panelHeight, inline: ui.inlinePanel,
                                               toggle: { ui.filter.toggle($0, $1) }, clearAll: { ui.filter.clear() }, done: { ui.panel = nil })
                               })
                    .zIndex(5)
                if let notice = ui.notice { noticeView(notice) }
                Scrolling {
                    VStack(alignment: .leading, spacing: 2) {
                        if !store.historyLoaded && store.phase != .unavailable {
                            ActionShimmerRows(count: 4)
                        }
                        ForEach(grouped) { group in
                            Text(group.title).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                                .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
                            ForEach(group.items) { item in
                                row(item, selected: item.id == selected?.id)
                            }
                        }
                    }
                    .padding(.bottom, 40)
                }
            }
            .padding(.vertical, 24).padding(.horizontal, 18)
            .paneWidth(.historyActions, automatic: 340)
            .background(Theme.window)
            .zIndex(5)
            Divider().overlay(Theme.border)
            Group {
                if store.phase == .unavailable {
                    ActionsUpdateCore()
                } else if all.isEmpty && store.historyLoaded {
                    ActionsEmpty(icon: "checkmark.circle", colors: (Theme.primaryTint, Theme.primary), title: "Nothing here yet",
                                 message: "Completed, removed and sent actions show up here, so you can see what happened and bring things back.") {
                        PrimaryButton(title: "Open To do", systemImage: "checkmark.circle", size: .small) { store.open(tab: "todo") }
                    }
                } else if list.isEmpty && store.historyLoaded {
                    ActionsEmpty(icon: "magnifyingglass", colors: (.clear, Theme.faint), title: "No actions match", message: noMatchText) {
                        SoftButton(title: "Clear filters", fill: .white, size: .small, stroke: true) { ui.filter = FacetFilter() }
                    }
                } else if let selected {
                    Scrolling { detail(selected).padding(.horizontal, 32).padding(.vertical, 28) }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .paneContainer()
        .background(Color.white.opacity(0.001).onTapGesture { ui.menu = nil })
        .overlay {
            if let id = ui.confirmDelete, let item = store.items[id] { deleteDialog(item) }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast { ActionToastView(toast: toast, openHistory: {}, dismiss: { store.toast = nil }, undoShortcut: store.editing.isEmpty) }
        }
        .onAppear { if !store.historyLoaded { store.loadHistory() } }
    }

    /// "Nothing matches Dismissed · This week. 4 actions are hidden by the filters."
    private var noMatchText: String {
        var parts: [String] = []
        let chips = ActionFacets.chips("history", ui.filter, types: store.types).map(\.text)
        if !chips.isEmpty { parts.append(chips.joined(separator: " · ")) }
        let q = ui.filter.text.trimmingCharacters(in: .whitespaces)
        if !q.isEmpty { parts.append("“\(q)”") }
        let n = all.count
        return "Nothing matches \(parts.joined(separator: " and ")). \(n) \(n == 1 ? "action is" : "actions are") hidden by the filters."
    }

    // MARK: List

    private func row(_ item: ActionItem, selected: Bool) -> some View {
        let outcome = ActionHistory.outcome(item)
        let canRestore = ActionHistory.canRestoreOutcome(item)
        return ActionRow(type: item.type, title: rowTitle(item), source: ActionHistory.outcomeLine(item, types: store.types, now: now),
                         status: outcome?.title ?? "", statusKind: kind(outcome), selected: selected, hover: ui.hover == item.id, mode: .history,
                         select: { store.selectedHistory = item.id; ui.notice = nil },
                         restore: canRestore ? { restore(item) } : nil) {
            ActionRowMore {
                if canRestore { Button("Restore") { restore(item) } }
                if let to = ActionHistory.sentTo(item) {
                    Button("Open in \(store.label(to))") { openSent(item, to: to) }
                }
                Divider()
                Button("Delete forever…") { ui.confirmDelete = item.id }
            }
        }
    }

    private func kind(_ o: ActionHistory.Outcome?) -> ActionRowStatusKind {
        switch o {
        case .completed: .completed; case .sent: .sent; case .created: .created; case .removed: .removed
        case .dismissed, nil: .dismissed
        }
    }

    private func rowTitle(_ item: ActionItem) -> String {
        if let key = item.external?.key, !key.contains(" ") { return "\(key) \(item.title)" }
        return item.title
    }

    private func openSent(_ item: ActionItem, to: String) {
        if let made = store.items.values.first(where: { $0.fromActionID == item.id }) { store.open(made) } else { store.open(tab: to) }
    }

    // MARK: Detail

    @ViewBuilder private func detail(_ item: ActionItem) -> some View {
        let outcome = ActionHistory.outcome(item)
        VStack(alignment: .leading, spacing: 16) {
            Text(headline(item)).font(Theme.body(13)).foregroundStyle(Theme.muted)
            HistoryCard(store: store, item: item)
            timeline(item)
            if outcome == .sent, let to = ActionHistory.sentTo(item) {
                HStack(spacing: 10) {
                    SoftButton(title: "Open in \(store.label(to))", fill: .white, size: .small, stroke: true,
                               systemImage: ActionsTheme.typeStyle(to).0) { openSent(item, to: to) }
                    Text("No Restore here: it lives on in \(store.label(to)). To undo the send, remove the draft before it is created.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                }
            } else {
                HStack(spacing: 10) {
                    PrimaryButton(title: "Restore", systemImage: "clock.arrow.circlepath", size: .small) { restore(item) }
                    Text(restoreHint(item)).font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    Spacer()
                    Button("Delete forever") { ui.confirmDelete = item.id }.buttonStyle(.plain)
                        .font(Theme.body(12, .semibold)).foregroundStyle(Theme.peachInk)
                }
                Text("Kept until \(keptUntil(item))").font(Theme.body(11)).foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: 600, alignment: .leading)
    }

    private func restoreHint(_ item: ActionItem) -> String {
        let list = store.label(listFor(item))
        if item.status == .dismissed { return "Puts it back in \(list) to confirm." }
        return "Puts it back in \(list) exactly as it was."
    }

    private func headline(_ item: ActionItem) -> String {
        let at = HistoryTime.phrase(ActionHistory.whenOutcome(item), now: now)
        switch ActionHistory.outcome(item) {
        case .removed: return "Removed \(at) from \(store.label(item.type))"
        case .sent:
            if let to = ActionHistory.sentTo(item) { return "Sent to \(store.label(to)) \(at)" }
            return "Marked as sent \(at)"
        case .completed: return "Completed by you \(at)"
        case .created: return ActionHistory.outcomeLine(item, types: store.types, now: now)
        case .dismissed: return "Dismissed \(at): found but not added"
        case nil: return at
        }
    }

    private func listFor(_ item: ActionItem) -> String {
        store.type(item.type)?.isUsable == true ? item.type : "todo"
    }

    private func keptUntil(_ item: ActionItem) -> String {
        let days = engine.settings.actionPreferences?.historyDays ?? 90 // Settings → To-do defaults; 0 = forever
        if days <= 0 { return "you delete it" }
        let until = Calendar.current.date(byAdding: .day, value: days, to: ActionHistory.whenOutcome(item)) ?? now
        let f = DateFormatter(); f.setLocalizedDateFormatFromTemplate("MMM d")
        return f.string(from: until)
    }

    private func timeline(_ item: ActionItem) -> some View {
        let steps = ActionHistory.timeline(item, types: store.types)
        return VStack(alignment: .leading, spacing: 0) {
            Text("What happened").font(Theme.body(13, .bold)).padding(.bottom, 8)
            ForEach(Array(steps.enumerated()), id: \.offset) { i, step in
                HStack(alignment: .top, spacing: 10) {
                    VStack(spacing: 0) {
                        Circle().fill(i == steps.count - 1 ? Theme.primary : ActionsTheme.ring).frame(width: 8, height: 8).padding(.top, 4)
                        if i < steps.count - 1 { Rectangle().fill(Theme.border).frame(width: 2).frame(maxHeight: .infinity) }
                    }
                    .frame(width: 8)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(step.title).font(Theme.body(13, .semibold))
                        Text(HistoryTime.phrase(step.at, now: now).prefix(1).uppercased() + HistoryTime.phrase(step.at, now: now).dropFirst())
                            .font(Theme.body(11)).foregroundStyle(Theme.muted)
                    }
                    .padding(.bottom, 10)
                }
            }
        }
    }

    // MARK: Restore

    private func restore(_ item: ActionItem) {
        if let t = store.type(item.type), !t.isUsable, item.type != "todo", ui.notice != .typeOff(id: item.id, type: item.type) {
            ui.notice = .typeOff(id: item.id, type: item.type)
            return
        }
        let to = item.status == .dismissed ? "To confirm in \(store.label(listFor(item)))" : store.label(listFor(item))
        store.restore(item.id)
        store.selectedHistory = nil
        if case .note(_, let path?, _, _) = item.source, let vault = item.vaultPath ?? engine.activeVault?.path,
           !FileManager.default.fileExists(atPath: URL(fileURLWithPath: vault).appendingPathComponent(path).path) {
            ui.notice = .noteGone(note: ActionList.noteTitle(item) ?? path)
        } else {
            ui.notice = .restored(id: item.id, to: to)
        }
    }

    @ViewBuilder private func noticeView(_ notice: HistoryNotice) -> some View {
        switch notice {
        case .restored(let id, let to):
            ActionCallout(icon: "arrow.uturn.backward.circle.fill", tint: Theme.limeInk, fill: ActionsTheme.doneFill, title: "Restored to \(to)") {
                ActionButton(title: "Open", kind: .soft, height: 26) { if let i = store.items[id] { store.open(i) }; ui.notice = nil }
            }
        case .noteGone(let note):
            ActionCallout(icon: "info.circle.fill", tint: Theme.primary, fill: Theme.primaryTint, title: "Restored without its note link",
                          text: "The note \(note) was deleted from your vault after this was found. The quoted lines are kept.") {
                ActionButton(title: "OK", kind: .soft, height: 26) { ui.notice = nil }
            }
        case .typeOff(let id, let type):
            let label = store.label(type)
            ActionCallout(icon: "exclamationmark.circle.fill", title: "\(label) are turned off",
                          text: "Restore this as a to-do instead, or turn \(label) on.") {
                ActionButton(title: "Restore as a to-do", kind: .primary, height: 26) {
                    store.restore(id); ui.notice = .restored(id: id, to: "To do")
                }
                ActionButton(title: "Open Settings", kind: .soft, height: 26) { store.openSettings("actions/\(type)") }
            }
        }
    }

    private func deleteDialog(_ item: ActionItem) -> some View {
        ZStack {
            Color.black.opacity(0.18).onTapGesture { ui.confirmDelete = nil }
            VStack(alignment: .leading, spacing: 10) {
                Text("Delete this forever?").font(.system(size: 17, weight: .semibold, design: .rounded))
                Text("“\(item.title)” can't be restored after this. The note stays in your vault.")
                    .font(Theme.body(13)).foregroundStyle(Theme.softInk).fixedSize(horizontal: false, vertical: true)
                HStack(spacing: 8) {
                    Spacer()
                    ActionButton(title: "Cancel", kind: .plain) { ui.confirmDelete = nil }
                        .keyboardShortcut(.cancelAction)
                    Button { store.deleteForever(item.id); ui.confirmDelete = nil; store.selectedHistory = nil } label: {
                        Text("Delete forever").font(Theme.body(13, .semibold)).foregroundStyle(.white)
                            .padding(.horizontal, 16).frame(height: 32).background(Capsule().fill(Theme.peachInk))
                    }
                    .buttonStyle(.plain)
                }
                .padding(.top, 6)
            }
            .padding(20)
            .frame(width: 360)
            .background(RoundedRectangle(cornerRadius: 16).fill(Color.white).shadow(color: .black.opacity(0.2), radius: 20, y: 10))
        }
    }
}

/// The outcome pill (the same colours as ActionRow's status kinds).
struct HistoryBadge: View {
    let outcome: ActionHistory.Outcome
    var body: some View {
        switch outcome {
        case .removed: StatusBadge(text: outcome.title, fill: Theme.peachTint, ink: Theme.peachInk)
        case .completed: StatusBadge(text: outcome.title, fill: Theme.limeTint, ink: Theme.limeInk)
        case .sent: StatusBadge(text: outcome.title, fill: Theme.primaryTint, ink: Theme.primary)
        case .created: StatusBadge(text: outcome.title, fill: Theme.skyTint, ink: Theme.skyInk)
        case .dismissed: StatusBadge(text: outcome.title, fill: Theme.panel, ink: Theme.muted)
        }
    }
}

/// The item as it was, read-only (a message's text, a ticket's fields, a to-do's title), and its context.
struct HistoryCard: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem

    var body: some View {
        let style = ActionsTheme.typeStyle(item.type)
        let type = store.type(item.type)
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 10) {
                Image(systemName: style.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(style.2)
                    .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9).fill(style.1))
                VStack(alignment: .leading, spacing: 1) {
                    Text((item.type == "todo" ? "To-do" : type?.label ?? item.type).uppercased()).font(Theme.body(11, .heavy)).kerning(0.5).foregroundStyle(style.2)
                    if let to = item.field("to") { Text("To \(to)").font(Theme.body(13, .semibold)) }
                    else if let key = item.external?.key { Text("\(key) · \(item.external?.status ?? "")").font(Theme.body(13, .semibold)) }
                }
                Spacer()
                if let o = ActionHistory.outcome(item) { HistoryBadge(outcome: o) }
            }
            Text(item.title).font(.system(size: 16, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
            if let body = item.body, !body.isEmpty {
                ActionBodyText(markdown: body)
                    .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
            }
            ActionContextBlock(item: item)
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white).shadow(color: .black.opacity(0.08), radius: 10, y: 6))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.06)))
        .opacity(0.92)
    }
}
