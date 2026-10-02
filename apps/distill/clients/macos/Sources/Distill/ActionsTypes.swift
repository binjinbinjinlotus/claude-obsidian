import AppKit
import SwiftUI
import DistillKit

// The type lists (canvas: ActionsSlack, ActionsJira, ActionsConfluence). A type
// with a Copy handler renders as message cards; one with Create as drafts on the
// left and the open card on the right. Unknown types use the same two layouts,
// labelled from ActionTypeInfo.

/// An edit in progress (title, Markdown body, fields), kept in the store so it survives redraws.
struct ActionEditDraft: Equatable {
    var title: String
    var body: String
    var fields: [String: String]
}

extension ActionsStore {
    func beginEdit(_ item: ActionItem) {
        editing[item.id] = ActionEditDraft(title: item.title, body: item.body ?? "", fields: item.fields)
    }

    /// Done: saves the edit, then (for types that improve) runs the improve pass.
    func finishEdit(_ item: ActionItem) {
        guard let draft = editing[item.id] else { return }
        editing[item.id] = nil
        var changed: [String: String?] = [:]
        for (k, v) in draft.fields where item.fields[k] != v { changed[k] = v.isEmpty ? nil : v }
        let bodyChanged = draft.body != (item.body ?? "")
        let patch = ActionPatch(title: draft.title == item.title ? nil : draft.title, body: bodyChanged ? .some(draft.body) : nil,
                                fields: changed.isEmpty ? nil : changed)
        guard !patch.isEmpty, let client = engine?.client else { return }
        let improves = bodyChanged && (type(item.type)?.improveAfterEdit ?? false)
        if var local = items[item.id] { local.title = draft.title; local.body = draft.body; items[item.id] = local }
        if improves { running[item.id] = .improving(Date()) }
        Task {
            do {
                let saved = try await client.updateAction(item.id, patch)
                items[saved.id] = saved
                if improves { improve(saved) }
            } catch {
                running[item.id] = nil
                engine?.report(error)
            }
        }
    }
}

// MARK: - Message types (Slack)

struct MessageTypeScreen: View {
    @ObservedObject var store: ActionsStore
    let type: ActionTypeInfo
    @State private var query = ""

    var body: some View {
        let list = store.items(type: type.id)
            .filter { [.open, .drafting, .ready].contains($0.status) && ActionSearch.match($0, query) != nil }
            .sorted { $0.createdAt > $1.createdAt }
        let pending = store.pending.filter { $0.type == type.id }
        VStack(alignment: .leading, spacing: 0) {
            ActionsHeader(eyebrow: "ACTIONS", title: type.pluralLabel, subtitle: store.lastFound(type: type.id)) {
                ActionButton(title: "History", icon: "clock", height: 34) { store.historyRequest += 1 }
            }
            HStack(spacing: 6) {
                ActionSearchField(text: $query, placeholder: "Search \(type.pluralLabel.lowercased())", width: 200)
                StatusBadge(text: "Status: Open", fill: Theme.primaryTint, ink: Theme.primary)
                Spacer()
                Text("Newest first").font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 10)
            Scrolling {
                VStack(alignment: .leading, spacing: 14) {
                    if store.phase != .loaded {
                        ActionShimmerRows(count: 3)
                    } else if list.isEmpty && pending.isEmpty {
                        ActionsEmpty(icon: ActionsTheme.typeStyle(type.id).0, title: query.isEmpty ? "No \(type.pluralLabel.lowercased()) to send" : "No \(type.pluralLabel.lowercased()) match",
                                     message: "When a note or an answer says someone should hear something, Distill writes it here. Sent and removed ones are in History.") {
                            ActionButton(title: "History", icon: "clock") { store.historyRequest += 1 }
                        }
                        .padding(.top, 60)
                    } else {
                        if !pending.isEmpty { ToConfirmGroup(store: store, items: pending) }
                        ForEach(list) { item in
                            MessageCard(store: store, type: type, item: item).frame(maxWidth: 876, alignment: .leading)
                        }
                    }
                }
                .padding(.horizontal, 32).padding(.bottom, 80).padding(.top, 4)
            }
        }
    }
}

struct MessageCard: View {
    @ObservedObject var store: ActionsStore
    let type: ActionTypeInfo
    let item: ActionItem
    @State private var menu: String?
    @State private var someone = ""

    init(store: ActionsStore, type: ActionTypeInfo, item: ActionItem, menu: String? = nil) {
        self.store = store
        self.type = type
        self.item = item
        _menu = State(initialValue: menu)
    }

