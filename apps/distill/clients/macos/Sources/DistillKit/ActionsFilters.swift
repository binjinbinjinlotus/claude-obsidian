import Foundation

// UI-free rules for the Actions toolbar and the Filter panel (canvas v57:
// ActionsToolbar, FilterPanel). One panel per tab kind ("todo", "slack",
// "jira", "confluence", "history"); each section is one filter, several
// values in a section mean "any of these". To do keeps `ActionFilter`; the
// other tabs use `FacetFilter`.

/// One choice in a Filter panel section.
public struct FacetOption: Equatable, Hashable, Sendable, Identifiable {
    public var id: String
    public var label: String
    /// Items with this value (shown on the right); nil for fixed lists (Status, Priority, …).
    public var count: Int?
    /// A sub-heading this option sits under (MORE → ADDED BY / VAULT).
    public var group: String?
    public init(id: String, label: String? = nil, count: Int? = nil, group: String? = nil) {
        self.id = id; self.label = label ?? id; self.count = count; self.group = group
    }
}

/// One section of the Filter panel ("STATUS", "PERSON", …).
public struct FacetSection: Equatable, Sendable, Identifiable {
    public var id: String
    public var title: String
    /// Radio rows (To do's Status); every other section is checkboxes.
    public var single: Bool
    /// A search field narrows the rows (Person, Recipient, Assignee).
    public var searchPlaceholder: String?
    public var options: [FacetOption]
    public var selected: Set<String>
    public init(id: String, title: String, single: Bool = false, searchPlaceholder: String? = nil,
                options: [FacetOption], selected: Set<String> = []) {
        self.id = id; self.title = title; self.single = single; self.searchPlaceholder = searchPlaceholder
        self.options = options; self.selected = selected
    }

    /// Options before "Show all N": a section with more than 6 shows the top 5 until expanded
    /// (and while searching, everything that matches).
    public func visible(query: String = "", expanded: Bool = false) -> (rows: [FacetOption], all: Int) {
        let q = query.trimmingCharacters(in: .whitespaces)
        let matching = options.filter { q.isEmpty || searchPlaceholder == nil || $0.label.localizedCaseInsensitiveContains(q) }
        if expanded || !q.isEmpty || matching.count <= 6 { return (matching, matching.count) }
        return (Array(matching.prefix(5)), matching.count)
    }
}

/// A removable chip after the Filter button: which section and value it clears.
public struct FacetChip: Equatable, Hashable, Sendable, Identifiable {
    public var section: String
    public var value: String
    public var text: String
    public var id: String { section + "\u{1F}" + value }
    public init(section: String, value: String, text: String) { self.section = section; self.value = value; self.text = text }
}

/// The Slack, Jira, Confluence and History filters: selected values per section, and search.
public struct FacetFilter: Equatable, Sendable {
    public var selected: [String: Set<String>] = [:]
    public var text = ""
    public init(selected: [String: Set<String>] = [:], text: String = "") { self.selected = selected; self.text = text }

    /// Filters set (one per value); the button reads "Filter · N".
    public var count: Int { selected.values.reduce(0) { $0 + $1.count } }
    public var isNarrowed: Bool { count > 0 || !text.trimmingCharacters(in: .whitespaces).isEmpty }

    public func values(_ section: String) -> Set<String> { selected[section] ?? [] }

    public mutating func toggle(_ section: String, _ value: String) {
        var s = selected[section] ?? []
        if s.contains(value) { s.remove(value) } else { s.insert(value) }
        selected[section] = s.isEmpty ? nil : s
    }

    public mutating func remove(_ section: String, _ value: String) {
        selected[section]?.remove(value)
        if selected[section]?.isEmpty == true { selected[section] = nil }
    }

    /// Clear all (search stays: it is not a filter).
    public mutating func clear() { selected = [:] }
}

public enum ActionFacets {
    // MARK: Section definitions per kind

