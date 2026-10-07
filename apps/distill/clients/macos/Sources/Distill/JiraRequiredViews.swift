import SwiftUI
import AppKit
import DistillKit

// Jira required fields (actions.md; canvas ActionsJiraFields K–N): the fields a project + type asks for,
// by name, with a control that follows Jira's field type, "Required by TLS", "Use for future TLS Tasks",
// and "Distill can't fill <Name> here" with Open in Jira for a type Distill can't fill.

extension ActionsStore {
    /// Saved required-field values per "PROJECT|Type" (Settings → Jira ticket → Defaults).
    var jiraRequiredDefaults: [String: [String: JiraRequiredDefault]] {
        (engine?.settings.actionPreferences ?? ActionPreferences()).jiraRequiredDefaults
    }

    /// The create screen for a ticket's project + type, with its project key and type name.
    func jiraScreen(_ values: [String: String]) -> (project: String, type: String, screen: JiraCreateScreen)? {
        guard let projects = jiraProjects?.projects, let p = JiraPick.project(values["project"], in: projects),
              let t = jiraTypes[p.key].flatMap({ JiraPick.type(values["issueType"], in: $0) }),
              let screen = jiraScreens[p.key + "|" + t.id] else { return nil }
        return (p.key, t.name, screen)
    }

    /// Saves (on) or removes (off) a field's value for future tickets of this project + type.
    func setJiraRequiredDefault(project: String, type: String, field: JiraField, value: String?) {
        guard let engine else { return }
        let key = JiraRequired.defaultsKey(project, type)
        SettingsEdits.setActions(&engine.settings) {
            $0.setJiraRequiredDefault(key, field: field.id, value.map { JiraRequiredDefault(name: field.name, value: $0) })
        }
    }

    func searchJiraUsers(_ project: String, _ query: String) async -> [JiraUser] {
        guard let client else { return [] }
        return (try? await client.jiraUsers(project, query: query)) ?? []
    }

    /// Open in Jira: Jira's create page with what Distill can fill.
    func openJiraCreatePage(_ item: ActionItem) {
        guard let client else { return }
        Task {
            do {
                if let url = try await client.jiraCreateURL(item.id) { NSWorkspace.shared.open(url) }
            } catch { engine?.report(error) }
        }
    }

    /// Copy the ticket text: the title and description, then each filled field by name.
    func copyJiraTicket(_ item: ActionItem, fields: [JiraField]) {
        let values = item.fields.compactMapValues { $0 }
        let lines = fields.compactMap { f in JiraRequired.display(f, values[f.key]).map { "\(f.name): \($0)" } }
        let text = ([item.title, item.body ?? ""] + (lines.isEmpty ? [] : [lines.joined(separator: "\n")])).filter { !$0.isEmpty }.joined(separator: "\n\n")
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text, forType: .string)
        show(ActionToast(text: "Copied the ticket text"))
    }
}

/// The required (and defaulted) fields under Assignee in the ticket detail.
struct JiraRequiredFields: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    var labelWidth: CGFloat = 70

    private var values: [String: String] { item.fields.compactMapValues { $0 } }

    var body: some View {
        if let s = store.jiraScreen(values) {
            let defaults = store.jiraRequiredDefaults[JiraRequired.defaultsKey(s.project, s.type)] ?? [:]
            let fields = JiraRequired.shown(s.screen.extra, defaults: defaults)
            VStack(alignment: .leading, spacing: 4) {
                ForEach(fields) { f in
                    JiraRequiredRow(store: store, item: item, field: f, project: s.project, type: s.type, defaults: defaults, all: fields, labelWidth: labelWidth)
                        .zIndex(store.jiraOpenField == item.id + "|" + f.id ? 2 : 0)
                }
            }
        }
    }
}

struct JiraRequiredRow: View {
    @ObservedObject var store: ActionsStore
    let item: ActionItem
    let field: JiraField
    let project: String
    let type: String
    let defaults: [String: JiraRequiredDefault]
    let all: [JiraField]
    var labelWidth: CGFloat = 70

    @State private var text = ""
    @State private var query = ""
    @State private var found: [JiraUser] = []
    @State private var day = Date()
    @FocusState private var focused: Bool

