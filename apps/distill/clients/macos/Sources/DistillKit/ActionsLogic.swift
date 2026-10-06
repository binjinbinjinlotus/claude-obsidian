import Foundation

// UI-free rules for the Actions screens (canvas row 6): counts, due dates,
// grouping, sorting, filtering, search, History wording. Times are clock
// times; nothing here ticks.

public enum ActionCounts {
    /// What an item adds to its sub-item's count: an open to-do, or a draft of
    /// another type that is ready to copy or create (canvas: SidebarStates
    /// 6 + 1 + 1 + 1). Pending items wait in "To confirm" and are not counted.
    public static func waitsOnYou(_ item: ActionItem) -> Bool {
        item.type == "todo" ? item.status == .open : item.status == .ready
    }

    /// Count per type id for the sidebar sub-items (only the given type ids).
    public static func byType(_ items: [ActionItem], types: [String]) -> [String: Int] {
        var out = Dictionary(uniqueKeysWithValues: types.map { ($0, 0) })
        for item in items where out[item.type] != nil && waitsOnYou(item) { out[item.type, default: 0] += 1 }
        return out
    }

    /// The collapsed Actions total: the sum of the sub-items.
    public static func total(_ items: [ActionItem], types: [String]) -> Int { byType(items, types: types).values.reduce(0, +) }

    /// "3 to-dos, 1 Slack message, 1 Jira ticket" (types in registry order; unknown ids by their id).
    public static func phrase(_ byType: [String: Int], types: [ActionTypeInfo]) -> String {
        var order = types.map(\.id)
        for id in byType.keys.sorted() where !order.contains(id) { order.append(id) }
        return order.compactMap { id -> String? in
            guard let n = byType[id], n > 0 else { return nil }
            return "\(n) " + noun(id, count: n, types: types)
        }.joined(separator: ", ")
    }

    /// "to-do" / "to-dos", "Slack message" / "Slack messages".
    public static func noun(_ typeID: String, count: Int, types: [ActionTypeInfo]) -> String {
        if typeID == "todo" { return count == 1 ? "to-do" : "to-dos" }
        guard let t = types.first(where: { $0.id == typeID }) else { return count == 1 ? typeID : typeID + "s" }
        return count == 1 ? t.label : t.pluralLabel
    }

    /// "Added 1 to-do and created 3 drafts".
    public static func addedPhrase(todos: Int, drafts: Int) -> String {
        let t = todos == 1 ? "1 to-do" : "\(todos) to-dos"
        let d = drafts == 1 ? "1 draft" : "\(drafts) drafts"
        switch (todos, drafts) {
        case (0, _): return "Created \(d)"
        case (_, 0): return "Added \(t)"
        default: return "Added \(t) and created \(d)"
        }
    }

    /// The job's line: "Found 5 actions to confirm" / "Added 3 to-dos and 2 drafts" / nil when nothing was found.
    public static func jobLine(_ s: JobActionsSummary) -> String? {
        switch s.status {
        case "finding": return nil
        case "failed": return "Couldn't find actions"
        default:
            if s.pending > 0 { return "Found \(s.pending) \(s.pending == 1 ? "action" : "actions") to confirm" }
            if s.found > 0 || s.added > 0 { return "Found \(max(s.found, s.added)) \(max(s.found, s.added) == 1 ? "action" : "actions")" }
            return nil
        }
    }
}

// MARK: - Due dates

public enum ActionDue {
    public enum Bucket: Int, CaseIterable, Sendable { case overdue, today, thisWeek, later, none
        public var title: String {
            switch self {
            case .overdue: "OVERDUE"; case .today: "TODAY"; case .thisWeek: "THIS WEEK"; case .later: "LATER"; case .none: "NO DUE DATE"
            }
        }
    }

    /// `due` as the core writes it: `2026-10-03`, or a full ISO-8601 time when it has one.
    public static func parse(_ raw: String?, calendar: Calendar = .current) -> (date: Date, hasTime: Bool)? {
        guard let raw = raw?.trimmingCharacters(in: .whitespaces), !raw.isEmpty else { return nil }
        if raw.count == 10 {
            let parts = raw.split(separator: "-").compactMap { Int($0) }
            guard parts.count == 3 else { return nil }
            var c = DateComponents(); c.year = parts[0]; c.month = parts[1]; c.day = parts[2]; c.hour = 12
            return calendar.date(from: c).map { ($0, false) }
        }
        return CoreDate.parse(raw).map { ($0, true) }
    }