    /// (key, TITLE, search placeholder) in panel order.
    public static func layout(_ kind: String) -> [(key: String, title: String, search: String?)] {
        switch kind {
        case "slack": return [("status", "STATUS", nil), ("recipient", "RECIPIENT", "Find a person or channel"), ("note", "SOURCE NOTE", nil), ("label", "LABEL", nil)]
        case "jira": return [("status", "STATUS", nil), ("project", "PROJECT", nil), ("type", "TYPE", nil), ("priority", "PRIORITY", nil),
                             ("assignee", "ASSIGNEE", "Find a person"), ("note", "SOURCE NOTE", nil)]
        case "confluence": return [("status", "STATUS", nil), ("space", "SPACE", nil), ("note", "SOURCE NOTE", nil)]
        case "history": return [("type", "TYPE", nil), ("outcome", "OUTCOME", nil), ("date", "DATE", nil), ("source", "SOURCE", nil)]
        default: return [("status", "STATUS", nil), ("due", "DUE", nil), ("person", "PERSON", "Find a person"), ("label", "LABEL", nil),
                         ("note", "SOURCE NOTE", nil), ("priority", "PRIORITY", nil), ("more", "MORE", nil)]
        }
    }

    /// Fixed option lists (no counts); other sections list the values the items have, by count.
    public static func fixed(_ kind: String, _ key: String, types: [ActionTypeInfo] = []) -> [String]? {
        switch (kind, key) {
        case ("slack", "status"): return ["Not written", "Draft", "Ready to paste", "Copied"]
        case ("jira", "status"), ("confluence", "status"): return ["Not written", "Draft", "Created"]
        case ("history", "type"):
            let builtin = ["To do", "Slack message", "Jira ticket", "Confluence page"]
            let more = types.filter { !$0.reserved && !["todo", "slack", "jira", "confluence"].contains($0.id) }.map(\.label)
            return builtin + more
        case ("history", "outcome"): return ActionHistory.Outcome.allCases.map(\.title)
        case ("history", "date"): return HistoryDate.allCases.map(\.title)
        case ("history", "source"): return ["Notes", "Ask answers", "Added by you"]
        default: return nil
        }
    }

    /// The values an item has for one section (empty = it never matches a filter on that section).
    public static func values(_ kind: String, _ key: String, _ item: ActionItem, now: Date = Date(),
                              types: [ActionTypeInfo] = [], copied: Bool = false) -> [String] {
        switch key {
        case "status":
            if kind == "slack" {
                if item.status == .open && (item.body ?? "").isEmpty { return ["Not written"] }
                if item.status == .ready { return [copied || item.lastEvent("copied") != nil ? "Copied" : "Ready to paste"] }
                return ["Draft"]
            }
            if item.status == .created { return ["Created"] }
            if item.status == .open && (item.body ?? "").isEmpty { return ["Not written"] }
            return ["Draft"]
        case "recipient": return item.field("to").map { [$0] } ?? []
        case "note": return ActionList.noteTitle(item).map { [$0] } ?? []
        case "label": return item.labels.map { "#" + $0 }
        case "project": return item.field("project").map { [$0] } ?? []
        case "type":
            if kind == "history" {
                if item.type == "todo" { return ["To do"] }
                return [types.first { $0.id == item.type }?.label ?? defaultLabel(item.type)]
            }
            return item.field("issueType").map { [$0] } ?? []
        case "priority": return item.field("priority").map { [$0] } ?? []
        case "assignee": return [item.field("assignee") ?? "Unassigned"]
        case "space": return item.field("space").map { [$0] } ?? []
        case "outcome": return ActionHistory.outcome(item).map { [$0.title] } ?? []
        case "date":
            let when = ActionHistory.whenOutcome(item)
            return HistoryDate.allCases.filter { $0.contains(when, now: now) }.map(\.title)
        case "source":
            switch item.source {
            case .note: return ["Notes"]
            case .ask: return ["Ask answers"]
            case .manual: return ["Added by you"]
            default: return []
            }
        default: return []
        }
    }

