import AppKit
import SwiftUI
import DistillKit

/// Sidebar section Actions: the open sub-item's list (To do or an action
/// type), the toast, and the calm states (first load, old core, type off).
struct ActionsScreen: View {
    @EnvironmentObject var engine: AppModel

    var body: some View {
        ActionsScreenContent(store: engine.actions)
    }
}

private struct ActionsScreenContent: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore

    var body: some View {
        Group {
            switch store.phase {
            case .unavailable:
                ActionsUpdateCore()
            case .failed(let message):
                ActionsEmpty(icon: "exclamationmark.triangle", title: "Couldn't load actions", message: message) {
                    ActionButton(title: "Try again", icon: "arrow.clockwise", kind: .primary) { store.load() }
                }
            default:
                page
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = store.toast {
                ActionToastView(toast: toast, openHistory: { store.historyRequest += 1 }, dismiss: { store.toast = nil },
                                undoShortcut: store.editing.isEmpty)
            }
        }
        .onAppear { if store.phase == .idle { store.load() } }
    }

    @ViewBuilder private var page: some View {
        let tab = store.tab
        if tab == "todo" {
            TodoScreen(store: store)
        } else if let type = store.type(tab), type.isUsable {
            TypeListScreen(store: store, type: type).id(type.id)
        } else if let type = store.type(tab) {
            ActionsEmpty(icon: ActionsTheme.typeStyle(type.id).0, title: "\(type.pluralLabel) are off",
                         message: "\(type.pluralLabel) to send are added as to-dos instead. Turn them on in Settings → Actions.") {
                ActionButton(title: "Open Settings", kind: .soft) { store.openSettings("actions/\(type.id)") }
            }
        } else {
            TodoScreen(store: store)
        }
    }
}

/// An older core without the Actions routes (501 / no route).
struct ActionsUpdateCore: View {
    var body: some View {
        ActionsEmpty(icon: "arrow.triangle.2.circlepath", title: "Update the Distill core",
                     message: "This core doesn't have Actions yet. Update Distill (distill.sh update) and they show up here. Nothing else is affected.") {
            EmptyView()
        }
    }
}

// MARK: - To do

/// What the To do screen shows besides the items (snapshots set it directly).
struct TodoUI {
    var filter = ActionFilter()
    var menu: String?
    var personQuery = ""
    var selection: Set<String> = []
    var adding: NewTodo?
    var editing = false
    /// Snapshots only: rows drawn as just completed (the app uses `ActionsStore.completing`).
    var completing: Set<String> = []
    /// The Filter panel: nil closed, "" at the top, or the section a chip opened.
    var panel: String?
    /// Snapshots draw the panel in place (a popover isn't captured).
    var inlinePanel = false
    /// Snapshots: To confirm rows drawn open on their preview.
    var previewing: Set<String> = []
    var panelHeight: CGFloat = 520
    /// Panel sections showing all their rows.
    var expanded: Set<String> = []
}

struct NewTodo: Equatable {
    var title = ""
    var due: String?
    var priority: String?
    var people = ""
    var labels: [String] = []
}

