import AppKit
import SwiftUI
import DistillKit

// "Found in this answer" under an Ask answer (canvas: ActionsAsk), full in the
// Ask screen and compact in quick ask, plus "Add to to-do ▾ / Send to ▾" on every
// answer. Detection runs in the core after each answer; items arrive as `action`
// events whose source is this conversation.

extension ActionsStore {
    /// The items found in one answer: the turn the core recorded, else the answer that
    /// quotes it, else the latest answer.
    func askItems(conversationID: String, turnIndex: Int, answer: String, isLast: Bool) -> [ActionItem] {
        items.values.filter { item in
            guard case .ask(let cid, _, let quote, _, let turn, _) = item.source, cid == conversationID else { return false }
            if item.source.isManual { return false }
            if let turn { return turn == turnIndex }
            if let quote, !quote.isEmpty, answer.contains(quote.trimmingCharacters(in: CharacterSet(charactersIn: "…. "))) { return true }
            return isLast
        }
        .filter { $0.status != .removed || $0.lastEvent("found") != nil }
        .sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) }
    }

    /// Items detection said are already in Actions (from a note or another chat).
    func alreadyItems(conversationID: String) -> [ActionItem] {
        (already[conversationID] ?? []).compactMap { items[$0] }
    }

    /// Detection still running for this chat (progress key `actions:<conversationID>`).
    func detecting(_ conversationID: String) -> CoreProgress? {
        guard let p = engine?.progress["actions:\(conversationID)"], !p.finished else { return nil }
        return p
    }

    /// The answer's gap became an action: the Gap callout is hidden.
    func gapTaken(conversationID: String, turnIndex: Int, answer: String, isLast: Bool) -> Bool {
        askItems(conversationID: conversationID, turnIndex: turnIndex, answer: answer, isLast: isLast).contains { item in
            if case .ask(_, _, _, _, _, true) = item.source { return item.status != .dismissed }
            return false
        }
    }

    /// Added without asking (confirm off): no "confirmed" event, never pending.
    static func autoAdded(_ item: ActionItem) -> Bool {
        ![.pending, .dismissed].contains(item.status) && item.lastEvent("confirmed") == nil
    }

    /// An action made by hand from an answer: To-do from the whole answer, or Send to a type.
    func createFromAnswer(type: String, title: String, conversationID: String, question: String, answer: String,
                          cited: [String], turnIndex: Int, fields: [String: String] = [:], labels: [String] = [], vault: String?) {
        let quote = String(answer.prefix(400))
        create(NewActionInput(type: type, title: title, fields: fields.isEmpty ? nil : fields, why: nil,
                              source: .ask(conversationID: conversationID, question: question, quote: quote, citedPaths: cited,
                                           turnIndex: turnIndex, gap: false),
                              vaultPath: vault, labels: labels.isEmpty ? nil : labels)) { [weak self] item in
            guard let self else { return }
            if type == "todo" {
                self.show(ActionToast(text: "Added “\(item.title)” to To do", undo: { [weak self] in self?.remove(item) },
                                      open: { [weak self] in self?.open(item) }))
            } else {
                self.open(tab: type, select: item.id)
            }
        }
    }
}

