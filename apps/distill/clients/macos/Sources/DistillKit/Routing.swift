import Foundation

// Whose items Distill handles, Pending and Highlights (docs/specs/actions-routing.md).
// The core decides where a found item goes; this file holds the models, the People
// settings accessors and the words the screens show.

/// Settings → Actions → Whose items Distill handles: a person and the names the notes use for them.
public struct ActionPerson: Codable, Hashable, Identifiable, Sendable {
    public static let youID = "you"
    public var id: String
    public var name: String
    public var aliases: [String]

    public init(id: String, name: String, aliases: [String] = []) {
        self.id = id; self.name = name; self.aliases = aliases
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        name = c.lossy(String.self, .name) ?? ""
        aliases = c.lossyArray(String.self, .aliases)
    }

    public var isYou: Bool { id == Self.youID }
    /// "Aditya" (the chips, the Nudge greeting).
    public var firstName: String { Routing.firstName(name) }
}

/// "In the last 7 days this would have sent …".
public struct RoutingPreview: Codable, Equatable, Sendable {
    public var days: Int
    public var lists: Int
    public var waiting: Int
    public var others: Int
    public init(days: Int = 7, lists: Int, waiting: Int, others: Int) {
        self.days = days; self.lists = lists; self.waiting = waiting; self.others = others
    }
}

/// One note's Highlights: what its wiki page says, and what others are doing.
public struct HighlightNote: Codable, Hashable, Identifiable, Sendable {
    public struct Wiki: Codable, Hashable, Sendable {
        public struct Line: Codable, Hashable, Sendable {
            public var text: String
            public var line: Int
            public init(text: String, line: Int) { self.text = text; self.line = line }
        }
        public var path: String
        public var title: String
        public var summary: String?
        public var keyPoints: [Line]
        public var decisions: [Line]
        public init(path: String, title: String, summary: String? = nil, keyPoints: [Line] = [], decisions: [Line] = []) {
            self.path = path; self.title = title; self.summary = summary; self.keyPoints = keyPoints; self.decisions = decisions
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            path = try c.decode(String.self, forKey: .path)
            title = c.lossy(String.self, .title) ?? path
            summary = c.lossy(String.self, .summary)
            keyPoints = c.lossyArray(Line.self, .keyPoints)
            decisions = c.lossyArray(Line.self, .decisions)
        }
    }
    public struct Item: Codable, Hashable, Identifiable, Sendable {
        public var id: String
        public var title: String
        public var due: String?
        public var line: Int?
        /// Already in the page's Others' actions section.
        public var onPage: Bool
        public init(id: String, title: String, due: String? = nil, line: Int? = nil, onPage: Bool = false) {
            self.id = id; self.title = title; self.due = due; self.line = line; self.onPage = onPage
        }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = c.lossy(String.self, .title) ?? ""
            due = c.lossy(String.self, .due)
            line = c.lossy(Int.self, .line)
            onPage = c.lossy(Bool.self, .onPage) ?? false
        }
    }
    public struct Group: Codable, Hashable, Sendable {
        public var person: String
        public var personID: String?
        public var items: [Item]
        public init(person: String, personID: String? = nil, items: [Item]) { self.person = person; self.personID = personID; self.items = items }
    }
    public struct Waiting: Codable, Hashable, Sendable {
        public var id: String
        public var person: String
        public var what: String
        public init(id: String, person: String, what: String) { self.id = id; self.person = person; self.what = what }
    }
    public struct Yours: Codable, Hashable, Sendable {
        public var lists: [String: Int]
        public var waiting: [Waiting]
        public init(lists: [String: Int] = [:], waiting: [Waiting] = []) { self.lists = lists; self.waiting = waiting }
    }
    public struct Counts: Codable, Hashable, Sendable {
        public var others: Int
        public var decisions: Int
        public var lists: Int
        public var waiting: Int
        public init(others: Int = 0, decisions: Int = 0, lists: Int = 0, waiting: Int = 0) {
            self.others = others; self.decisions = decisions; self.lists = lists; self.waiting = waiting
        }
    }

    public var notePath: String
    public var title: String
    public var date: String
    public var kind: String
    public var duration: String?
    public var people: [String]
    public var wiki: Wiki?
    public var others: [Group]
    public var yours: Yours
    public var counts: Counts
    public var foundAt: String

    public var id: String { notePath }
    public var isMeeting: Bool { kind == "meeting" }

    public init(notePath: String, title: String, date: String, kind: String = "note", duration: String? = nil, people: [String] = [],
                wiki: Wiki? = nil, others: [Group] = [], yours: Yours = Yours(), counts: Counts = Counts(), foundAt: String = "") {
        self.notePath = notePath; self.title = title; self.date = date; self.kind = kind; self.duration = duration; self.people = people
        self.wiki = wiki; self.others = others; self.yours = yours; self.counts = counts; self.foundAt = foundAt
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        notePath = try c.decode(String.self, forKey: .notePath)
        title = c.lossy(String.self, .title) ?? notePath
        date = c.lossy(String.self, .date) ?? ""
        kind = c.lossy(String.self, .kind) ?? "note"
        duration = c.lossy(String.self, .duration)
        people = c.lossyArray(String.self, .people)
        wiki = c.lossy(Wiki.self, .wiki)
        others = c.lossyArray(Group.self, .others)
        yours = c.lossy(Yours.self, .yours) ?? Yours()
        counts = c.lossy(Counts.self, .counts) ?? Counts()
        foundAt = c.lossy(String.self, .foundAt) ?? ""
    }
}