    public static func bucket(_ raw: String?, now: Date = Date(), calendar: Calendar = .current) -> Bucket {
        guard let (date, _) = parse(raw, calendar: calendar) else { return .none }
        let today = calendar.startOfDay(for: now)
        let day = calendar.startOfDay(for: date)
        if day < today { return .overdue }
        if day == today { return .today }
        let days = calendar.dateComponents([.day], from: today, to: day).day ?? 99
        return days <= 7 ? .thisWeek : .later
    }

    /// Short label for a row: "5:00 PM" (today with a time), "Today", "Fri" (within a week), "Sep 30".
    public static func short(_ raw: String?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let (date, hasTime) = parse(raw, calendar: calendar) else { return nil }
        let f = DateFormatter(); f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        switch bucket(raw, now: now, calendar: calendar) {
        case .today:
            if hasTime { f.dateStyle = .none; f.timeStyle = .short; return f.string(from: date) }
            return "Today"
        case .thisWeek:
            f.setLocalizedDateFormatFromTemplate("EEE"); return f.string(from: date)
        default:
            f.setLocalizedDateFormatFromTemplate(sameYear(date, now, calendar) ? "MMM d" : "MMM d yyyy"); return f.string(from: date)
        }
    }

    /// Long label for the detail: "Thu, Oct 2", "Tue, Sep 30 · 2 days late".
    public static func long(_ raw: String?, now: Date = Date(), calendar: Calendar = .current, locale: Locale = .current) -> String? {
        guard let (date, _) = parse(raw, calendar: calendar) else { return nil }
        let f = DateFormatter(); f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.setLocalizedDateFormatFromTemplate(sameYear(date, now, calendar) ? "EEE MMM d" : "EEE MMM d yyyy")
        var s = f.string(from: date)
        let late = calendar.dateComponents([.day], from: calendar.startOfDay(for: date), to: calendar.startOfDay(for: now)).day ?? 0
        if late > 0 { s += " · \(late) \(late == 1 ? "day" : "days") late" }
        return s
    }

    /// `YYYY-MM-DD` for a picked day.
    public static func format(_ date: Date, calendar: Calendar = .current) -> String {
        let c = calendar.dateComponents([.year, .month, .day], from: date)
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }

    private static func sameYear(_ a: Date, _ b: Date, _ calendar: Calendar) -> Bool {
        calendar.component(.year, from: a) == calendar.component(.year, from: b)
    }
}

// MARK: - Lists

public enum ActionGrouping: String, CaseIterable, Sendable {
    case due, note, label, person, priority, created, none
    public var title: String {
        switch self {
        case .due: "Due date"; case .note: "Source note"; case .label: "Label"; case .person: "Person"
        case .priority: "Priority"; case .created: "Created"; case .none: "No groups"
        }
    }
}

public enum ActionSort: String, CaseIterable, Sendable {
    case due, priority, created, title
    public var title: String {
        switch self {
        case .due: "Due date, soonest first"; case .priority: "Priority, highest first"
        case .created: "Created, newest first"; case .title: "Title, A to Z"
        }
    }
}

public struct ActionGroup: Identifiable, Equatable, Sendable {
    public var id: String
    public var title: String
    public var items: [ActionItem]
    public init(id: String, title: String, items: [ActionItem]) { self.id = id; self.title = title; self.items = items }
}

public enum ActionList {
    /// Whether a to-do row is drawn selected. With nothing in the pane, the first row stands in for the
    /// selection; a To-confirm item in the pane is the selection, so no to-do row is drawn selected too.
    public static func todoHighlighted(_ id: String, selected: String?, paneShowsSelection: Bool, first: String?) -> Bool {
        if id == selected { return true }
        return !paneShowsSelection && id == first
    }

    public static let priorities = ["High", "Medium", "Low"]

    public static func priorityRank(_ item: ActionItem) -> Int {
        guard let p = item.field("priority")?.lowercased() else { return 3 }
        return priorities.firstIndex { $0.lowercased() == p } ?? 3
    }

