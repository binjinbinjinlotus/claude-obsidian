import AppKit
import SwiftUI
import DistillKit

// Track as Pending from To confirm, and Move to Pending for an added to-do (actions-routing.md; canvas
// board "Actions · Track as Pending"): the store's commands, the inline panel (Waiting on, By, the
// line and the Pending preview) and its footer. The item stays the same item; the core keeps where it
// was, so the toast's Undo puts it back.

extension ActionsStore {
    /// Opens the panel, filled from the item. With no one to fill in, the Waiting on list opens.
    func startTrack(_ item: ActionItem) {
        guard TrackPending.origin(item) != nil else { return }
        addAsMenu = nil
        addingAs[item.id] = nil
        let draft = TrackPending.prefill(item, people: people)
        tracking[item.id] = draft
        trackPicker = draft.waitingOn == nil ? item.id : nil
    }

    func cancelTrack(_ item: ActionItem) {
        tracking[item.id] = nil
        if trackPicker == item.id { trackPicker = nil }
    }

    func trackBlock(_ item: ActionItem) -> String? {
        tracking[item.id].flatMap { TrackPending.blockReason($0, people: people) }
    }

    /// Tracks it, moves the selection on (`onDone`), and shows "Tracked as Pending · waiting on Aditya · Undo".
    func finishTrack(_ item: ActionItem, onDone: (() -> Void)? = nil) {
        PendingSaves.shared.flushAll() // a name still being typed
        guard let draft = tracking[item.id], let waitingOn = draft.waitingOn, trackBlock(item) == nil, let client else { return }
        let tab = self.tab
        Task {
            do {
                let tracked = try await client.trackAsPending(item.id, waitingOn: waitingOn, by: draft.by)
                put(tracked)
                tracking[item.id] = nil
                if trackPicker == item.id { trackPicker = nil }
                onDone?()
                show(ActionToast(text: TrackPending.toast(draft, people: people), undo: { [weak self] in
                    self?.restore(item.id)
                    self?.selected[tab] = item.id
                }))
            } catch {
                engine?.report(error)
            }
        }
    }

    /// The Waiting on list for an item.
    func trackChoices(_ item: ActionItem, typed: String) -> (note: [TrackPending.Choice], people: [TrackPending.Choice]) {
        TrackPending.choices(for: item, all: Array(items.values) + Array(routed.values), people: people, typed: typed)
    }
}

/// The inline "Track as Pending" panel (To confirm) or "Move to Pending" (a to-do's detail).
struct TrackPendingPanel: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var labelWidth: CGFloat = 72
    var now: Date = Date()

    private var draft: TrackPending.Draft { store.tracking[item.id] ?? TrackPending.prefill(item, people: store.people) }

    var body: some View {
        let d = draft
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "clock").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    .frame(width: 24, height: 24)
                    .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel))
                    .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                Text(TrackPending.title(d)).font(Theme.body(14, .bold)).lineLimit(1).fixedSize()
                Spacer(minLength: 4)
                if let sub = TrackPending.subtitle(item, d, typeWords: AddAs.typeWords(item.type, types: store.types)) {
                    Text(sub).font(Theme.body(11)).foregroundStyle(Theme.faint).lineLimit(1)
                }
            }
            if d.origin == .confirm && TrackPending.ownerIsYou(item) {
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "person.crop.circle.badge.questionmark").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.peachInk)
                    youNote.font(Theme.body(12)).foregroundStyle(Theme.ink).fixedSize(horizontal: false, vertical: true)
                }
                .padding(.horizontal, 10).padding(.vertical, 9)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 9).fill(Theme.peachTint))
            }
            row("Waiting on", note: d.waitingOn == nil ? "required" : nil) { WaitingOnField(store: store, item: item) }
                .zIndex(2)
            row("By", note: "optional") { byField(d) }
            if let line = TrackPending.noteLine(d, people: store.people) {
                Text(line).font(Theme.body(11.5)).foregroundStyle(Theme.muted)
                    .fixedSize(horizontal: false, vertical: true).padding(.leading, labelWidth + 8)
            }
            if d.waitingOn != nil { preview(d) }
        }
        .padding(14)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 12).fill(Theme.window))
        .overlay(RoundedRectangle(cornerRadius: 12).strokeBorder(Theme.border, lineWidth: 1.5))
        .background(RoundedRectangle(cornerRadius: 14).strokeBorder(Theme.panel, lineWidth: 4).padding(-4))
        .zIndex(3)
    }

    private var youNote: Text {
        let text = TrackPending.youNote(item)
        guard let r = text.range(of: "you") else { return Text(text) }
        return Text(String(text[..<r.lowerBound])) + Text("you").bold() + Text(String(text[r.upperBound...]))
    }

    private func row<C: View>(_ label: String, note: String?, @ViewBuilder _ content: () -> C) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label).font(Theme.body(12)).foregroundStyle(Theme.muted).frame(width: labelWidth, alignment: .leading).padding(.top, 7)
            content().frame(maxWidth: .infinity, alignment: .leading)
            if let note { Text(note).font(Theme.body(11)).foregroundStyle(Theme.faint).padding(.top, 7).fixedSize() }
        }
    }

    /// "Fri, Oct 9 ×": a date menu; × clears it (no date: it never turns Overdue).
    private func byField(_ d: TrackPending.Draft) -> some View {
        HStack(spacing: 7) {
            Menu {
                ForEach(AddTodoRow.dueChoices(now: now), id: \.1) { title, value in
                    Button(title) { store.tracking[item.id]?.by = value; store.tracking[item.id]?.byFromItem = false }
                }
                Button("No date") { clearBy() }
            } label: {
                HStack(spacing: 7) {
                    Image(systemName: "calendar").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text(TrackPending.byLabel(d.by) ?? "No date").font(Theme.body(12.5)).foregroundStyle(d.by == nil ? Theme.faint : Theme.ink)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton).menuIndicator(.hidden)
            if d.by != nil {
                Button { clearBy() } label: { Text("×").font(Theme.body(13)).foregroundStyle(Theme.faint) }
                    .buttonStyle(.plain).help("No date")
            }
        }
        .padding(.leading, 9).padding(.trailing, 8).frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.window))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ActionsTheme.quoteBar))
    }

    private func clearBy() {
        store.tracking[item.id]?.by = nil
        store.tracking[item.id]?.byFromItem = false
    }

    /// "IN PENDING IT WILL READ": the row as Pending will show it.
    private func preview(_ d: TrackPending.Draft) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("IN PENDING IT WILL READ").font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
            HStack(alignment: .top, spacing: 9) {
                Image(systemName: "clock").font(.system(size: 13)).foregroundStyle(Theme.faint)
                VStack(alignment: .leading, spacing: 2) {
                    Text(item.title).font(Theme.body(13, .semibold)).fixedSize(horizontal: false, vertical: true)
                    Text(TrackPending.previewLine(item, d, people: store.people, now: now)).font(Theme.body(11)).foregroundStyle(Theme.muted)
                }
            }
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
    }
}

