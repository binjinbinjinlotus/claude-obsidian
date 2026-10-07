import Foundation

/// Track as Pending from To confirm, and Move to Pending for an added to-do (actions-routing.md): the
/// panel's prefill, who it can be, what blocks it, and the words it shows. The core keeps the item and
/// checks the same way (`POST /v1/actions/:id/track-pending {waitingOn, by?}`).
public enum TrackPending {
    /// Where the item is: To confirm (any found type) or an open to-do in your list.
    public enum Origin: Equatable, Sendable { case confirm, todo }

    public static func origin(_ item: ActionItem) -> Origin? {
        guard item.inLists else { return nil }
        if item.status == .pending { return .confirm }
        if item.type == "todo" && (item.status == .open || item.status == .ready) { return .todo }
        return nil
    }

    /// The panel's fields.
    public struct Draft: Hashable, Sendable {
        public var origin: Origin
        /// The People entry picked (or matched), else nil for a name kept as written.
        public var personID: String?
        /// What Waiting on reads: the person's name, or the name as typed.
        public var name: String
        /// YYYY-MM-DD; nil = no date.
        public var by: String?
        /// Filled from the item's owner, and from its due date (the "Filled from…" line).
        public var personFromItem: Bool
        public var byFromItem: Bool

        public init(origin: Origin, personID: String? = nil, name: String = "", by: String? = nil, personFromItem: Bool = false, byFromItem: Bool = false) {
            self.origin = origin; self.personID = personID; self.name = name; self.by = by
            self.personFromItem = personFromItem; self.byFromItem = byFromItem
        }

        /// What the core gets as `waitingOn`: the People id, else the trimmed name; nil when empty.
        public var waitingOn: String? {
            if let personID { return personID }
            let t = name.trimmingCharacters(in: .whitespacesAndNewlines)
            return t.isEmpty ? nil : t
        }
    }