/// What one answer shows: the Found block (or its detecting placeholder).
struct AskFoundBlock: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let conversationID: String
    let turnIndex: Int
    let answer: String
    var isLast = true
    var compact = false
    /// Snapshots: start with a type menu open or a row being edited.
    @State var menu: String? = nil
    @State var editing: String? = nil
    @State private var editText = ""

    var body: some View {
        let found = store.askItems(conversationID: conversationID, turnIndex: turnIndex, answer: answer, isLast: isLast)
        let already = isLast ? store.alreadyItems(conversationID: conversationID) : []
        if isLast, found.isEmpty, let p = store.detecting(conversationID) {
            detectingView(p)
        } else if !found.isEmpty || !already.isEmpty {
            let auto = found.filter(ActionsStore.autoAdded)
            let key = "\(conversationID)#\(turnIndex)"
            if !compact, store.addedAll[key] == nil, !auto.isEmpty, auto.count == found.filter({ $0.status != .dismissed }).count,
               !store.expandedAdded.contains(key) {
                autoAddedLine(auto, key: key)
            } else {
                block(found, already: already, key: key)
            }
        }
    }

    // MARK: Pieces

    private func detectingView(_ p: CoreProgress) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Spinner(size: 13)
                Text("Looking for actions in this answer…").font(Theme.body(12, .bold))
                Text(ModelChoice.shortName(p.model ?? "sonnet")).font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
            if !compact {
                ForEach(0..<2, id: \.self) { i in
                    HStack(spacing: 10) {
                        Shimmer(width: 30, height: 30, radius: 8)
                        VStack(alignment: .leading, spacing: 6) { Shimmer(width: [260, 200][i], height: 10); Shimmer(width: [180, 140][i], height: 8) }
                    }
                }
            }
        }
        .padding(compact ? 8 : 12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: 0xD6E4FB), lineWidth: 1.5))
    }

    /// Confirm off: "Added 1 to-do and created 3 drafts from this answer · Show · Undo · Open Actions".
    private func autoAddedLine(_ auto: [ActionItem], key: String) -> some View {
        let todos = auto.filter { $0.type == "todo" }.count
        return HStack(spacing: 10) {
            Image(systemName: "checkmark.circle.fill").foregroundStyle(Theme.limeInk)
            Text(ActionCounts.addedPhrase(todos: todos, drafts: auto.count - todos) + " from this answer").font(Theme.body(12, .semibold))
            Spacer(minLength: 6)
            link("Show") { store.expandedAdded.insert(key) }
            link("Undo") { store.dismiss(auto.map(\.id)) }
            link("Open Actions") { store.open(tab: "todo") }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 14).fill(ActionsTheme.doneFill))
    }

    private func block(_ found: [ActionItem], already: [ActionItem], key: String) -> some View {
        let pending = found.filter { $0.status == .pending }
        let live = found.filter { $0.status != .dismissed }
        return VStack(alignment: .leading, spacing: 2) {
            header(found: found, pending: pending, key: key)
            ForEach(live) { item in row(item) }
            ForEach(already) { item in alreadyRow(item) }
            ForEach(found.filter { $0.status == .dismissed }) { item in dismissedRow(item) }
        }
        .padding(compact ? 6 : 10)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: 0xD6E4FB), lineWidth: 1.5))
        .zIndex(menu == nil ? 0 : 10)
        .onAppear {
            if let id = store.fixtureFoundMenu { menu = id }
            if let id = store.fixtureFoundEdit, let item = store.items[id] { editing = id; editText = item.title + " 2 PM" }
        }
    }

    @ViewBuilder private func header(found: [ActionItem], pending: [ActionItem], key: String) -> some View {
        if let ids = store.addedAll[key] {
            let added = ids.compactMap { store.items[$0] }
            let todos = added.filter { $0.type == "todo" }.count
            HStack(spacing: 8) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 12)).foregroundStyle(Theme.limeInk)
                Text(ActionCounts.addedPhrase(todos: todos, drafts: added.count - todos)).font(Theme.body(12, .heavy))
                Spacer(minLength: 6)
                link("Undo") { store.dismiss(ids); store.addedAll[key] = nil }
                if !compact { link("Open Actions") { store.open(tab: "todo") } }
            }
            .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 4)
        } else {
            HStack(spacing: 8) {
                Image(systemName: "sparkles").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.primary)
                Text("Found in this answer").font(Theme.body(12, .heavy))
                let model = found.first?.lastEvent("found")?.detail ?? "Sonnet"
                Text("\(found.filter { $0.status != .dismissed }.count) · \(model)").font(Theme.body(11)).foregroundStyle(Theme.muted)
                Spacer(minLength: 6)
                if pending.count > 1 {
                    if !compact {
                        Button("Dismiss all") { store.dismiss(pending.map(\.id)) }.buttonStyle(.plain)
                            .font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted).padding(.horizontal, 8)
                    }
                    ActionButton(title: "Add all", kind: .primary, height: 26) {
                        store.confirm(pending.map(\.id))
                        store.addedAll[key] = pending.map(\.id)
                    }
                }
            }
            .padding(.horizontal, 4).padding(.top, 2).padding(.bottom, 4)
        }
    }

    private func typeLine(_ item: ActionItem) -> some View {
        let style = ActionsTheme.typeStyle(item.type)
        let label = item.type == "todo" ? "TO DO" : (store.type(item.type)?.label ?? item.type).uppercased()
        return HStack(spacing: 8) {
            Button { if item.status == .pending { menu = menu == item.id ? nil : item.id } } label: {
                HStack(spacing: 4) {
                    Text(label).font(Theme.body(10, .heavy)).kerning(0.5)
                    if item.status == .pending { Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold)) }
                }
                .foregroundStyle(style.2)
            }
            .buttonStyle(.plain)
            .help("Change where it goes")
            .overlay(alignment: .topLeading) {
                if menu == item.id && store.fixtureFoundMenu != nil { typeMenu(item).offset(y: 18) }
            }
            .popover(isPresented: Binding(get: { menu == item.id && store.fixtureFoundMenu == nil }, set: { if !$0 { menu = nil } }),
                     arrowEdge: .bottom) { typeMenu(item).padding(4) }
            if !compact, let target = target(item) { Text(target).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1) }
        }
        .zIndex(menu == item.id ? 10 : 0)
    }

    private func target(_ item: ActionItem) -> String? {
        if let to = item.field("to") { return "To \(to)" }
        if let space = item.field("space") { return [space, item.field("parent")].compactMap { $0 }.joined(separator: " › ") }
        if let project = item.field("project") { return project }
        return nil
    }

    private func typeMenu(_ item: ActionItem) -> some View {
        ActionMenuPanel(title: "ADD AS", width: 230) {
            ForEach(store.types.filter { $0.enabled || $0.reserved }) { t in
                let style = ActionsTheme.typeStyle(t.id)
                ActionMenuRow(title: t.id == "todo" ? "To-do" : t.label, icon: style.0, iconStyle: (style.1, style.2), checked: t.id == item.type,
                              badge: t.reserved ? "Coming later" : nil, disabled: !t.isUsable) {
                    store.update(item.id, ActionPatch(type: t.id)); menu = nil
                }
            }
        }
    }

    private func row(_ item: ActionItem) -> some View {
        let style = ActionsTheme.typeStyle(item.type)
        return HStack(alignment: .center, spacing: 10) {
            Image(systemName: style.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(style.2)
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30).background(RoundedRectangle(cornerRadius: 8).fill(style.1))
            VStack(alignment: .leading, spacing: 2) {
                typeLine(item)
                if editing == item.id {
                    TextField("Title", text: $editText).textFieldStyle(.plain).font(Theme.body(13, .semibold))
                        .padding(.horizontal, 6).padding(.vertical, 3)
                        .background(RoundedRectangle(cornerRadius: 6).strokeBorder(ActionsTheme.selectedStroke, lineWidth: 1.5))
                        .onSubmit { store.update(item.id, ActionPatch(title: editText)); store.confirm([item.id]); editing = nil }
                        .onExitCommand { editing = nil }
                } else {
                    Text(item.title).font(Theme.body(13, .semibold)).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                        .onTapGesture { if item.status == .pending { editText = item.title; editing = item.id } }
                        .help(compact ? (item.why ?? "") : "Click to fix it before adding")
                }
                if !compact, let why = item.why, !why.isEmpty {
                    (Text("Why: ").fontWeight(.bold).foregroundColor(Theme.softInk) + Text(why))
                        .font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(2)
                }
            }
            Spacer(minLength: 6)
            rowTrailing(item)
        }
        .padding(.horizontal, compact ? 6 : 10).padding(.vertical, compact ? 6 : 9)
        .zIndex(menu == item.id ? 10 : 0)
    }

    @ViewBuilder private func rowTrailing(_ item: ActionItem) -> some View {
        if editing == item.id {
            ActionButton(title: item.type == "todo" ? "Add" : "Create draft", icon: "plus", kind: .soft, height: 26) {
                store.update(item.id, ActionPatch(title: editText)); store.confirm([item.id]); editing = nil
            }
            Button("Cancel") { editing = nil }.buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
        } else if item.status == .pending {
            ActionButton(title: item.type == "todo" ? "Add" : "Create draft", icon: "plus", kind: .soft, height: 26) { store.confirm([item.id]) }
            IconButton(icon: "xmark", help: "Dismiss", size: 26) { store.dismiss([item.id]) }
        } else if item.status == .drafting || store.running[item.id] != nil {
            HStack(spacing: 6) { Spinner(size: 11); Text("Writing draft…").font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted) }
        } else {
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").font(.system(size: 11)).foregroundStyle(Theme.limeInk)
                Text(item.type == "todo" ? "Added to To do" : "Draft in \(store.label(item.type))").font(Theme.body(12, .semibold)).foregroundStyle(Theme.limeInk)
                link("Open") { store.open(item) }
            }
        }
    }

    private func alreadyRow(_ item: ActionItem) -> some View {
        let style = ActionsTheme.typeStyle(item.type)
        return HStack(spacing: 10) {
            Image(systemName: style.0).font(.system(size: 12, weight: .semibold)).foregroundStyle(style.2)
                .frame(width: compact ? 26 : 30, height: compact ? 26 : 30).background(RoundedRectangle(cornerRadius: 8).fill(style.1))
            VStack(alignment: .leading, spacing: 2) {
                Text(item.type == "todo" ? "TO DO" : (store.type(item.type)?.label ?? item.type).uppercased())
                    .font(Theme.body(10, .heavy)).kerning(0.5).foregroundStyle(style.2)
                Text(item.title).font(Theme.body(13, .semibold)).lineLimit(2)
            }
            Spacer(minLength: 6)
            Text("Already in \(store.label(item.type))").font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
            link("Open") { store.open(item) }
        }
        .padding(.horizontal, compact ? 6 : 10).padding(.vertical, compact ? 6 : 9)
    }

    private func dismissedRow(_ item: ActionItem) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "xmark").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.faint).frame(width: compact ? 26 : 30)
            Text(item.title).font(Theme.body(12)).foregroundStyle(Theme.faint).lineLimit(1).strikethrough(color: Theme.faint)
            Text("Dismissed").font(Theme.body(11)).foregroundStyle(Theme.faint)
            Spacer(minLength: 6)
            link("Undo") { store.restore(item.id) }
        }
        .padding(.horizontal, compact ? 6 : 10).padding(.vertical, 5)
        .opacity(0.8)
    }

    private func link(_ title: String, _ action: @escaping () -> Void) -> some View {
        Button(title, action: action).buttonStyle(.plain).font(Theme.body(12, .bold)).foregroundStyle(Theme.primary)
    }
}

