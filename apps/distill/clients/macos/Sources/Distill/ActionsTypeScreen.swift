import AppKit
import SwiftUI
import DistillKit

/// What a handler tab shows besides the items (snapshots set it directly).
struct TypeListUI {
    var filter = FacetFilter()
    /// The Filter panel: nil closed, "" at the top, or the section a chip opened.
    var panel: String?
    var inlinePanel = false
    var panelHeight: CGFloat = 480
    var expanded: Set<String> = []
    /// Slack: newest first (default) or oldest first.
    var oldestFirst = false
    /// Snapshots: the row drawn hovered (✓ Complete and ⋯).
    var hover: String?
}

/// A handler tab (Slack messages, Jira tickets, Confluence pages, or any type
/// from the registry): header, the ActionsToolbar, ActionRows on the left and
/// the selected item on the right (canvas v57 ActionsSlack / Jira / Confluence).
struct TypeListScreen: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let type: ActionTypeInfo
    @State var ui: TypeListUI

    init(store: ActionsStore, type: ActionTypeInfo, ui: TypeListUI = TypeListUI()) {
        self.store = store
        self.type = type
        _ui = State(initialValue: ui)
    }

    private var creates: Bool { type.handler("create") != nil }
    /// The Filter panel's kind for this type.
    private var kind: String {
        if ["slack", "jira", "confluence"].contains(type.id) { return type.id }
        return creates ? "confluence" : "slack"
    }
    private var service: String { store.typeName(type.id) }
    /// "tickets" / "pages" / "messages".
    private var things: String {
        let words = type.pluralLabel.split(separator: " ")
        return (words.count > 1 ? words.dropFirst().joined(separator: " ") : type.pluralLabel).lowercased()
    }

    /// Everything still on this tab (filters aside): live items, and the ones just completed (leaving).
    private var live: [ActionItem] {
        let statuses: [ActionStatus] = creates ? [.open, .drafting, .ready, .creating, .created] : [.open, .drafting, .ready]
        return store.items(type: type.id).filter { statuses.contains($0.status) || store.completing.contains($0.id) }
    }
    private var visible: [ActionItem] {
        live.filter { store.completing.contains($0.id)
            || ActionFacets.matches(kind, ui.filter, $0, types: store.types, copied: store.copiedAt[$0.id] != nil) }
    }
    private var pending: [ActionItem] { store.pending.filter { $0.type == type.id } }

    var body: some View {
        let list = visible
        let groups = grouped(list)
        let ordered = groups.flatMap(\.1)
        let selected = ordered.first { $0.id == store.selected[type.id] && !store.completing.contains($0.id) }
            ?? ordered.first { !store.completing.contains($0.id) }
        VStack(alignment: .leading, spacing: 0) {
            ActionsHeader(eyebrow: "ACTIONS", title: type.pluralLabel, subtitle: store.lastFound(type: type.id)) {
                SoftButton(title: "History", fill: .white, size: .small, stroke: true, systemImage: "clock") { store.historyRequest += 1 }
            }
            toolbar
                .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 8)
                .zIndex(10)
                .onAppear { if creates { store.engine?.loadConnections() } }
            if store.phase != .loaded {
                ActionShimmerRows(count: 3).padding(.horizontal, 20)
                Spacer()
            } else if live.isEmpty && pending.isEmpty {
                emptyState
            } else if list.isEmpty && pending.isEmpty {
                noMatch
            } else {
                GeometryReader { geo in
                    // The list narrows before the detail does, so the detail footer stays one line.
                    let listWidth = min(330, max(250, (geo.size.width - 20) * 0.42))
                    HStack(alignment: .top, spacing: 14) {
                        Scrolling {
                            VStack(alignment: .leading, spacing: 2) {
                                if !pending.isEmpty { ToConfirmGroup(store: store, items: pending) }
                                ForEach(groups, id: \.0) { title, items in
                                    ActionGroupHeader(title: title, count: items.count, icon: "chevron.down")
                                    ForEach(items) { row($0, selected: $0.id == selected?.id) }
                                }
                            }
                            .padding(.bottom, 60)
                        }
                        .paneWidth(.actionsList(type.id), automatic: listWidth, container: geo.size.width)
                        Scrolling {
                            if let selected { detail(selected).padding(2).padding(.bottom, 60) }
                        }
                        .frame(maxWidth: .infinity)
                    }
                    .padding(.leading, 20).padding(.trailing, 24)
                }
            }
        }
    }

    // MARK: Toolbar

    /// Connected, or it needs setting up (Settings → Connections); never "connecting".
    private var connection: ToolbarConnection {
        type.handler("create")?.available == true ? .connected : .disconnected
    }

    private var site: String {
        let s = type.connectionID.flatMap { store.engine?.settingsUI.connection($0)?.site }?.replacingOccurrences(of: "https://", with: "")
        // Never invent a site: without a stored connection it reads "Atlassian · connected".
        guard let s else { return type.connectionID == "atlassian" ? "Atlassian" : service }
        return s + (type.id == "confluence" ? "/wiki" : "")
    }

    @ViewBuilder private var toolbar: some View {
        let chips = ActionFacets.chips(kind, ui.filter, types: store.types)
        if creates {
            ActionsToolbar(search: $ui.filter.text, placeholder: "Search \(things)", searchWidth: 180, chips: chips,
                           right: type.connectionID == nil ? .none : .connection, connection: connection, site: site,
                           service: type.connectionID == "atlassian" ? "Atlassian" : service,
                           panel: $ui.panel, inlinePanel: ui.inlinePanel,
                           removeChip: { ui.filter.remove($0.section, $0.value) },
                           connect: { store.openSettings("connections") },
                           sortItems: { EmptyView() }, panelContent: panel)
        } else {
            ActionsToolbar(search: $ui.filter.text, placeholder: "Search \(things)", chips: chips, right: .sort,
                           sortTitle: ui.oldestFirst ? "Oldest first" : "Newest first",
                           panel: $ui.panel, inlinePanel: ui.inlinePanel,
                           removeChip: { ui.filter.remove($0.section, $0.value) },
                           sortItems: {
                               Button("Newest first") { ui.oldestFirst = false }
                               Button("Oldest first") { ui.oldestFirst = true }
                           }, panelContent: panel)
        }
    }

    private func panel(_ section: String) -> FilterPanel {
        FilterPanel(kind: kind, sections: ActionFacets.sections(kind, items: live, filter: ui.filter, types: store.types,
                                                                 copied: Set(store.copiedAt.keys)),
                    scrollTo: section, focus: section.isEmpty ? nil : section, height: ui.panelHeight, inline: ui.inlinePanel,
                    expanded: ui.expanded, toggle: { ui.filter.toggle($0, $1) }, clearAll: { ui.filter.clear() }, done: { ui.panel = nil })
    }

    // MARK: List

    private func grouped(_ list: [ActionItem]) -> [(String, [ActionItem])] {
        if creates {
            let drafts = list.filter { $0.status != .created && !($0.status == .done && $0.external?.key != nil) }.sorted { $0.createdAt > $1.createdAt }
            let made = list.filter { !drafts.contains($0) }.sorted { $0.updatedAt > $1.updatedAt }
            return [("DRAFTS", drafts), ("CREATED IN \(service.uppercased())", made)].filter { !$0.1.isEmpty }
        }
        let sorted = list.sorted { ui.oldestFirst ? $0.createdAt < $1.createdAt : $0.createdAt > $1.createdAt }
        return sorted.isEmpty ? [] : [(things.uppercased(), sorted)]
    }

    private func row(_ item: ActionItem, selected: Bool) -> some View {
        let leaving = store.completing.contains(item.id)
        let status = leaving ? ("Completed", ActionRowStatusKind.completed) : rowStatus(item)
        let busy = status.1 == .busy
        return ActionRow(type: type.id, title: rowTitle(item), source: leaving ? "Completed just now" : source(item),
                         status: status.0, statusKind: status.1, selected: selected && !leaving,
                         hover: ui.hover == item.id, faded: leaving,
                         select: { store.selected[type.id] = item.id },
                         complete: busy || leaving ? nil : { store.complete(item) }) {
            ActionRowMore {
                Button("Complete") { store.complete(item) }.disabled(busy)
                if item.status == .ready && type.handler("markSent") != nil { Button("Mark as sent") { store.markSent(item) } }
                if item.status != .created { Button("Edit") { store.selected[type.id] = item.id; store.beginEdit(item) }.disabled(busy) }
                Button("Remove") { store.remove(item) }
                Divider()
                Button("Settings for \(type.pluralLabel)") { store.openSettings("actions/\(type.id)") }
            }
        }
    }

    private func rowTitle(_ item: ActionItem) -> String {
        if item.status == .created, let key = item.external?.key, !key.contains(" ") { return "\(key) \(item.title)" }
        return item.title
    }

    /// "From Tea club planning · today at 3:44 PM" / "· not written yet" / "· copied at 3:52 PM" /
    /// "Created today at 3:51 PM · In progress in Jira".
    private func source(_ item: ActionItem) -> String {
        if item.status == .created {
            let at = HistoryTime.phrase(item.lastEvent("created")?.at ?? item.updatedAt)
            let status = item.external?.status.map { " · \($0) in \(service)" } ?? ""
            return "Created \(at)\(status)"
        }
        let from = ActionList.noteTitle(item).map { "From \($0)" } ?? "Added by you"
        if item.status == .open && (item.body ?? "").isEmpty { return "\(from) · not written yet" }
        if item.status == .ready, let copied = store.copiedAt[item.id] ?? item.lastEvent("copied")?.at { return "\(from) · copied at \(ActionsClock.time(copied))" }
        return "\(from) · \(HistoryTime.phrase(item.createdAt))"
    }

    /// The row's pill: the same words as the detail's.
    private func rowStatus(_ item: ActionItem) -> (String, ActionRowStatusKind) {
        let run = store.running[item.id]
        if store.editing[item.id] != nil { return ("Editing", .busy) }
        if case .drafting? = run { return ("Writing", .busy) }
        if item.status == .drafting { return ("Writing", .busy) }
        if case .improving? = run { return (creates ? "Improving" : "Polishing", .busy) }
        if case .creating? = run { return ("Creating", .busy) }
        if item.status == .creating { return ("Creating", .busy) }
        if item.status == .created { return ("Created", .created) }
        if let e = item.error, e.code != "ai_failed", creates { return ("Not created", .error) }
        if item.status == .open && (item.body ?? "").isEmpty { return ("Not written", .muted) }
        if !creates {
            if item.status == .ready && (store.copiedAt[item.id] != nil || item.lastEvent("copied") != nil) { return ("Copied", .ready) }
            if item.status == .ready { return (type.handler("send")?.available == true ? "Ready to send" : "Ready to paste", .ready) }
        }
        return ("Draft", .draft)
    }

    @ViewBuilder private func detail(_ item: ActionItem) -> some View {
        if creates {
            ExternalCard(store: store, type: type, item: item).frame(maxWidth: 560, alignment: .leading)
        } else {
            MessageCard(store: store, type: type, item: item).frame(maxWidth: 560, alignment: .leading)
        }
    }

    // MARK: States

    @ViewBuilder private var emptyState: some View {
        let colors = (ActionsTheme.typeStyle(type.id).1, ActionsTheme.typeStyle(type.id).2)
        if creates && connection != .connected {
            ActionsEmpty(icon: ActionsTheme.typeStyle(type.id).0, colors: colors, title: "No \(things) yet",
                         message: "Set up the \(type.connectionID == "atlassian" ? "Atlassian" : service) connection once in Settings and Distill can create \(things) on \(site == "Atlassian" ? "your Atlassian site" : site) with one click. Drafts from your notes and To do appear here.") {
                PrimaryButton(title: ToolbarConnection.setUpTitle, systemImage: "link", size: .small) { store.openSettings("connections") }
                SoftButton(title: "History", fill: .white, size: .small, stroke: true, systemImage: "clock") { store.historyRequest += 1 }
            }
        } else if creates {
            ActionsEmpty(icon: ActionsTheme.typeStyle(type.id).0, colors: colors, title: "No \(things) yet",
                         message: "When a note asks for one, Distill drafts it here. Nothing is created in \(service) until you press Create. You can also send a to-do here from To do.") {
                PrimaryButton(title: "Open To do", systemImage: "checkmark.circle", size: .small) { store.open(tab: "todo") }
                SoftButton(title: "History", fill: .white, size: .small, stroke: true, systemImage: "clock") { store.historyRequest += 1 }
            }
        } else {
            ActionsEmpty(icon: ActionsTheme.typeStyle(type.id).0, colors: colors, title: "No \(type.pluralLabel) to send",
                         message: "When a processed note or an Ask answer needs a message, Distill writes it here. You can also send a to-do here from To do.") {
                PrimaryButton(title: "Open To do", systemImage: "checkmark.circle", size: .small) { store.open(tab: "todo") }
                SoftButton(title: "History", fill: .white, size: .small, stroke: true, systemImage: "clock") { store.historyRequest += 1 }
            }
        }
    }

    private var noMatch: some View {
        let chips = ActionFacets.chips(kind, ui.filter, types: store.types).map(\.text)
        let q = ui.filter.text.trimmingCharacters(in: .whitespaces)
        var parts: [String] = []
        if !chips.isEmpty { parts.append(chips.joined(separator: " · ")) }
        if !q.isEmpty { parts.append("“\(q)”") }
        let hidden = live.count
        let text = "Nothing matches \(parts.joined(separator: " and ")). \(hidden) \(hidden == 1 ? String(things.dropLast()) : things) \(hidden == 1 ? "is" : "are") hidden by the filters."
        return ActionsEmpty(icon: "magnifyingglass", colors: (.clear, Theme.faint), title: "No \(things) match", message: text) {
            SoftButton(title: "Clear filters", fill: .white, size: .small, stroke: true) { ui.filter = FacetFilter() }
        }
    }
}