// MARK: - Settings

extension ActionPreferences {
    /// People, the user first (an empty "you" when Settings has none).
    public var people: [ActionPerson] {
        get {
            var list: [ActionPerson] = []
            if case .array(let a)? = value(["people"]) {
                for v in a {
                    guard let data = try? JSONEncoder().encode(v), let p = try? JSONDecoder().decode(ActionPerson.self, from: data),
                          !p.id.isEmpty, !list.contains(where: { $0.id == p.id }) else { continue }
                    list.append(p)
                }
            }
            let you = list.first(where: \.isYou) ?? ActionPerson(id: ActionPerson.youID, name: "")
            return [you] + list.filter { !$0.isYou }
        }
        set {
            let values: [JSONValue] = newValue.map { p in
                .object(["id": .string(p.id), "name": .string(p.name), "aliases": .array(p.aliases.map(JSONValue.string))])
            }
            set(["people"], .array(values))
        }
    }

    /// People ids whose items of this type go to your lists (default: you).
    public func handlesFor(_ typeID: String) -> [String] {
        let ids = Set(people.map(\.id))
        guard let list = typeValue(typeID, "handlesFor")?.stringArray else { return [ActionPerson.youID] }
        return list.filter(ids.contains)
    }

    public mutating func setHandlesFor(_ typeID: String, _ ids: [String]) {
        var seen = Set<String>()
        setTypeValue(typeID, "handlesFor", .array(ids.filter { seen.insert($0).inserted }.map(JSONValue.string)))
    }

    /// Routing is on once the user has a name or an alias.
    public var routingOn: Bool {
        let you = people[0]
        return !you.name.trimmingCharacters(in: .whitespaces).isEmpty || you.aliases.contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
    }

    /// Saves a person's name as the People field saves it (trimmed; never empty for anyone but you).
    /// A person just added is kept in the page until named, so the core never sees an empty name
    /// (it drops those): their first name adds them here.
    public mutating func setName(_ person: ActionPerson, _ name: String) {
        guard people.contains(where: { $0.id == person.id }) else {
            people.append(ActionPerson(id: person.id, name: name, aliases: person.aliases))
            return
        }
        people = people.map { $0.id == person.id ? ActionPerson(id: $0.id, name: name, aliases: $0.aliases) : $0 }
    }

    /// Removes a person, and them from every type's Handles items for.
    public mutating func removePerson(_ id: String, types: [String]) {
        guard id != ActionPerson.youID else { return }
        for t in types where typeValue(t, "handlesFor") != nil { setHandlesFor(t, handlesFor(t).filter { $0 != id }) }
        people = people.filter { $0.id != id }
    }
}

// MARK: - Words

public enum Routing {
    /// "Jin Bin Liu" → "JL": first and last name (People chips).
    public static func initials(_ name: String) -> String {
        let words = name.split(whereSeparator: \.isWhitespace).filter { $0.first?.isLetter == true }
        guard let first = words.first?.first else { return "" }
        guard words.count > 1, let last = words.last?.first else { return String(first).uppercased() }
        return (String(first) + String(last)).uppercased()
    }

    public static func firstName(_ name: String) -> String {
        name.split(whereSeparator: \.isWhitespace).first.map(String.init) ?? name
    }