/// "Add to to-do ▾" and "Send to ▾" under every answer, and the small prefilled form.
struct AnswerActionButtons: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let conversationID: String?
    let turnIndex: Int
    let question: String
    let answer: String
    let cited: [String]
    @Binding var form: NewTodo?
    @State var menu: Bool = false

    var body: some View {
        HStack(spacing: 8) {
            button("Add to to-do", icon: "checklist") { menu.toggle() }
            button("Send to", icon: "arrow.turn.up.right") { menu.toggle() }
        }
        // A popover in the app (the chat scrolls and would clip a drawn panel);
        // snapshots draw the panel in place.
        .overlay(alignment: .topLeading) {
            if menu && store.fixtureAnswerMenu { panel.offset(y: 40) }
        }
        .popover(isPresented: Binding(get: { menu && !store.fixtureAnswerMenu }, set: { menu = $0 }), arrowEdge: .bottom) {
            panel.padding(4)
        }
        .zIndex(menu ? 10 : 0)
        .onAppear { if store.fixtureAnswerMenu { menu = true } }
        .disabled(conversationID == nil)
        .help(conversationID == nil ? "Available once the answer is saved in this chat" : "")
    }

    private var panel: some View {
        ActionMenuPanel(title: "ADD OR SEND THIS ANSWER", width: 320) {
            ActionMenuRow(title: "To-do from the whole answer", detail: "Title: \(Self.title(answer))", icon: "checkmark.circle",
                          iconStyle: (Theme.limeTint, Theme.limeInk)) {
                form = NewTodo(title: Self.title(answer)); menu = false
            }
            ActionMenuRow(title: "To-do from selected text", detail: "Select text in the answer first", icon: "text.cursor",
                          iconStyle: (Theme.panel, Theme.muted), disabled: true) {}
            ForEach(store.types.filter { $0.id != "todo" && ($0.enabled || $0.reserved) }) { t in
                let style = ActionsTheme.typeStyle(t.id)
                ActionMenuRow(title: t.label, detail: t.reserved ? nil : "Draft from this answer", icon: style.0, iconStyle: (style.1, style.2),
                              badge: t.reserved ? "Coming later" : nil, disabled: !t.isUsable) {
                    if let cid = conversationID {
                        store.createFromAnswer(type: t.id, title: Self.title(answer), conversationID: cid, question: question, answer: answer,
                                               cited: cited, turnIndex: turnIndex, vault: engine.activeVault?.path)
                    }
                    menu = false
                }
            }
        }
    }

    private func button(_ title: String, icon: String, _ action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: icon).font(.system(size: 11, weight: .bold))
                Text(title).font(Theme.body(13, .semibold))
                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 14).frame(height: 34)
            .background(Capsule().fill(Theme.panel))
            .fixedSize()
        }
        .buttonStyle(.plain)
    }

    /// The answer's first sentence (without markers and Markdown), at most 80 characters.
    static func title(_ answer: String) -> String {
        var s = answer.replacingOccurrences(of: #"\[\d+\]"#, with: "", options: .regularExpression)
            .replacingOccurrences(of: "**", with: "").replacingOccurrences(of: "\n", with: " ")
        if let end = s.range(of: ". ") { s = String(s[..<end.lowerBound]) }
        s = s.trimmingCharacters(in: .whitespacesAndNewlines.union(CharacterSet(charactersIn: ".")))
        return s.count > 80 ? String(s.prefix(79)) + "…" : s
    }
}

