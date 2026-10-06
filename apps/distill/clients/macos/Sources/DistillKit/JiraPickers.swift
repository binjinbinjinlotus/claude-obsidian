import Foundation

/// Jira pickers (actions.md): what the connected account allows (GET /v1/jira/…), the caption and
/// offline words, and the same check the core makes before Create, so the field is marked early.
public struct JiraProject: Codable, Hashable, Sendable, Identifiable {
    public var key: String
    public var name: String
    public var id: String { key }
    public init(key: String, name: String) { self.key = key; self.name = name }
    /// "TLS · Telus Platform"
    public var label: String { name.isEmpty ? key : "\(key) · \(name)" }
}

public struct JiraIssueType: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var name: String
    public init(id: String, name: String) { self.id = id; self.name = name }
}

public struct JiraProjectList: Codable, Hashable, Sendable {
    public var site: String
    public var account: String?
    public var fetchedAt: Date
    public var projects: [JiraProject]
    public init(site: String, account: String?, fetchedAt: Date, projects: [JiraProject]) {
        self.site = site; self.account = account; self.fetchedAt = fetchedAt; self.projects = projects
    }

    enum Keys: String, CodingKey { case site, account, fetchedAt, projects }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        site = c.lossy(String.self, .site) ?? ""
        account = c.lossy(String.self, .account)
        fetchedAt = c.lossy(String.self, .fetchedAt).flatMap(CoreDate.parse) ?? Date()
        projects = c.lossyArray(JiraProject.self, .projects)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(site, forKey: .site)
        try c.encodeIfPresent(account, forKey: .account)
        try c.encode(CoreDate.format(fetchedAt), forKey: .fetchedAt)
        try c.encode(projects, forKey: .projects)
    }
}

public struct JiraTypeList: Codable, Hashable, Sendable {
    public var project: String
    public var types: [JiraIssueType]
    public init(project: String, types: [JiraIssueType]) { self.project = project; self.types = types }
}

public struct JiraCreateScreen: Codable, Hashable, Sendable {
    public var project: String
    public var typeId: String
    /// nil: the create screen has no Priority field.
    public var priorities: [String]?
    public init(project: String, typeId: String, priorities: [String]?) {
        self.project = project; self.typeId = typeId; self.priorities = priorities
    }
}

/// Why the lists couldn't be loaded (the core's `error.jira`).
public enum JiraListProblem: Equatable, Sendable {
    case notConnected(String)
    case unreachable(String)
    case other(String)

    public var message: String {
        switch self { case .notConnected(let m), .unreachable(let m), .other(let m): return m }
    }
}

public struct JiraListError: Error, Equatable, Sendable {
    public var problem: JiraListProblem
}

public enum JiraPick {
    /// "TLS · Telus Platform" or "tls" → "TLS".
    public static func key(_ value: String) -> String {
        String(value.trimmingCharacters(in: .whitespaces).split(whereSeparator: { $0 == " " || $0 == "·" }).first ?? "").uppercased()
    }

    static func same(_ a: String, _ b: String) -> Bool {
        a.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased() == b.split(whereSeparator: \.isWhitespace).joined(separator: " ").lowercased()
    }

    /// The project a field value names, by key or name.
    public static func project(_ value: String?, in list: [JiraProject]) -> JiraProject? {
        guard let value, !value.trimmingCharacters(in: .whitespaces).isEmpty else { return nil }
        let k = key(value)
        return list.first { $0.key == k } ?? list.first { same($0.name, value) }
    }

    public static func type(_ value: String?, in list: [JiraIssueType]) -> JiraIssueType? {
        let v = (value?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Task"
        return list.first { same($0.name, v) }
    }

    /// What a picked project saves in `fields.project`: its key ("TLS"), so a button's {fields.project}, the
    /// filters, Add as and Copy all read the key. The picker shows `label` instead.
    public static func stored(_ p: JiraProject) -> String { p.key }

    /// Key → name, cached from the last list so the picker can name a project while Jira can't be reached.
    public static func names(_ list: [JiraProject]) -> [String: String] {
        Dictionary(list.filter { !$0.name.isEmpty }.map { ($0.key, $0.name) }, uniquingKeysWith: { a, _ in a })
    }

    /// What the picker shows for a saved value: "TLS · Telus Platform" from Jira's list, else from the cached
    /// names (offline), else the value as saved. Nil when empty.
    public static func label(_ value: String?, projects: [JiraProject]?, names: [String: String]) -> String? {
        guard let v = value?.trimmingCharacters(in: .whitespaces), !v.isEmpty else { return nil }
        if let projects, let p = project(v, in: projects) { return p.label }
        if let name = names[key(v)] { return JiraProject(key: key(v), name: name).label }
        return v
    }

    /// Projects whose key or name contains the search text.
    public static func search(_ text: String, in list: [JiraProject]) -> [JiraProject] {
        let t = text.trimmingCharacters(in: .whitespaces).lowercased()
        guard !t.isEmpty else { return list }
        return list.filter { $0.key.lowercased().contains(t) || $0.name.lowercased().contains(t) }
    }

    /// "Medium isn’t a priority in TLS. Pick one:" (the core's words; the colon leads into the list).
    public static func priorityProblem(_ value: String?, project: String, priorities: [String]?) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty, let priorities else { return nil }
        return priorities.contains(where: { same($0, value) }) ? nil : "\(value) isn’t a priority in \(project). Pick one:"
    }