    /// The People name for an owner, else the name as written ("Vladan").
    public static func displayName(id: String?, written: String?, people: [ActionPerson]) -> String {
        if let id, let p = people.first(where: { $0.id == id }), !p.name.trimmingCharacters(in: .whitespaces).isEmpty { return p.name }
        if id == ActionPerson.youID { return "You" }
        let w = (written ?? "").trimmingCharacters(in: .whitespaces)
        return w.isEmpty ? "Someone" : w
    }

    public static func owner(_ item: ActionItem, people: [ActionPerson]) -> String {
        displayName(id: item.ownerID, written: item.owner, people: people)
    }

    /// "for Aditya" on a To confirm row whose owner you handle (nil for your own).
    public static func forWhom(_ item: ActionItem, people: [ActionPerson]) -> String? {
        guard item.inLists, let id = item.ownerID, id != ActionPerson.youID else { return nil }
        return "for \(firstName(displayName(id: id, written: item.owner, people: people)))"
    }

    /// Nudge's text: "Hi Aditya, any update on the ticket links?".
    public static func nudgeText(person: String, what: String) -> String {
        let first = firstName(person.trimmingCharacters(in: .whitespaces))
        let thing = what.trimmingCharacters(in: .whitespacesAndNewlines)
        return "Hi \(first.isEmpty ? "there" : first), any update on \(thing.isEmpty ? "this" : thing)?"
    }

    /// Nudge's To: "Aditya Pradhan (@aditya)" when People knows their handle, else the name.
    public static func nudgeTo(_ item: ActionItem, people: [ActionPerson]) -> String {
        let name = owner(item, people: people)
        let handle = item.ownerID.flatMap { id in people.first { $0.id == id } }?.aliases.first { $0.hasPrefix("@") }
        return handle.map { "\(name) (\($0))" } ?? name
    }

    /// The thing a promise is about: `what`, else the title.
    public static func what(_ item: ActionItem) -> String {
        if let w = item.what?.trimmingCharacters(in: .whitespaces), !w.isEmpty { return w }
        return item.title
    }

    // MARK: Settings

    /// Each type's line under Handles items for: "Your to-dos, and the ones you do for Aditya." / "Messages Jin has to send."
    public static func handlesHint(type: String, handles: [String], people: [ActionPerson]) -> String {
        let you = people.first { $0.isYou }
        let youName = you.map { firstName($0.name) }.flatMap { $0.isEmpty ? nil : $0 } ?? "you"
        let others = handles.filter { $0 != ActionPerson.youID }.compactMap { id in people.first { $0.id == id } }.map(\.firstName)
        let mine = handles.contains(ActionPerson.youID)
        if handles.isEmpty { return "Nobody’s: these go to Pending or Highlights." }
        let list = others.count <= 1 ? others.joined() : others.dropLast().joined(separator: ", ") + " and " + others.last!
        switch type {
        case "todo":
            if mine { return others.isEmpty ? "Your to-dos." : "Your to-dos, and the ones you do for \(list)." }
            return "The to-dos you do for \(list)."
        default:
            let (things, verb) = type == "slack" ? ("Messages", "send") : type == "jira" ? ("Tickets", "file") : type == "confluence" ? ("Pages", "write") : ("Items", "do")
            let who = mine ? ([youName] + others) : others
            let names = who.count <= 1 ? who.joined() : who.dropLast().joined(separator: ", ") + " and " + who.last!
            return "\(things) \(names) \(who.count == 1 && names != "you" ? "has" : "have") to \(verb)."
        }
    }

    /// "Aditya Pradhan (A)": a short alias (an initial) helps tell people apart.
    public static func chipName(_ p: ActionPerson) -> String {
        guard !p.isYou, let short = p.aliases.first(where: { $0.count <= 2 && !$0.hasPrefix("@") }) else { return p.name }
        return "\(p.name) (\(short))"
    }

    // MARK: Pending

    /// "Fri" within the coming week, else "Oct 12"; nil for no date.
    public static func by(_ due: String?, now: Date = Date()) -> String? {
        guard let due, let date = day(due) else { return nil }
        let cal = Calendar(identifier: .gregorian)
        let start = cal.startOfDay(for: now)
        let days = cal.dateComponents([.day], from: start, to: date).day ?? 0
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = cal.timeZone
        f.dateFormat = days >= 0 && days < 7 ? "EEE" : "MMM d"
        return f.string(from: date)
    }