    private var run: ActionRun? { store.running[item.id] }
    private var draft: ActionEditDraft? { store.editing[item.id] }
    private var model: String { item.draftModel ?? "Sonnet" }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            content
            if draft == nil { ActionContextBlock(item: item) }
            footer
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white)
            .shadow(color: .black.opacity(0.10), radius: 12, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.06)))
        .zIndex(menu == nil ? 0 : 10)
    }

    // MARK: Header

    private var header: some View {
        let style = ActionsTheme.typeStyle(type.id)
        return HStack(spacing: 10) {
            Image(systemName: style.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(style.2)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9).fill(style.1))
            VStack(alignment: .leading, spacing: 1) {
                Text(type.label.uppercased()).font(Theme.body(11, .heavy)).kerning(0.5).foregroundStyle(style.2)
                recipient
            }
            Spacer(minLength: 6)
            status
            Menu {
                if item.status == .ready { Button("Mark as sent") { store.markSent(item) } }
                Button("Edit") { store.beginEdit(item) }
                Button("Remove") { store.remove(item) }
                Divider()
                Button("Settings for \(type.pluralLabel)") { store.openSettings("actions/\(type.id)") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    private var recipient: some View {
        let to = item.field("to") ?? ""
        return Button { menu = menu == "to" ? nil : "to" } label: {
            HStack(spacing: 6) {
                Text("To")
                if to.isEmpty {
                    Text("Choose who gets it").foregroundStyle(Theme.primary)
                } else if to.hasPrefix("#") {
                    Image(systemName: "number").font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.muted)
                    Text(String(to.dropFirst())).fontWeight(.bold)
                    Text("· channel").fontWeight(.regular).foregroundStyle(Theme.faint)
                } else {
                    let names = to.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                    PersonChip(name: names[0], size: 18, showName: false)
                    Text(to).fontWeight(.bold).lineLimit(1)
                    Text(names.count > 1 ? "· group message" : "· direct message").fontWeight(.regular).foregroundStyle(Theme.faint)
                }
            }
            .font(Theme.body(13, .semibold))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Click to change who gets it")
        .overlay(alignment: .topLeading) {
            if menu == "to" { recipientPanel.offset(y: 24) }
        }
    }

    private var recipientPanel: some View {
        let to = item.field("to") ?? ""
        var options: [(String, String)] = []
        if !to.isEmpty { options.append((to, to.hasPrefix("#") ? "Channel · from the note" : "Direct message · from the note")) }
        let people = ActionList.people(item).filter { $0 != to && !$0.hasPrefix("You") }
        if !to.isEmpty, !to.hasPrefix("#"), let other = people.first { options.append(("\(to), \(other)", "Group message")) }
        for label in item.labels where "#\(label)" != to { options.append(("#\(label)", "Channel")) }
        return ActionMenuPanel(title: "SEND TO", width: 300) {
            ForEach(options, id: \.0) { name, detail in
                ActionMenuRow(title: name, detail: detail, icon: name.hasPrefix("#") ? "number" : "person", checked: name == to) {
                    store.update(item.id, ActionPatch(fields: ["to": name])); menu = nil
                }
            }
            HStack(spacing: 8) {
                Image(systemName: "plus").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 16)
                TextField("Someone else… (a name or #channel)", text: $someone).textFieldStyle(.plain).font(Theme.body(13))
                    .onSubmit {
                        let v = someone.trimmingCharacters(in: .whitespaces)
                        if !v.isEmpty { store.update(item.id, ActionPatch(fields: ["to": v])) }
                        someone = ""; menu = nil
                    }
            }
            .padding(.horizontal, 10).padding(.vertical, 8)
            Text("Distill doesn't look anything up in Slack yet, so names are typed freely.")
                .font(Theme.body(11)).foregroundStyle(Theme.muted).padding(.horizontal, 10).padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var status: some View {
        if draft != nil {
            StatusBadge(text: "Editing", fill: Theme.primaryTint, ink: Theme.primary)
        } else if case .drafting? = run {
            StatusBadge(text: "Writing", fill: Theme.primaryTint, ink: Theme.primary, busy: true)
        } else if item.status == .drafting {
            StatusBadge(text: "Writing", fill: Theme.primaryTint, ink: Theme.primary, busy: true)
        } else if case .improving? = run {
            StatusBadge(text: "Polishing", fill: Theme.primaryTint, ink: Theme.primary, busy: true)
        } else if let copied = store.copiedAt[item.id] {
            StatusBadge(text: "Copied at \(ActionsClock.time(copied))", fill: ActionsTheme.doneFill, ink: Theme.limeInk)
        } else if item.status == .ready {
            StatusBadge(text: type.handler("send")?.available == true ? "Ready to send" : "Ready to paste", fill: ActionsTheme.doneFill, ink: Theme.limeInk)
        } else {
            StatusBadge(text: "Not written", fill: Theme.panel, ink: Theme.muted)
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let draft {
            VStack(alignment: .leading, spacing: 8) {
                MarkdownEditor(text: Binding(get: { draft.body }, set: { store.editing[item.id]?.body = $0 }),
                               placeholder: "Write the message", textSize: 13, minLines: 3, bar: .compact, submit: .commandReturn,
                               onSubmit: { store.finishEdit(item) }, autoFocus: true, textBox: true)
                Text(type.improveAfterEdit ? "When you click Done (or ⌘↩), \(model) fixes grammar and spelling." : "Done saves your text.")
                    .font(Theme.body(11)).foregroundStyle(Theme.muted)
            }
        } else if case .drafting? = run {
            writingBox("Writing with \(model)…")
        } else if item.status == .drafting {
            writingBox("Writing with \(model)…")
        } else if case .improving? = run {
            VStack(alignment: .leading, spacing: 8) {
                ActionBodyText(markdown: item.body ?? "").opacity(0.45)
                    .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    .overlay(Shimmer(height: 4, radius: 2).padding(.horizontal, 14), alignment: .bottom)
                ActionRunLine(title: "Polishing with \(model)…") { store.cancelRun(item.id) }
            }
        } else if item.status == .open && (item.body ?? "").isEmpty {
            Text("Distill found a message to send but hasn't written it. \(type.pluralLabel) are set to be written only when you ask.")
                .font(Theme.body(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
        } else {
            VStack(alignment: .leading, spacing: 10) {
                ActionBodyText(markdown: item.body ?? "",
                               tinted: store.justImproved.contains(item.id) ? Set(ActionText.addedWords(from: item.previousBody ?? "", to: item.body ?? "")) : [])
                    .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                    .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                ImprovedLine(store: store, item: item, summary: "fixed grammar and punctuation")
                if let error = item.error, error.code == "ai_failed" {
                    ActionCallout(title: "Couldn't write it: \(error.message)", text: "Your text is unchanged.") {
                        ActionButton(title: "Try again", kind: .soft, height: 28) { store.draft(item) }
                    }
                }
                if store.copiedAt[item.id] != nil && item.status == .ready {
                    ActionCallout(icon: "doc.on.clipboard.fill", tint: Theme.limeInk, fill: ActionsTheme.doneFill,
                                  title: "Copied. Paste it in Slack.", text: "Once it's posted, mark it as sent so it leaves this list.") {
                        ActionButton(title: "Mark as sent", icon: "checkmark", kind: .done, height: 28) { store.markSent(item) }
                        Button("Not yet") { store.copiedAt[item.id] = nil }.buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.muted)
                    }
                }
            }
        }
    }

    private func writingBox(_ title: String) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            VStack(alignment: .leading, spacing: 8) {
                Shimmer(width: 420, height: 10)
                Shimmer(width: 360, height: 10)
                Shimmer(width: 220, height: 10)
            }
            ActionRunLine(title: title) { store.cancelRun(item.id) }
        }
        .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if draft != nil {
                Spacer()
                ActionButton(title: "Cancel", kind: .plain) { store.editing[item.id] = nil }
                ActionButton(title: "Done", kind: .primary) { store.finishEdit(item) }
                    .keyboardShortcut(.return, modifiers: .command)
            } else if item.status == .open && (item.body ?? "").isEmpty && run == nil {
                ActionButton(title: "Create message", kind: .primary, height: 30) { store.draft(item) }
                Text("\(model) writes it from the note").font(Theme.body(11)).foregroundStyle(Theme.muted)
                Spacer()
                IconButton(icon: "trash", help: "Remove") { store.remove(item) }
            } else {
                let busy = run != nil || item.status == .drafting
                if type.handler("copy") != nil {
                    ActionButton(title: store.copiedFlash.contains(item.id) ? "Copied" : "Copy",
                                 icon: store.copiedFlash.contains(item.id) ? "checkmark" : "doc.on.doc",
                                 kind: store.copiedFlash.contains(item.id) ? .done : .primary) { store.copy(item) }
                        .disabled(busy || (item.body ?? "").isEmpty).opacity(busy ? 0.45 : 1)
                }
                if let send = type.handler("send") {
                    if send.available {
                        ActionButton(title: send.label, icon: "paperplane", kind: .soft) { store.perform(item, handler: "send") }
                    } else {
                        LaterSlot(title: send.label == "send" ? "Send in Slack" : send.label)
                    }
                }
                Spacer()
                if !busy {
                    IconButton(icon: "pencil", help: "Edit") { store.beginEdit(item) }
                    IconButton(icon: "trash", help: "Remove") { store.remove(item) }
                }
            }
        }
        .padding(.top, 4)
    }
}

/// "Improved by Sonnet at 3:51 PM: … · Undo ⌘Z · Show changes".
struct ImprovedLine: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var summary: String

    var body: some View {
        if let previous = item.previousBody, previous != item.body {
            let at = item.lastEvent("improved")?.at ?? item.updatedAt
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 8) {
                    Image(systemName: "sparkles").font(.system(size: 10)).foregroundStyle(Theme.primary)
                    Text("Improved by \(item.draftModel ?? "Sonnet") at \(ActionsClock.time(at)): \(item.lastEvent("improved")?.detail ?? summary)")
                        .lineLimit(1)
                    Spacer(minLength: 6)
                    Button { store.undoImprove(item) } label: {
                        HStack(spacing: 4) { Image(systemName: "arrow.uturn.backward").font(.system(size: 9, weight: .bold)); Text("Undo ⌘Z") }
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.primary).fontWeight(.bold)
                    .keyboardShortcut("z", modifiers: .command)
                    Button(store.showingChanges.contains(item.id) ? "Hide changes" : "Show changes") {
                        if store.showingChanges.contains(item.id) { store.showingChanges.remove(item.id) } else { store.showingChanges.insert(item.id) }
                    }
                    .buttonStyle(.plain).foregroundStyle(Theme.primary).fontWeight(.bold)
                }
                .font(Theme.body(11)).foregroundStyle(Theme.muted)
                if store.showingChanges.contains(item.id) {
                    ForEach(Array(ActionText.changes(from: previous, to: item.body ?? "").enumerated()), id: \.offset) { _, change in
                        VStack(alignment: .leading, spacing: 3) {
                            if !change.removed.isEmpty { Text("− \(change.removed)").foregroundStyle(Theme.peachInk).strikethrough() }
                            if !change.added.isEmpty { Text("+ \(change.added)").foregroundStyle(Theme.limeInk) }
                        }
                        .font(Theme.body(12))
                        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
                        .background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                    }
                }
            }
        }
    }
}