    private static func defaultLabel(_ id: String) -> String {
        switch id {
        case "slack": return "Slack message"; case "jira": return "Jira ticket"; case "confluence": return "Confluence page"
        default: return id
        }
    }

    // MARK: Matching, sections, chips

    public static func matches(_ kind: String, _ filter: FacetFilter, _ item: ActionItem, now: Date = Date(),
                               types: [ActionTypeInfo] = [], copied: Bool = false) -> Bool {
        for (key, wanted) in filter.selected where !wanted.isEmpty {
            if Set(values(kind, key, item, now: now, types: types, copied: copied)).isDisjoint(with: wanted) { return false }
        }
        return ActionSearch.match(item, filter.text) != nil
    }

    /// The panel's sections: fixed lists as designed, the others from the items (most used first).
    public static func sections(_ kind: String, items: [ActionItem], filter: FacetFilter, now: Date = Date(),
                                types: [ActionTypeInfo] = [], copied: Set<String> = []) -> [FacetSection] {
        layout(kind).map { key, title, search in
            let selected = filter.values(key)
            var options: [FacetOption]
            if let fixed = fixed(kind, key, types: types) {
                options = fixed.map { FacetOption(id: $0) }
            } else {
                var counts: [String: Int] = [:]
                for item in items {
                    for v in values(kind, key, item, now: now, types: types, copied: copied.contains(item.id)) { counts[v, default: 0] += 1 }
                }
                options = counted(counts).map { FacetOption(id: $0.0, count: $0.1) }
            }
            // A selected value no item has any more still shows, so it can be cleared.
            for v in selected.sorted() where !options.contains(where: { $0.id == v }) { options.append(FacetOption(id: v, count: 0)) }
            return FacetSection(id: key, title: title, searchPlaceholder: search, options: options, selected: selected)
        }
    }

    /// One chip per value, in panel order: plain for status-like values ("Draft", "Completed",
    /// "This week"), "#label" for labels, "Section: value" for the rest.
    public static func chips(_ kind: String, _ filter: FacetFilter, types: [ActionTypeInfo] = []) -> [FacetChip] {
        layout(kind).flatMap { key, title, _ -> [FacetChip] in
            let order = fixed(kind, key, types: types) ?? []
            return filter.values(key).sorted { (order.firstIndex(of: $0) ?? 99, $0) < (order.firstIndex(of: $1) ?? 99, $1) }.map { v in
                FacetChip(section: key, value: v, text: chipText(key, title, v))
            }
        }
    }

    static func chipText(_ key: String, _ title: String, _ value: String) -> String {
        switch key {
        case "status", "outcome", "date", "type", "source", "label": return value
        case "recipient": return "To: \(value)"
        case "note": return "Note: \(value)"
        default: return title.prefix(1) + title.dropFirst().lowercased() + ": \(value)"
        }
    }

