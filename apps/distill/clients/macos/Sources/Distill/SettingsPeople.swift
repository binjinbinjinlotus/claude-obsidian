import AppKit
import SwiftUI
import DistillKit

// Settings → Actions → Whose items Distill handles (spec actions-routing.md; canvas
// settings-actions-people): People (you first, with the names the notes use), each type's
// "Handles items for", and what the last 7 days would have done. Edits `actionPreferences`.

/// The row on the Actions page that opens the People page.
struct PeopleSettingsRow: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore

    var body: some View {
        let prefs = SettingsEdits.actions(engine.settings)
        let others = prefs.people.filter { !$0.isYou }.count
        HStack(spacing: 12) {
            Image(systemName: "person.2").font(.system(size: 13, weight: .semibold)).foregroundStyle(Theme.pinkInk)
                .frame(width: 32, height: 32).background(RoundedRectangle(cornerRadius: 9).fill(Theme.pinkTint))
            VStack(alignment: .leading, spacing: 2) {
                Text("Whose items Distill handles").font(Theme.body(14, .semibold))
                Text(prefs.routingOn
                     ? "You\(others > 0 ? " and \(others) \(others == 1 ? "other person" : "other people")" : ""): everyone else’s items go to Pending or Highlights"
                     : "Off until you add the names the notes use for you: every found item goes to your lists")
                    .font(Theme.body(12)).foregroundStyle(Theme.muted).lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Image(systemName: "chevron.right").font(.system(size: 11, weight: .semibold)).foregroundStyle(Theme.faint)
        }
        .padding(.vertical, 12)
        .contentShape(Rectangle())
        .onTapGesture { ui.select(SettingsTarget(.actions, actionType: PeopleSettingsPage.id)) }
        .settingsAnchor("Whose items Distill handles")
    }
}

struct PeopleSettingsPage: View {
    static let id = "people"
    @EnvironmentObject var engine: AppModel
    @ObservedObject var ui: SettingsStore
    @ObservedObject var store: ActionsStore
    /// Snapshots: a fixed preview (the app asks the core).
    var fixturePreview: RoutingPreview? = nil
    @State private var adding: [String: String] = [:]
    @State private var editingName: String?
    /// Just added and not named yet: shown here, saved with its first name.
    @State private var newPerson: ActionPerson?