struct TodoScreen: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    @State var ui: TodoUI
    /// Changes here are remembered; empty = Settings → To-do defaults.
    @AppStorage("distill.todo.group") private var groupRaw = ""
    @AppStorage("distill.todo.sort") private var sortRaw = ""
    var now = Date()

    init(store: ActionsStore, ui: TodoUI = TodoUI(), now: Date = Date()) {
        self.store = store
        _ui = State(initialValue: ui)
        self.now = now
    }

    private var grouping: ActionGrouping {
        ActionGrouping(rawValue: groupRaw.isEmpty ? (engine.settings.actionPreferences?.todoGroup ?? "due") : groupRaw) ?? .due
    }
    private var sort: ActionSort {
        ActionSort(rawValue: sortRaw.isEmpty ? (engine.settings.actionPreferences?.todoSort ?? "due") : sortRaw) ?? .due
    }

    private var todos: [ActionItem] { store.items(type: "todo") }
    private var completing: Set<String> { ui.completing.union(store.completing) }
    private var visible: [ActionItem] { todos.filter { ui.filter.matches($0, now: now) || completing.contains($0.id) } }
    private var toConfirm: [ActionItem] {
        guard !ui.filter.isNarrowed || ui.filter.jobID != nil else { return [] }
        return store.pending.filter { ui.filter.jobID == nil || $0.source.jobID == ui.filter.jobID }
    }
    private var selectedItem: ActionItem? {
        if let id = store.selected["todo"], let item = store.items[id], item.type == "todo", item.status == .open || item.status == .done { return item }
        return nil
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            ActionsHeader(eyebrow: "ACTIONS", title: "To do", subtitle: store.lastFound(type: "todo")) {
                ActionButton(title: "History", icon: "clock", height: 34) { store.historyRequest += 1 }
                ActionButton(title: "Add to-do", icon: "plus", kind: .primary, height: 34) { startAdding() }
                    .keyboardShortcut("n", modifiers: .command)
            }
            TodoFilterBar(store: store, ui: $ui, grouping: Binding(get: { grouping }, set: { groupRaw = $0.rawValue }),
                          sort: Binding(get: { sort }, set: { sortRaw = $0.rawValue }), todos: todos, now: now)
                .zIndex(5)
            HStack(alignment: .top, spacing: 8) {
                list
                if let item = selectedItem ?? (visible.first { $0.status == .open }), store.phase == .loaded, !visible.isEmpty {
                    TodoDetail(store: store, item: item, editing: $ui.editing, menu: $ui.menu, now: now)
                        .frame(width: 330)
                        .frame(maxHeight: .infinity, alignment: .top)
                        .overlay(alignment: .leading) { Rectangle().fill(Theme.border).frame(width: 1) }
                        .zIndex(4)
                }
            }
            .padding(.leading, 20)
            .frame(maxHeight: .infinity, alignment: .top)
        }
        .overlay(alignment: .bottom) {
            if !ui.selection.isEmpty { BulkBar(store: store, ui: $ui) }
        }
        .background(
            // A click outside an open menu closes it.
            Color.white.opacity(0.001).onTapGesture { ui.menu = nil }
        )
        .onAppear(perform: takeJobFilter)
        .onChange(of: store.jobFilter) { takeJobFilter() }
    }

    @ViewBuilder private var list: some View {
        Scrolling {
            VStack(alignment: .leading, spacing: 1) {
                findingState
                if let adding = ui.adding {
                    AddTodoRow(draft: Binding(get: { adding }, set: { ui.adding = $0 }), menu: $ui.menu,
                               add: addTodo, cancel: { ui.adding = nil })
                        .zIndex(3)
                }
                if store.phase != .loaded {
                    ActionShimmerRows()
                } else if visible.isEmpty && toConfirm.isEmpty && ui.adding == nil {
                    emptyState.padding(.top, 60)
                } else {
                    if !toConfirm.isEmpty { ToConfirmGroup(store: store, items: toConfirm, expanded: ui.previewing) }
                    if case .context(let line)? = searchContext, !ui.filter.text.isEmpty {
                        Text("\(visible.count) of \(todos.filter { ui.filter.statusMatches($0) }.count) to-dos match")
                            .font(Theme.body(12)).foregroundStyle(Theme.muted).padding(.horizontal, 12).padding(.vertical, 6)
                        let _ = line
                    }
                    ForEach(ActionList.grouped(visible, by: grouping, sort: sort, now: now)) { group in
                        if !group.title.isEmpty {
                            ActionGroupHeader(title: group.title, count: group.items.count, icon: groupIcon(group),
                                              ink: group.title == "OVERDUE" ? Theme.peachInk : Theme.faint)
                        }
                        ForEach(group.items) { item in
                            TodoRow(item: item, selected: store.selected["todo"] == item.id || (selectedItem == nil && item.id == visible.first?.id),
                                    checked: ui.selection.contains(item.id), selecting: !ui.selection.isEmpty,
                                    struck: completing.contains(item.id) || item.status == .done,
                                    match: ActionSearch.match(item, ui.filter.text), now: now,
                                    complete: { complete(item) },
                                    toggle: { toggle(item.id) },
                                    select: { store.selected["todo"] = item.id; ui.editing = false })
                        }
                    }
                }
            }
            .padding(.trailing, 8).padding(.bottom, 80)
        }
        // Delete removes the open to-do (never from a text field, unlike a key equivalent).
        .onDeleteCommand {
            if let item = selectedItem ?? visible.first(where: { $0.status == .open }) { store.remove(item) }
        }
    }

    private var searchContext: ActionSearch.Hit? {
        visible.lazy.compactMap { ActionSearch.match($0, ui.filter.text) }.first { $0 != .title }
    }

    private func groupIcon(_ g: ActionGroup) -> String? {
        switch g.title {
        case "OVERDUE": return "exclamationmark.circle"
        case "TODAY": return "sun.max"
        case "THIS WEEK", "LATER": return "calendar"
        case "NO DUE DATE": return "minus.circle"
        default: return grouping == .note ? "doc.text" : nil
        }
    }

    // MARK: States

    @ViewBuilder private var findingState: some View {
        if let (title, start) = findingNow {
            FindingStrip(title: title, start: start).padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 4)
        }
        if let job = failedJob {
            ActionCallout(title: "Couldn't find actions in \(job.displayTitle)",
                          text: "\(job.actionsFound?.error ?? "The action step failed.") The note itself was added to your vault; only the action step failed.") {
                ActionButton(title: "Try again", kind: .soft, height: 28) { store.findAgain(jobID: job.id) }
                ActionButton(title: "Settings", kind: .plain, height: 28) { store.openSettings("actions") }
            }
            .padding(.horizontal, 12).padding(.top, 10).padding(.bottom, 6)
        }
    }

    /// "Finding actions in 2 notes with Sonnet…" while a batch's last step runs.
    private var findingNow: (String, Date)? {
        for job in engine.jobs where job.actionsFound?.status == "finding" {
            let p = engine.progress[job.id]
            let model = ModelChoice.shortName(p?.model ?? job.actionsFound?.model ?? "sonnet")
            let n = max(1, job.files.count)
            return ("Finding actions in \(n == 1 ? "1 note" : "\(n) notes") with \(model)…", p?.startedAt ?? job.updatedAt)
        }
        return nil
    }

    private var failedJob: Job? {
        engine.jobs.filter { $0.actionsFound?.status == "failed" }.max { $0.updatedAt < $1.updatedAt }
    }

    @ViewBuilder private var emptyState: some View {
        if ui.filter.isNarrowed || ui.filter.status != .open {
            let hidden = todos.filter { $0.status == .done && ui.filter.facetsMatch($0, now: now) && ActionSearch.match($0, ui.filter.text) != nil }.count
            ActionsEmpty(icon: "magnifyingglass", title: "No to-dos match", message: noMatchText(hidden: hidden)) {
                ActionButton(title: "Clear filters", kind: .soft) { ui.filter = ActionFilter() }
                if hidden > 0 && ui.filter.status == .open {
                    ActionButton(title: "Show completed", kind: .plain) { ui.filter.status = .all }
                }
            }
        } else {
            ActionsEmpty(title: "Nothing to do", message: "When a processed note asks you to do something, Distill adds it here. Done and removed items are in History.") {
                ActionButton(title: "Add to-do", icon: "plus", kind: .primary) { startAdding() }
                ActionButton(title: "History", icon: "clock") { store.historyRequest += 1 }
            }
        }
    }

    private func noMatchText(hidden: Int) -> String {
        var what = ui.filter.status == .open ? "Nothing open" : "Nothing"
        if !ui.filter.labels.isEmpty { what += " with " + ui.filter.labels.sorted().map { "#" + $0 }.joined(separator: " or ") }
        let q = ui.filter.text.trimmingCharacters(in: .whitespaces)
        what += q.isEmpty ? " matches these filters." : " mentions “\(q)”."
        if hidden > 0 { what += " \(hidden) completed \(hidden == 1 ? "to-do matches" : "to-dos match")." }
        return what
    }

    // MARK: Commands

    private func takeJobFilter() {
        guard let id = store.jobFilter else { return }
        ui.filter = ActionFilter()
        ui.filter.jobID = id
        store.jobFilter = nil
    }

    private func startAdding() {
        ui.adding = NewTodo(labels: Array(ui.filter.labels).sorted())
    }

    private func addTodo() {
        guard let draft = ui.adding, !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var fields: [String: String] = [:]
        if let due = draft.due { fields["due"] = due }
        if let p = draft.priority { fields["priority"] = p }
        if !draft.people.isEmpty { fields["person"] = draft.people }
        store.create(NewActionInput(title: draft.title.trimmingCharacters(in: .whitespaces), fields: fields,
                                    vaultPath: engine.activeVault?.path, labels: draft.labels.isEmpty ? nil : draft.labels)) { item in
            store.selected["todo"] = item.id
        }
        ui.adding = nil
    }

    private func complete(_ item: ActionItem) {
        if item.status == .done { store.restore(item.id); return }
        store.complete(item)
    }

    private func toggle(_ id: String) {
        if ui.selection.contains(id) { ui.selection.remove(id) } else { ui.selection.insert(id) }
    }
}

