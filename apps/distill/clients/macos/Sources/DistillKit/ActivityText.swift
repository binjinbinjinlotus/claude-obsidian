import Foundation

// History → Activity (canvas row 8, board Activity): the filter, the words and
// the detail facts. Pure: every function takes `now`, so tests and snapshots
// pin the clock. The core sends data (summary, type, details); the words of
// the Mac screen live here.

// MARK: - Filter

/// The Filter popover's WHAT: families of entry types.
public enum ActivityWhat: String, CaseIterable, Sendable {
    case all, chats, collectors, actions, batches, queue, settings

    public var title: String {
        switch self {
        case .all: "All"; case .chats: "Chats"; case .collectors: "Collectors"; case .actions: "Actions"
        case .batches: "Batches"; case .queue: "Queue"; case .settings: "Settings"
        }
    }

    /// The `type` filter. Notes count as Queue (a note is added to the queue), label runs as
    /// Batches (they are jobs), and keys and connections as Settings (configuration).
    public var types: [String] {
        switch self {
        case .all: []
        case .chats: ["chat"]
        case .collectors: ["collector"]
        case .actions: ["action"]
        case .batches: ["batch", "labels"]
        case .queue: ["queue", "note"]
        case .settings: ["settings", "runner", "connection"]
        }
    }
}

/// FROM: who asked.
public enum ActivityFrom: String, CaseIterable, Sendable {
    case anywhere, app, cli, agent, automatic

    public var title: String {
        switch self {
        case .anywhere: "Anywhere"; case .app: "Mac app"; case .cli: "CLI"; case .agent: "Agent"; case .automatic: "Automatic"
        }
    }

    public var source: ActivitySource? {
        switch self {
        case .anywhere: nil; case .app: .app; case .cli: .cli; case .agent: .agent; case .automatic: .scheduler
        }
    }
}

/// WHEN: how far back.
public enum ActivityWhen: String, CaseIterable, Sendable {
    case any, today, week, month

    public var title: String {
        switch self { case .any: "Any time"; case .today: "Today"; case .week: "7 days"; case .month: "30 days" }
    }

    /// Today starts at local midnight; 7 and 30 days count back from now.
    public func since(now: Date, calendar: Calendar = .current) -> Date? {
        switch self {
        case .any: nil
        case .today: calendar.startOfDay(for: now)
        case .week: now.addingTimeInterval(-7 * 86_400)
        case .month: now.addingTimeInterval(-30 * 86_400)
        }
    }
}

/// Search, the popover's three choices and switch, and "Show everything for X".
public struct ActivityFilter: Equatable, Sendable {
    public struct Object: Equatable, Sendable {
        public var id: String
        public var name: String
        public init(id: String, name: String) { self.id = id; self.name = name }
    }

    public var text = ""
    public var what: ActivityWhat = .all
    public var from: ActivityFrom = .anywhere
    public var when: ActivityWhen = .any
    public var onlyFailures = false
    /// Show everything for one chat, collector, batch, …
    public var object: Object?

    public init(text: String = "", what: ActivityWhat = .all, from: ActivityFrom = .anywhere, when: ActivityWhen = .any,
                onlyFailures: Bool = false, object: Object? = nil) {
        self.text = text; self.what = what; self.from = from; self.when = when; self.onlyFailures = onlyFailures; self.object = object
    }

    public var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    public var isActive: Bool { !trimmedText.isEmpty || !chips.isEmpty }

    public func query(now: Date, calendar: Calendar = .current, limit: Int = 50, cursor: String? = nil) -> ActivityQuery {
        ActivityQuery(types: what.types, objectID: object?.id, sources: from.source.map { [$0] } ?? [],
                      since: when.since(now: now, calendar: calendar), text: trimmedText.isEmpty ? nil : trimmedText,
                      onlyFailures: onlyFailures, limit: limit, cursor: cursor)
    }

    /// One removable chip per filter beyond the defaults: "Collectors", "From: Mac app", "When: 7 days".
    public var chips: [FacetChip] {
        var out: [FacetChip] = []
        if let object { out.append(FacetChip(section: "object", value: object.id, text: "For: \(object.name)")) }
        if what != .all { out.append(FacetChip(section: "what", value: what.rawValue, text: what.title)) }
        if from != .anywhere { out.append(FacetChip(section: "from", value: from.rawValue, text: "From: \(from.title)")) }
        if when != .any { out.append(FacetChip(section: "when", value: when.rawValue, text: "When: \(when.title)")) }
        if onlyFailures { out.append(FacetChip(section: "failed", value: "1", text: "Only failures")) }
        return out
    }