/// Waiting on: the person picked (avatar, name, "@aditya · the item’s owner", ▾); open, a field to type a
/// name over IN THIS NOTE and PEOPLE. A name not in People is kept as written.
struct WaitingOnField: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    @State private var typed = ""

    private var open: Bool { store.trackPicker == item.id }
    private var draft: TrackPending.Draft? { store.tracking[item.id] }

    var body: some View {
        Group {
            if open { search } else { picked }
        }
        // Anchored to the field's right edge, so a narrow pane's list grows to the left, inside the panel.
        .overlay(alignment: .topTrailing) {
            if open { list.offset(y: 34) }
        }
    }

    private var picked: some View {
        Button { typed = ""; store.trackPicker = item.id } label: {
            HStack(spacing: 7) {
                if let d = draft, d.waitingOn != nil {
                    let name = TrackPending.displayName(d, people: store.people)
                    let id = d.personID ?? TrackPending.match(d.name, people: store.people)
                    PersonAvatar(name: name, size: 20)
                    Text(name).font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                    let detail = [TrackPending.handle(id, people: store.people), d.personFromItem && d.origin == .confirm ? "the item’s owner" : nil]
                        .compactMap { $0 }.joined(separator: " · ")
                    if !detail.isEmpty { Text(detail).font(Theme.body(12.5)).foregroundStyle(Theme.muted).lineLimit(1).truncationMode(.tail) }
                } else {
                    Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
                    Text(TrackPending.pickerPlaceholder).font(Theme.body(12.5)).foregroundStyle(Theme.faint)
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.down").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
            }
            .padding(.leading, 9).padding(.trailing, 8).frame(minHeight: 30)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.window))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(ActionsTheme.quoteBar))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Who you are waiting on")
    }

    private var search: some View {
        HStack(spacing: 7) {
            Image(systemName: "magnifyingglass").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.muted)
            // Typing keeps its spaces (DraftTextField); the name is kept as written until a person is picked.
            DraftTextField(placeholder: TrackPending.pickerPlaceholder, key: item.id, value: typed, autoFocus: !store.fixtureInlineMenus,
                           normalize: { $0 }, save: { _, text in
                               // A late save (the list closing after a pick) never replaces the person just picked.
                               guard store.trackPicker == item.id else { return }
                               typed = text
                               type(text)
                           })
                .textFieldStyle(.plain).font(Theme.body(12.5))
                .onSubmit { PendingSaves.shared.flushAll(); store.trackPicker = nil }
                .onExitCommand { PendingSaves.shared.flushAll(); store.trackPicker = nil }
            Image(systemName: "chevron.up").font(.system(size: 9, weight: .bold)).foregroundStyle(Theme.muted)
                .onTapGesture { PendingSaves.shared.flushAll(); store.trackPicker = nil }
        }
        .padding(.leading, 9).padding(.trailing, 8).frame(minHeight: 30)
        .background(RoundedRectangle(cornerRadius: 7).fill(Theme.window))
        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.primary, lineWidth: 1.5))
        .background(RoundedRectangle(cornerRadius: 9).strokeBorder(Theme.primaryTint, lineWidth: 3).padding(-2.5))
    }

    /// A typed name: kept as written (the core matches it to People too).
    private func type(_ text: String) {
        store.tracking[item.id]?.personID = nil
        store.tracking[item.id]?.name = text
        store.tracking[item.id]?.personFromItem = false
    }

    private func pick(_ c: TrackPending.Choice) {
        store.tracking[item.id]?.personID = c.personID
        store.tracking[item.id]?.name = c.name
        store.tracking[item.id]?.personFromItem = false
        store.trackPicker = nil
        typed = ""
    }

    private var list: some View {
        let choices = store.trackChoices(item, typed: typed)
        let first = (choices.note + choices.people).first?.id
        return VStack(alignment: .leading, spacing: 0) {
            if !choices.note.isEmpty {
                header("IN THIS NOTE")
                ForEach(choices.note) { c in choiceRow(c, bold: true, highlighted: c.id == first) }
            }
            if !choices.people.isEmpty {
                if !choices.note.isEmpty { Divider().overlay(Theme.border).padding(.vertical, 5) }
                header("PEOPLE")
                ForEach(choices.people) { c in choiceRow(c, bold: false, highlighted: c.id == first) }
            }
            if !(choices.note.isEmpty && choices.people.isEmpty) { Divider().overlay(Theme.border).padding(.vertical, 5) }
            Text(TrackPending.pickerFootnote).font(Theme.body(11.5)).foregroundStyle(Theme.muted)
                .fixedSize(horizontal: false, vertical: true).padding(.horizontal, 10).padding(.vertical, 3)
        }
        .padding(.vertical, 6)
        .frame(minWidth: 240, maxWidth: .infinity, alignment: .leading)
        .background(RoundedRectangle(cornerRadius: 10).fill(Theme.window).shadow(color: .black.opacity(0.16), radius: 15, y: 12))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Theme.border))
    }

    private func header(_ title: String) -> some View {
        Text(title).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
            .padding(.horizontal, 10).padding(.top, 2).padding(.bottom, 4)
    }

    private func choiceRow(_ c: TrackPending.Choice, bold: Bool, highlighted: Bool) -> some View {
        Button { pick(c) } label: {
            HStack(spacing: 8) {
                PersonAvatar(name: c.name, size: 20)
                Text(c.name).font(Theme.body(12.5, bold ? .semibold : .regular)).foregroundStyle(Theme.ink).lineLimit(1).fixedSize()
                if bold, let h = c.handle { Text(h).font(Theme.body(11.5)).foregroundStyle(Theme.muted).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 10).padding(.vertical, 5)
            .background(highlighted ? Theme.primaryTint : .clear)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// The detail footer while the panel is open. To confirm: Cancel · why it's off · Track as Pending. A to-do:
/// Cancel · Move to Pending, on the right. ⌘Return tracks; Esc cancels.
struct TrackPendingFooter: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var onDone: (() -> Void)? = nil

    var body: some View {
        let reason = store.trackBlock(item)
        // A narrow pane puts why it's off on its own line.
        ViewThatFits(in: .horizontal) {
            buttons(reason, inline: true)
            VStack(alignment: .trailing, spacing: 6) {
                if let reason { reasonText(reason).frame(maxWidth: .infinity, alignment: .trailing) }
                buttons(reason, inline: false)
            }
        }
    }

    private func buttons(_ reason: String?, inline: Bool) -> some View {
        HStack(spacing: 8) {
            if store.tracking[item.id]?.origin == .todo {
                Spacer(minLength: 0)
                cancel
            } else {
                cancel
                Spacer(minLength: 0)
            }
            if inline, let reason { reasonText(reason) }
            PrimaryButton(title: store.tracking[item.id].map(TrackPending.title) ?? "Track as Pending", systemImage: "clock", size: .small,
                          enabled: reason == nil) {
                store.finishTrack(item, onDone: onDone)
            }
            .fixedSize()
            .help(reason ?? "")
            .keyboardShortcut(.return, modifiers: .command)
        }
    }

    private func reasonText(_ text: String) -> some View {
        Text(text).font(Theme.body(11.5)).foregroundStyle(Theme.peachInk).lineLimit(1).fixedSize()
    }

    private var cancel: some View {
        SoftButton(title: "Cancel", fill: Theme.window, size: .small, stroke: true) { store.cancelTrack(item) }
            .fixedSize()
            .keyboardShortcut(.cancelAction)
    }
}

/// ⇧⌥Return: Track as Pending… for the selected To confirm row, Move to Pending… for the selected to-do.
/// Never while typing in a text field.
enum TrackPendingKey {
    static func allowed() -> Bool { !(NSApp.keyWindow?.firstResponder is NSTextView) }
}