    private var values: [String: String] { item.fields.compactMapValues { $0 } }
    private var raw: String? { JiraRequired.value(field, values: values, defaults: defaults) }
    private var empty: Bool { raw == nil }
    private var openKey: String { item.id + "|" + field.id }
    private var picked: Bool { store.jiraPicked.contains(openKey) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if field.kind == .unsupported {
                unsupported
            } else {
                HStack(alignment: .center, spacing: 10) {
                    label
                    control
                    if field.asked { requiredBy }
                    Spacer(minLength: 0)
                }
                .frame(minHeight: 28)
                if picked, !empty {
                    Toggle(isOn: Binding(get: { defaults[field.id]?.value == raw }, set: { on in
                        store.setJiraRequiredDefault(project: project, type: type, field: field, value: on ? raw : nil)
                    })) {
                        Text(JiraRequired.useForFuture(project: project, type: type)).font(Theme.body(12.5))
                    }
                    .toggleStyle(.checkbox)
                    .padding(.leading, labelWidth + 10)
                }
            }
        }
    }

    private var label: some View {
        Text(field.name).font(Theme.body(12, .semibold)).foregroundStyle(Theme.ink)
            .frame(width: labelWidth, alignment: .leading).fixedSize(horizontal: false, vertical: true)
    }

    private var requiredBy: some View {
        Text("Required by \(project)").font(Theme.body(11.5, .bold)).foregroundStyle(Theme.peachInk).lineLimit(1).fixedSize()
    }

    private func set(_ v: String?, from tag: String? = nil) {
        var patch: [String: String?] = [field.key: v.flatMap { JiraRequired.isEmpty($0) ? nil : $0 }]
        patch[JiraRequired.fromKey(field.id)] = tag
        store.update(item.id, ActionPatch(fields: patch))
        store.jiraPicked.insert(openKey)
    }

    // MARK: Controls by type

    @ViewBuilder private var control: some View {
        switch field.kind {
        case .option:
            pop(raw ?? JiraRequired.placeholder(field.name), placeholder: empty) {
                list(field.options.map(\.name), current: raw) { set($0) }
            }
        case .options:
            chips
        case .cascading:
            let (parent, child) = JiraRequired.pair(raw)
            let children = field.options.first { $0.name.lowercased() == parent?.lowercased() }?.children ?? []
            HStack(spacing: 8) {
                pop(parent ?? JiraRequired.placeholder(field.name), placeholder: parent == nil) {
                    list(field.options.map(\.name), current: parent) { set(JiraRequired.encode([$0])) }
                }
                if !children.isEmpty {
                    Text("›").font(Theme.body(12)).foregroundStyle(Theme.muted)
                    pop(child ?? "Choose", placeholder: child == nil, key: openKey + "|child") {
                        list(children.map(\.name), current: child, key: openKey + "|child") { set(JiraRequired.encode([parent ?? "", $0])) }
                    }
                }
            }
        case .date:
            pop(JiraRequired.dayLabel(raw) ?? JiraRequired.placeholder(field.name), placeholder: empty, icon: "calendar") {
                DatePicker("", selection: $day, displayedComponents: .date)
                    .datePickerStyle(.graphical).labelsHidden().padding(8)
                    .onAppear { day = JiraRequired.date(raw) ?? store.jiraNow() }
                    .onChange(of: day) { _, d in set(JiraRequired.dayString(d)) }
            }
        case .user:
            person
        case .text, .number, .textarea:
            TextField(field.kind == .number ? "A number" : field.name, text: $text, axis: field.kind == .textarea ? .vertical : .horizontal)
                .textFieldStyle(.plain).font(Theme.body(13)).focused($focused)
                .lineLimit(field.kind == .textarea ? 2...5 : 1...1)
                .padding(.horizontal, 9).padding(.vertical, 5).frame(minHeight: 26).frame(maxWidth: 280)
                .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(empty && field.asked ? Theme.peachInk : Theme.border, lineWidth: empty && field.asked ? 1.5 : 1))
                .onAppear { text = raw ?? "" }
                .onSubmit { set(text) }
                .onChange(of: focused) { _, f in if !f && text != (raw ?? "") { set(text) } }
        case .unsupported:
            EmptyView()
        }
    }

    /// Several choices: a chip per name (× removes it), "from the note" after the ones the note gave, ＋ adds.
    private var chips: some View {
        let names = JiraRequired.names(raw)
        let fromNote = JiraRequired.fromNote(field, values: values)
        let tag = values[JiraRequired.fromKey(field.id)]
        return HStack(spacing: 6) {
            ForEach(Array(names.enumerated()), id: \.element) { i, n in
                HStack(spacing: 5) {
                    Text(n).font(Theme.body(12.5))
                    Button {
                        let rest = names.filter { $0 != n }
                        let notes = fromNote.filter { $0 != n }
                        set(JiraRequired.encode(rest), from: notes.isEmpty ? nil : JiraRequired.encode(notes))
                    } label: { Image(systemName: "xmark").font(.system(size: 7.5, weight: .bold)) }
                        .buttonStyle(.plain).foregroundStyle(Theme.skyInk.opacity(0.7))
                }
                .padding(.horizontal, 9).frame(height: 24)
                .background(Capsule().fill(Theme.skyTint))
                // After the last name the note gave.
                if !fromNote.isEmpty, n == names.last(where: { fromNote.contains($0) }) ?? "", i < names.count {
                    Text("from the note").font(Theme.body(11, .bold)).foregroundStyle(Theme.limeInk)
                        .padding(.horizontal, 8).frame(height: 22).background(Capsule().fill(Theme.limeTint))
                }
            }
            let left = field.options.map(\.name).filter { o in !names.contains { $0.lowercased() == o.lowercased() } }
            Button { store.jiraOpenField = store.jiraOpenField == openKey ? nil : openKey } label: {
                Image(systemName: "plus").font(.system(size: 10, weight: .semibold)).foregroundStyle(Theme.muted)
                    .frame(width: 24, height: 24)
                    .overlay(Circle().strokeBorder(style: StrokeStyle(lineWidth: 1, dash: [3, 2])).foregroundStyle(empty && field.asked ? Theme.peachInk : Theme.faint))
            }
            .buttonStyle(.plain)
            .menu(isOpen: store.jiraOpenField == openKey, inline: store.fixtureInlineMenus, close: { store.jiraOpenField = nil }) {
                list(left, current: nil) { set(JiraRequired.encode(names + [$0]), from: tag) }
            }
        }
    }

    /// A person: "AP Aditya Pradhan" as a pill; the menu searches the people Jira can assign in the project.
    private var person: some View {
        let u = JiraRequired.user(raw)
        return Button { store.jiraOpenField = store.jiraOpenField == openKey ? nil : openKey } label: {
            HStack(spacing: 7) {
                if let u {
                    Text(JiraRequired.initials(u.name)).font(Theme.body(9, .heavy)).foregroundStyle(Theme.pinkInk)
                        .frame(width: 20, height: 20).background(Circle().fill(Theme.pinkTint))
                    Text(u.name).font(Theme.body(13)).foregroundStyle(Theme.ink)
                } else {
                    Image(systemName: "person.crop.circle").font(.system(size: 13)).foregroundStyle(Theme.faint)
                    Text(JiraRequired.placeholder(field.name)).font(Theme.body(13)).foregroundStyle(Theme.faint)
                }
            }
            .padding(.leading, u == nil ? 9 : 4).padding(.trailing, 11).frame(height: 26)
            .background(Capsule().fill(Color.white))
            .overlay(Capsule().strokeBorder(empty && field.asked ? Theme.peachInk : Theme.border, lineWidth: empty && field.asked ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .menu(isOpen: store.jiraOpenField == openKey, inline: store.fixtureInlineMenus, close: { store.jiraOpenField = nil }) {
            ActionMenuPanel(title: "PEOPLE IN \(project)", width: 260) {
                HStack(spacing: 6) {
                    Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.muted)
                    TextField("Search people", text: $query).textFieldStyle(.plain).font(Theme.body(13))
                }
                .padding(.horizontal, 10).padding(.vertical, 6)
                .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel)).padding(.horizontal, 6).padding(.vertical, 4)
                ForEach(found) { p in
                    ActionMenuRow(title: p.name, checked: p.accountId == u?.accountId) {
                        set(JiraRequired.encode(p)); store.jiraOpenField = nil; query = ""
                    }
                }
            }
            .task(id: query) {
                try? await Task.sleep(nanoseconds: 250_000_000)
                if !Task.isCancelled { found = await store.searchJiraUsers(project, query) }
            }
        }
    }

    /// Distill can't fill this type: say so, Open in Jira with the rest passed along, or copy the ticket text.
    private var unsupported: some View {
        HStack(alignment: .top, spacing: 10) {
            label.padding(.top, 2)
            VStack(alignment: .leading, spacing: 8) {
                if field.asked { requiredBy }
                VStack(alignment: .leading, spacing: 6) {
                    Text("Distill can’t fill \(field.name) here").font(Theme.body(13, .semibold))
                    Text("It’s a field type Distill doesn’t know. Open in Jira starts Jira’s create page with everything else filled in.")
                        .font(Theme.body(12)).foregroundStyle(Theme.muted).fixedSize(horizontal: false, vertical: true)
                    HStack(spacing: 14) {
                        Button { store.openJiraCreatePage(item) } label: {
                            HStack(spacing: 3) { Text("Open in Jira"); Image(systemName: "arrow.up.right").font(.system(size: 9, weight: .bold)) }
                        }
                        Button("Copy the ticket text") { store.copyJiraTicket(item, fields: all) }
                    }
                    .buttonStyle(.plain).font(Theme.body(12.5, .semibold)).foregroundStyle(Theme.primary).padding(.top, 2)
                }
                .padding(.horizontal, 12).padding(.vertical, 10).frame(maxWidth: .infinity, alignment: .leading)
                .background(RoundedRectangle(cornerRadius: 10).fill(Theme.panel))
            }
        }
    }

    // MARK: Menus

    private func pop<M: View>(_ title: String, placeholder: Bool, icon: String? = nil, key: String? = nil, @ViewBuilder menu: @escaping () -> M) -> some View {
        let k = key ?? openKey
        let warn = placeholder && field.asked
        return Button { store.jiraOpenField = store.jiraOpenField == k ? nil : k } label: {
            HStack(spacing: 6) {
                if let icon { Image(systemName: icon).font(.system(size: 11)).foregroundStyle(Theme.muted) }
                Text(title).font(Theme.body(13)).foregroundStyle(placeholder ? Theme.faint : Theme.ink).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(warn ? Theme.peachInk : Theme.border, lineWidth: warn ? 1.5 : 1))
        }
        .buttonStyle(.plain)
        .menu(isOpen: store.jiraOpenField == k, inline: store.fixtureInlineMenus, close: { store.jiraOpenField = nil }, content: menu)
    }

    private func list(_ names: [String], current: String?, key: String? = nil, pick: @escaping (String) -> Void) -> some View {
        ActionMenuPanel(title: JiraRequired.menuTitle(field.name, project: project), width: 240) {
            ForEach(names, id: \.self) { n in
                ActionMenuRow(title: n, checked: current.map { $0.lowercased() == n.lowercased() } ?? false) {
                    pick(n); store.jiraOpenField = nil
                }
            }
        }
    }
}

