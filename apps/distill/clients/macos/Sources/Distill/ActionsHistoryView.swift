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
    var query = ""
    var what: Set<ActionHistory.What> = []
    var types: Set<String> = []
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

    private var items: [ActionItem] {
        store.items.values.filter { item in
            guard let what = ActionHistory.what(item) else { return false }
            if !ui.what.isEmpty && !ui.what.contains(what) { return false }
            if !ui.types.isEmpty && !ui.types.contains(item.type) { return false }
            return ActionSearch.match(item, ui.query) != nil
        }
    }

    var body: some View {
        let list = items
        let selected = store.selectedHistory.flatMap { id in list.first { $0.id == id } } ?? ActionHistory.groups(list, now: now).first?.items.first
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 12) {
                VStack(alignment: .leading, spacing: 4) {
                    Text("HISTORY").font(Theme.body(11, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                    Text("Actions").font(Theme.display(24))
                }
                ActionSearchField(text: $ui.query, placeholder: "Search history", width: 284)
                filters.zIndex(5)
                if let notice = ui.notice { noticeView(notice) }
                Scrolling {
                    VStack(alignment: .leading, spacing: 2) {
                        if !store.historyLoaded && store.phase != .unavailable {
                            ActionShimmerRows(count: 4)
                        }
                        ForEach(ActionHistory.groups(list, now: now)) { group in
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
            .frame(width: 340)
            .background(Theme.window)
            Divider().overlay(Theme.border)
            Group {
                if store.phase == .unavailable {
                    ActionsUpdateCore()
                } else if list.isEmpty && store.historyLoaded {
                    ActionsEmpty(icon: "clock", title: ui.what.isEmpty && ui.query.isEmpty ? "Nothing here yet" : "Nothing matches",
                                 message: "Completed, removed, sent and done actions show up here, so you can see what happened and bring things back.") {
                        EmptyView()
                    }
                } else if let selected {
                    Scrolling { detail(selected).padding(.horizontal, 32).padding(.vertical, 28) }
                } else {
                    Color.clear
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .background(Color.white.opacity(0.001).onTapGesture { ui.menu = nil })
        .overlay {
            if let id = ui.confirmDelete, let item = store.items[id] { deleteDialog(item) }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast { ActionToastView(toast: toast, openHistory: {}, dismiss: { store.toast = nil }) }
        }
        .onAppear { if !store.historyLoaded { store.loadHistory() } }
    }

    // MARK: List

    private var filters: some View {
        HStack(spacing: 6) {
            FilterMenuChip(title: "What", value: ui.what.isEmpty ? nil : ActionHistory.What.allCases.filter { ui.what.contains($0) }.map(\.title).joined(separator: ", "),
                           onClear: { ui.what = [] }, open: menu("what")) {
                ActionMenuPanel(title: "WHAT HAPPENED", width: 260) {
                    ActionMenuRow(title: "Everything", checked: ui.what.isEmpty) { ui.what = []; ui.menu = nil }
                    ForEach(ActionHistory.What.allCases, id: \.self) { w in
                        ActionMenuRow(title: w.title, detail: w.help, checked: ui.what.contains(w)) {
                            if ui.what.contains(w) { ui.what.remove(w) } else { ui.what.insert(w) }
                        }
                    }
                }
            }
            FilterMenuChip(title: "Type", value: ui.types.isEmpty ? nil : ui.types.map { store.label($0) }.sorted().joined(separator: ", "),
                           onClear: { ui.types = [] }, open: menu("type")) {
                ActionMenuPanel(title: "ACTION TYPE", width: 220) {
                    ForEach(store.types.filter { !$0.reserved }) { t in
                        ActionMenuRow(title: store.label(t.id), icon: ActionsTheme.typeStyle(t.id).0, checked: ui.types.contains(t.id)) {
                            if ui.types.contains(t.id) { ui.types.remove(t.id) } else { ui.types.insert(t.id) }
                        }
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    private func menu(_ id: String) -> Binding<Bool> { Binding(get: { ui.menu == id }, set: { ui.menu = $0 ? id : nil }) }

    private func row(_ item: ActionItem, selected: Bool) -> some View {
        let what = ActionHistory.what(item)
        let style = ActionsTheme.typeStyle(item.type)
        return Button { store.selectedHistory = item.id; ui.notice = nil } label: {
            HStack(alignment: .top, spacing: 10) {
                Image(systemName: style.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(style.2)
                    .frame(width: 24, height: 24).background(RoundedRectangle(cornerRadius: 7).fill(style.1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(rowTitle(item)).font(Theme.body(13, .semibold)).lineLimit(1)
                        .strikethrough(what == .completed, color: Theme.faint)
                    HStack(spacing: 6) {
                        if let what { HistoryBadge(what: what) }
                        Text(ActionHistory.detail(item, types: store.types, now: now)).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 12).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? Theme.panel : .clear))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func rowTitle(_ item: ActionItem) -> String {
        if let key = item.external?.key { return "\(key) \(item.title)" }
        return item.title
    }

    // MARK: Detail

    @ViewBuilder private func detail(_ item: ActionItem) -> some View {
        let what = ActionHistory.what(item)
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 8) {
                if let what { HistoryBadge(what: what) }
                Text(headline(item)).font(Theme.body(13)).foregroundStyle(Theme.muted)
            }
            HistoryCard(store: store, item: item)
            timeline(item)
            if what == .sent {
                if let to = ActionHistory.sentTo(item) {
                    let made = store.items.values.first { $0.fromActionID == item.id }
                    ActionButton(title: "Open in \(store.label(to))", icon: "arrow.right", kind: .primary) {
                        if let made { store.open(made) } else { store.open(tab: to) }
                    }
                }
                Text("No Restore here: it lives on in \(ActionHistory.sentTo(item).map { store.label($0) } ?? "its new list"). To undo the send, remove the draft before it is created.")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
            } else {
                HStack(spacing: 10) {
                    ActionButton(title: "Restore", icon: "arrow.uturn.backward", kind: .primary) { restore(item) }
                    Text("Puts it back in \(store.label(listFor(item))) exactly as it was.").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    Spacer()
                    Button("Delete forever") { ui.confirmDelete = item.id }.buttonStyle(.plain)
                        .font(Theme.body(12, .semibold)).foregroundStyle(Theme.peachInk)
                }
                Text("Kept until \(keptUntil(item))").font(Theme.body(11)).foregroundStyle(Theme.faint)
            }
        }
        .frame(maxWidth: 600, alignment: .leading)
    }

    private func headline(_ item: ActionItem) -> String {
        let at = HistoryTime.phrase(ActionHistory.when(item), now: now)
        switch ActionHistory.what(item) {
        case .removed: return "Removed \(at) from \(store.label(item.type))"
        case .sent: return "Sent to \(ActionHistory.sentTo(item).map { store.label($0) } ?? "another list") \(at)"
        case .markedSent: return "Marked as sent \(at)"
        case .completed: return "Completed \(at)"
        case .done: return "Done \(at)"
        case nil: return at
        }
    }

    private func listFor(_ item: ActionItem) -> String {
        store.type(item.type)?.isUsable == true ? item.type : "todo"
    }

    private func keptUntil(_ item: ActionItem) -> String {
        let days = engine.settings.actionPreferences?.historyDays ?? 90 // Settings → To-do defaults; 0 = forever
        if days <= 0 { return "you delete it" }
        let until = Calendar.current.date(byAdding: .day, value: days, to: ActionHistory.when(item)) ?? now
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
        let to = store.label(listFor(item))
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

struct HistoryBadge: View {
    let what: ActionHistory.What
    var body: some View {
        switch what {
        case .removed: StatusBadge(text: what.title, fill: Theme.panel, ink: Theme.muted)
        case .completed, .done: StatusBadge(text: what.title, fill: Theme.limeTint, ink: Theme.limeInk)
        case .sent, .markedSent: StatusBadge(text: what.title, fill: Theme.primaryTint, ink: Theme.primary)
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
                if let what = ActionHistory.what(item) { HistoryBadge(what: what) }
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
