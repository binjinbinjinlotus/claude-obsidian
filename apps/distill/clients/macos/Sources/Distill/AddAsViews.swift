import SwiftUI
import DistillKit

// "Add as" at confirm time (actions.md): the split button (Add as <found type> | ▾), the Add as…
// menu, and the inline panel that adds the item as another type with its fields prefilled.

extension ActionsStore {
    /// The found type adds at once; another type opens the panel, prefilled.
    func addAs(_ item: ActionItem, _ typeID: String) {
        addAsMenu = nil
        if typeID == item.type { confirm([item.id]); return }
        guard let type = type(typeID) else { return }
        addingAs[item.id] = AddAs.prefill(item, as: type)
    }

    /// Why the panel's Add is off; a Slack To that is a name nobody has said who it is counts as empty.
    func addAsBlock(_ item: ActionItem, _ draft: AddAs.Draft, _ type: ActionTypeInfo) -> String? {
        var unknown = false
        if type.id == "slack", slackSendsToField(type) {
            unknown = SlackTarget.resolve(to: draft.fields["to"], thread: draft.fields["thread"],
                                          lookup: SlackToText.lookup(slackPeople, vault: slackVault(item))).ask != nil
        }
        return AddAs.blockReason(draft, type: type, unknownName: unknown)
    }

    func finishAddAs(_ item: ActionItem, onDone: (() -> Void)? = nil) {
        guard let draft = addingAs[item.id], let type = type(draft.type), addAsBlock(item, draft, type) == nil, let client else { return }
        Task {
            do {
                if let added = try await client.confirmAction(item.id, as: ConfirmAs(draft)) { items[added.id] = added }
                addingAs[item.id] = nil
                onDone?()
            } catch {
                engine?.report(error)
            }
        }
    }
}

/// Dismiss | [Add as to-do | ▾]: the main part adds as the found type; ▾ opens Add as….
struct AddAsSplitButton: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var height: CGFloat = 32
    var onDone: (() -> Void)? = nil

    private var open: Bool { store.addAsMenu == item.id }

    var body: some View {
        HStack(spacing: 1) {
            Button { store.confirm([item.id]); onDone?() } label: {
                HStack(spacing: 6) {
                    Image(systemName: "plus").font(.system(size: 11, weight: .bold))
                    Text(AddAs.mainTitle(item, types: store.types)).font(Theme.body(13, .semibold)).lineLimit(1)
                }
                .padding(.leading, 14).padding(.trailing, 10).frame(height: height)
                .background(UnevenRoundedRectangle(topLeadingRadius: height / 2, bottomLeadingRadius: height / 2).fill(Theme.primary))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.return, modifiers: .command)
            Button { store.addAsMenu = open ? nil : item.id } label: {
                Image(systemName: "chevron.down").font(.system(size: 10, weight: .bold))
                    .frame(width: 30, height: height)
                    .background(UnevenRoundedRectangle(bottomTrailingRadius: height / 2, topTrailingRadius: height / 2).fill(Theme.primary))
            }
            .buttonStyle(.plain)
            .help("Add as… (⌥↩)")
            .keyboardShortcut(.return, modifiers: .option)
        }
        .foregroundStyle(.white)
        .fixedSize()
        .overlay(alignment: .bottomTrailing) {
            if open && store.fixtureInlineMenus { AddAsMenu(store: store, item: item).offset(y: -(height + 8)).fixedSize() }
        }
        .popover(isPresented: Binding(get: { open && !store.fixtureInlineMenus }, set: { if !$0 { store.addAsMenu = nil } }), arrowEdge: .top) {
            AddAsMenu(store: store, item: item).padding(4)
        }
    }
}