    /// A To confirm item whose owner is you (or nobody named): Waiting on starts empty and required.
    public static func ownerIsYou(_ item: ActionItem) -> Bool {
        if item.ownerID == ActionPerson.youID { return true }
        return item.ownerID == nil && (item.owner ?? "").trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// Waiting on: the item's owner when it isn't you; else a to-do's person (from People when one matches);
    /// else empty. By: the due date (the to-do's, else the promise's).
    public static func prefill(_ item: ActionItem, people: [ActionPerson]) -> Draft {
        let origin = origin(item) ?? .confirm
        var d = Draft(origin: origin)
        let due = item.field("due") ?? item.due
        if let due, Routing.day(due) != nil {
            d.by = String(due.prefix(10))
            d.byFromItem = true
        }
        if !ownerIsYou(item) {
            d.personID = item.ownerID.flatMap { id in people.first { $0.id == id }?.id }
            d.name = Routing.owner(item, people: people)
            d.personFromItem = true
        } else if let written = (item.field("person") ?? item.field("to"))?.split(separator: ",").first
                    .map({ $0.trimmingCharacters(in: .whitespaces) }), !written.isEmpty {
            let id = match(written, people: people)
            if id != ActionPerson.youID {
                d.personID = id
                d.name = id.flatMap { id in people.first { $0.id == id }?.name } ?? written
                d.personFromItem = true
            }
        }
        return d
    }

    /// The People id a name matches: exact on a name or an alias, ignoring case; nil for none or two.
    public static func match(_ name: String, people: [ActionPerson]) -> String? {
        let n = name.trimmingCharacters(in: .whitespaces).lowercased()
        guard !n.isEmpty else { return nil }
        if ["me", "i", "myself", "you"].contains(n) { return ActionPerson.youID }
        let hits = people.filter { ([$0.name] + $0.aliases).contains { !$0.trimmingCharacters(in: .whitespaces).isEmpty && $0.trimmingCharacters(in: .whitespaces).lowercased() == n } }
        return hits.count == 1 ? hits[0].id : nil
    }

    /// Why the button is off, between Cancel and Track as Pending.
    public static func blockReason(_ d: Draft, people: [ActionPerson]) -> String? {
        guard let w = d.waitingOn else { return "Fill in who you’re waiting on" }
        if w == ActionPerson.youID || (d.personID == nil && match(w, people: people) == ActionPerson.youID) { return "Pick someone other than you" }
        return nil
    }

    /// The name shown for the person: the People name, else as written.
    public static func displayName(_ d: Draft, people: [ActionPerson]) -> String {
        let id = d.personID ?? match(d.name, people: people)
        return Routing.displayName(id: id, written: d.name, people: people)
    }

    /// "@aditya" from People.
    public static func handle(_ id: String?, people: [ActionPerson]) -> String? {
        id.flatMap { id in people.first { $0.id == id } }?.aliases.first { $0.hasPrefix("@") }
    }

    // MARK: Words

    public static let menuTitle = "Track as Pending…"
    public static let moveTitle = "Move to Pending…"
    public static let menuDetail = "Someone else will do it; you wait"
    public static let keyHint = "⇧⌥Return tracks as Pending…"
    public static let shortcut = "⇧⌥↩"
    public static let pickerPlaceholder = "A name from People, or type one"
    public static let pickerFootnote = "Or type any name; someone not in People is kept as written."
    /// Send to's last line when Move to Pending is offered.
    public static let sendToFootnote = "A type makes it a draft you check first; Move to Pending makes it something you wait for."

    /// The panel's title: "Track as Pending" / "Move to Pending".
    public static func title(_ d: Draft) -> String { d.origin == .confirm ? "Track as Pending" : "Move to Pending" }

    /// The panel's subtitle: "filled from the to-do", "the owner is you"; none for a to-do.
    public static func subtitle(_ item: ActionItem, _ d: Draft, typeWords: String) -> String? {
        guard d.origin == .confirm else { return nil }
        return ownerIsYou(item) ? "the owner is you" : "filled from the \(typeWords)"
    }

    /// "Filled from its owner and due date. It leaves To confirm; nothing is sent to Aditya." (To confirm, once
    /// someone is filled in).
    public static func noteLine(_ d: Draft, people: [ActionPerson]) -> String? {
        guard d.origin == .confirm, d.waitingOn != nil else { return nil }
        let from: String?
        switch (d.personFromItem, d.byFromItem && d.by != nil) {
        case (true, true): from = "Filled from its owner and due date. "
        case (true, false): from = "Filled from its owner. "
        case (false, true): from = "By is filled from its due date. "
        default: from = nil
        }
        return (from ?? "") + "It leaves To confirm; nothing is sent to \(Routing.firstName(displayName(d, people: people)))."
    }

    /// The peach note when the owner is you, quoting the note's line when there is one.
    public static func youNote(_ item: ActionItem) -> String {
        let quote = item.source.quote?.split(whereSeparator: \.isNewline).first.map { $0.trimmingCharacters(in: .whitespaces) }
            .flatMap { $0.isEmpty ? nil : $0 }
        let said = quote.map { " (“\($0)”)" } ?? ""
        return "The note says you would do this\(said), so there is no one to fill in. Pick who you are waiting on."
    }

    /// "IN PENDING IT WILL READ": the Pending row's line, "from Aditya Pradhan · promised in Testing sync · by Fri".
    public static func previewLine(_ item: ActionItem, _ d: Draft, people: [ActionPerson], now: Date = Date()) -> String {
        var row = item
        row.ownerID = d.personID ?? match(d.name, people: people)
        row.owner = d.name.trimmingCharacters(in: .whitespaces)
        let by = Routing.by(d.by, now: now).map { " · by \($0)" } ?? ""
        return Routing.pendingMeta(row, people: people) + " " + (ActionList.noteTitle(item) ?? "a note") + by
    }

    /// The By field: "Fri, Oct 9".
    public static func byLabel(_ by: String?) -> String? {
        guard let by, let date = Routing.day(by) else { return nil }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.dateFormat = "EEE, MMM d"
        return f.string(from: date)
    }

    /// The toast: "Tracked as Pending · waiting on Aditya".
    public static func toast(_ d: Draft, people: [ActionPerson]) -> String {
        "Tracked as Pending · waiting on \(Routing.firstName(displayName(d, people: people)))"
    }

    // MARK: Who

    public struct Choice: Hashable, Sendable, Identifiable {
        /// The People id, or nil for a name the note uses that isn't in People.
        public var personID: String?
        public var name: String
        public var handle: String?
        public var id: String { personID ?? "name:\(name.lowercased())" }
    }

    /// The picker's two sections: IN THIS NOTE (whose items, who they're for and who a message goes to, in
    /// the item's note, as Highlights names them; never you) and PEOPLE (everyone else in People). `typed`
    /// narrows both to names and aliases containing it.
    public static func choices(for item: ActionItem, all: [ActionItem], people: [ActionPerson], typed: String = "") -> (note: [Choice], people: [Choice]) {
        let note = noteKey(item)
        var inNote: [Choice] = []
        func add(_ id: String?, _ written: String?) {
            let w = (written ?? "").trimmingCharacters(in: .whitespaces)
            let pid = id.flatMap { id in people.first { $0.id == id }?.id } ?? match(w, people: people)
            guard pid != ActionPerson.youID, pid != nil || !w.isEmpty, !["me", "i", "myself", "you"].contains(w.lowercased()) else { return }
            let c = Choice(personID: pid, name: Routing.displayName(id: pid, written: w, people: people), handle: handle(pid, people: people))
            if !inNote.contains(where: { $0.id == c.id }) { inNote.append(c) }
        }
        if let note {
            for i in ([item] + all.filter { $0.id != item.id }) where noteKey(i) == note && i.status != .dismissed {
                add(i.ownerID, i.owner)
                add(i.owedToID, i.owedTo)
                if let to = i.field("to") ?? i.field("person") { add(nil, to) }
            }
        }
        // People-list entries first, in list order; then others as the note names them (as Highlights does).
        let order = { (c: Choice) -> Int in c.personID.flatMap { id in people.firstIndex { $0.id == id } } ?? people.count }
        inNote = inNote.enumerated().sorted { (order($0.element), $0.offset) < (order($1.element), $1.offset) }.map(\.element)
        let rest = people.filter { p in !p.isYou && !p.name.trimmingCharacters(in: .whitespaces).isEmpty && !inNote.contains { $0.personID == p.id } }
            .map { Choice(personID: $0.id, name: $0.name, handle: handle($0.id, people: people)) }
        let q = typed.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return (inNote, rest) }
        let hit = { (c: Choice) -> Bool in
            let aliases = c.personID.flatMap { id in people.first { $0.id == id }?.aliases } ?? []
            return ([c.name] + aliases).contains { $0.lowercased().contains(q) }
        }
        return (inNote.filter(hit), rest.filter(hit))
    }

    private static func noteKey(_ item: ActionItem) -> String? {
        if case .note(_, let path, let title, _) = item.source {
            if let path, !path.isEmpty { return "\(item.vaultPath ?? "")|\(path)" }
            if let title, !title.isEmpty { return "\(item.vaultPath ?? "")|title:\(title)" }
        }
        return nil
    }
}

extension CoreClient {
    /// Track as Pending from To confirm or To do: who you are waiting on (a People id or a name) and by when (nil = no date).
    public func trackAsPending(_ id: String, waitingOn: String, by: String?) async throws -> ActionItem {
        try await sendPlain("POST", "/v1/actions/\(Self.segment(id))/track-pending",
                            body: JSONValue.object(["waitingOn": .string(waitingOn), "by": by.map(JSONValue.string) ?? .null]))
    }
}
