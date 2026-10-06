import SwiftUI
import DistillKit

// Jira pickers (actions.md): Project (searchable), Type and Priority from what the connected Jira
// account allows, with "From your Jira (… · updated N min ago) · Refresh" and the offline note.
// Used in the Jira ticket detail, the Add as… panel and Settings → Jira ticket defaults.

extension ActionsStore {
    /// The account's projects; a quiet no-op while loaded and fresh (the core caches an hour).
    func loadJiraProjects(refresh: Bool = false) {
        guard let client, refresh || (jiraProjects == nil && !jiraLoading) else { return }
        jiraLoading = true
        Task {
            defer { jiraLoading = false }
            do {
                jiraProjects = try await client.jiraProjects(refresh: refresh)
                jiraProblem = nil
                if refresh { jiraTypes = [:]; jiraScreens = [:] }
            } catch let e as JiraListError {
                jiraProblem = e.problem
            } catch {
                jiraProblem = .other((error as? CustomStringConvertible)?.description ?? error.localizedDescription)
            }
        }
    }

    func loadJiraTypes(_ key: String) {
        guard let client, !key.isEmpty, jiraTypes[key] == nil else { return }
        Task {
            if let list = try? await client.jiraIssueTypes(key) { jiraTypes[key] = list.types }
        }
    }

    func loadJiraScreen(_ key: String, typeId: String) {
        let k = key + "|" + typeId
        guard let client, jiraScreens[k] == nil else { return }
        Task {
            if let s = try? await client.jiraCreateScreen(key, typeId: typeId) { jiraScreens[k] = s }
        }
    }
}

/// Project, Type and Priority as pickers. `values` reads and `set` writes a field ("" clears it).
struct JiraFieldPickers: View {
    /// The fields these pickers own; the rest stay in the caller's own rows.
    static let keys: Set<String> = ["project", "issueType", "priority"]

    @ObservedObject var store: ActionsStore
    let values: [String: String]
    let set: (String, String) -> Void
    var labelWidth: CGFloat = 70
    /// The field the core refused (marked as well).
    var marked: String? = nil
    /// Snapshots draw the project menu open.
    var menuOpen = false

    @State private var showProjects = false
    @State private var search = ""