    static func counted(_ counts: [String: Int]) -> [(String, Int)] {
        counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key.localizedCaseInsensitiveCompare($1.key) == .orderedAscending }
            .map { ($0.key, $0.value) }
    }

    // MARK: To do (ActionFilter)

    /// Due options, in order (ActionDue buckets).
    public static let dueOptions: [(ActionDue.Bucket, String)] = [(.overdue, "Overdue"), (.today, "Today"), (.thisWeek, "This week"),
                                                                  (.later, "Later"), (.none, "No due date")]

    /// To do's panel: Status (single), Due, Person (search), Label, Source note, Priority, More.
    public static func todoSections(_ todos: [ActionItem], filter: ActionFilter) -> [FacetSection] {
        let scope = todos.filter { filter.statusMatches($0) }
        func count(_ f: (ActionItem) -> [String]) -> [FacetOption] {
            var c: [String: Int] = [:]
            for item in scope { for v in f(item) { c[v, default: 0] += 1 } }
            return counted(c).map { FacetOption(id: $0.0, count: $0.1) }
        }
        func keep(_ options: [FacetOption], _ selected: Set<String>) -> [FacetOption] {
            options + selected.sorted().filter { s in !options.contains { $0.id == s } }.map { FacetOption(id: $0, count: 0) }
        }
        var more: [FacetOption] = [FacetOption(id: "added:distill", label: "Distill", group: "ADDED BY"),
                                   FacetOption(id: "added:you", label: "You", group: "ADDED BY")]
        let vaults = Array(Set(todos.compactMap(\.vaultPath))).sorted()
        more += vaults.map { FacetOption(id: "vault:" + $0, label: ($0 as NSString).lastPathComponent, group: "VAULT") }
        if filter.jobID != nil { more.append(FacetOption(id: "job", label: "Only from the last batch", group: "")) }
        var moreSelected: Set<String> = Set(filter.vaults.map { "vault:" + $0 })
        if let a = filter.addedBy { moreSelected.insert("added:" + a.rawValue) }
        if filter.jobID != nil { moreSelected.insert("job") }
        let labels = Set(filter.labels.map { "#" + $0 })
        return [
            FacetSection(id: "status", title: "STATUS", single: true, options: ActionFilter.Status.allCases.map { FacetOption(id: $0.rawValue, label: $0.title) },
                         selected: [filter.status.rawValue]),
            FacetSection(id: "due", title: "DUE", options: dueOptions.map { FacetOption(id: $0.1) },
                         selected: Set(dueOptions.filter { filter.due.contains($0.0) }.map(\.1))),
            FacetSection(id: "person", title: "PERSON", searchPlaceholder: "Find a person", options: keep(count { ActionList.people($0) }, filter.people), selected: filter.people),
            FacetSection(id: "label", title: "LABEL", options: keep(count { $0.labels.map { "#" + $0 } }, labels), selected: labels),
            FacetSection(id: "note", title: "SOURCE NOTE", options: keep(count { ActionList.noteTitle($0).map { [$0] } ?? [] }, filter.notes), selected: filter.notes),
            FacetSection(id: "priority", title: "PRIORITY", options: (ActionList.priorities + ["None"]).map { FacetOption(id: $0) }, selected: filter.priorities),
            FacetSection(id: "more", title: "MORE", options: more, selected: moreSelected),
        ]
    }

    /// To do's chips: Status only when it isn't the default Open.
    public static func todoChips(_ filter: ActionFilter) -> [FacetChip] {
        var out: [FacetChip] = []
        if filter.status != .open { out.append(FacetChip(section: "status", value: filter.status.rawValue, text: "Status: \(filter.status.title)")) }
        for (b, title) in dueOptions where filter.due.contains(b) { out.append(FacetChip(section: "due", value: title, text: "Due: \(title)")) }
        for p in filter.people.sorted() { out.append(FacetChip(section: "person", value: p, text: "Person: \(p.hasPrefix("You") ? "You" : p)")) }
        for l in filter.labels.sorted() { out.append(FacetChip(section: "label", value: "#" + l, text: "#" + l)) }
        for n in filter.notes.sorted() { out.append(FacetChip(section: "note", value: n, text: "Note: \(n)")) }
        for p in (ActionList.priorities + ["None"]) where filter.priorities.contains(p) { out.append(FacetChip(section: "priority", value: p, text: "Priority: \(p)")) }
        if let a = filter.addedBy { out.append(FacetChip(section: "more", value: "added:" + a.rawValue, text: a == .you ? "Added by you" : "Added by Distill")) }
        for v in filter.vaults.sorted() { out.append(FacetChip(section: "more", value: "vault:" + v, text: (v as NSString).lastPathComponent)) }
        if filter.jobID != nil { out.append(FacetChip(section: "more", value: "job", text: "This batch")) }
        return out
    }
}

extension ActionFilter {
    /// Filters beyond the default Status: Open (one per chip); the button reads "Filter · N".
    public var count: Int { ActionFacets.todoChips(self).count }