    public static func typeProblem(_ value: String?, project: String, types: [JiraIssueType]) -> String? {
        let v = (value?.trimmingCharacters(in: .whitespaces)).flatMap { $0.isEmpty ? nil : $0 } ?? "Task"
        return type(v, in: types) == nil ? "\(v) isn’t an issue type in \(project). Pick one:" : nil
    }

    public static func projectProblem(_ value: String?, projects: [JiraProject]) -> String? {
        guard let value = value?.trimmingCharacters(in: .whitespaces), !value.isEmpty else { return nil }
        return project(value, in: projects) == nil ? "\(value) isn’t a Jira project you can create tickets in. Pick one:" : nil
    }

    /// The first value outside the lists (project, then type, then priority), and the footer's words
    /// beside a disabled Create in Jira ("Pick a priority TLS uses"). Nil when all are allowed or unknown.
    public static func check(_ values: [String: String], projects: [JiraProject]?, types: [String: [JiraIssueType]],
                             screens: [String: JiraCreateScreen]) -> (field: String, message: String, footer: String)? {
        guard let projects else { return nil }
        if let m = projectProblem(values["project"], projects: projects) { return ("project", m, "Pick a project you can create in") }
        guard let p = project(values["project"], in: projects), let list = types[p.key] else { return nil }
        if let m = typeProblem(values["issueType"], project: p.key, types: list) { return ("issueType", m, "Pick a type \(p.key) has") }
        guard let t = type(values["issueType"], in: list), let screen = screens[p.key + "|" + t.id] else { return nil }
        if let m = priorityProblem(values["priority"], project: p.key, priorities: screen.priorities) { return ("priority", m, "Pick a priority \(p.key) uses") }
        return nil
    }

    /// RECENT in the project menu: the current project first, then others used on Jira tickets, newest first (at most 3).
    public static func recent(current: String?, used: [String], in list: [JiraProject]) -> [JiraProject] {
        var keys: [String] = []
        for v in [current].compactMap({ $0 }) + used {
            guard let p = project(v, in: list), !keys.contains(p.key) else { continue }
            keys.append(p.key)
            if keys.count == 3 { break }
        }
        return keys.compactMap { k in list.first { $0.key == k } }
    }

    /// "From your Jira (Jin Liu · updated 3 min ago)".
    public static func caption(account: String?, fetchedAt: Date, now: Date = Date()) -> String {
        let mins = max(0, Int(now.timeIntervalSince(fetchedAt) / 60))
        let ago = mins < 1 ? "just now" : mins < 60 ? "\(mins) min ago" : "\(mins / 60) h ago"
        // A long account (an email) is cut: "jin@lotusflare…".
        let who = account.map { $0.count > 14 ? String($0.prefix(14)) + "…" : $0 }
        return "From your Jira (\([who, "updated \(ago)"].compactMap { $0 }.joined(separator: " · ")))"
    }

    public static let offline = "Couldn’t reach Jira to check these"

    /// "Priority isn't used in this project".
    public static func hiddenNote(_ label: String) -> String { "\(label) isn’t used in this project" }
}

private struct JiraErrorBody: Decodable {
    struct E: Decodable { let message: String?; let jira: String? }
    let error: E?
}

extension CoreClient {
    private func jiraGet<T: Decodable>(_ path: String, as: T.Type) async throws -> T {
        let (status, data) = try await sendRaw("GET", path, body: Optional<JSONValue>.none)
        if (200..<300).contains(status) {
            do { return try JSONDecoder.core.decode(T.self, from: data) }
            catch { throw CoreClientError.badResponse("jira: \(error)") }
        }
        if let e = (try? JSONDecoder.core.decode(JiraErrorBody.self, from: data))?.error, let kind = e.jira {
            let m = e.message ?? "Jira didn’t answer."
            switch kind {
            case "not_connected", "auth_expired": throw JiraListError(problem: .notConnected(m))
            case "unreachable": throw JiraListError(problem: .unreachable(m))
            default: throw JiraListError(problem: .other(m))
            }
        }
        throw Self.apiError(status: status, data: data)
    }

    public func jiraProjects(refresh: Bool = false) async throws -> JiraProjectList {
        try await jiraGet("/v1/jira/projects" + (refresh ? "?refresh=1" : ""), as: JiraProjectList.self)
    }

    public func jiraIssueTypes(_ project: String, refresh: Bool = false) async throws -> JiraTypeList {
        try await jiraGet("/v1/jira/projects/\(Self.segment(project))/types" + (refresh ? "?refresh=1" : ""), as: JiraTypeList.self)
    }

    public func jiraCreateScreen(_ project: String, typeId: String, refresh: Bool = false) async throws -> JiraCreateScreen {
        try await jiraGet("/v1/jira/projects/\(Self.segment(project))/types/\(Self.segment(typeId))/fields" + (refresh ? "?refresh=1" : ""),
                          as: JiraCreateScreen.self)
    }
}
