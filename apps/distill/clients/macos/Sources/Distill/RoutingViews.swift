import AppKit
import SwiftUI
import DistillKit

// Whose items Distill handles (spec actions-routing.md; canvas board ActionsRouting): the store's
// routing commands and the small pieces To confirm shows (the quiet line, "for Aditya",
// "Whose is this?"). Pending and Highlights have their own files.

/// Nudge's Add as Slack message panel: who it goes to and the text.
struct NudgeDraft: Equatable {
    var to: String
    var text: String
}

enum RoutingWords {
    /// "for Aditya" in pink, or "owner unclear" in peach, after a To confirm row's type.
    static func whose(_ item: ActionItem, people: [ActionPerson]) -> (String, Color)? {
        if item.ownerUnclear { return ("owner unclear", Theme.peachInk) }
        if let f = Routing.forWhom(item, people: people) { return (f, Theme.pinkInk) }
        return nil
    }
}

extension ActionsStore {
    /// Whose is this?: you, a person from People, or nil for Not mine (→ the note's Highlights).
    func assignOwner(_ item: ActionItem, owner: String?) {
        call { try await $0.assignActionOwner(item.id, owner: owner) }
        if owner == nil {
            show(ActionToast(text: "Not yours: “\(item.title)” went to Highlights", open: { [weak self] in self?.open(tab: "highlights") }))
        }
    }

    func trackAsPending(_ item: ActionItem) {
        call { try await $0.trackAsPending(item.id) }
        show(ActionToast(text: "Tracking “\(item.title)” in Pending", open: { [weak self] in self?.open(tab: "pending", select: item.id) }))
    }

    /// It's mine: an Others' action goes to its type's list as yours.
    func claim(_ item: ActionItem) {
        call { try await $0.claimAction(item.id) }
        let tab = listTypes.contains { $0.id == item.type } ? item.type : "todo"
        show(ActionToast(text: "Moved “\(item.title)” to \(label(tab))", open: { [weak self] in self?.open(tab: tab, select: item.id) }))
    }

    func markReceived(_ item: ActionItem) {
        call { try await $0.markReceived(item.id) }
        show(ActionToast(text: "Marked “\(item.title)” received", undo: { [weak self] in self?.restore(item.id) }, history: true))
    }

    func stopWaiting(_ item: ActionItem) {
        call { try await $0.stopWaiting(item.id) }
        show(ActionToast(text: "Not waiting for “\(item.title)” anymore", undo: { [weak self] in self?.restore(item.id) }, history: true))
    }

    /// Nudge opens Add as Slack message to the person, prefilled "Hi Aditya, any update on the ticket links?".
    func startNudge(_ item: ActionItem) {
        let person = Routing.owner(item, people: people)
        nudging[item.id] = NudgeDraft(to: Routing.nudgeTo(item, people: people), text: Routing.nudgeText(person: person, what: Routing.what(item)))
    }

    func sendNudge(_ item: ActionItem) {
        guard let client, let draft = nudging[item.id] else { return }
        Task {
            do {
                let r = try await client.nudgeAction(item.id, to: draft.to, text: draft.text)
                put(r.item)
                put(r.message)
                nudging[item.id] = nil
                show(ActionToast(text: "Added a Slack message to \(Routing.firstName(Routing.owner(item, people: people)))",
                                 open: { [weak self] in self?.open(tab: "slack", select: r.message.id) }))
            } catch { engine?.report(error) }
        }
    }

    /// The live preview line under Each type (Settings), for the People being edited.
    func refreshRoutingPreview(_ prefs: ActionPreferences, types: [String]) {
        guard let client else { return }
        let handles = Dictionary(uniqueKeysWithValues: types.map { ($0, prefs.handlesFor($0)) })
        Task {
            if let p = try? await client.routingPreview(people: prefs.people, handles: handles) { routingPreview = p }
        }
    }

    func copySummary(_ note: HighlightNote) {
        let text = Routing.summaryMarkdown(note) { [weak self] type, n in
            "\(self?.label(type) ?? type) \(n)"
        }
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(ActionToast(text: "Copied the summary of \(note.title)"))
    }
}

/// "Whose is this?  You · Someone… · Not mine" on a To confirm row whose owner Distill couldn't tell.
struct WhoseIsThis: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem

    var body: some View {
        VStack(alignment: .trailing, spacing: 3) {
            Text("Whose is this?").foregroundStyle(Theme.muted)
            HStack(spacing: 8) {
                Button("You") { store.assignOwner(item, owner: ActionPerson.youID) }
                Menu {
                    ForEach(store.people.filter { !$0.isYou }) { p in
                        Button(p.name) { store.assignOwner(item, owner: p.id) }
                    }
                    if store.people.count > 1 { Divider() }
                    Button("Add a person in Settings…") { store.openSettings("actions/people") }
                } label: { Text("Someone…").foregroundColor(Theme.primary) }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize().tint(Theme.primary)
                Button("Not mine") { store.assignOwner(item, owner: nil) }
            }
            .buttonStyle(.plain)
            .foregroundStyle(Theme.primary)
        }
        .font(Theme.body(11, .semibold))
        .fixedSize()
    }
}

/// To do: "6 items for other people went to Highlights · 2 to Pending · Show" above To confirm.
struct RoutedAwayLine: View {
    @ObservedObject var store: ActionsStore
    let pending: [ActionItem]

    var body: some View {
        if let text = Routing.elsewhereLine(pending: pending, routed: Array(store.routed.values)) {
            HStack(spacing: 4) {
                Text(text + " ·").foregroundStyle(Theme.muted)
                Button("Show") { store.open(tab: store.others.isEmpty ? "pending" : "highlights") }
                    .buttonStyle(.plain).fontWeight(.semibold).foregroundStyle(Theme.primary)
                Spacer(minLength: 0)
            }
            .font(Theme.body(12))
            .padding(.horizontal, 12).padding(.vertical, 8)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            .padding(.top, 4).padding(.bottom, 2)
        }
    }
}

/// ConfirmDetail: "For Aditya Pradhan · you handle To-dos for Aditya (Settings → Actions)".
struct ForWhomLine: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem

    var body: some View {
        if let id = item.ownerID, id != ActionPerson.youID, item.inLists {
            let name = Routing.owner(item, people: store.people)
            let type = store.type(item.type)?.pluralLabel ?? "items"
            HStack(spacing: 8) {
                PersonAvatar(name: name, size: 20)
                (Text("For \(name)").fontWeight(.bold).foregroundColor(Theme.ink)
                    + Text(" · you handle \(type == "To do" ? "To-dos" : type) for \(Routing.firstName(name)) (Settings → Actions)"))
                    .font(Theme.body(12)).foregroundStyle(Theme.softInk)
                Spacer(minLength: 0)
            }
            .padding(.horizontal, 11).padding(.vertical, 9)
            .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
        }
    }
}

/// Initials in a pink circle (People, Pending, Highlights).
struct PersonAvatar: View {
    let name: String
    var size: CGFloat = 24
    var you = false

    var body: some View {
        Text(Routing.initials(name))
            .font(Theme.body(size * 0.4, .bold))
            .foregroundStyle(you ? Theme.primary : Theme.pinkInk)
            .frame(width: size, height: size)
            .background(Circle().fill(you ? Theme.primaryTint : Theme.pinkTint))
    }
}