    /// A row clicked in the panel (or a chip's ×): status picks, everything else toggles.
    public mutating func toggle(_ section: String, _ value: String) {
        func flip<T: Hashable>(_ set: inout Set<T>, _ v: T) { if set.contains(v) { set.remove(v) } else { set.insert(v) } }
        switch section {
        case "status": status = Status(rawValue: value) ?? .open
        case "due": if let b = ActionFacets.dueOptions.first(where: { $0.1 == value })?.0 { flip(&due, b) }
        case "person": flip(&people, value)
        case "label": flip(&labels, value.hasPrefix("#") ? String(value.dropFirst()) : value)
        case "note": flip(&notes, value)
        case "priority": flip(&priorities, value)
        case "more":
            if value.hasPrefix("added:") {
                let a = AddedBy(rawValue: String(value.dropFirst(6)))
                addedBy = addedBy == a ? nil : a
            } else if value.hasPrefix("vault:") {
                flip(&vaults, String(value.dropFirst(6)))
            } else if value == "job" {
                jobID = nil
            }
        default: break
        }
    }

    /// A chip's ×: Status goes back to Open; the rest toggles off.
    public mutating func remove(_ chip: FacetChip) {
        if chip.section == "status" { status = .open } else { toggle(chip.section, chip.value) }
    }

    /// Clear all: back to Status: Open, nothing else (search stays).
    public mutating func clearFilters() {
        let q = text
        self = ActionFilter()
        text = q
    }
}

// MARK: - History dates (presets only)

public enum HistoryDate: String, CaseIterable, Sendable {
    case today, thisWeek, last30
    public var title: String { switch self { case .today: "Today"; case .thisWeek: "This week"; case .last30: "Last 30 days" } }

    /// Today: since midnight; This week: the last 7 days; Last 30 days: the last 30.
    public func contains(_ date: Date, now: Date = Date(), calendar: Calendar = .current) -> Bool {
        let today = calendar.startOfDay(for: now)
        let days: Int
        switch self { case .today: days = 0; case .thisWeek: days = 6; case .last30: days = 29 }
        guard let start = calendar.date(byAdding: .day, value: -days, to: today) else { return false }
        return date >= start
    }
}

// MARK: - History outcomes

extension ActionHistory {
    /// History → Actions OUTCOME: Completed (handled, any type, by you), Sent (to another
    /// type, or marked as sent), Created (Jira / Confluence reported Done by itself),
    /// Removed, Dismissed (found but not added).
    public enum Outcome: String, CaseIterable, Sendable {
        case completed, sent, created, removed, dismissed
        public var title: String {
            switch self { case .completed: "Completed"; case .sent: "Sent"; case .created: "Created"; case .removed: "Removed"; case .dismissed: "Dismissed" }
        }
        public var help: String {
            switch self {
            case .completed: "Handled: any type, by you"; case .sent: "To-dos handed to an action type"
            case .created: "Jira and Confluence items created"; case .removed: "Can be restored"; case .dismissed: "Found but not added"
            }
        }
    }

    public static func outcome(_ item: ActionItem) -> Outcome? {
        switch item.status {
        case .removed: return .removed
        case .dismissed: return .dismissed
        case .sent: return .sent
        case .done: return isAutomaticDone(item) ? .created : .completed
        default: return nil
        }
    }

    /// Done because Jira or Confluence said so on refresh ("in Jira (Done)"), not by Complete.
    public static func isAutomaticDone(_ item: ActionItem) -> Bool {
        guard item.status == .done, let detail = item.lastEvent("done")?.detail else { return false }
        return detail.hasPrefix("in ")
    }

    /// Restore puts it back (Completed, Created, Removed, Dismissed, a message marked as sent);
    /// a to-do sent to another type lives on as that item instead.
    public static func canRestoreOutcome(_ item: ActionItem) -> Bool {
        guard let o = outcome(item) else { return false }
        return o != .sent || sentTo(item) == nil
    }