/// Draft text as on the boards: headings, bullets, checkboxes, @mentions in blue,
/// inline Markdown; `tinted` word indexes (after an improve) get a green tint.
struct ActionBodyText: View {
    let markdown: String
    var size: CGFloat = 13
    var tinted: Set<Int> = []

    var body: some View {
        let lines = markdown.components(separatedBy: "\n")
        var wordIndex = 0
        return VStack(alignment: .leading, spacing: 4) {
            ForEach(Array(lines.enumerated()), id: \.offset) { _, raw in
                let line = raw.trimmingCharacters(in: .whitespaces)
                let start = wordIndex
                let _ = (wordIndex += line.split(separator: " ").count)
                if line.isEmpty {
                    Color.clear.frame(height: 2)
                } else if line.hasPrefix("#") {
                    Text(line.drop { $0 == "#" }.trimmingCharacters(in: .whitespaces))
                        .font(.system(size: size + 1, weight: .semibold, design: .rounded)).padding(.top, 4)
                } else if line.hasPrefix("- [ ] ") || line.hasPrefix("- [x] ") {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Image(systemName: line.hasPrefix("- [x]") ? "checkmark.square" : "square").font(.system(size: size - 2)).foregroundStyle(ActionsTheme.ring)
                        inline(String(line.dropFirst(6)), start: start + 3)
                    }
                } else if line.hasPrefix("- ") || line.hasPrefix("* ") || line.hasPrefix("• ") {
                    HStack(alignment: .firstTextBaseline, spacing: 7) {
                        Text("•").foregroundStyle(Theme.faint)
                        inline(String(line.dropFirst(2)), start: start + 1)
                    }
                } else {
                    inline(line, start: start)
                }
            }
        }
        .font(Theme.body(size))
        .foregroundStyle(Theme.bodyInk)
        .lineSpacing(3)
        .textSelection(.enabled)
        .fixedSize(horizontal: false, vertical: true)
    }

    /// One line: inline Markdown on the whole line (so **bold** can span words),
    /// @mentions in blue, and the tinted words of an improve.
    private func inline(_ text: String, start: Int) -> Text {
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        var a = (try? AttributedString(markdown: text, options: options)) ?? AttributedString(text)
        let plain = String(a.characters)
        var offset = 0
        for (i, word) in plain.split(separator: " ", omittingEmptySubsequences: false).enumerated() {
            let w = String(word)
            if !w.isEmpty {
                let lower = a.characters.index(a.startIndex, offsetBy: offset)
                let upper = a.characters.index(lower, offsetBy: w.count)
                if w.hasPrefix("@") {
                    a[lower..<upper].foregroundColor = Theme.primary
                    a[lower..<upper].inlinePresentationIntent = .stronglyEmphasized
                }
                if tinted.contains(start + i) {
                    a[lower..<upper].backgroundColor = ActionsTheme.changedFill
                    a[lower..<upper].foregroundColor = Theme.limeInk
                }
            }
            offset += w.count + 1
        }
        return Text(a)
    }
}