/// One to-do row: circle, title, note · person · labels · priority, due badge.
struct TodoRow: View {
    let item: ActionItem
    var selected = false
    var checked = false
    var selecting = false
    var struck = false
    var match: ActionSearch.Hit? = .title
    var now = Date()
    var complete: () -> Void = {}
    var toggle: () -> Void = {}
    var select: () -> Void = {}

    var body: some View {
        HStack(spacing: 12) {
            if selecting {
                Button(action: toggle) {
                    Image(systemName: checked ? "checkmark.square.fill" : "square").font(.system(size: 16))
                        .foregroundStyle(checked ? Theme.primary : ActionsTheme.ring)
                }
                .buttonStyle(.plain)
            } else {
                Button(action: complete) {
                    ZStack {
                        Circle().strokeBorder(struck ? Theme.limeInk : ActionsTheme.ring, lineWidth: 1.5)
                        if struck { Circle().fill(Theme.lime).padding(1.5); Image(systemName: "checkmark").font(.system(size: 9, weight: .heavy)).foregroundStyle(Theme.limeInk) }
                    }
                    .frame(width: 18, height: 18)
                }
                .buttonStyle(.plain)
                .help(struck ? "Bring it back" : "Complete")
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(item.title).font(Theme.body(14, .semibold)).lineLimit(1)
                    .strikethrough(struck, color: Theme.faint).foregroundStyle(struck ? Theme.faint : Theme.ink)
                if case .context(let line)? = match {
                    Text("Match in the note excerpt: “\(line)”").font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                TodoMeta(item: item)
            }
            Spacer(minLength: 6)
            if let due = item.field("due") { DueBadge(due: due, now: now) }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(selected || checked ? ActionsTheme.selectedFill : .clear))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected || checked ? ActionsTheme.selectedStroke : .clear, lineWidth: 1.5))
        .contentShape(Rectangle())
        .onTapGesture {
            if selecting || NSEvent.modifierFlags.contains(.command) || NSEvent.modifierFlags.contains(.shift) { toggle() } else { select() }
        }
        .opacity(struck ? 0.7 : 1)
    }
}

