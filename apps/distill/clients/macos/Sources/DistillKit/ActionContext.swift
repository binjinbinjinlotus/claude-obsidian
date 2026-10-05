import Foundation

// Action context (docs/specs/action-context.md, contracts.ts → ActionRawRef / ActionWikiRef):
// where in the ORIGINAL source an action comes from, and the wiki pages it relates to. They live
// inside the item's `source` object (`source.raw`, `source.wiki`, `source.contextNote`); the
// positional `ActionSource` enum is left as it is and `ActionItem.context` reads them from the
// same object. All of it is optional: older items have none of it.

/// `ActionRawRef`: the original's lines, located by the core (never taken from the model).
public struct ActionRawRef: Codable, Hashable, Sendable {
    /// Vault-relative: `.raw/captured/<sha>.<ext>` once archived, else where the source was (inbox/…).
    public var path: String
    public var inboxPath: String?
    public var sha256: String?
    /// 1-based, inclusive. Nil when the lines aren't known (`match` none) or the stored value was malformed.
    public var lines: ClosedRange<Int>?
    public var excerpt: String?
    /// quote | closest | none (raw; unknown values kept).
    public var match: String?

    public init(path: String, inboxPath: String? = nil, sha256: String? = nil, lines: ClosedRange<Int>? = nil,
                excerpt: String? = nil, match: String? = nil) {
        self.path = path; self.inboxPath = inboxPath; self.sha256 = sha256; self.lines = lines
        self.excerpt = excerpt; self.match = match
    }

    enum CodingKeys: String, CodingKey { case path, inboxPath, sha256, lines, excerpt, match }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let p = c.lossy(String.self, .path), !p.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "raw ref without a path")
        }
        path = p
        inboxPath = c.lossy(String.self, .inboxPath)
        sha256 = c.lossy(String.self, .sha256)
        excerpt = c.lossy(String.self, .excerpt)
        match = c.lossy(String.self, .match)
        lines = Self.range(c.lossy(JSONValue.self, .lines))
    }

    /// `[from, to]`: two positive integers, from ≤ to; anything else is dropped.
    static func range(_ v: JSONValue?) -> ClosedRange<Int>? {
        guard case .array(let a)? = v, a.count == 2, let f = a[0].doubleValue, let t = a[1].doubleValue,
              f.rounded() == f, t.rounded() == t, f >= 1, t >= f else { return nil }
        return Int(f)...Int(t)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(inboxPath, forKey: .inboxPath)
        try c.encodeIfPresent(sha256, forKey: .sha256)
        if let lines { try c.encode([lines.lowerBound, lines.upperBound], forKey: .lines) }
        try c.encodeIfPresent(excerpt, forKey: .excerpt)
        try c.encodeIfPresent(match, forKey: .match)
    }

    /// The quoted words were found on these lines.
    public var isQuote: Bool { match == nil ? lines != nil : match == "quote" }
    /// Ask: the lines sharing the most words (not a quote).
    public var isClosest: Bool { match == "closest" }

    /// "lines 210–214", "line 215", or nil.
    public var linesText: String? {
        guard let lines else { return nil }
        return lines.count == 1 ? "line \(lines.lowerBound)" : "lines \(lines.lowerBound)–\(lines.upperBound)"
    }

    /// The excerpt split into numbered lines (first number = `lines.lowerBound`).
    public var numberedLines: [(Int, String)] {
        guard let excerpt, !excerpt.isEmpty else { return [] }
        let start = lines?.lowerBound ?? 1
        return excerpt.components(separatedBy: "\n").enumerated().map { (start + $0.offset, $0.element) }
    }

    /// Candidate files to open, in order: the archive (`path`), then where it was found (`inboxPath`).
    public func candidates(vault: String) -> [String] {
        var out: [String] = []
        for p in [path, inboxPath].compactMap({ $0 }) where !p.isEmpty {
            let full = p.hasPrefix("/") ? p : URL(fileURLWithPath: vault).appendingPathComponent(p).path
            if !out.contains(full) { out.append(full) }
        }
        return out
    }

    /// The first candidate that exists, or nil: "The original is gone".
    public func resolve(vault: String, exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> String? {
        candidates(vault: vault).first(where: exists)
    }
}

/// `ActionWikiRef`: a wiki page (and section) the action relates to.
public struct ActionWikiRef: Codable, Hashable, Sendable {
    public var path: String
    public var title: String?
    public var heading: String?
    public var excerpt: String?

    public init(path: String, title: String? = nil, heading: String? = nil, excerpt: String? = nil) {
        self.path = path; self.title = title; self.heading = heading; self.excerpt = excerpt
    }