// MARK: - External types (Jira, Confluence)

struct ExternalTypeScreen: View {
    @ObservedObject var store: ActionsStore
    let type: ActionTypeInfo
    @State private var query = ""

    private var service: String { store.typeName(type.id) }

    var body: some View {
        let all = store.items(type: type.id).filter { ActionSearch.match($0, query) != nil }
        let drafts = all.filter { [.open, .drafting, .ready, .creating].contains($0.status) }.sorted { $0.createdAt > $1.createdAt }
        let created = all.filter { $0.status == .created }.sorted { $0.updatedAt > $1.updatedAt }
        let pending = store.pending.filter { $0.type == type.id }
        let selectedID = store.selected[type.id]
        let selected = (drafts + created).first { $0.id == selectedID } ?? drafts.first ?? created.first
        VStack(alignment: .leading, spacing: 0) {
            ActionsHeader(eyebrow: "ACTIONS", title: type.pluralLabel, subtitle: store.lastFound(type: type.id)) {
                ActionButton(title: "History", icon: "clock", height: 34) { store.historyRequest += 1 }
            }
            HStack(spacing: 6) {
                ActionSearchField(text: $query, placeholder: "Search \(type.pluralLabel.lowercased())", width: 180)
                StatusBadge(text: "Status: Drafts, Created", fill: Theme.primaryTint, ink: Theme.primary)
                Spacer()
                connectionLine
            }
            .padding(.horizontal, 32).padding(.top, 14).padding(.bottom, 8)
            if store.phase != .loaded {
                ActionShimmerRows(count: 3).padding(.horizontal, 20)
                Spacer()
            } else if drafts.isEmpty && created.isEmpty && pending.isEmpty {
                ActionsEmpty(icon: ActionsTheme.typeStyle(type.id).0, title: "No \(type.pluralLabel.lowercased()) yet",
                             message: "When a note asks for one, Distill drafts it here. Nothing is created in \(service) until you press Create.") {
                    ActionButton(title: "History", icon: "clock") { store.historyRequest += 1 }
                }
            } else {
                HStack(alignment: .top, spacing: 18) {
                    Scrolling {
                        VStack(alignment: .leading, spacing: 1) {
                            if !pending.isEmpty { ToConfirmGroup(store: store, items: pending) }
                            if !drafts.isEmpty {
                                ActionGroupHeader(title: "DRAFTS", count: drafts.count, icon: "pencil.line")
                                ForEach(drafts) { row($0, selected: $0.id == selected?.id) }
                            }
                            if !created.isEmpty {
                                ActionGroupHeader(title: "CREATED IN \(service.uppercased())", count: created.count, icon: "checkmark.seal")
                                ForEach(created) { row($0, selected: $0.id == selected?.id) }
                            }
                        }
                        .padding(.bottom, 60)
                    }
                    .frame(width: 330)
                    Scrolling {
                        if let selected {
                            ExternalCard(store: store, type: type, item: selected)
                                .frame(maxWidth: 560, alignment: .leading)
                                .padding(2).padding(.bottom, 60)
                        }
                    }
                }
                .padding(.leading, 20).padding(.trailing, 24)
            }
        }
    }