    public static func overdue(_ due: String?, now: Date = Date()) -> Bool {
        guard let due, let date = day(due) else { return false }
        return date < Calendar(identifier: .gregorian).startOfDay(for: now)
    }

    static func day(_ s: String) -> Date? {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.calendar = Calendar(identifier: .gregorian)
        f.dateFormat = "yyyy-MM-dd"
        return f.date(from: String(s.prefix(10)))
    }

    /// "from Aditya Pradhan · promised in" (the note's name follows as a link, then " · by Fri").
    public static func pendingMeta(_ item: ActionItem, people: [ActionPerson]) -> String {
        "from \(owner(item, people: people)) · promised in"
    }

    /// "Looks received in 2026-10-06 Standup. Mark received?".
    public static func receivedLine(_ r: ActionReceived) -> String { "Looks received in \(r.noteName). Mark received?" }

    public struct PendingGroup: Identifiable, Hashable, Sendable {
        public var id: String
        public var title: String
        public var items: [ActionItem]
    }

    /// Pending grouped by person (People order, then by name) or by date (overdue, then soonest; no date last).
    public static func pendingGroups(_ items: [ActionItem], byDate: Bool, people: [ActionPerson], now: Date = Date()) -> [PendingGroup] {
        if byDate {
            let sorted = items.sorted { ($0.due ?? "9999") < ($1.due ?? "9999") || (($0.due ?? "9999") == ($1.due ?? "9999") && $0.createdAt > $1.createdAt) }
            var groups: [PendingGroup] = []
            for item in sorted {
                let key = overdue(item.due, now: now) ? "Overdue" : item.due.flatMap { by($0, now: now) } ?? "No date"
                if let k = groups.firstIndex(where: { $0.id == key }) { groups[k].items.append(item) } else { groups.append(PendingGroup(id: key, title: key, items: [item])) }
            }
            return groups
        }
        var groups: [PendingGroup] = []
        for item in items.sorted(by: { $0.createdAt > $1.createdAt }) {
            let name = owner(item, people: people)
            let key = item.ownerID ?? "name:\(name.lowercased())"
            if let k = groups.firstIndex(where: { $0.id == key }) { groups[k].items.append(item) } else { groups.append(PendingGroup(id: key, title: name, items: [item])) }
        }
        // People-list entries first, in list order; then others in the order they first appear in the notes.
        let order = { (g: PendingGroup) -> Int in people.firstIndex { $0.id == g.id } ?? people.count }
        let first = { (g: PendingGroup) -> Date in g.items.map(\.createdAt).min() ?? .distantFuture }
        return groups.sorted { order($0) != order($1) ? order($0) < order($1) : first($0) != first($1) ? first($0) < first($1) : $0.title < $1.title }
    }

    // MARK: To confirm

    /// "6 items for other people went to Highlights · 2 to Pending" for the notes of the items to confirm.
    public static func elsewhereLine(pending: [ActionItem], routed: [ActionItem]) -> String? {
        let jobs = Set(pending.compactMap(\.source.jobID))
        guard !jobs.isEmpty else { return nil }
        let mine = routed.filter { $0.source.jobID.map(jobs.contains) ?? false }
        let others = mine.filter { $0.route == .others }.count
        let waiting = mine.filter { $0.route == .waiting }.count
        guard others + waiting > 0 else { return nil }
        let items = { (n: Int) in "\(n) \(n == 1 ? "item" : "items") for other people went to" }
        if others == 0 { return "\(items(waiting)) Pending" }
        return "\(items(others)) Highlights" + (waiting > 0 ? " · \(waiting) to Pending" : "")
    }

    // MARK: Highlights

    /// "Others’ actions 5 · Decisions 2 · Your items: 3 in your lists, 2 Pending".
    public static func highlightCounts(_ n: HighlightNote) -> String {
        let yours: String
        if n.counts.lists == 0 && n.counts.waiting == 0 { yours = "none" } else {
            yours = [n.counts.lists > 0 ? "\(n.counts.lists) in your lists" : nil, n.counts.waiting > 0 ? "\(n.counts.waiting) Pending" : nil]
                .compactMap { $0 }.joined(separator: ", ")
        }
        return "Others’ actions \(n.counts.others) · Decisions \(n.counts.decisions) · Your items: \(yours)"
    }