    private var prefs: ActionPreferences { SettingsEdits.actions(engine.settings) }
    private var types: [SettingsActionType] { ui.actionTypes.filter { !$0.reserved && SettingsEdits.typeEnabled($0, engine.settings) } }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 4) {
                Button { ui.select(SettingsTarget(.actions)) } label: { Text("Actions").foregroundStyle(Theme.muted) }.buttonStyle(.plain)
                Text("›").foregroundStyle(Theme.muted)
                Text("Whose items Distill handles").fontWeight(.bold)
            }
            .font(Theme.body(12))
            Text("Whose items Distill handles").font(Theme.display(22))
                .settingsAnchor("Whose items Distill handles")
            Text("An item found in a note goes to your lists only when its owner, the person who has to do it, is someone you handle that type for. Things others owe you go to Pending; everyone else’s go to the note’s Highlights.")
                .font(Theme.body(13)).foregroundStyle(Theme.softInk).lineSpacing(3).fixedSize(horizontal: false, vertical: true)
                .frame(maxWidth: 820, alignment: .leading)
            caps("People").padding(.top, 4)
            ForEach(prefs.people + (newPerson.map { [$0] } ?? [])) { person in personRow(person) }
            Button { addPerson() } label: { Text("＋ Add a person").font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary) }
                .buttonStyle(.plain).padding(.top, 2).padding(.bottom, 6)
            caps("Each type")
            ForEach(types) { t in typeRow(t) }
            previewLine.padding(.top, 6)
        }
        .task(id: prefs) {
            guard fixturePreview == nil else { return }
            try? await Task.sleep(nanoseconds: 300_000_000)
            store.refreshRoutingPreview(prefs, types: types.map(\.id))
        }
    }

    private func caps(_ text: String) -> some View {
        Text(text.uppercased()).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
    }

    // MARK: People

    private func personRow(_ p: ActionPerson) -> some View {
        HStack(alignment: .center, spacing: 10) {
            PersonAvatar(name: p.name.isEmpty ? "?" : p.name, size: 28, you: p.isYou)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    if editingName == p.id || p.name.isEmpty {
                        DraftTextField(placeholder: p.isYou ? "Your name, as the notes write it" : "Their name", key: p.id, value: p.name,
                                       normalize: p.isYou ? FieldText.trimmed : FieldText.nonEmpty,
                                       save: { _, name in saveName(p, name) })
                            .textFieldStyle(.plain).font(Theme.body(13.5, .semibold)).frame(maxWidth: 260)
                            .onSubmit { editingName = nil }
                    } else {
                        Text(p.name).font(Theme.body(13.5, .semibold)).onTapGesture { editingName = p.id }
                    }
                    if p.isYou { Text("YOU").font(Theme.body(11, .medium)).foregroundStyle(Theme.primary) }
                }
                FlowLayout(spacing: 5) {
                    Text("The notes call them").font(Theme.body(11.5)).foregroundStyle(Theme.muted).frame(height: 24)
                    ForEach(p.aliases, id: \.self) { alias in
                        HStack(spacing: 4) {
                            Text(alias)
                            Button { setAliases(p, p.aliases.filter { $0 != alias }) } label: { Text("×").foregroundStyle(Theme.faint) }
                                .buttonStyle(.plain).help("Remove \(alias)")
                        }
                        .font(Theme.body(12)).padding(.horizontal, 9).frame(height: 24)
                        .background(Capsule().fill(Theme.panel))
                    }
                    if let text = adding[p.id] {
                        TextField("Name or @handle", text: Binding(get: { text }, set: { adding[p.id] = $0 }))
                            .textFieldStyle(.plain).font(Theme.body(12)).frame(width: 120, height: 24).padding(.horizontal, 8)
                            .overlay(Capsule().strokeBorder(Theme.primary))
                            .onSubmit { commitAlias(p) }
                    } else {
                        Button { adding[p.id] = "" } label: {
                            Text("＋").font(Theme.body(12)).foregroundStyle(Theme.muted).padding(.horizontal, 9).frame(height: 24)
                                .overlay(Capsule().strokeBorder(Color(hex: 0xD6D3CC), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                        }
                        .buttonStyle(.plain).help("Add a name the notes use for them")
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            if !p.isYou {
                Button("Remove") {
                    if newPerson?.id == p.id { newPerson = nil; return }
                    SettingsEdits.setActions(&engine.settings) { $0.removePerson(p.id, types: ui.actionTypes.map(\.id)) }
                }
                    .buttonStyle(.plain).font(Theme.body(12)).foregroundStyle(Theme.muted)
            }
        }
        .padding(.vertical, 9)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xF0EEEA)).frame(height: 1) }
    }

    /// A person just added joins Settings with their first name (the core drops an empty one).
    private func saveName(_ p: ActionPerson, _ name: String) {
        if let n = newPerson, n.id == p.id {
            newPerson = nil
            SettingsEdits.setActions(&engine.settings) { $0.people.append(ActionPerson(id: n.id, name: name, aliases: n.aliases)) }
        } else {
            SettingsEdits.setActions(&engine.settings) { $0.setName(p.id, name) }
        }
    }

    private func setAliases(_ p: ActionPerson, _ aliases: [String]) {
        if newPerson?.id == p.id { newPerson?.aliases = aliases; return }
        SettingsEdits.setActions(&engine.settings) { pr in
            pr.people = pr.people.map { $0.id == p.id ? ActionPerson(id: $0.id, name: $0.name, aliases: aliases) : $0 }
        }
    }

    private func commitAlias(_ p: ActionPerson) {
        let v = (adding[p.id] ?? "").trimmingCharacters(in: .whitespaces)
        adding[p.id] = nil
        guard !v.isEmpty, !p.aliases.contains(where: { $0.caseInsensitiveCompare(v) == .orderedSame }) else { return }
        setAliases(p, p.aliases + [v])
    }

    private func addPerson() {
        let id = "p-" + UUID().uuidString.prefix(8).lowercased()
        newPerson = ActionPerson(id: id, name: "")
        editingName = id
    }

    // MARK: Each type

    private func typeRow(_ t: SettingsActionType) -> some View {
        let handles = prefs.handlesFor(t.id)
        let people = prefs.people
        let missing = people.filter { !handles.contains($0.id) && !$0.name.isEmpty }
        return HStack(alignment: .center, spacing: 12) {
            ActionTypeTile(id: t.id, size: 22)
            Text(t.id == "todo" ? "To-do" : t.label).font(Theme.body(13, .semibold)).frame(width: 110, alignment: .leading)
            VStack(alignment: .leading, spacing: 4) {
                FlowLayout(spacing: 5) {
                    Text("Handles items for").font(Theme.body(11.5)).foregroundStyle(Theme.muted).frame(height: 26)
                    ForEach(handles, id: \.self) { id in
                        if let p = people.first(where: { $0.id == id }) {
                            HStack(spacing: 5) {
                                PersonAvatar(name: p.name.isEmpty ? "You" : p.name, size: 20, you: p.isYou)
                                Text(p.name.isEmpty ? "You" : Routing.chipName(p)).font(Theme.body(12.5, .semibold))
                                Button { set(t.id, handles.filter { $0 != id }) } label: { Text("×").foregroundStyle(Color(hex: 0x6B9BE8)) }
                                    .buttonStyle(.plain).help("Stop handling \(t.pluralLabel) for \(p.name.isEmpty ? "you" : p.name)")
                            }
                            .padding(.leading, 3).padding(.trailing, 10).frame(height: 26)
                            .background(Capsule().fill(Theme.primaryTint))
                        }
                    }
                    Menu {
                        ForEach(missing) { p in Button(p.isYou ? "\(p.name) (you)" : p.name) { set(t.id, handles + [p.id]) } }
                        if missing.isEmpty { Text("Everyone in People is here") }
                    } label: {
                        Text("＋").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.horizontal, 9).frame(height: 24)
                    .overlay(Capsule().strokeBorder(Color(hex: 0xD6D3CC), style: StrokeStyle(lineWidth: 1.5, dash: [3, 2])))
                }
                Text(Routing.handlesHint(type: t.id, handles: handles, people: people)).font(Theme.body(11.5)).foregroundStyle(Theme.faint)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, 10)
        .overlay(alignment: .bottom) { Rectangle().fill(Color(hex: 0xF0EEEA)).frame(height: 1) }
    }

    private func set(_ type: String, _ ids: [String]) {
        SettingsEdits.setActions(&engine.settings) { $0.setHandlesFor(type, ids) }
    }

    // MARK: Preview

    @ViewBuilder private var previewLine: some View {
        HStack(spacing: 8) {
            Image(systemName: "clock").font(.system(size: 12, weight: .semibold)).foregroundStyle(Theme.primary)
            if !prefs.routingOn {
                Text("Add the names the notes use for you, and Distill starts sorting new items by whose they are. Until then every found item goes to your lists.")
                    .font(Theme.body(12.5)).fixedSize(horizontal: false, vertical: true)
            } else if let p = fixturePreview ?? store.routingPreview {
                (Text("In the last \(p.days) days this would have sent ") + Text("\(p.lists)").bold() + Text(" to your lists, ")
                 + Text("\(p.waiting)").bold() + Text(" to Pending and ") + Text("\(p.others)").bold() + Text(" to Highlights."))
                    .font(Theme.body(12.5))
            } else {
                Text("Working out what the last 7 days would have done…").font(Theme.body(12.5)).foregroundStyle(Theme.muted)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12).padding(.vertical, 10)
        .background(RoundedRectangle(cornerRadius: 10).fill(Color(hex: 0xF2F7FF)))
    }
}