private extension View {
    /// A menu under the control: a popover in the app, drawn in place for snapshots.
    func menu<M: View>(isOpen: Bool, inline: Bool, close: @escaping () -> Void, @ViewBuilder content: @escaping () -> M) -> some View {
        self
            .overlay(alignment: .topLeading) { if isOpen && inline { content().offset(y: 30).fixedSize() } }
            .popover(isPresented: Binding(get: { isOpen && !inline }, set: { if !$0 { close() } }), arrowEdge: .bottom) { content().padding(4) }
    }
}

/// Settings → Jira ticket → Defaults: REQUIRED FIELDS, PER PROJECT AND TYPE. A saved value per project + type
/// with Remove; a required field with none reads "not set: asked on each ticket".
struct JiraRequiredDefaultsSection: View {
    @EnvironmentObject var engine: AppModel
    @ObservedObject var store: ActionsStore
    @State private var open: String?

    private struct Line: Identifiable {
        var key: String
        var field: JiraField
        var saved: JiraRequiredDefault?
        var id: String { key + "|" + field.id }
    }

    private var defaults: [String: [String: JiraRequiredDefault]] { SettingsEdits.actions(engine.settings).jiraRequiredDefaults }

    /// The saved keys, and the default project + type's (so its required fields show before anything is saved).
    private var keys: [String] {
        let p = SettingsEdits.actions(engine.settings)
        var out = defaults.keys.sorted()
        if let project = p.fieldDefault("jira", "project") {
            let k = JiraRequired.defaultsKey(JiraPick.key(project), p.fieldDefault("jira", "issueType") ?? "Task")
            out.removeAll { $0 == k }
            out.insert(k, at: 0)
        }
        // Screens already loaded whose project + type asks for something.
        for (k, screen) in store.jiraScreens.sorted(by: { $0.key < $1.key }) where screen.extra.contains(where: \.asked) {
            let project = String(k.split(separator: "|").first ?? "")
            guard let t = store.jiraTypes[project]?.first(where: { $0.id == screen.typeId }) else { continue }
            let key = JiraRequired.defaultsKey(project, t.name)
            if !out.contains(key) { out.append(key) }
        }
        return out
    }