    private var projects: [JiraProject]? { store.jiraProjects?.projects }
    private var project: JiraProject? { projects.flatMap { JiraPick.project(values["project"], in: $0) } }
    private var types: [JiraIssueType]? { project.flatMap { store.jiraTypes[$0.key] } }
    private var type: JiraIssueType? { types.flatMap { JiraPick.type(values["issueType"], in: $0) } }
    private var screen: JiraCreateScreen? { project.flatMap { p in type.flatMap { store.jiraScreens[p.key + "|" + $0.id] } } }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if let projects {
                row("Project", problem: JiraPick.projectProblem(values["project"], projects: projects) ?? markedProblem("project")) { projectButton }
                    .zIndex(showProjects ? 1 : 0) // the open menu draws over Type and Priority
                row("Type", problem: typeProblem ?? markedProblem("issueType")) { typePicker }
                if let screen, screen.priorities == nil {
                    row("Priority", problem: nil) {
                        Text(JiraPick.hiddenNote("Priority")).font(Theme.body(12)).foregroundStyle(Theme.faint)
                    }
                } else {
                    row("Priority", problem: priorityProblem ?? markedProblem("priority")) { priorityPicker }
                }
                caption
            } else {
                // No lists: the values as written, and why (Jira checks on create).
                ForEach([("project", "Project"), ("issueType", "Type"), ("priority", "Priority")], id: \.0) { key, label in
                    row(label, problem: markedProblem(key)) {
                        TextField(label, text: Binding(get: { values[key] ?? "" }, set: { set(key, $0) }))
                            .textFieldStyle(.roundedBorder).font(Theme.body(13))
                    }
                }
                if case .unreachable? = store.jiraProblem { offline } else if case .other? = store.jiraProblem { offline }
            }
        }
        .onAppear {
            store.loadJiraProjects()
            if menuOpen { showProjects = true }
        }
        .onChange(of: project?.key) { _, key in if let key { store.loadJiraTypes(key) } }
        .onChange(of: type?.id) { _, id in if let id, let key = project?.key { store.loadJiraScreen(key, typeId: id) } }
        .task(id: (project?.key ?? "") + "|" + (type?.id ?? "")) {
            if let key = project?.key { store.loadJiraTypes(key) }
            if let id = type?.id, let key = project?.key { store.loadJiraScreen(key, typeId: id) }
        }
    }

    private func markedProblem(_ key: String) -> String? { marked == key ? "" : nil }

    private var typeProblem: String? {
        guard let p = project, let types else { return nil }
        return JiraPick.typeProblem(values["issueType"], project: p.key, types: types)
    }

    private var priorityProblem: String? {
        guard let p = project else { return nil }
        return JiraPick.priorityProblem(values["priority"], project: p.key, priorities: screen?.priorities)
    }

    private func row<C: View>(_ label: String, problem: String?, @ViewBuilder _ content: () -> C) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(label).font(Theme.body(12)).foregroundStyle(problem != nil ? Theme.peachInk : Theme.muted).frame(width: labelWidth, alignment: .leading)
                content()
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
            .padding(.horizontal, problem != nil ? 6 : 0)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(problem != nil ? Theme.peachInk : .clear, lineWidth: 1.5))
            if let problem, !problem.isEmpty {
                Text(problem).font(Theme.body(11.5)).foregroundStyle(Theme.peachInk).padding(.leading, labelWidth + 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    private var projectButton: some View {
        Button { showProjects.toggle() } label: {
            HStack(spacing: 6) {
                Text(project?.label ?? (values["project"].flatMap { $0.isEmpty ? nil : $0 } ?? "Choose a project"))
                    .font(Theme.body(13)).foregroundStyle(values["project"]?.isEmpty == false ? Theme.ink : Theme.faint).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(Color.white))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
        }
        .buttonStyle(.plain)
        .overlay(alignment: .topLeading) {
            if showProjects && store.fixtureInlineMenus { projectMenu.offset(y: 30).fixedSize() }
        }
        .popover(isPresented: Binding(get: { showProjects && !store.fixtureInlineMenus }, set: { showProjects = $0 }), arrowEdge: .bottom) {
            projectMenu.padding(4)
        }
        .zIndex(showProjects ? 10 : 0)
    }

    private var projectMenu: some View {
        ActionMenuPanel(title: "PROJECTS YOU CAN CREATE IN", width: 300) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.muted)
                TextField("Search projects", text: $search).textFieldStyle(.plain).font(Theme.body(13))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel)).padding(.horizontal, 6).padding(.bottom, 4)
            ForEach(JiraPick.search(search, in: projects ?? []).prefix(12)) { p in
                ActionMenuRow(title: p.key, detail: p.name, icon: "ticket", checked: p.key == project?.key) {
                    set("project", p.key)
                    showProjects = false
                    search = ""
                }
            }
        }
    }

    private var typePicker: some View {
        Picker("", selection: Binding(get: { type?.name ?? (values["issueType"] ?? "") }, set: { set("issueType", $0) })) {
            if type == nil { Text(values["issueType"].flatMap { $0.isEmpty ? nil : $0 } ?? "—").tag(values["issueType"] ?? "") }
            ForEach(types ?? []) { Text($0.name).tag($0.name) }
        }
        .labelsHidden().frame(maxWidth: 200, alignment: .leading)
        .disabled(types == nil)
    }

    private var priorityPicker: some View {
        let current = values["priority"] ?? ""
        let list = screen?.priorities ?? []
        let match = list.first { $0.lowercased() == current.lowercased() }
        return Picker("", selection: Binding(get: { match ?? current }, set: { set("priority", $0) })) {
            Text("—").tag("")
            if match == nil && !current.isEmpty { Text(current).tag(current) }
            ForEach(list, id: \.self) { Text($0).tag($0) }
        }
        .labelsHidden().frame(maxWidth: 200, alignment: .leading)
        .disabled(screen == nil)
    }

    private var caption: some View {
        HStack(spacing: 4) {
            if let list = store.jiraProjects {
                Text(JiraPick.caption(account: list.account, fetchedAt: list.fetchedAt, now: store.jiraNow()) + " ·")
            }
            Button("Refresh") { store.loadJiraProjects(refresh: true) }.buttonStyle(.plain).foregroundStyle(Theme.primary).fontWeight(.semibold)
            if store.jiraLoading { Spinner(size: 10) }
        }
        .font(Theme.body(11)).foregroundStyle(Theme.muted).padding(.top, 2)
    }

    private var offline: some View {
        HStack(spacing: 4) {
            Image(systemName: "wifi.slash").font(.system(size: 10))
            Text(JiraPick.offline + " ·")
            Button("Retry") { store.loadJiraProjects(refresh: true) }.buttonStyle(.plain).foregroundStyle(Theme.primary).fontWeight(.semibold)
        }
        .font(Theme.body(11)).foregroundStyle(Theme.muted).padding(.top, 2)
    }
}