/// "ADD AS…": To-do first, then the types with a handler or a button, each with its icon and what happens.
struct AddAsMenu: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem

    var body: some View {
        ActionMenuPanel(title: "ADD AS…", width: 320) {
            ForEach(AddAs.options(store.types)) { o in
                let style = ActionsTheme.typeStyle(o.id)
                ActionMenuRow(title: o.label, detail: o.id == item.type ? AddAs.foundLine(o.id, types: store.types) : o.detail,
                              icon: style.0, iconStyle: (style.1, style.2), checked: o.id == item.type) {
                    store.addAs(item, o.id)
                }
            }
            Divider().padding(.vertical, 2)
            Text(AddAs.keysHint(item, types: store.types)).font(Theme.body(11)).foregroundStyle(Theme.faint)
                .padding(.horizontal, 10).padding(.bottom, 4)
        }
        .alignmentGuide(.bottom) { $0[.bottom] }
        .frame(alignment: .bottom)
    }
}

/// The inline "Add as Slack message" panel: the type's fields prefilled from the item. Required fields
/// left empty block Add, with the field named; for Slack, an unknown name asks who it is.
struct AddAsPanel: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    let type: ActionTypeInfo

    private var draft: AddAs.Draft { store.addingAs[item.id] ?? AddAs.prefill(item, as: type) }

    private func binding(_ key: String) -> Binding<String> {
        Binding(get: { store.addingAs[item.id]?.fields[key] ?? "" }, set: { store.addingAs[item.id]?.fields[key] = $0 })
    }

    var body: some View {
        let style = ActionsTheme.typeStyle(type.id)
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: style.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.2)
                    .frame(width: 22, height: 22).background(RoundedRectangle(cornerRadius: 7).fill(style.1))
                VStack(alignment: .leading, spacing: 1) {
                    Text("Add as \(AddAs.typeWords(type.id, types: store.types))").font(Theme.body(14, .bold))
                    Text("filled from the \(AddAs.typeWords(item.type, types: store.types))").font(Theme.body(11.5)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
            }
            row("Title") {
                TextField("Title", text: Binding(get: { store.addingAs[item.id]?.title ?? "" }, set: { store.addingAs[item.id]?.title = $0 }))
                    .textFieldStyle(.roundedBorder).font(Theme.body(13))
            }
            ForEach(type.fields.filter { $0.kind != "markdown" }, id: \.key) { spec in
                row(spec.label + (spec.required ? " *" : "")) { field(spec) }
                if type.id == "slack" && spec.key == "to" { slackWho }
            }
            VStack(alignment: .leading, spacing: 4) {
                Text(AddAs.bodyLabel(type).uppercased()).font(Theme.body(10.5, .bold)).tracking(0.6).foregroundStyle(Theme.faint)
                MarkdownEditor(text: Binding(get: { store.addingAs[item.id]?.body ?? "" }, set: { store.addingAs[item.id]?.body = $0 }),
                               placeholder: type.id == "todo" ? "A note (optional)" : "Leave empty and \(item.draftModel ?? "Sonnet") writes it",
                               textSize: 13, minLines: 3, maxLines: 8, textBox: true)
            }
            Text("Keeps its source note, line and Why.").font(Theme.body(11)).foregroundStyle(Theme.muted)
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Color.white))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(ActionsTheme.selectedStroke, lineWidth: 1.5))
    }

    private func row<C: View>(_ label: String, @ViewBuilder _ content: () -> C) -> some View {
        HStack(spacing: 10) {
            Text(label).font(Theme.body(12.5)).foregroundStyle(Theme.muted).frame(width: 64, alignment: .leading)
            content()
        }
    }

    @ViewBuilder private func field(_ spec: ActionFieldSpec) -> some View {
        if spec.kind == "choice" && !spec.choices.isEmpty {
            Picker("", selection: binding(spec.key)) {
                Text("—").tag("")
                ForEach(spec.choices, id: \.self) { Text($0).tag($0) }
            }
            .labelsHidden().frame(maxWidth: 200, alignment: .leading)
            Spacer(minLength: 0)
        } else {
            TextField(placeholder(spec), text: binding(spec.key)).textFieldStyle(.roundedBorder).font(Theme.body(13))
        }
    }

    private func placeholder(_ spec: ActionFieldSpec) -> String {
        switch (type.id, spec.key) {
        case ("slack", "to"): return "A name, @handle or #channel"
        case ("slack", "thread"): return "A Slack message link (optional)"
        default: return spec.kind == "date" ? "YYYY-MM-DD" : (spec.required ? "Required" : "Optional")
        }
    }

    /// The To row's "Who is X in Slack?" (action-buttons.md, Where to send), right in the panel.
    @ViewBuilder private var slackWho: some View {
        let t = SlackTarget.resolve(to: draft.fields["to"], thread: draft.fields["thread"],
                                    lookup: SlackToText.lookup(store.slackPeople, vault: store.slackVault(item)))
        if let ask = t.ask, store.slackSendsToField(type) {
            SlackWhoIsRow(question: ask, name: t.written, pattern: store.slackTargetPattern(type)) { value in
                store.rememberSlack(item, name: t.written, target: value)
            }
        } else if let name = t.name, let target = t.target {
            Text("\(name) is \(target) in Slack.").font(Theme.body(11.5)).foregroundStyle(Theme.muted).padding(.leading, 74)
        }
    }
}