    public mutating func remove(_ chip: FacetChip) {
        switch chip.section {
        case "object": object = nil
        case "what": what = .all
        case "from": from = .anywhere
        case "when": when = .any
        case "failed": onlyFailures = false
        default: break
        }
    }

    /// Clear in the popover: the choices go back to their defaults; the search stays.
    public mutating func clearChoices() {
        what = .all; from = .anywhere; when = .any; onlyFailures = false; object = nil
    }

    /// Whether an entry that just arrived belongs in the filtered list (search is the core's: nil = ask it).
    public func matches(_ e: ActivityEntry, now: Date, calendar: Calendar = .current) -> Bool? {
        if !trimmedText.isEmpty { return nil }
        if !what.types.isEmpty && !what.types.contains(e.family) && !what.types.contains(e.type) { return false }
        if let s = from.source, e.source != s { return false }
        if let since = when.since(now: now, calendar: calendar), e.at < since { return false }
        if onlyFailures && !e.failed { return false }
        if let object, e.object.id != object.id { return false }
        return true
    }
}

// MARK: - Recovery state

/// What the detail's recovery card says, worked out from the entry, the trash
/// listing and the restore entries, so a relaunch shows the same thing.
public enum ActivityRecoveryState: Equatable, Sendable {
    /// In Distill’s trash until `expiresAt`; `keptHours` is how long a copy is kept (24 for chats closed with history off).
    case inTrash(trashID: String, expiresAt: Date?, keptHours: Int)
    /// Restored (from a `*.restored` entry with this trash id).
    case restored(at: Date, objectID: String?)
    /// The trash copy is gone: expired, or removed elsewhere.
    case trashGone(expiresAt: Date?)
    case macosTrash(path: String)
    case none(reason: String)
}

/// A restore that happened, from a `chat.restored` / `collector.restored` entry.
public struct ActivityRestore: Equatable, Sendable {
    public var at: Date
    public var objectID: String?
    public init(at: Date, objectID: String?) { self.at = at; self.objectID = objectID }

    /// trashId → restore, from successful restore entries.
    public static func index(_ entries: [ActivityEntry]) -> [String: ActivityRestore] {
        var out: [String: ActivityRestore] = [:]
        for e in entries where e.verb == "restored" && !e.failed {
            guard let id = e.string("trashId"), out[id] == nil || out[id]!.at < e.at else { continue }
            out[id] = ActivityRestore(at: e.at, objectID: e.object.id)
        }
        return out
    }
}

// MARK: - Words

public struct ActivityText: Sendable {
    public var calendar: Calendar
    public var locale: Locale
    public var collectorText: CollectorText

    public init(calendar: Calendar = .current, locale: Locale = Locale(identifier: "en_US"), home: String = NSHomeDirectory()) {
        self.calendar = calendar
        self.locale = locale
        collectorText = CollectorText(calendar: calendar, locale: locale, home: home)
    }

    // MARK: Sources

    /// The row's faint source: Mac app, CLI, Agent, Automatic, Other app, Distill.
    public func source(_ s: ActivitySource) -> String {
        switch s {
        case .app: "Mac app"
        case .cli: "CLI"
        case .agent: "Agent"
        case .scheduler: "Automatic"
        case .core: "Distill"
        default: "Other app"
        }
    }

    /// The detail's "from …": "from the Mac app", "Automatic".
    public func fromPhrase(_ s: ActivitySource) -> String {
        switch s {
        case .app: "from the Mac app"
        case .cli: "from the CLI"
        case .agent: "from an agent (the CLI in Claude Code or Codex)"
        case .scheduler: "Automatic"
        case .core: "from Distill itself"
        default: "from another app"
        }
    }

    // MARK: Times

    public func clock(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = "h:mm a"
        return f.string(from: date)
    }