    /// "acme.atlassian.net · connected" from the Create handler (the connection's site arrives with Settings → Connections).
    private var connectionLine: some View {
        let create = type.handler("create")
        let connected = create?.available ?? false
        return HStack(spacing: 5) {
            Image(systemName: connected ? "checkmark.circle.fill" : "xmark.circle").font(.system(size: 11))
                .foregroundStyle(connected ? Theme.limeInk : Theme.peachInk)
            Text(type.connectionID == "atlassian" ? "Atlassian" : service)
            Text(connected ? "· connected" : "· not connected").foregroundStyle(connected ? Theme.muted : Theme.peachInk)
        }
        .font(Theme.body(12)).foregroundStyle(Theme.muted)
        .help(create?.reason ?? "")
    }

    private func row(_ item: ActionItem, selected: Bool) -> some View {
        let style = ActionsTheme.typeStyle(type.id)
        return Button { store.selected[type.id] = item.id } label: {
            HStack(spacing: 10) {
                Image(systemName: style.0).font(.system(size: 11, weight: .semibold)).foregroundStyle(style.2)
                    .frame(width: 28, height: 28).background(RoundedRectangle(cornerRadius: 8).fill(style.1))
                VStack(alignment: .leading, spacing: 3) {
                    Text(item.title).font(Theme.body(13, .semibold)).lineLimit(2).multilineTextAlignment(.leading)
                    Text(meta(item)).font(Theme.body(11)).foregroundStyle(Theme.muted).lineLimit(1)
                }
                Spacer(minLength: 4)
                ExternalStatusBadge(store: store, item: item, compact: true)
            }
            .padding(.horizontal, 12).padding(.vertical, 10)
            .background(RoundedRectangle(cornerRadius: 12).fill(selected ? ActionsTheme.selectedFill : .clear))
            .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(selected ? ActionsTheme.selectedStroke : .clear, lineWidth: 1.5))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func meta(_ item: ActionItem) -> String {
        if item.status == .created, let key = item.external?.key {
            return "\(key) · created \(HistoryTime.phrase(item.lastEvent("created")?.at ?? item.updatedAt))"
        }
        let from = ActionList.noteTitle(item).map { "From \($0)" } ?? "Added by you"
        let written = item.status == .open && (item.body ?? "").isEmpty ? "not written yet" : "created \(HistoryTime.phrase(item.createdAt))"
        return "\(from) · \(written)"
    }
}

struct ExternalStatusBadge: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var compact = false

    var body: some View {
        let run = store.running[item.id]
        if store.editing[item.id] != nil {
            StatusBadge(text: "Editing", fill: Theme.primaryTint, ink: Theme.primary)
        } else if case .drafting? = run {
            StatusBadge(text: "Writing", fill: Theme.primaryTint, ink: Theme.primary, busy: true)
        } else if item.status == .drafting {
            StatusBadge(text: "Writing", fill: Theme.primaryTint, ink: Theme.primary, busy: true)
        } else if case .improving? = run {
            StatusBadge(text: "Improving", fill: Theme.primaryTint, ink: Theme.primary, busy: true)
        } else if case .creating? = run {
            StatusBadge(text: "Creating", fill: Theme.primaryTint, ink: Theme.primary, busy: true)
        } else if item.status == .creating {
            StatusBadge(text: "Creating", fill: Theme.primaryTint, ink: Theme.primary, busy: true)
        } else if item.status == .created {
            if compact {
                StatusBadge(text: item.external?.status ?? "Created", fill: Theme.skyTint, ink: Theme.skyInk)
            } else {
                StatusBadge(text: "Created", fill: Theme.skyTint, ink: Theme.skyInk)
            }
        } else if item.error != nil && item.error?.code != "ai_failed" {
            StatusBadge(text: "Not created", fill: Theme.peachTint, ink: Theme.peachInk)
        } else if item.status == .open && (item.body ?? "").isEmpty {
            StatusBadge(text: "Not written", fill: Theme.panel, ink: Theme.muted)
        } else {
            StatusBadge(text: "Draft", fill: Theme.panel, ink: Theme.softInk)
        }
    }
}

