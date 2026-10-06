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

extension ActionsStore {
    /// The first Jira value outside the account's lists, for the field mark and the footer.
    func jiraCheck(_ values: [String: String]) -> (field: String, message: String, footer: String)? {
        JiraPick.check(values, projects: jiraProjects?.projects, types: jiraTypes, screens: jiraScreens)
    }

    /// Projects used on Jira tickets, newest first (RECENT in the project menu).
    var jiraUsedProjects: [String] {
        items.values.filter { $0.type == "jira" }.sorted { $0.createdAt > $1.createdAt }.compactMap { $0.field("project") }
    }
}

/// Project, Type and Priority as pop-up pickers. `values` reads and `set` writes a field ("" clears it).
struct JiraFieldPickers: View {
    /// The fields these pickers own; the rest stay in the caller's own rows.
    static let keys: Set<String> = ["project", "issueType", "priority"]

    @ObservedObject var store: ActionsStore
    let values: [String: String]
    let set: (String, String) -> Void
    var labelWidth: CGFloat = 70
    /// The field the core refused (marked as well).
    var marked: String? = nil
    /// The caption under the pickers; the ticket detail puts it after its other fields instead.
    var showCaption = true
    /// Snapshots draw a menu open ("project", "issueType", "priority").
    var menuOpen: String? = nil

    @State private var open: String?
    @State private var search = ""