    private func screen(_ key: String) -> JiraCreateScreen? {
        let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
        guard parts.count == 2 else { return nil }
        return store.jiraScreen(["project": parts[0], "issueType": parts[1]])?.screen
    }

    private var lines: [Line] {
        keys.flatMap { key -> [Line] in
            let saved = defaults[key] ?? [:]
            if let s = screen(key) {
                return JiraRequired.shown(s.extra, defaults: saved).filter { $0.kind != .unsupported }.map { Line(key: key, field: $0, saved: saved[$0.id]) }
            }
            return saved.sorted { $0.key < $1.key }.map { id, d in Line(key: key, field: JiraField(id: id, name: d.name, kind: .text), saved: d) }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("REQUIRED FIELDS, PER PROJECT AND TYPE").font(Theme.body(10.5, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
                .padding(.top, 14)
            Text("Filled into every new ticket for that project and type. Set here, or with “Use for future … Tasks” on a ticket.")
                .font(Theme.body(12)).foregroundStyle(Theme.muted).padding(.top, 4).padding(.bottom, 4)
                .fixedSize(horizontal: false, vertical: true)
            if lines.isEmpty {
                Text("None yet: a project’s required fields show here once you pick it.").font(Theme.body(12)).foregroundStyle(Theme.faint).padding(.vertical, 10)
            }
            ForEach(lines) { line in
                row(line)
                Divider()
            }
        }
        .settingsAnchor("Required fields, per project and type")
        .task(id: keys.joined(separator: ",")) {
            store.loadJiraProjects()
            for key in keys {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                if parts.count == 2 { store.loadJiraTypes(parts[0]) }
            }
        }
        .onChange(of: store.jiraTypes) { _, types in
            for key in keys {
                let parts = key.split(separator: "|", maxSplits: 1).map(String.init)
                guard parts.count == 2, let t = types[parts[0]].flatMap({ JiraPick.type(parts[1], in: $0) }) else { continue }
                store.loadJiraScreen(parts[0], typeId: t.id)
            }
        }
    }

    private func row(_ line: Line) -> some View {
        let parts = line.key.split(separator: "|", maxSplits: 1).map(String.init)
        let project = parts.first ?? line.key, type = parts.count > 1 ? parts[1] : ""
        return HStack(spacing: 12) {
            Text("\(project) · \(type)").font(Theme.body(13, .semibold)).frame(width: 130, alignment: .leading)
            HStack(spacing: 4) {
                Text(line.field.name).font(Theme.body(13))
                if line.field.asked { Text("required").font(Theme.body(11.5, .bold)).foregroundStyle(Theme.peachInk) }
            }
            .frame(width: 160, alignment: .leading)
            if let saved = line.saved {
                if line.field.kind == .option || line.field.kind == .options, !line.field.options.isEmpty {
                    Button { open = open == line.id ? nil : line.id } label: {
                        HStack(spacing: 6) {
                            Text(JiraRequired.display(line.field, saved.value) ?? saved.value).font(Theme.body(13)).foregroundStyle(Theme.ink)
                            Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
                        }
                        .padding(.horizontal, 9).frame(height: 26)
                        .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
                        .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
                    }
                    .buttonStyle(.plain)
                    .popover(isPresented: Binding(get: { open == line.id }, set: { if !$0 { open = nil } }), arrowEdge: .bottom) {
                        ActionMenuPanel(title: JiraRequired.menuTitle(line.field.name, project: project), width: 240) {
                            ForEach(line.field.options) { o in
                                ActionMenuRow(title: o.name, checked: JiraRequired.names(saved.value).contains(o.name) || saved.value == o.name) {
                                    save(line, line.field.kind == .options ? JiraRequired.encode([o.name]) : o.name); open = nil
                                }
                            }
                        }
                        .padding(4)
                    }
                } else {
                    Text(JiraRequired.display(line.field, saved.value) ?? saved.value).font(Theme.body(13))
                }
                Spacer(minLength: 8)
                Button("Remove") { save(line, nil) }.buttonStyle(.plain).font(Theme.body(12)).foregroundStyle(Theme.muted)
            } else {
                Text("not set: asked on each ticket").font(Theme.body(13)).italic().foregroundStyle(Theme.faint)
                Spacer(minLength: 0)
            }
        }
        .padding(.vertical, 10)
    }

    private func save(_ line: Line, _ value: String?) {
        SettingsEdits.setActions(&engine.settings) {
            $0.setJiraRequiredDefault(line.key, field: line.field.id, value.map { JiraRequiredDefault(name: line.field.name, value: $0) })
        }
    }
}