    enum CodingKeys: String, CodingKey { case path, title, heading, excerpt }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let p = c.lossy(String.self, .path), !p.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .path, in: c, debugDescription: "wiki ref without a path")
        }
        path = p
        title = c.lossy(String.self, .title)
        heading = c.lossy(String.self, .heading)
        excerpt = c.lossy(String.self, .excerpt)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(title, forKey: .title)
        try c.encodeIfPresent(heading, forKey: .heading)
        try c.encodeIfPresent(excerpt, forKey: .excerpt)
    }

    /// "Tomasz and Jin · Sep 30" (title, else the file name).
    public var pageName: String {
        if let title, !title.isEmpty { return title }
        return ((path as NSString).lastPathComponent as NSString).deletingPathExtension
    }
}

/// The context keys of an item's `source`.
public struct ActionContextRefs: Codable, Hashable, Sendable {
    public var raw: ActionRawRef?
    public var wiki: [ActionWikiRef]
    /// Why there is no `raw`, in plain words.
    public var note: String?

    public init(raw: ActionRawRef? = nil, wiki: [ActionWikiRef] = [], note: String? = nil) {
        self.raw = raw; self.wiki = wiki; self.note = note
    }

    public static let none = ActionContextRefs()
    public var isEmpty: Bool { raw == nil && wiki.isEmpty && note == nil }
    /// From the wiki only: no original lines to show.
    public var isWikiOnly: Bool { raw?.lines == nil && !wiki.isEmpty }

    enum CodingKeys: String, CodingKey { case raw, wiki, contextNote }

    public init(from decoder: Decoder) throws {
        guard let c = try? decoder.container(keyedBy: CodingKeys.self) else { self = .none; return }
        raw = c.lossy(ActionRawRef.self, .raw)
        wiki = c.lossyArray(ActionWikiRef.self, .wiki)
        note = c.lossy(String.self, .contextNote)
    }

    /// Writes into the `source` object (alongside the source's own keys).
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(raw, forKey: .raw)
        if !wiki.isEmpty { try c.encode(wiki, forKey: .wiki) }
        try c.encodeIfPresent(note, forKey: .contextNote)
    }
}

/// `JobActionProposal`: one action a batch found, as Review shows it (GET /v1/jobs/:id/actions).
public struct JobActionProposal: Codable, Hashable, Identifiable, Sendable {
    public var item: ActionItem
    public var file: String
    public var page: String?
    /// waiting | added | duplicate | notApplied (raw).
    public var state: String
    public var existingID: String?

    public var id: String { item.id }

    public init(item: ActionItem, file: String, page: String? = nil, state: String = "waiting", existingID: String? = nil) {
        self.item = item; self.file = file; self.page = page; self.state = state; self.existingID = existingID
    }

    enum CodingKeys: String, CodingKey { case item, file, page, state, existingID }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        item = try c.decode(ActionItem.self, forKey: .item)
        file = c.lossy(String.self, .file) ?? ""
        page = c.lossy(String.self, .page)
        state = c.lossy(String.self, .state) ?? "waiting"
        existingID = c.lossy(String.self, .existingID)
    }

    public var isLeftOut: Bool { state == "notApplied" }
    public var isDuplicate: Bool { state == "duplicate" }
}

/// `JobActions`: `{summary, proposals}`.
public struct JobActions: Codable, Hashable, Sendable {
    public var summary: JobActionsSummary?
    public var proposals: [JobActionProposal]

    public init(summary: JobActionsSummary? = nil, proposals: [JobActionProposal] = []) {
        self.summary = summary; self.proposals = proposals
    }

    enum CodingKeys: String, CodingKey { case summary, proposals }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        summary = c.lossy(JobActionsSummary.self, .summary)
        proposals = c.lossyArray(JobActionProposal.self, .proposals)
    }

    /// Shown in Review: everything but the duplicates (they are counted, not listed).
    public var shown: [JobActionProposal] { proposals.filter { !$0.isDuplicate } }
}

/// Plain words for the preview (shared by To confirm, Ask and Review).
public enum ActionContextText {
    /// "Tomasz and Jin" from a source path / page title.
    public static func sourceName(_ item: ActionItem) -> String? {
        switch item.source {
        case .note(_, let path, let title, _):
            if let title, !title.isEmpty { return title }
            if let path { return ((path as NSString).lastPathComponent as NSString).deletingPathExtension }
            return item.context.raw.map { (($0.inboxPath ?? $0.path) as NSString).lastPathComponent }
        case .ask(_, _, _, let cited, _, _):
            if let w = item.context.wiki.first { return w.pageName }
            return cited.first.map { (($0 as NSString).lastPathComponent as NSString).deletingPathExtension }
        default: return nil
        }
    }