    /// The note an item came from, for the row link and grouping: the page title,
    /// the note's file name, "Ask chat", or nil (added by you).
    public static func noteTitle(_ item: ActionItem) -> String? {
        switch item.source {
        case .note(_, let path, let title, _):
            if let title, !title.isEmpty { return title }
            guard let path, !path.isEmpty else { return nil }
            return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        case .ask: return "Ask chat"
        default: return nil
        }
    }

    /// People on the item (`person`, comma separated; `to` for messages).
    public static func people(_ item: ActionItem) -> [String] {
        let raw = item.field("person") ?? item.field("people") ?? ""
        return raw.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    public static func sorted(_ items: [ActionItem], by sort: ActionSort, now: Date = Date()) -> [ActionItem] {
        items.sorted { a, b in
            switch sort {
            case .due:
                let da = ActionDue.parse(a.field("due"))?.date, db = ActionDue.parse(b.field("due"))?.date
                if da != db {
                    guard let da else { return false }
                    guard let db else { return true }
                    return da < db
                }
                if priorityRank(a) != priorityRank(b) { return priorityRank(a) < priorityRank(b) }
                return a.createdAt > b.createdAt
            case .priority:
                if priorityRank(a) != priorityRank(b) { return priorityRank(a) < priorityRank(b) }
                return a.createdAt > b.createdAt
            case .created: return a.createdAt > b.createdAt
            case .title: return a.title.localizedCaseInsensitiveCompare(b.title) == .orderedAscending
            }
        }
    }

    /// Groups in display order; items sorted inside each group.
    public static func grouped(_ items: [ActionItem], by group: ActionGrouping, sort: ActionSort,
                               now: Date = Date(), calendar: Calendar = .current) -> [ActionGroup] {
        let items = sorted(items, by: sort, now: now)
        switch group {
        case .none:
            return items.isEmpty ? [] : [ActionGroup(id: "all", title: "", items: items)]
        case .due:
            return ActionDue.Bucket.allCases.compactMap { b in
                let inB = items.filter { ActionDue.bucket($0.field("due"), now: now, calendar: calendar) == b }
                return inB.isEmpty ? nil : ActionGroup(id: "due-\(b.rawValue)", title: b.title, items: inB)
            }
        case .priority:
            let names = priorities + ["None"]
            return names.enumerated().compactMap { i, name in
                let inP = items.filter { priorityRank($0) == i }
                return inP.isEmpty ? nil : ActionGroup(id: "p-\(name)", title: name.uppercased(), items: inP)
            }
        case .created:
            var out: [ActionGroup] = []
            for item in items {
                let title = HistoryDay.title(item.createdAt, now: now, calendar: calendar)
                if let i = out.firstIndex(where: { $0.title == title }) { out[i].items.append(item) }
                else { out.append(ActionGroup(id: "c-\(title)", title: title, items: [item])) }
            }
            return out
        case .note, .label, .person:
            var keys: [String: [ActionItem]] = [:]
            for item in items {
                let ks: [String]
                switch group {
                case .note: ks = [noteTitle(item) ?? "Added by you"]
                case .label: ks = item.labels.isEmpty ? ["No label"] : item.labels.map { "#" + $0 }
                default: ks = people(item).isEmpty ? ["No one"] : people(item)
                }
                for k in ks { keys[k, default: []].append(item) }
            }
            return keys.keys.sorted { $0.localizedCaseInsensitiveCompare($1) == .orderedAscending }
                .map { ActionGroup(id: "\(group.rawValue)-\($0)", title: $0.uppercased(), items: keys[$0]!) }
        }
    }
}

/// The To do filter bar: every chip is one filter; several values in one filter mean "any of these".
public struct ActionFilter: Equatable, Sendable {
    public enum Status: String, CaseIterable, Sendable {
        case open, completed, all
        public var title: String { switch self { case .open: "Open"; case .completed: "Completed"; case .all: "All" } }
    }
    public enum AddedBy: String, CaseIterable, Sendable { case distill, you }

    public var status: Status = .open
    public var due: Set<ActionDue.Bucket> = []
    public var people: Set<String> = []
    public var labels: Set<String> = []
    public var notes: Set<String> = []
    public var priorities: Set<String> = []
    public var addedBy: AddedBy?
    public var vaults: Set<String> = []
    public var jobID: String?
    public var text = ""

    public init() {}