struct TodoMeta: View {
    let item: ActionItem

    var body: some View {
        HStack(spacing: 10) {
            if let note = ActionList.noteTitle(item) {
                HStack(spacing: 4) {
                    Image(systemName: item.source.conversationID != nil ? "bubble.left" : "doc.text").font(.system(size: 9))
                    Text(note).lineLimit(1)
                }
                .foregroundStyle(Theme.muted)
            }
            ForEach(ActionList.people(item).prefix(2), id: \.self) { PersonChip(name: $0).foregroundStyle(Theme.muted) }
            ForEach(item.labels.prefix(3), id: \.self) { LabelTag(name: $0) }
            if let p = item.field("priority") { PriorityTag(priority: p) }
        }
        .font(Theme.body(11))
        .lineLimit(1)
    }
}

/// "TO CONFIRM 2": found items waiting for Add or ×, with Add all.
struct ToConfirmGroup: View {
    @ObservedObject var store: ActionsStore
    let items: [ActionItem]
    /// Rows open on their preview (snapshots start with some open).
    @State var expanded: Set<String> = []

    var body: some View {
        VStack(alignment: .leading, spacing: 1) {
            HStack {
                ActionGroupHeader(title: "TO CONFIRM", count: items.count, icon: "tray.and.arrow.down", ink: Theme.primary)
                if items.count > 1 {
                    Button("Dismiss all") { store.dismiss(items.map(\.id)) }.buttonStyle(.plain)
                        .font(Theme.body(11, .semibold)).foregroundStyle(Theme.muted)
                    Button("Add all") { store.confirm(items.map(\.id)) }.buttonStyle(.plain)
                        .font(Theme.body(11, .bold)).foregroundStyle(Theme.primary).padding(.trailing, 12)
                }
            }
            ForEach(items) { item in
                // v11 (action-context.md): the full title and where it goes; open it for the preview.
                ActionConfirmRow(store: store, item: item, expanded: Binding(
                    get: { expanded.contains(item.id) },
                    set: { open in if open { expanded.insert(item.id) } else { expanded.remove(item.id) } }))
            }
        }
        .padding(.bottom, 6)
    }
}

/// To do's toolbar (canvas ActionsToolbar): search, Filter ▾ with the FilterPanel
/// (Status, Due, Person, Label, Source note, Priority, More), one chip per filter
/// beyond Status: Open, and Group and sort on the right. One line at any width.
struct TodoFilterBar: View {
    @ObservedObject var store: ActionsStore
    @Binding var ui: TodoUI
    @Binding var grouping: ActionGrouping
    @Binding var sort: ActionSort
    let todos: [ActionItem]
    var now = Date()