    /// "Jira ticket · PAY · Task", "Slack message · to Mei", "To-do · due 2026-10-09".
    public static func target(_ item: ActionItem, typeLabel: String) -> String {
        var parts = [item.type == "todo" ? "To-do" : typeLabel]
        switch item.type {
        case "jira":
            if let p = item.field("project") { parts.append(p) }
            if let t = item.field("issueType") { parts.append(t) }
        case "confluence":
            if let s = item.field("space") { parts.append(s) }
        case "slack":
            if let to = item.field("to") { parts.append("to \(to)") }
        default:
            if let due = item.field("due") { parts.append("due \(due)") }
        }
        return parts.joined(separator: " · ")
    }

    /// What Create draft (or Add) will do, in plain words.
    public static func willWrite(_ item: ActionItem, typeLabel: String, model: String, contextLines: Int = 25) -> String {
        if item.type == "todo" { return "Add puts it in To do as it is. Nothing is written by AI." }
        // Type labels name products ("Jira ticket", "Slack message"): kept as they are.
        let what = typeLabel
        var from: [String] = []
        if let r = item.context.raw, let l = r.lines {
            from.append("lines \(max(1, l.lowerBound - contextLines))–\(l.upperBound + contextLines) of the original")
        }
        let w = item.context.wiki.count
        if w > 0 { from.append(w == 1 ? "1 wiki section" : "\(min(w, 3)) wiki sections") }
        if from.isEmpty { from.append(item.source.quote != nil ? "the quoted lines and the note" : "the item") }
        let tail: String
        switch item.type {
        case "jira": tail = "Nothing is created in Jira until you click Create in Jira."
        case "confluence": tail = "Nothing is created in Confluence until you click Create in Confluence."
        case "slack": tail = "Nothing is sent: you copy it into Slack."
        default: tail = "Nothing leaves Distill until you act on it."
        }
        let article = what.first.map { "aeiou".contains($0) } == true ? "An" : "A"
        return "\(article) \(what) draft with \(model), from \(from.joined(separator: " and ")). \(tail)"
    }

    /// Fields with values, and the type's fields still empty ("not set yet").
    public static func fields(_ item: ActionItem, specs: [ActionFieldSpec]) -> (set: [(String, String)], unset: [String]) {
        var set: [(String, String)] = []
        var unset: [String] = []
        for f in specs {
            if let v = item.field(f.key) { set.append((f.label, v)) } else { unset.append(f.label) }
        }
        let known = Set(specs.map(\.key))
        for k in item.fields.keys.sorted() where !known.contains(k) { if let v = item.field(k) { set.append((k.capitalized, v)) } }
        return (set, unset)
    }
}

/// Words for Review's "Actions found" group (canvas ActionContext, frames C and D).
public enum ReviewActionsWords {
    static func n(_ v: Int) -> String {
        let f = NumberFormatter(); f.numberStyle = .decimal; f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: v)) ?? "\(v)"
    }

    static func plural(_ count: Int, _ one: String) -> String { "\(count) \(count == 1 ? one : one + "s")" }

    /// "Looking for actions in 3 sources · lines 1–1,380 of 2,243".
    public static func finding(_ s: JobActionsSummary?, sources fallback: Int) -> String {
        var out = "Looking for actions in \(plural(max(s?.sources ?? fallback, 1), "source"))"
        if let of = s?.linesOf, of > 0 {
            let done = s?.lines ?? 0
            out += done > 0 ? " · lines 1–\(n(done)) of \(n(of))" : " · \(n(of)) lines"
        }
        return out
    }

    /// The group header's summary: "3 go to To confirm", "3 are added when you approve", "in Actions".
    public static func headerSummary(waiting: Int, added: Int, confirm: Bool) -> String {
        if waiting == 0 { return added > 0 ? "in Actions" : "" }
        return confirm ? "\(waiting) go to To confirm" : "\(waiting) \(waiting == 1 ? "is" : "are") added when you approve"
    }

    /// "Looked through 2,243 of 2,243 lines. They go to To confirm when you approve; 1 was already in Actions and isn’t shown again."
    public static func footer(_ s: JobActionsSummary?, confirm: Bool, applied: Bool) -> String {
        var parts: [String] = []
        if let of = s?.linesOf, of > 0 { parts.append("Looked through \(n(s?.lines ?? of)) of \(n(of)) lines.") }
        if applied { parts.append(confirm ? "They are in To confirm" : "They are in Actions") }
        else { parts.append(confirm ? "They go to To confirm when you approve" : "They are added when you approve") }
        var text = parts.joined(separator: " ")
        if let d = s?.duplicates, d > 0 {
            text += "; \(d == 1 ? "1 was" : "\(d) were") already in Actions and \(d == 1 ? "isn’t" : "aren’t") shown again."
        } else {
            text += "."
        }
        return text
    }

    /// A proposal whose source isn't in what will apply.
    public static let leftOut = "Not added: its source is left out of this change"
}