    /// Anything beyond the default "Status: Open" and no search.
    public var isNarrowed: Bool {
        !due.isEmpty || !people.isEmpty || !labels.isEmpty || !notes.isEmpty || !priorities.isEmpty || addedBy != nil
            || !vaults.isEmpty || jobID != nil || !text.trimmingCharacters(in: .whitespaces).isEmpty
    }

    public func statusMatches(_ item: ActionItem) -> Bool {
        switch status {
        case .open: return item.status == .open
        case .completed: return item.status == .done
        case .all: return item.status == .open || item.status == .done
        }
    }

    /// Everything but status and text.
    public func facetsMatch(_ item: ActionItem, now: Date = Date()) -> Bool {
        if !due.isEmpty && !due.contains(ActionDue.bucket(item.field("due"), now: now)) { return false }
        if !people.isEmpty && Set(ActionList.people(item)).isDisjoint(with: people) { return false }
        if !labels.isEmpty && Set(item.labels).isDisjoint(with: labels) { return false }
        if !notes.isEmpty && !notes.contains(ActionList.noteTitle(item) ?? "") { return false }
        if !priorities.isEmpty && !priorities.contains(item.field("priority") ?? "None") { return false }
        if let addedBy, (addedBy == .you) != item.source.isManual { return false }
        if !vaults.isEmpty && !vaults.contains(item.vaultPath ?? "") { return false }
        if let jobID, item.source.jobID != jobID { return false }
        return true
    }

    public func matches(_ item: ActionItem, now: Date = Date()) -> Bool {
        statusMatches(item) && facetsMatch(item, now: now) && ActionSearch.match(item, text) != nil
    }
}

public enum ActionSearch {
    public enum Hit: Equatable, Sendable {
        /// The query is empty, or the title matches.
        case title
        /// Matched outside the title: the line it came from ("…bring the new tin.").
        case context(String)
    }

    /// nil = no match. Matches title, body, people, labels, the recipient and the quoted excerpt.
    public static func match(_ item: ActionItem, _ query: String) -> Hit? {
        let q = query.trimmingCharacters(in: .whitespaces)
        if q.isEmpty || item.title.localizedCaseInsensitiveContains(q) { return .title }
        let others = [item.source.quote, item.body, item.why, item.field("to"), item.field("person")]
            .compactMap { $0 } + item.labels.map { "#" + $0 }
        for text in others where text.localizedCaseInsensitiveContains(q) { return .context(excerpt(text, q)) }
        return nil
    }

    /// About 40 characters around the first match, with "…" where it was cut.
    public static func excerpt(_ text: String, _ query: String, radius: Int = 24) -> String {
        let flat = text.replacingOccurrences(of: "\n", with: " ")
        guard let r = flat.range(of: query, options: .caseInsensitive) else { return flat }
        let start = flat.index(r.lowerBound, offsetBy: -radius, limitedBy: flat.startIndex) ?? flat.startIndex
        let end = flat.index(r.upperBound, offsetBy: radius, limitedBy: flat.endIndex) ?? flat.endIndex
        return (start > flat.startIndex ? "…" : "") + flat[start..<end] + (end < flat.endIndex ? "…" : "")
    }
}

// MARK: - History

public enum HistoryDay {
    /// "TODAY", "YESTERDAY", "SEP 30", "SEP 30, 2025".
    public static func title(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "TODAY" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "YESTERDAY" }
        let f = DateFormatter(); f.locale = Locale(identifier: "en_US"); f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date).uppercased()
    }
}

public enum ActionHistory {
    /// History → Actions "What happened" filter.
    public enum What: String, CaseIterable, Sendable {
        case completed, removed, sent, markedSent, done
        public var title: String {
            switch self {
            case .completed: "Completed"; case .removed: "Removed"; case .sent: "Sent"
            case .markedSent: "Marked as sent"; case .done: "Done"
            }
        }
        public var help: String {
            switch self {
            case .completed: "To-dos you checked off"; case .removed: "Can be restored"
            case .sent: "To-dos handed to an action type"; case .markedSent: "Slack messages you posted"
            case .done: "Jira and Confluence items finished"
            }
        }
    }

    public static func what(_ item: ActionItem) -> What? {
        switch item.status {
        case .removed: return .removed
        case .done: return item.type == "todo" ? .completed : .done
        case .sent: return item.type == "todo" ? .sent : .markedSent
        default: return nil
        }
    }