    var body: some View {
        ActionsToolbar(search: $ui.filter.text, placeholder: "Search to-dos", chips: ActionFacets.todoChips(ui.filter),
                       right: .sort, sortTitle: grouping.title, panel: $ui.panel, inlinePanel: ui.inlinePanel,
                       removeChip: { ui.filter.remove($0) },
                       sortAction: { ui.menu = ui.menu == "group" ? nil : "group" },
                       sortItems: { EmptyView() },
                       panelContent: { section in
                           FilterPanel(kind: "todo", sections: ActionFacets.todoSections(todos, filter: ui.filter),
                                       scrollTo: section, focus: section.isEmpty ? nil : section, height: ui.panelHeight,
                                       inline: ui.inlinePanel, personQuery: ui.personQuery, expanded: ui.expanded,
                                       toggle: { ui.filter.toggle($0, $1) }, clearAll: { ui.filter.clearFilters() }, done: { ui.panel = nil })
                       })
        .overlay(alignment: .topTrailing) {
            if ui.menu == "group" { groupPanel.offset(y: 38) }
        }
        .zIndex(ui.menu == "group" || ui.panel != nil ? 20 : 0)
        .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 8)
    }

    private var groupPanel: some View {
        ActionMenuPanel(width: 260) {
            Text("GROUP BY").font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint).padding(.horizontal, 10).padding(.top, 6)
            ForEach(ActionGrouping.allCases, id: \.self) { g in
                ActionMenuRow(title: g.title, checked: grouping == g) { grouping = g }
            }
            Divider().padding(.vertical, 4)
            Text("SORT").font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint).padding(.horizontal, 10)
            ForEach(ActionSort.allCases, id: \.self) { s in
                ActionMenuRow(title: s.title, checked: sort == s) { sort = s }
            }
            Divider().padding(.vertical, 4)
            ActionMenuRow(title: "Show completed", detail: "Greyed", checked: ui.filter.status == .all) {
                ui.filter.status = ui.filter.status == .all ? .open : .all
            }
        }
    }
}

/// The new row at the top after Add to-do.
struct AddTodoRow: View {
    @Binding var draft: NewTodo
    @Binding var menu: String?
    let add: () -> Void
    let cancel: () -> Void
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Circle().strokeBorder(ActionsTheme.ring, lineWidth: 1.5).frame(width: 18, height: 18)
                TextField("What needs doing?", text: $draft.title).textFieldStyle(.plain).font(Theme.body(14, .semibold))
                    .focused($focused)
                    .onSubmit(add)
                    .onExitCommand(perform: cancel)
            }
            HStack(spacing: 6) {
                FilterMenuChip(title: "Due", value: draft.due.flatMap { ActionDue.short($0) }, onClear: { draft.due = nil },
                               open: Binding(get: { menu == "add-due" }, set: { menu = $0 ? "add-due" : nil })) {
                    ActionMenuPanel(title: "DUE", width: 200) {
                        ForEach(Self.dueChoices(), id: \.1) { title, value in
                            ActionMenuRow(title: title, checked: draft.due == value) { draft.due = value; menu = nil }
                        }
                    }
                }
                FilterMenuChip(title: "Priority", value: draft.priority, onClear: { draft.priority = nil },
                               open: Binding(get: { menu == "add-priority" }, set: { menu = $0 ? "add-priority" : nil })) {
                    ActionMenuPanel(title: "PRIORITY", width: 180) {
                        ForEach(ActionList.priorities, id: \.self) { p in
                            ActionMenuRow(title: p, icon: "flag", checked: draft.priority == p) { draft.priority = p; menu = nil }
                        }
                    }
                }
                HStack(spacing: 5) {
                    Image(systemName: "person").font(.system(size: 10))
                    TextField("People", text: $draft.people).textFieldStyle(.plain).frame(width: 90)
                }
                .font(Theme.body(12)).padding(.horizontal, 10).frame(height: 28)
                .overlay(Capsule().strokeBorder(Theme.border))
                ForEach(draft.labels, id: \.self) { LabelTag(name: $0, size: 12) }
                Spacer(minLength: 6)
                Text("↩ adds · Esc cancels · no source note").font(Theme.body(11)).foregroundStyle(Theme.faint).lineLimit(1).fixedSize()
                ActionButton(title: "Add", kind: .primary, height: 28, action: add)
                    .disabled(draft.title.trimmingCharacters(in: .whitespaces).isEmpty)
            }
            .padding(.leading, 30)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 12).fill(ActionsTheme.selectedFill))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ActionsTheme.selectedStroke, lineWidth: 1.5))
        .padding(.top, 8)
        .onAppear { focused = true }
    }

    static func dueChoices(now: Date = Date(), calendar: Calendar = .current) -> [(String, String)] {
        let day = { (n: Int) in ActionDue.format(calendar.date(byAdding: .day, value: n, to: now) ?? now, calendar: calendar) }
        let weekdayF = DateFormatter(); weekdayF.setLocalizedDateFormatFromTemplate("EEEE")
        var out = [("Today", day(0)), ("Tomorrow", day(1))]
        for n in 2...6 { out.append((weekdayF.string(from: calendar.date(byAdding: .day, value: n, to: now) ?? now), day(n))) }
        out.append(("Next week", day(7)))
        return out
    }
}