struct ExternalCard: View {
    @ObservedObject var store: ActionsStore
    let type: ActionTypeInfo
    let item: ActionItem

    private var run: ActionRun? { store.running[item.id] }
    private var draft: ActionEditDraft? { store.editing[item.id] }
    private var model: String { item.draftModel ?? "Sonnet" }
    private var service: String { store.typeName(type.id) }
    /// "tickets" / "pages": the plural without the service name.
    private var things: String {
        let words = type.pluralLabel.split(separator: " ")
        return (words.count > 1 ? words.dropFirst().joined(separator: " ") : type.pluralLabel).lowercased()
    }
    private var notWritten: Bool { item.status == .open && (item.body ?? "").isEmpty }
    private var creating: Bool { item.status == .creating || { if case .creating? = run { return true }; return false }() }
    private var writing: Bool { item.status == .drafting || { if case .drafting? = run { return true }; return false }() }
    private var improving: Bool { if case .improving? = run { return true }; return false }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            if let error = item.error, draft == nil, !creating { errorCallout(error) }
            content
            if draft == nil && !(item.error?.needsSignIn ?? false) { ActionContextBlock(item: item) }
            footer
        }
        .padding(.horizontal, 18).padding(.vertical, 16)
        .background(RoundedRectangle(cornerRadius: 16).fill(Color.white).shadow(color: .black.opacity(0.10), radius: 12, y: 8))
        .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color.black.opacity(0.06)))
    }

    private var header: some View {
        let style = ActionsTheme.typeStyle(type.id)
        return HStack(spacing: 10) {
            Image(systemName: style.0).font(.system(size: 13, weight: .semibold)).foregroundStyle(style.2)
                .frame(width: 30, height: 30).background(RoundedRectangle(cornerRadius: 9).fill(style.1))
            VStack(alignment: .leading, spacing: 1) {
                Text(type.label.uppercased()).font(Theme.body(11, .heavy)).kerning(0.5).foregroundStyle(style.2)
                Text(where_).font(Theme.body(13, .semibold)).lineLimit(1)
            }
            Spacer(minLength: 6)
            ExternalStatusBadge(store: store, item: item)
            Menu {
                Button("Edit") { store.beginEdit(item) }.disabled(item.status == .created)
                Button("Remove") { store.remove(item) }
                Divider()
                Button("Settings for \(type.pluralLabel)") { store.openSettings("actions/\(type.id)") }
            } label: {
                Image(systemName: "ellipsis").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.muted).frame(width: 26, height: 26)
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
        }
    }

    /// "PX · Project X · Task" / "Project X › Incident reviews".
    private var where_: String {
        if type.id == "confluence" || item.field("space") != nil {
            return [item.field("space"), item.field("parent")].compactMap { $0 }.joined(separator: " › ")
        }
        return [item.field("project"), item.field("issueType")].compactMap { $0 }.joined(separator: " · ")
    }

    // MARK: Errors

    @ViewBuilder private func errorCallout(_ error: ActionError) -> some View {
        let site = type.connectionID == "atlassian" ? "your Atlassian site" : service
        let connectedNow = type.handler("create")?.available ?? false
        if error.needsSignIn && connectedNow {
            ActionCallout(icon: "checkmark.circle.fill", tint: Theme.limeInk, fill: ActionsTheme.doneFill, title: "Signed in to \(service)",
                          text: "\(site.prefix(1).uppercased() + site.dropFirst()) is connected. Your draft hasn't been sent yet.") {
                ActionButton(title: "Retry: Create in \(service)", icon: "arrow.clockwise", kind: .primary, height: 28) { store.perform(item, handler: "create") }
            }
        } else {
            switch error.code {
            case "not_connected":
                ActionCallout(icon: "link", tint: Theme.peachInk, title: "\(service) isn't connected",
                              text: "Your draft is safe here. Sign in once and Distill can create \(things) on \(site).") {
                    ActionButton(title: "Sign in to \(service) in your browser", icon: "safari", kind: .primary, height: 28) { store.openSettings("connections") }
                    ActionButton(title: "Settings", kind: .plain, height: 28) { store.openSettings("connections") }
                }
            case "auth_expired":
                ActionCallout(icon: "clock.badge.exclamationmark", tint: Theme.peachInk, title: "Your \(service) sign-in expired",
                              text: "\(error.message.isEmpty ? "" : error.message + " ")Your draft is safe. Sign in again, then retry.") {
                    ActionButton(title: "Sign in again in your browser", icon: "safari", kind: .primary, height: 28) { store.openSettings("connections") }
                    ActionButton(title: "Retry", icon: "arrow.clockwise", kind: .soft, height: 28) { store.perform(item, handler: "create") }
                }
            case "refused":
                ActionCallout(title: "\(service) didn't create it: \(error.message)",
                              text: "Nothing was created and your draft is unchanged. Fix the marked field, then retry.") {
                    ActionButton(title: "Retry", icon: "arrow.clockwise", kind: .soft, height: 28) { store.perform(item, handler: "create") }
                }
            case "unreachable":
                ActionCallout(icon: "wifi.slash", title: "Couldn't reach \(site)", text: "You might be offline. Nothing was created; the draft is safe.") {
                    ActionButton(title: "Retry", icon: "arrow.clockwise", kind: .soft, height: 28) { store.perform(item, handler: "create") }
                }
            case "ai_failed":
                ActionCallout(title: "Couldn't write the draft: \(error.message)", text: "Nothing changed.") {
                    ActionButton(title: "Try again", kind: .soft, height: 28) { store.draft(item) }
                }
            default:
                ActionCallout(title: error.message.isEmpty ? "Something went wrong" : error.message, text: "Your draft is safe.") {
                    ActionButton(title: "Retry", icon: "arrow.clockwise", kind: .soft, height: 28) { store.perform(item, handler: "create") }
                }
            }
        }
    }

    // MARK: Content

    @ViewBuilder private var content: some View {
        if let draft {
            editor(draft)
        } else {
            VStack(alignment: .leading, spacing: 10) {
                HStack(alignment: .firstTextBaseline, spacing: 8) {
                    Text(item.title).font(.system(size: 16, weight: .semibold, design: .rounded)).fixedSize(horizontal: false, vertical: true)
                    if item.status == .created, let key = item.external?.key {
                        Spacer(minLength: 4)
                        Button { open(item.external?.url) } label: {
                            HStack(spacing: 3) { Text(key); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)) }
                        }
                        .buttonStyle(.plain).font(Theme.body(13, .bold)).foregroundStyle(Theme.primary)
                    }
                }
                if item.status == .created {
                    createdBlock
                } else if notWritten && !writing {
                    Text("Distill found \(ActionCounts.noun(type.id, count: 1, types: store.types).lowercased().hasPrefix("a") ? "an" : "a") \(type.label.lowercased()) to create but hasn't written the draft. Write draft fills in the fields and description from the note; nothing is sent to \(service).")
                        .font(Theme.body(13)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                } else if writing {
                    VStack(alignment: .leading, spacing: 8) {
                        Shimmer(width: 300, height: 10); Shimmer(width: 360, height: 10); Shimmer(width: 200, height: 10)
                    }
                    ActionRunLine(title: "Writing the draft with \(model)…") { store.cancelRun(item.id) }
                } else {
                    fieldsBlock
                    if !(item.error?.needsSignIn ?? false) {
                        ActionBodyText(markdown: item.body ?? "", size: 12,
                                       tinted: store.justImproved.contains(item.id) ? ActionText.addedWords(from: item.previousBody ?? "", to: item.body ?? "") : [])
                            .opacity(improving ? 0.45 : 1)
                            .padding(.horizontal, 14).padding(.vertical, 12).frame(maxWidth: .infinity, alignment: .leading)
                            .background(RoundedRectangle(cornerRadius: 12).fill(Theme.panel))
                    }
                    if improving {
                        ActionRunLine(title: "Improving with \(model)…") { store.cancelRun(item.id) }
                    } else {
                        ImprovedLine(store: store, item: item, summary: "clearer sentences")
                    }
                }
            }
        }
    }

    private var createdBlock: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                StatusBadge(text: item.external?.status ?? "Created", fill: Theme.skyTint, ink: Theme.skyInk)
            }
            HStack(spacing: 4) {
                if case .refreshing? = run { Spinner(size: 10) } else { Image(systemName: "arrow.triangle.2.circlepath").font(.system(size: 10)) }
                Text("Status from \(service) at \(ActionsClock.time(item.external?.checkedAt ?? item.updatedAt)) ·")
                Button("Refresh") { store.perform(item, handler: "refresh") }.buttonStyle(.plain).foregroundStyle(Theme.primary).fontWeight(.semibold)
                Text("· Created \(HistoryTime.phrase(item.lastEvent("created")?.at ?? item.updatedAt))")
            }
            .font(Theme.body(11)).foregroundStyle(Theme.muted)
        }
    }

    /// Type fields (Project, Type, Priority, Assignee, Labels / Space, Parent page), the refused one marked.
    private var fieldsBlock: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(shownFields, id: \.key) { spec in
                let refused = item.error?.code == "refused" && item.error?.field == spec.key
                HStack(spacing: 10) {
                    Text(spec.label).font(Theme.body(12)).foregroundStyle(refused ? Theme.peachInk : Theme.muted).frame(width: 70, alignment: .leading)
                    if let v = item.field(spec.key) {
                        Text(v).font(Theme.body(13))
                    } else {
                        Text(refused ? "Choose \(spec.label.lowercased().hasPrefix("a") ? "an" : "a") \(spec.label.lowercased())" : "—")
                            .font(Theme.body(13)).foregroundStyle(refused ? Theme.peachInk : Theme.faint)
                    }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 26)
                .padding(.horizontal, refused ? 6 : 0)
                .background(RoundedRectangle(cornerRadius: 8).strokeBorder(refused ? Theme.peachInk : .clear, lineWidth: 1.5))
                .onTapGesture { if refused { store.beginEdit(item) } }
            }
            if !item.labels.isEmpty {
                HStack(spacing: 10) {
                    Text("Labels").font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: 70, alignment: .leading)
                    Text(item.labels.joined(separator: ", ")).font(Theme.body(13))
                }
                .frame(minHeight: 26)
            }
        }
    }

    private var shownFields: [ActionFieldSpec] {
        var specs = type.fields.filter { $0.kind != "markdown" && $0.key != "title" && $0.key != "summary" }
        if let refused = item.error?.field, item.error?.code == "refused", !specs.contains(where: { $0.key == refused }) {
            specs.append(ActionFieldSpec(key: refused, label: refused.prefix(1).uppercased() + refused.dropFirst()))
        }
        return specs.filter { item.field($0.key) != nil || $0.required || item.error?.field == $0.key }
    }

    private func editor(_ draft: ActionEditDraft) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            TextField("Title", text: Binding(get: { draft.title }, set: { store.editing[item.id]?.title = $0 }), axis: .vertical)
                .textFieldStyle(.plain).font(.system(size: 16, weight: .semibold, design: .rounded))
                .padding(8).background(RoundedRectangle(cornerRadius: 10).strokeBorder(ActionsTheme.selectedStroke, lineWidth: 1.5))
            ForEach(type.fields.filter { $0.kind != "markdown" }, id: \.key) { spec in
                HStack(spacing: 10) {
                    Text(spec.label).font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: 70, alignment: .leading)
                    if spec.kind == "choice" && !spec.choices.isEmpty {
                        Menu {
                            ForEach(spec.choices, id: \.self) { c in Button(c) { store.editing[item.id]?.fields[spec.key] = c } }
                        } label: {
                            HStack(spacing: 5) {
                                Text(draft.fields[spec.key] ?? "Choose").font(Theme.body(13))
                                Image(systemName: "chevron.down").font(.system(size: 8, weight: .bold)).foregroundStyle(Theme.muted)
                            }
                            .padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                        }
                        .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    } else {
                        TextField(spec.label, text: Binding(get: { draft.fields[spec.key] ?? "" }, set: { store.editing[item.id]?.fields[spec.key] = $0 }))
                            .textFieldStyle(.plain).font(Theme.body(13))
                            .padding(.horizontal, 8).frame(height: 26).background(RoundedRectangle(cornerRadius: 8).fill(Theme.panel))
                    }
                }
            }
            MarkdownEditor(text: Binding(get: { draft.body }, set: { store.editing[item.id]?.body = $0 }),
                           placeholder: "Description", textSize: 12, minLines: 4, bar: .compact, submit: .commandReturn,
                           onSubmit: { store.finishEdit(item) }, textBox: true)
            Text(type.improveAfterEdit ? "Done runs the improve prompt with \(model). Fields you set are kept." : "Done saves your changes.")
                .font(Theme.body(11)).foregroundStyle(Theme.muted)
        }
    }

    // MARK: Footer

    @ViewBuilder private var footer: some View {
        HStack(spacing: 8) {
            if draft != nil {
                Spacer()
                ActionButton(title: "Cancel", kind: .plain) { store.editing[item.id] = nil }
                ActionButton(title: "Done", kind: .primary) { store.finishEdit(item) }
                    .keyboardShortcut(.return, modifiers: .command)
            } else if item.status == .created {
                ActionButton(title: "Open in \(service)", icon: "arrow.up.right", kind: .primary) { open(item.external?.url) }
                ActionButton(title: "Mark done", icon: "checkmark", kind: .soft) { store.markDone(item) }
                Spacer()
                IconButton(icon: "trash", help: "Remove from Distill (stays in \(service))") { store.remove(item) }
            } else if notWritten && !writing {
                ActionButton(title: "Write draft", kind: .primary, height: 30) { store.draft(item) }
                Text("with \(model)").font(Theme.body(11)).foregroundStyle(Theme.muted)
                Spacer()
                IconButton(icon: "trash", help: "Remove") { store.remove(item) }
            } else {
                if creating {
                    Spinner(size: 14)
                    Text("Creating in \(service)…").font(Theme.body(13, .semibold))
                } else {
                    let label = type.handler("create")?.label ?? "Create"
                    ActionButton(title: label.lowercased().hasPrefix("create") && label.count > 6 ? label : "Create in \(service)", icon: "plus", kind: .primary) {
                        store.perform(item, handler: "create")
                    }
                    .disabled(writing || improving).opacity(writing || improving ? 0.45 : 1)
                }
                Spacer()
                if !creating && !writing && !improving {
                    IconButton(icon: "pencil", help: "Edit") { store.beginEdit(item) }
                    IconButton(icon: "trash", help: "Remove") { store.remove(item) }
                }
            }
        }
        .padding(.top, 4)
    }

    private func open(_ url: String?) {
        if let url, let u = URL(string: url) { NSWorkspace.shared.open(u) }
    }
}