    /// When it left the list: the last event of that kind, else `updatedAt`.
    public static func when(_ item: ActionItem) -> Date {
        let names: [String]
        switch item.status {
        case .removed: names = ["removed"]
        case .done: names = ["done", "status"]
        case .sent: names = ["sent"] + item.events.map(\.event).filter { $0.hasPrefix("sent-to:") }
        default: names = []
        }
        return item.events.last { names.contains($0.event) }?.at ?? item.updatedAt
    }

    /// The type an item was sent to ("sent-to:jira").
    public static func sentTo(_ item: ActionItem) -> String? {
        item.events.last { $0.event.hasPrefix("sent-to:") }.map { String($0.event.dropFirst("sent-to:".count)) }
    }

    /// "today at 4:02 PM" / "to Jira tickets today at 3:50 PM" / "in Jira · checked today at 3:55 PM" / "by you yesterday at 5:40 PM".
    public static func detail(_ item: ActionItem, types: [ActionTypeInfo], now: Date = Date()) -> String {
        let at = HistoryTime.phrase(when(item), now: now)
        switch what(item) {
        case .sent:
            if let to = sentTo(item) { return "to \(types.first { $0.id == to }?.pluralLabel ?? to) \(at)" }
            return at
        case .done:
            if item.external?.status != nil, let checked = item.external?.checkedAt {
                let label = types.first { $0.id == item.type }?.label.components(separatedBy: " ").first ?? item.type
                return "in \(label) · checked \(HistoryTime.phrase(checked, now: now))"
            }
            return "by you \(at)"
        default: return at
        }
    }

    /// Restore puts it back; a sent to-do lives on as the new item instead.
    public static func canRestore(_ item: ActionItem) -> Bool { what(item) != .sent }

    public static func groups(_ items: [ActionItem], now: Date = Date(), calendar: Calendar = .current) -> [ActionGroup] {
        var out: [ActionGroup] = []
        for item in items.sorted(by: { when($0) > when($1) }) {
            let title = HistoryDay.title(when(item), now: now, calendar: calendar)
            if let i = out.firstIndex(where: { $0.title == title }) { out[i].items.append(item) }
            else { out.append(ActionGroup(id: title, title: title, items: [item])) }
        }
        return out
    }

    /// The timeline in "What happened": one line per event, oldest first.
    public static func timeline(_ item: ActionItem, types: [ActionTypeInfo]) -> [(title: String, at: Date)] {
        let typeLabel = { (id: String) in types.first { $0.id == id }?.pluralLabel ?? id }
        let note = ActionList.noteTitle(item)
        return item.events.compactMap { e -> (String, Date)? in
            switch e.event {
            case "found":
                let what = item.type == "todo" ? "To-do" : (types.first { $0.id == item.type }?.label ?? item.type)
                let model = e.detail.map { " by \($0)" } ?? ""
                return (note.map { "\(what) found in \($0)\(model)" } ?? "Found\(model)", e.at)
            case "confirmed": return ("Added by you", e.at)
            case "drafted": return ("Written with \(e.detail ?? item.draftModel ?? "AI")", e.at)
            case "edited": return ("Edited by you", e.at)
            case "improved": return ("Improved by \(e.detail ?? item.draftModel ?? "AI")", e.at)
            case "improve-undone": return ("Improvement undone", e.at)
            case "copied": return ("Copied", e.at)
            case "created": return ("Created \(e.detail ?? item.external?.key ?? "")".trimmingCharacters(in: .whitespaces), e.at)
            case "status": return ("Status: \(e.detail ?? "")", e.at)
            case "done":
                // Complete records the status it left; Jira / Confluence's own Done reads "in Jira (Done)".
                if let d = e.detail, d.hasPrefix("in ") { return ("Done \(d)", e.at) }
                return ("Completed by you", e.at)
            case "sent": return ("Marked as sent", e.at)
            case "removed": return ("Removed by you", e.at)
            case "restored": return ("Restored", e.at)
            default:
                if e.event.hasPrefix("sent-to:") { return ("Sent to \(typeLabel(String(e.event.dropFirst(8))))", e.at) }
                return e.event.isEmpty ? nil : (e.event.prefix(1).uppercased() + e.event.dropFirst(), e.at)
            }
        }
    }
}