    /// "Today", "Yesterday", "Sep 23", "Sep 23, 2025".
    public func day(_ date: Date, now: Date) -> String {
        if calendar.isDate(date, inSameDayAs: now) { return "Today" }
        if let y = calendar.date(byAdding: .day, value: -1, to: now), calendar.isDate(date, inSameDayAs: y) { return "Yesterday" }
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    /// "Today 7:04 PM".
    public func when(_ date: Date, now: Date) -> String { "\(day(date, now: now)) \(clock(date))" }

    /// "Nov 3" (or "Nov 3, 2027" in another year).
    public func date(_ date: Date, now: Date) -> String {
        let f = DateFormatter()
        f.locale = locale; f.calendar = calendar; f.timeZone = calendar.timeZone
        f.dateFormat = calendar.component(.year, from: date) == calendar.component(.year, from: now) ? "MMM d" : "MMM d, yyyy"
        return f.string(from: date)
    }

    /// "Today 7:04 PM · from the Mac app".
    public func detailLine(_ e: ActivityEntry, now: Date) -> String {
        "\(when(e.at, now: now)) · \(fromPhrase(e.source))"
    }

    // MARK: Day groups

    public struct Group: Equatable, Sendable, Identifiable {
        public var title: String
        public var entries: [ActivityEntry]
        public var id: String { title }
    }

    /// Newest first, under TODAY, YESTERDAY, then the date.
    public func groups(_ entries: [ActivityEntry], now: Date) -> [Group] {
        var out: [Group] = []
        for e in entries.sorted(by: { $0.id > $1.id }) {
            let title = HistoryDay.title(e.at, now: now, calendar: calendar)
            if let i = out.indices.last, out[i].title == title { out[i].entries.append(e) }
            else { out.append(Group(title: title, entries: [e])) }
        }
        return out
    }

    // MARK: Recovery

    public func recovery(_ e: ActivityEntry, trash: [String: TrashItem], restores: [String: ActivityRestore]) -> ActivityRecoveryState? {
        guard let recovery = e.recovery else { return nil }
        switch recovery {
        case .trash(let id, let expiresAt):
            if let r = restores[id] { return .restored(at: r.at, objectID: r.objectID) }
            if let item = trash[id] {
                let expires = item.expiresAt ?? expiresAt
                let hours = expires.map { max(1, Int(($0.timeIntervalSince(item.deletedAt ?? e.at) / 3600).rounded())) } ?? 30 * 24
                return .inTrash(trashID: id, expiresAt: expires, keptHours: hours)
            }
            return .trashGone(expiresAt: expiresAt)
        case .macosTrash(let path): return .macosTrash(path: path)
        case .none(let reason): return .none(reason: reason)
        case .unknown: return nil
        }
    }

    /// The row's quiet tag: "In trash" or "Restored" (nothing once the copy is gone).
    public func tag(_ state: ActivityRecoveryState?) -> String {
        switch state {
        case .inTrash: "In trash"
        case .restored: "Restored"
        default: ""
        }
    }

    /// "Kept 30 days", "Kept 24 hours".
    public func kept(hours: Int) -> String {
        if hours < 48 { return "Kept \(hours) hours" }
        let days = Int((Double(hours) / 24).rounded())
        return "Kept \(days) days"
    }

    // MARK: Facts

    public struct Fact: Equatable, Sendable, Identifiable {
        public var label: String
        public var value: String
        /// The part after "→" drawn bold (settings changes).
        public var emphasis: String?
        /// Drawn as code (the type).
        public var code = false
        public var id: String { label + "\u{1F}" + value }
        public init(_ label: String, _ value: String, emphasis: String? = nil, code: Bool = false) {
            self.label = label; self.value = value; self.emphasis = emphasis; self.code = code
        }
    }

    public struct Facts: Equatable, Sendable {
        /// WHAT WAS THERE, CHANGES, PAGES or DETAILS.
        public var heading: String
        public var rows: [Fact]
        /// A note under the rows (settings: secrets are never shown).
        public var footnote: String?
    }

    /// The detail's facts for an entry, from the keys the core writes (core/src/activity/instrument.ts).
    /// `vaultName` turns a vault path into its name.
    public func facts(_ e: ActivityEntry, now: Date, vaultName: (String) -> String = { ($0 as NSString).lastPathComponent }) -> Facts {
        var rows: [Fact] = []
        var heading = "DETAILS"
        var footnote: String?
        let name = e.object.name.map { "“\($0)”" } ?? ""
        var used: Set<String> = []
        func add(_ label: String, _ value: String?, keys: [String] = []) {
            used.formUnion(keys)
            if let value, !value.isEmpty { rows.append(Fact(label, value)) }
        }
        func whenText(_ key: String) -> String? { e.string(key).flatMap(CoreDate.parse).map { when($0, now: now) } }

        switch e.family {
        case "collector" where e.verb == "run":
            add("Collector", e.object.name)
            let trigger: String? = switch e.string("trigger") {
            case "schedule": "Scheduled"; case "catch-up": "Catch-up after sleep"; case "now": "Run now"; case let t?: t; case nil: nil
            }
            let duration = e.number("durationMs").map(seconds)
            let exit = e.int("exitCode").map { "exit \($0)" }
            add("Run", [trigger, duration, exit].compactMap { $0 }.joined(separator: " · "), keys: ["trigger", "durationMs", "exitCode", "runId"])
            let added = e.strings("filesAdded")
            add("Added", added.isEmpty ? "Nothing" : list(added), keys: ["filesAdded"])
            used.insert("result")
        case "collector":
            if ["deleted", "created", "restored"].contains(e.verb) { heading = e.verb == "deleted" ? "WHAT WAS THERE" : "DETAILS" }
            let kind = e.string("kind")
            if let kind { add("What", "\(kind == "script" ? "Script" : kind == "folder" ? "Folder" : kind.capitalized) collector \(name)", keys: ["kind"]) }
            if kind == "script" || e.details["interpreter"] != nil {
                var parts: [String] = []
                if let i = e.string("interpreter") { parts.append(i) }
                // Written in Distill (inline, or a file Distill keeps: `scriptManaged`) shows lines and size;
                // the path stays in the entry for Show in Finder. Your own file shows its path.
                if let file = e.string("scriptFile"), e.details["scriptManaged"] != .bool(true) {
                    parts.append(collectorText.tilde(file))
                } else {
                    if let lines = e.int("scriptLines") { parts.append(lines == 1 ? "1 line" : "\(lines) lines") }
                    if let bytes = e.int("scriptBytes") { parts.append(Self.size(bytes) + ", written in Distill") }
                    else if e.details["scriptManaged"] == .bool(true) { parts.append("written in Distill") }
                }
                add("Script", parts.joined(separator: " · "), keys: ["interpreter", "scriptFile", "scriptManaged", "scriptLines", "scriptBytes"])
            }
            add("Folder", e.string("folder").map(collectorText.tilde), keys: ["folder"])
            add("After", e.string("afterCollect").map { $0 == "move" ? "Moves files into the queue" : $0 == "copy" ? "Copies files into the queue" : $0 },
                keys: ["afterCollect"])
            add("Schedule", e.string("schedule").map(collectorText.schedule), keys: ["schedule"])
            add("Into", e.string("vault").map(vaultName), keys: ["vault"])
            if let last = whenText("lastRunAt") {
                let collected = e.int("collected").map { $0 == 1 ? " · 1 file collected" : " · \($0) files collected" } ?? ""
                add("Last run", last + collected, keys: ["lastRunAt", "collected"])
            } else { used.formUnion(["lastRunAt", "collected"]) }
            if e.verb == "consented" { used.insert("sha256") }
            if let from = e.string("renamedFrom") { add("Was", "“\(from)”", keys: ["renamedFrom"]) }
            if e.verb == "restored" {
                add("Deleted", whenText("deletedAt"), keys: ["deletedAt", "trashId"])
                add("Old id", e.string("previousID"), keys: ["previousID"])
            }
        case "chat":
            if ["deleted", "expired"].contains(e.verb) { heading = "WHAT WAS THERE" }
            add("What", e.object.name.map { "Ask chat “\($0)”" })
            var size: [String] = []
            if let n = e.int("turnCount") { size.append(n == 1 ? "1 question" : "\(n) questions") }
            if let b = e.int("sizeBytes") { size.append(Self.size(b)) }
            add("Size", size.joined(separator: " · "), keys: ["turnCount", "sizeBytes"])
            add("Started", whenText("createdAt"), keys: ["createdAt"])
            add("Last message", e.string("lastMessageAt").flatMap(CoreDate.parse).map { day($0, now: now) }, keys: ["lastMessageAt"])
            let why: String? = switch e.string("reason") {
            case "keep-history-off": "Closed with Keep history off"
            case "retention": "Older than Ask history keeps chats"
            default: nil
            }
            add("Why", why, keys: ["reason"])
            if e.verb == "restored" { add("Deleted", whenText("deletedAt"), keys: ["deletedAt", "trashId"]) }
        case "settings":
            heading = "CHANGES"
            // `readableChanges` (newer cores) is already in Settings' words; `changes` has the raw keys.
            let readable = e.strings("readableChanges")
            if readable.isEmpty {
                for change in e.strings("changes") { rows.append(settingsFact(change)) }
            } else {
                for line in readable { rows.append(readableSettingsFact(line)) }
            }
            used.formUnion(["changes", "readableChanges"])
            footnote = "Only what changed is listed. Keys and tokens are never shown, only that they changed."
        case "batch" where e.verb == "applied" || e.verb == "ready":
            heading = "PAGES"
            let paths = e.strings("changedPaths")
            add("Changed", paths.isEmpty ? "Nothing" : list(paths, show: 2), keys: ["changedPaths"])
            add("Operation", e.string("operationID"), keys: ["operationID"])
        case "queue":
            if e.verb == "removed" { heading = "WHAT WAS THERE" }
            add("Size", e.int("size").flatMap { $0 > 0 ? Self.size($0) : nil }, keys: ["size"])
            add("Files", e.int("fileCount").map { $0 == 1 ? "1 file" : "\($0) files" }, keys: ["fileCount"])
            used.formUnion(["path", "itemKind"])
        default:
            break
        }

        // Every other key the core wrote, as it is (a newer core's facts still show).
        for key in e.details.keys.sorted() where !used.contains(key) {
            guard let value = e.details[key], let text = plain(value) else { continue }
            rows.append(Fact(Self.label(key), text))
        }
        rows.append(Fact("Type", e.type, code: true))
        return Facts(heading: heading, rows: rows, footnote: footnote)
    }

    /// "askPreferences.keepHistory: true → false" → Keep history: On → **Off**; "x: changed" → X: Changed.
    public func settingsFact(_ change: String) -> Fact {
        guard let colon = change.firstIndex(of: ":") else { return Fact("Setting", change) }
        let key = String(change[..<colon])
        let label = Self.label(String(key.split(separator: ".").last ?? Substring(key)))
        let rest = change[change.index(after: colon)...].trimmingCharacters(in: .whitespaces)
        if let arrow = rest.range(of: " → ") {
            let old = Self.word(String(rest[..<arrow.lowerBound])), new = Self.word(String(rest[arrow.upperBound...]))
            return Fact(label, "\(old) → ", emphasis: new)
        }
        return Fact(label, rest == "changed" ? "Changed" : rest)
    }

    /// "Keep history: On → Off" → Keep history: On → **Off**; "Runner options: changed" → Runner options: Changed.
    /// The label is Settings' own and is kept as it is (it may hold a colon: "Queue folder: label automatically").
    public func readableSettingsFact(_ line: String) -> Fact {
        let head = line.range(of: " → ").map { line[..<$0.lowerBound] } ?? line[...]
        guard let colon = head.range(of: ": ", options: .backwards) else { return Fact("Setting", line) }
        let label = String(line[..<colon.lowerBound])
        let rest = String(line[colon.upperBound...])
        if let arrow = rest.range(of: " → ") {
            return Fact(label, "\(rest[..<arrow.lowerBound]) → ", emphasis: String(rest[arrow.upperBound...]))
        }
        return Fact(label, rest == "changed" ? "Changed" : rest)
    }

    // MARK: Helpers

    /// "a.md, b.md, +4 more".
    func list(_ items: [String], show: Int = 3) -> String {
        if items.count <= show { return items.joined(separator: ", ") }
        return items.prefix(show).joined(separator: ", ") + ", +\(items.count - show) more"
    }

    func seconds(_ ms: Double) -> String {
        ms < 1000 ? "\(Int(ms)) ms" : String(format: ms < 10_000 ? "%.1f s" : "%.0f s", ms / 1000)
    }

    func plain(_ v: JSONValue) -> String? {
        switch v {
        case .string(let s): return s.isEmpty ? nil : s
        case .number(let n): return n == n.rounded() && abs(n) < 1e15 ? String(Int(n)) : String(n)
        case .bool(let b): return b ? "Yes" : "No"
        case .array(let a):
            let parts = a.compactMap(plain)
            return parts.isEmpty ? nil : parts.joined(separator: ", ")
        case .object, .null: return nil
        }
    }

    public static func size(_ bytes: Int) -> String {
        let f = ByteCountFormatter()
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    /// "keepHistory" → "Keep history"; "operationID" → "Operation id".
    public static func label(_ key: String) -> String {
        var words: [String] = []
        var current = ""
        for ch in key {
            if ch == "_" || ch == "-" || ch == " " { if !current.isEmpty { words.append(current) }; current = ""; continue }
            if ch.isUppercase, let last = current.last, !last.isUppercase { words.append(current); current = "" }
            current.append(ch)
        }
        if !current.isEmpty { words.append(current) }
        let text = words.map { $0.lowercased() }.joined(separator: " ")
        return text.prefix(1).uppercased() + text.dropFirst()
    }

    /// true/false → On/Off; "—" stays.
    static func word(_ s: String) -> String {
        switch s { case "true": "On"; case "false": "Off"; default: s }
    }
}