/// The detail footer while the panel is open: why Add is off, Cancel, and "Add as Slack message".
struct AddAsPanelFooter: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    let type: ActionTypeInfo
    var onDone: (() -> Void)? = nil

    private var reason: String? { store.addingAs[item.id].flatMap { store.addAsBlock(item, $0, type) } }

    var body: some View {
        // Cancel · why Add is off · Add as Slack message (disabled); a narrow pane puts the reason on its own line.
        ViewThatFits(in: .horizontal) {
            HStack(spacing: 10) {
                Spacer(minLength: 0)
                cancel
                if let reason { reasonText(reason).fixedSize() }
                add
            }
            VStack(alignment: .trailing, spacing: 6) {
                if let reason { reasonText(reason).frame(maxWidth: .infinity, alignment: .trailing) }
                HStack(spacing: 10) { Spacer(minLength: 0); cancel; add }
            }
        }
    }

    private func reasonText(_ text: String) -> some View {
        Text(text).font(Theme.body(12)).foregroundStyle(Theme.peachInk)
    }

    private var cancel: some View {
        ActionButton(title: "Cancel", kind: .plain, height: 32) { store.addingAs[item.id] = nil }
            .keyboardShortcut(.cancelAction)
    }

    private var add: some View {
        ActionButton(title: "Add as \(AddAs.typeWords(type.id, types: store.types))", icon: "plus", kind: .primary, height: 32) {
            store.finishAddAs(item, onDone: onDone)
        }
        .disabled(reason != nil).opacity(reason == nil ? 1 : 0.45)
        .help(reason ?? "")
        .keyboardShortcut(.return, modifiers: .command)
    }
}

extension AddAs {
    /// A Return key press as Add as reads it (the list and the To-confirm detail share it).
    static func addAsKey(_ press: KeyPress) -> Key? {
        let m = press.modifiers
        return key(option: m.contains(.option), command: m.contains(.command), other: m.contains(.shift) || m.contains(.control))
    }
}

/// The To-confirm detail: plain Return adds as the found type, ⌥Return opens Add as… (actions.md), as in the
/// list. A focused text field keeps its own Return; with the Add as panel open, its own footer decides.
struct AddAsDetailKeys: ViewModifier {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var onDone: (() -> Void)?

    func body(content: Content) -> some View {
        content
            .focusable()
            .focusEffectDisabled()
            .onKeyPress(keys: [.return]) { press in
                guard store.addingAs[item.id] == nil else { return .ignored }
                switch AddAs.addAsKey(press) {
                case nil: return .ignored
                case .add?:
                    store.confirm([item.id])
                    onDone?()
                case .openMenu?: store.addAsMenu = item.id
                }
                return .handled
            }
    }
}