/// The selection bar: "3 selected · Complete · Due date · Priority · Label · Send to · Remove · Clear".
struct BulkBar: View {
    @ObservedObject var store: ActionsStore
    @Binding var ui: TodoUI

    var body: some View {
        let items = ui.selection.compactMap { store.items[$0] }
        HStack(spacing: 6) {
            Text("\(items.count) selected").font(Theme.body(13, .bold)).foregroundStyle(.white).padding(.trailing, 6)
            bar("Complete", "checkmark.circle") { store.complete(items); ui.selection = [] }
            bar("Due date", "calendar") { ui.menu = ui.menu == "bulk-due" ? nil : "bulk-due" }
                .overlay(alignment: .bottomLeading) {
                    if ui.menu == "bulk-due" {
                        ActionMenuPanel(title: "DUE", width: 200) {
                            ForEach(AddTodoRow.dueChoices(), id: \.1) { title, value in
                                ActionMenuRow(title: title) { items.forEach { store.update($0.id, ActionPatch(fields: ["due": value])) }; ui.menu = nil }
                            }
                            ActionMenuRow(title: "No due date") { items.forEach { store.update($0.id, ActionPatch(fields: ["due": nil])) }; ui.menu = nil }
                        }
                        .offset(y: -44)
                    }
                }
            bar("Priority", "flag") { ui.menu = ui.menu == "bulk-priority" ? nil : "bulk-priority" }
                .overlay(alignment: .bottomLeading) {
                    if ui.menu == "bulk-priority" {
                        ActionMenuPanel(title: "PRIORITY", width: 180) {
                            ForEach(ActionList.priorities + ["None"], id: \.self) { p in
                                ActionMenuRow(title: p) { items.forEach { store.update($0.id, ActionPatch(fields: ["priority": p == "None" ? nil : p])) }; ui.menu = nil }
                            }
                        }
                        .offset(y: -44)
                    }
                }
            bar("Label", "tag") { ui.menu = ui.menu == "bulk-label" ? nil : "bulk-label" }
                .overlay(alignment: .bottomLeading) {
                    if ui.menu == "bulk-label" {
                        ActionMenuPanel(title: "ADD A LABEL", width: 200) {
                            ForEach(Array(Set(store.items(type: "todo").flatMap(\.labels))).sorted(), id: \.self) { l in
                                ActionMenuRow(title: "#\(l)") {
                                    for i in items where !i.labels.contains(l) {
                                        store.update(i.id, ActionPatch(labels: i.labels + [l]))
                                    }
                                    ui.menu = nil
                                }
                            }
                        }
                        .offset(y: -44)
                    }
                }
            bar("Send to", "arrow.turn.up.right") { ui.menu = ui.menu == "bulk-send" ? nil : "bulk-send" }
                .overlay(alignment: .bottomLeading) {
                    if ui.menu == "bulk-send" {
                        SendToPanel(store: store, item: items.first) { type in items.forEach { store.sendTo($0, type: type) }; ui.selection = []; ui.menu = nil }
                            .offset(y: -44)
                    }
                }
            bar("Remove", "trash") { items.forEach { store.remove($0) }; ui.selection = [] }
            Button("Clear") { ui.selection = []; ui.menu = nil }.buttonStyle(.plain).font(Theme.body(12, .semibold))
                .foregroundStyle(Color(hex: 0x9CC2FF)).padding(.leading, 4)
        }
        .padding(.horizontal, 14).frame(height: 46)
        .background(Capsule().fill(Theme.ink).shadow(color: .black.opacity(0.2), radius: 12, y: 6))
        .padding(.bottom, 22)
    }