    private var projects: [JiraProject]? { store.jiraProjects?.projects }
    private var project: JiraProject? { projects.flatMap { JiraPick.project(values["project"], in: $0) } }
    private var types: [JiraIssueType]? { project.flatMap { store.jiraTypes[$0.key] } }
    private var type: JiraIssueType? { types.flatMap { JiraPick.type(values["issueType"], in: $0) } }
    private var screen: JiraCreateScreen? { project.flatMap { p in type.flatMap { store.jiraScreens[p.key + "|" + $0.id] } } }
    /// Without the lists the pickers are muted and keep the saved values (Jira checks on create).
    private var muted: Bool { projects == nil }
    private var problem: (field: String, message: String, footer: String)? { store.jiraCheck(values) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            row("project", "Project") {
                pop("project", project?.label ?? text("project", or: "Choose a project")) { projectMenu }
            }
            .zIndex(open == "project" ? 2 : 0)
            row("issueType", "Type") {
                pop("issueType", type?.name ?? text("issueType", or: "Task")) {
                    listMenu("TYPES IN \(project?.key ?? "THE PROJECT")", (types ?? []).map(\.name), current: type?.name) { set("issueType", $0) }
                }
            }
            .zIndex(open == "issueType" ? 2 : 0)
            if let screen, screen.priorities == nil {
                row("priority", "Priority") {
                    Text(JiraPick.hiddenNote("Priority")).font(Theme.body(12)).foregroundStyle(Theme.faint)
                }
            } else {
                row("priority", "Priority") {
                    pop("priority", text("priority", or: "—")) {
                        listMenu("PRIORITIES IN \(project?.key ?? "THE PROJECT")", screen?.priorities ?? [], current: values["priority"]) { set("priority", $0) }
                    }
                }
                .zIndex(open == "priority" ? 2 : 0)
            }
            if showCaption { JiraCaption(store: store) }
        }
        .onAppear {
            store.loadJiraProjects()
            if let menuOpen { open = menuOpen }
        }
        .task(id: (project?.key ?? "") + "|" + (type?.id ?? "")) {
            if let key = project?.key { store.loadJiraTypes(key) }
            if let id = type?.id, let key = project?.key { store.loadJiraScreen(key, typeId: id) }
        }
    }

    private func text(_ key: String, or placeholder: String) -> String {
        values[key].flatMap { $0.isEmpty ? nil : $0 } ?? placeholder
    }

    private func row<C: View>(_ key: String, _ label: String, @ViewBuilder _ content: () -> C) -> some View {
        let message = problem?.field == key ? problem?.message : (marked == key ? "" : nil)
        return VStack(alignment: .leading, spacing: 2) {
            HStack(spacing: 10) {
                Text(label).font(Theme.body(12)).foregroundStyle(message != nil ? Theme.peachInk : Theme.muted).frame(width: labelWidth, alignment: .leading)
                content()
                Spacer(minLength: 0)
            }
            .frame(minHeight: 28)
            .padding(.horizontal, message != nil ? 6 : 0)
            .background(RoundedRectangle(cornerRadius: 8).strokeBorder(message != nil ? Theme.peachInk : .clear, lineWidth: 1.5))
            if let message, !message.isEmpty {
                Text(message).font(Theme.body(11.5)).foregroundStyle(Theme.peachInk).padding(.leading, labelWidth + 10)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
    }

    /// A pop-up button ("TLS · Telus Platform ⌃⌄") and its menu.
    private func pop<M: View>(_ key: String, _ title: String, @ViewBuilder menu: @escaping () -> M) -> some View {
        Button { if !muted { open = open == key ? nil : key } } label: {
            HStack(spacing: 6) {
                Text(title).font(Theme.body(13)).foregroundStyle(muted ? Theme.muted : Theme.ink).lineLimit(1)
                Image(systemName: "chevron.up.chevron.down").font(.system(size: 9, weight: .semibold)).foregroundStyle(Theme.muted)
            }
            .padding(.horizontal, 9).frame(height: 26)
            .background(RoundedRectangle(cornerRadius: 7).fill(muted ? Theme.panel : Color.white))
            .overlay(RoundedRectangle(cornerRadius: 7).strokeBorder(Theme.border))
            .opacity(muted ? 0.75 : 1)
        }
        .buttonStyle(.plain)
        .help(muted ? JiraPick.offline : "")
        .overlay(alignment: .topLeading) {
            // Below the field's message when it has one, so "Pick one:" leads into the list.
            if open == key && store.fixtureInlineMenus { menu().offset(y: problem?.field == key ? 52 : 30).fixedSize() }
        }
        .popover(isPresented: Binding(get: { open == key && !store.fixtureInlineMenus }, set: { if !$0 { open = nil } }), arrowEdge: .bottom) {
            menu().padding(4)
        }
    }

    /// Search projects, RECENT (✓ on the current one), then ALL PROJECTS YOU CAN CREATE IN.
    private var projectMenu: some View {
        let all = projects ?? []
        let recent = JiraPick.recent(current: values["project"], used: store.jiraUsedProjects, in: all)
        let found = JiraPick.search(search, in: all)
        return ActionMenuPanel(width: 300) {
            HStack(spacing: 6) {
                Image(systemName: "magnifyingglass").font(.system(size: 11)).foregroundStyle(Theme.muted)
                TextField("Search projects", text: $search).textFieldStyle(.plain).font(Theme.body(13))
            }
            .padding(.horizontal, 10).padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 7).fill(Theme.panel)).padding(.horizontal, 6).padding(.vertical, 4)
            if search.isEmpty && !recent.isEmpty {
                section("RECENT")
                ForEach(recent) { projectRow($0) }
            }
            section("ALL PROJECTS YOU CAN CREATE IN")
            ForEach(found.filter { p in !search.isEmpty || !recent.contains(p) }.prefix(12)) { projectRow($0) }
        }
    }

    private func section(_ title: String) -> some View {
        Text(title).font(Theme.body(10, .heavy)).kerning(0.6).foregroundStyle(Theme.faint)
            .padding(.horizontal, 10).padding(.top, 6).padding(.bottom, 2)
    }

    private func projectRow(_ p: JiraProject) -> some View {
        ActionMenuRow(title: p.label, checked: p.key == project?.key) {
            // "TLS · Telus Platform" reads well even when Jira can't be reached; the core takes the key from it.
            set("project", p.label); open = nil; search = ""
        }
    }

    private func listMenu(_ title: String, _ names: [String], current: String?, pick: @escaping (String) -> Void) -> some View {
        ActionMenuPanel(title: title, width: 240) {
            ForEach(names, id: \.self) { n in
                ActionMenuRow(title: n, checked: current.map { $0.lowercased() == n.lowercased() } ?? false) { pick(n); open = nil }
            }
        }
    }
}

/// "From your Jira (jin@lotusflare… · updated 2 min ago) · Refresh", or "Couldn’t reach Jira to check these · Retry".
struct JiraCaption: View {
    @ObservedObject var store: ActionsStore

    var body: some View {
        HStack(spacing: 4) {
            if let list = store.jiraProjects {
                Text(JiraPick.caption(account: list.account, fetchedAt: list.fetchedAt, now: store.jiraNow()) + " ·")
                Button("Refresh") { store.loadJiraProjects(refresh: true) }.buttonStyle(.plain).foregroundStyle(Theme.primary).fontWeight(.semibold)
            } else if store.jiraProblem != nil, !store.jiraNotConnected {
                Text(JiraPick.offline + " ·")
                Button("Retry") { store.loadJiraProjects(refresh: true) }.buttonStyle(.plain).foregroundStyle(Theme.primary).fontWeight(.semibold)
            }
            if store.jiraLoading { Spinner(size: 10) }
        }
        .font(Theme.body(11)).foregroundStyle(Theme.muted).padding(.top, 2)
    }
}

extension ActionsStore {
    var jiraNotConnected: Bool { if case .notConnected? = jiraProblem { return true }; return false }
}