    /// The row's second line: "Completed by you yesterday at 5:40 PM", "Sent to Jira tickets today at 3:50 PM",
    /// "Marked as sent …", "Done in Jira · checked …", "Removed today at 4:02 PM", "Dismissed …".
    public static func outcomeLine(_ item: ActionItem, types: [ActionTypeInfo], now: Date = Date()) -> String {
        let at = HistoryTime.phrase(whenOutcome(item), now: now)
        switch outcome(item) {
        case .completed: return "Completed by you \(at)"
        case .sent:
            if let to = sentTo(item) { return "Sent to \(types.first { $0.id == to }?.pluralLabel ?? to) \(at)" }
            return "Marked as sent \(at)"
        case .created:
            let label = types.first { $0.id == item.type }?.label.components(separatedBy: " ").first ?? item.type
            return "Done in \(label) · checked \(HistoryTime.phrase(item.external?.checkedAt ?? whenOutcome(item), now: now))"
        case .removed: return "Removed \(at)"
        case .dismissed: return "Dismissed \(at)"
        case nil: return at
        }
    }

    /// When it left the list (dismissed included).
    public static func whenOutcome(_ item: ActionItem) -> Date {
        if item.status == .dismissed { return item.lastEvent("dismissed")?.at ?? item.updatedAt }
        return when(item)
    }
}

// MARK: - Toolbar fit (one line at any window width)

/// How the Actions toolbar fits one line: search, Filter, chips, "+N", a flexible gap, the right slot.
/// Widths are measured by the app; this only decides. Degrade order: chips collapse into "+N",
/// then the search narrows (160, then 140), then the right slot drops its status text.
public struct ToolbarFit: Equatable, Sendable {
    public var searchWidth: Double
    public var compactRight: Bool
    public var visibleChips: Int

    public init(searchWidth: Double, compactRight: Bool, visibleChips: Int) {
        self.searchWidth = searchWidth; self.compactRight = compactRight; self.visibleChips = visibleChips
    }

    /// Spacing between toolbar items, and the gap's minimum width.
    public static let gap = 6.0, minGap = 8.0

    /// - total: the bar's width; search: the designed search width; filter: the Filter button;
    ///   right / rightCompact: the right slot with and without its status text (0 for none);
    ///   chips: each chip's width; plus: the "+N" chip's width for N hidden.
    public static func plan(total: Double, search: Double, filter: Double, right: Double, rightCompact: Double,
                            chips: [Double], plus: (Int) -> Double) -> ToolbarFit {
        var candidates: [(Double, Bool)] = [(search, false)]
        for w in [160.0, 140.0] where w < search { candidates.append((w, false)) }
        candidates.append((min(search, 140), true))

        func visible(_ sw: Double, _ compact: Bool) -> (count: Int, room: Double) {
            let fixed = sw + gap + filter + gap + minGap + gap + (compact ? rightCompact : right)
            let room = total - fixed
            var used = 0.0, k = 0
            for (i, w) in chips.enumerated() {
                let hidden = chips.count - i - 1
                let need = used + w + gap + (hidden > 0 ? plus(hidden) + gap : 0)
                if need > room { break }
                used += w + gap
                k = i + 1
            }
            return (k, room)
        }
        // The right slot keeps its status text while anything else can give.
        let full = candidates.filter { !$0.1 }
        for (sw, compact) in full {
            let v = visible(sw, compact)
            if v.count == chips.count && v.room >= 0 { return ToolbarFit(searchWidth: sw, compactRight: compact, visibleChips: v.count) }
        }
        // Not everything fits: the widest search that still shows "+N"; the compact right slot last.
        for (sw, compact) in full.dropFirst() + candidates.filter(\.1) {
            let v = visible(sw, compact)
            let needPlus = chips.isEmpty ? 0 : plus(chips.count - v.count) + gap
            if v.count > 0 || v.room >= needPlus { return ToolbarFit(searchWidth: sw, compactRight: compact, visibleChips: v.count) }
        }
        let last = candidates[candidates.count - 1]
        return ToolbarFit(searchWidth: last.0, compactRight: last.1, visibleChips: visible(last.0, last.1).count)
    }
}