    /// "Oct 5 · 45 min".
    public static func highlightWhen(_ n: HighlightNote) -> String {
        let date = day(n.date).map { d -> String in
            let f = DateFormatter()
            f.locale = Locale(identifier: "en_US")
            f.dateFormat = "MMM d"
            return f.string(from: d)
        } ?? n.date
        return [date, n.duration].compactMap { $0 }.joined(separator: " · ")
    }

    /// Copy as summary: Markdown of the card.
    public static func summaryMarkdown(_ n: HighlightNote, typeLabel: (String, Int) -> String) -> String {
        var out = ["# \(n.title)", ""]
        if let s = n.wiki?.summary { out += [s, ""] }
        if let kp = n.wiki?.keyPoints, !kp.isEmpty { out += ["## Key points"] + kp.map { "- \($0.text)" } + [""] }
        if let d = n.wiki?.decisions, !d.isEmpty { out += ["## Decisions"] + d.map { "- \($0.text)" } + [""] }
        if !n.others.isEmpty {
            out.append("## Others’ actions")
            for g in n.others { for i in g.items { out.append("- **\(g.person)**: \(i.title)\(i.due.map { " (by \($0))" } ?? "")") } }
            out.append("")
        }
        let lists = n.yours.lists.sorted { $0.key < $1.key }.map { typeLabel($0.key, $0.value) }
        if !lists.isEmpty || !n.yours.waiting.isEmpty {
            out.append("## Your items")
            if !lists.isEmpty { out.append("- In your lists: \(lists.joined(separator: ", "))") }
            for w in n.yours.waiting { out.append("- Pending: \(firstName(w.person)): \(w.what)") }
            out.append("")
        }
        return out.joined(separator: "\n").trimmingCharacters(in: .whitespacesAndNewlines) + "\n"
    }
}

// MARK: - Client

extension CoreClient {
    /// Whose is this?: "you", a People id or a name; nil = Not mine.
    public func assignActionOwner(_ id: String, owner: String?) async throws -> ActionItem {
        try await sendPlain("POST", "/v1/actions/\(Self.segment(id))/owner", body: JSONValue.object(["owner": owner.map(JSONValue.string) ?? .null]))
    }
    public func trackAsPending(_ id: String) async throws -> ActionItem { try await routeCall(id, "track-pending") }
    public func claimAction(_ id: String) async throws -> ActionItem { try await routeCall(id, "claim") }
    public func markReceived(_ id: String) async throws -> ActionItem { try await routeCall(id, "received") }
    public func stopWaiting(_ id: String) async throws -> ActionItem { try await routeCall(id, "stop-waiting") }

    public struct NudgeResult: Decodable, Sendable {
        public var item: ActionItem
        public var message: ActionItem
    }

    public func nudgeAction(_ id: String, to: String, text: String) async throws -> NudgeResult {
        try await sendPlain("POST", "/v1/actions/\(Self.segment(id))/nudge", body: JSONValue.object(["to": .string(to), "text": .string(text)]))
    }

    /// The 7-day preview for People being edited (nil = the saved settings).
    public func routingPreview(people: [ActionPerson]? = nil, handles: [String: [String]] = [:]) async throws -> RoutingPreview {
        var body: [String: JSONValue] = [:]
        if let people {
            body["people"] = .array(people.map { .object(["id": .string($0.id), "name": .string($0.name), "aliases": .array($0.aliases.map(JSONValue.string))]) })
        }
        if !handles.isEmpty {
            body["types"] = .object(handles.mapValues { .object(["handlesFor": .array($0.map(JSONValue.string))]) })
        }
        return try await sendPlain("POST", "/v1/actions/routing-preview", body: JSONValue.object(body))
    }

    public func highlights() async throws -> [HighlightNote] {
        try await getWrapped("/v1/highlights", LossyList<HighlightNote>.self, key: "notes").items
    }

    public func highlight(_ notePath: String) async throws -> HighlightNote {
        var c = URLComponents()
        c.queryItems = [URLQueryItem(name: "path", value: notePath)]
        return try await getPlain("/v1/highlights/note?" + (c.percentEncodedQuery ?? ""))
    }

    private func routeCall(_ id: String, _ action: String) async throws -> ActionItem {
        try await sendPlain("POST", "/v1/actions/\(Self.segment(id))/\(action)", body: JSONValue.object([:]))
    }
}