    private func bar(_ title: String, _ icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 5) {
                Image(systemName: icon).font(.system(size: 11, weight: .semibold))
                Text(title).font(Theme.body(12, .semibold))
            }
            .foregroundStyle(.white).padding(.horizontal, 10).frame(height: 30)
            .background(Capsule().fill(Color.white.opacity(0.1)))
            .fixedSize()
        }
        .buttonStyle(.plain)
    }
}

/// SEND TO: each type that is on, the suggested one first; reserved ones disabled.
struct SendToPanel: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem?
    let pick: (String) -> Void

    var body: some View {
        ActionMenuPanel(title: "SEND TO", width: 320) {
            ForEach(store.types.filter { $0.id != "todo" && ($0.enabled || $0.reserved) }
                .sorted { ($0.id == suggested ? 0 : $0.reserved ? 2 : 1) < ($1.id == suggested ? 0 : $1.reserved ? 2 : 1) }) { t in
                let style = ActionsTheme.typeStyle(t.id)
                ActionMenuRow(title: t.label, detail: detail(t), icon: style.0, iconStyle: (style.1, style.2),
                              badge: t.reserved ? "Coming later" : (suggested == t.id ? "Suggested" : nil),
                              disabled: !t.isUsable) { pick(t.id) }
            }
            Text("It leaves To do and becomes a draft you check first. Nothing is created until you press Create.")
                .font(Theme.body(11)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 10).padding(.vertical, 6)
        }
    }

    /// A type named in the quote or why ("Needs a ticket in PX" → Jira).
    private var suggested: String? {
        guard let item else { return nil }
        let text = [item.source.quote, item.why, item.title].compactMap { $0 }.joined(separator: " ").lowercased()
        if text.contains("ticket") || text.contains("jira") { return "jira" }
        if text.contains("confluence") || text.contains("write up") || text.contains("write-up") { return "confluence" }
        if text.contains("slack") || text.contains("tell ") || text.contains("message") { return "slack" }
        return nil
    }

    private func detail(_ t: ActionTypeInfo) -> String {
        switch t.id {
        case "jira": return "Draft a ticket" + (item?.field("project").map { " in \($0)" } ?? "")
        case "confluence": return "Draft a page" + (item?.field("space").map { " in the \($0) space" } ?? "")
        case "slack": return "Write a message to paste in Slack"
        case "email": return "Write an email"
        default: return "Draft a \(t.label.lowercased())"
        }
    }
}