/// "NEW TO-DO FROM THIS ANSWER": the small prefilled form under an answer.
struct AnswerTodoForm: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    let conversationID: String?
    let turnIndex: Int
    let question: String
    let answer: String
    let cited: [String]
    @Binding var form: NewTodo?

    /// The new to-do form appears under the answer.
    var body: some View {
        if let draft = form, let cid = conversationID {
            VStack(alignment: .leading, spacing: 10) {
                Text("NEW TO-DO FROM THIS ANSWER").font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                TextField("What needs doing?", text: Binding(get: { draft.title }, set: { form?.title = $0 }))
                    .textFieldStyle(.plain).font(Theme.body(14, .semibold))
                    .onSubmit { add(cid) }
                HStack(spacing: 6) {
                    Menu {
                        ForEach(AddTodoRow.dueChoices(), id: \.1) { title, value in Button(title) { form?.due = value } }
                        Button("No due date") { form?.due = nil }
                    } label: { Text("Due: \(draft.due.flatMap { ActionDue.short($0) } ?? "None")") }
                        .menuStyle(.borderlessButton).fixedSize()
                    Menu {
                        ForEach(ActionList.priorities + ["None"], id: \.self) { p in Button(p) { form?.priority = p == "None" ? nil : p } }
                    } label: { Text("Priority: \(draft.priority ?? "None")") }
                        .menuStyle(.borderlessButton).fixedSize()
                    ForEach(draft.labels, id: \.self) { LabelTag(name: $0, size: 12) }
                }
                .font(Theme.body(12))
                Text("The quote and chat link are kept as context.").font(Theme.body(11)).foregroundStyle(Theme.muted)
                HStack {
                    Spacer()
                    ActionButton(title: "Cancel", kind: .plain, height: 30) { form = nil }
                    ActionButton(title: "Add to-do", kind: .primary, height: 30) { add(cid) }
                }
            }
            .padding(14)
            .frame(maxWidth: 520, alignment: .leading)
            .background(RoundedRectangle(cornerRadius: 14).fill(Color.white).shadow(color: .black.opacity(0.08), radius: 10, y: 6))
            .overlay(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.border))
        }
    }

    private func add(_ cid: String) {
        guard let draft = form, !draft.title.trimmingCharacters(in: .whitespaces).isEmpty else { return }
        var fields: [String: String] = [:]
        if let d = draft.due { fields["due"] = d }
        if let p = draft.priority { fields["priority"] = p }
        store.createFromAnswer(type: "todo", title: draft.title, conversationID: cid, question: question, answer: answer, cited: cited,
                               turnIndex: turnIndex, fields: fields, labels: draft.labels, vault: engine.activeVault?.path)
        form = nil
    }

}

/// An answer's Gap callouts, hidden when the gap became an action.
struct AnswerGaps: View {
    @ObservedObject var store: ActionsStore
    let gaps: [String]
    let conversationID: String?
    let turnIndex: Int
    let answer: String
    let isLast: Bool

    var body: some View {
        if !(conversationID.map { store.gapTaken(conversationID: $0, turnIndex: turnIndex, answer: answer, isLast: isLast) } ?? false) {
            ForEach(gaps, id: \.self) { GapCallout(text: $0) }
        }
    }
}