/// The right-hand detail of a to-do: fields, context, Complete / Send to / Remove; edit in place.
struct TodoDetail: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    @Binding var editing: Bool
    @Binding var menu: String?
    var now = Date()

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 6) {
                StatusBadge(text: item.status == .done ? "Completed" : "Open", fill: item.status == .done ? Theme.limeTint : Theme.panel,
                            ink: item.status == .done ? Theme.limeInk : Theme.softInk)
                Spacer()
                IconButton(systemImage: editing ? "checkmark" : "pencil", size: 28, help: editing ? "Done" : "Edit") { editing.toggle() }
                    .keyboardShortcut(editing ? KeyboardShortcut(.return, modifiers: .command) : nil)
            }
            if editing { editor } else { reading }
            ActionContextBlock(item: item)
            siblings
            Spacer(minLength: 0)
            if editing {
                HStack {
                    Text("Saved as you type").font(Theme.body(11)).foregroundStyle(Theme.muted)
                    Spacer()
                    ActionButton(title: "Done", kind: .primary) { editing = false }
                }
            } else {
                // Same order on every tab: remove on the left; Complete, then the primary action.
                HStack(spacing: 8) {
                    IconButton(systemImage: "trash", size: 30, help: "Remove (Delete)") { store.remove(item) }
                    Spacer(minLength: 4)
                    if item.status == .done {
                        SoftButton(title: "Bring back", size: .small, systemImage: "arrow.uturn.backward") { store.restore(item.id) }
                    } else {
                        SoftButton(title: "Complete", size: .small, systemImage: "checkmark") { store.complete(item) }
                        PrimaryButton(title: "Send to", systemImage: "paperplane", size: .small) { menu = menu == "sendto" ? nil : "sendto" }
                    }
                }
                .overlay(alignment: .bottomTrailing) {
                    if menu == "sendto" {
                        SendToPanel(store: store, item: item) { store.sendTo(item, type: $0); menu = nil }
                            .offset(y: -42)
                    }
                }
                .zIndex(10)
            }
        }
        .padding(.horizontal, 22).padding(.top, 4).padding(.bottom, 20)
    }

    private var reading: some View {
        VStack(alignment: .leading, spacing: 14) {
            Text(item.title).font(.system(size: 18, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                .onTapGesture(count: 2) { editing = true }
            VStack(alignment: .leading, spacing: 4) {
                if let due = item.field("due") {
                    fieldRow("Due") {
                        DueBadge(due: due, now: now)
                        if let long = ActionDue.long(due, now: now) { Text(long).font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true) }
                    }
                }
                if let p = item.field("priority") { fieldRow("Priority") { PriorityTag(priority: p, size: 12) } }
                let people = ActionList.people(item)
                if !people.isEmpty {
                    fieldRow("People") { ForEach(people, id: \.self) { PersonChip(name: $0, size: 20, short: false).font(Theme.body(13)) } }
                }
                if !item.labels.isEmpty { fieldRow("Labels") { ForEach(item.labels, id: \.self) { LabelTag(name: $0, size: 12) } } }
            }
            if let body = item.body, !body.isEmpty {
                Markdown(body).font(Theme.body(13)).foregroundStyle(Theme.softInk)
            }
        }
    }

    private var editor: some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: Binding(get: { item.title }, set: { store.update(item.id, ActionPatch(title: $0)) }), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 18, weight: .semibold, design: .rounded))
                .padding(8).background(RoundedRectangle(cornerRadius: 10).strokeBorder(ActionsTheme.selectedStroke, lineWidth: 1.5))
            fieldRow("Due") {
                Menu {
                    ForEach(AddTodoRow.dueChoices(), id: \.1) { title, value in
                        Button(title) { store.update(item.id, ActionPatch(fields: ["due": value])) }
                    }
                    Button("No due date") { store.update(item.id, ActionPatch(fields: ["due": nil])) }
                } label: { editValue(item.field("due").flatMap { ActionDue.long($0, now: now) } ?? "No due date") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            fieldRow("Priority") {
                Menu {
                    ForEach(ActionList.priorities + ["None"], id: \.self) { p in
                        Button(p) { store.update(item.id, ActionPatch(fields: ["priority": p == "None" ? nil : p])) }
                    }
                } label: { editValue(item.field("priority") ?? "None") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
            }
            fieldRow("People") {
                TextField("Who it involves", text: Binding(get: { item.field("person") ?? "" },
                                                           set: { store.update(item.id, ActionPatch(fields: ["person": $0.isEmpty ? nil : $0])) }))
                    .textFieldStyle(.plain).font(Theme.body(13))
                    .padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            }
            fieldRow("Labels") {
                TextField("tea-club, project-x", text: Binding(get: { item.labels.joined(separator: ", ") },
                                                              set: { store.update(item.id, ActionPatch(labels: Self.labels($0))) }))
                    .textFieldStyle(.plain).font(Theme.body(13))
                    .padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
            }
        }
    }

    static func labels(_ text: String) -> [String] {
        text.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces).trimmingCharacters(in: CharacterSet(charactersIn: "#")) }
            .filter { !$0.isEmpty }
    }

    private func editValue(_ text: String) -> some View {
        HStack(spacing: 5) {
            Text(text).font(Theme.body(13))
            Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
        }
        .padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
    }

    private func fieldRow<V: View>(_ label: String, @ViewBuilder _ value: () -> V) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: 70, alignment: .leading)
            HStack(spacing: 6) { value() }
            Spacer(minLength: 0)
        }
        .frame(minHeight: 26)
    }

    /// "Also from this note: Message to Mei in Slack messages".
    @ViewBuilder private var siblings: some View {
        let note = ActionList.noteTitle(item)
        let others = store.items.values.filter {
            $0.id != item.id && $0.type != "todo" && !$0.status.isHistory && $0.status != .dismissed && $0.status != .pending
                && note != nil && ActionList.noteTitle($0) == note && $0.source.jobID == item.source.jobID
        }
        if let other = others.first {
            let style = ActionsTheme.typeStyle(other.type)
            Button { store.open(other) } label: {
                HStack(spacing: 8) {
                    Image(systemName: style.0).font(.system(size: 10, weight: .semibold)).foregroundStyle(style.2)
                        .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 7).fill(style.1))
                    (Text("Also from this note: ") + Text(other.title).fontWeight(.semibold).foregroundColor(Theme.primary)
                     + Text(" in \(store.label(other.type))"))
                        .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            .buttonStyle(.plain)
        }
    }
}
