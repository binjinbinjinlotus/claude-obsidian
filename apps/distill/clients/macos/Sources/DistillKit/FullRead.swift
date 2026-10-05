import Foundation

// v10 Full reads (spec full-read.md): what a batch's session read, counted by the core from the tool
// results; the sources that couldn't be read in full; the batch size and the detail level per source
// type. All additive: an older core omits them and every field decodes leniently.

/// One source's coverage ("647 lines · read in full").
public struct CoverageSource: Codable, Equatable, Sendable {
    /// full | partial | unreadable | stopped | later (an unknown state from a newer core is kept as it is).
    public var file: String
    /// Lines that had to be read (image placeholder lines left out); 1 for a PDF or image.
    public var lines: Int
    public var read: Int
    public var state: String
    public var reason: String?
    /// Embedded images in it (not text, not read).
    public var images: Int
    /// More rounds of reading this source needed (nil when none).
    public var rounds: Int?
    /// The last line read with no gap from line 1 (0 = nothing read; nil for full sources).
    public var readTo: Int?

    public init(file: String, lines: Int, read: Int? = nil, state: String = "full", reason: String? = nil, images: Int = 0, rounds: Int? = nil,
                readTo: Int? = nil) {
        self.file = file; self.lines = lines; self.read = read ?? lines; self.state = state; self.reason = reason; self.images = images
        self.rounds = rounds; self.readTo = readTo
    }

    enum CodingKeys: String, CodingKey { case file, lines, read, state, reason, images, rounds, readTo }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        lines = max(0, c.lossyInt(.lines) ?? 0)
        read = max(0, c.lossyInt(.read) ?? 0)
        state = c.lossy(String.self, .state) ?? "partial"
        reason = c.lossy(String.self, .reason)
        images = max(0, c.lossyInt(.images) ?? 0)
        rounds = c.lossyInt(.rounds).flatMap { $0 > 0 ? $0 : nil }
        readTo = c.lossyInt(.readTo).map { max(0, $0) }
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(file, forKey: .file)
        try c.encode(lines, forKey: .lines)
        try c.encode(read, forKey: .read)
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(reason, forKey: .reason)
        if images > 0 { try c.encode(images, forKey: .images) }
        try c.encodeIfPresent(rounds, forKey: .rounds)
        try c.encodeIfPresent(readTo, forKey: .readTo)
    }
}

/// The detail pass: what the pages missed and was added before Review, and what was left.
public struct CoverageDetail: Codable, Equatable, Sendable {
    public var checked: Int
    public var added: Int
    public var left: Int
    public var note: String?

    public init(checked: Int = 0, added: Int = 0, left: Int = 0, note: String? = nil) {
        self.checked = checked; self.added = added; self.left = left; self.note = note
    }

    enum CodingKeys: String, CodingKey { case checked, added, left, note }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        checked = max(0, c.lossyInt(.checked) ?? 0)
        added = max(0, c.lossyInt(.added) ?? 0)
        left = max(0, c.lossyInt(.left) ?? 0)
        note = c.lossy(String.self, .note).flatMap { $0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : $0 }
    }
}

/// A batch's coverage. Information for the owner, never a decision.
public struct CoverageSummary: Codable, Equatable, Sendable {
    public var sources: [CoverageSource]
    /// Sources read in full, of the readable ones.
    public var full: Int
    public var of: Int
    public var lines: Int
    /// Automatic continuations sent in this session, of every kind.
    public var rounds: Int
    /// Sources that needed at least one more round of reading ("2 needed a second round").
    public var continued: Int
    /// reading | complete | split | stopped
    public var state: String
    public var detail: CoverageDetail?
    /// Pages that still say they are partial although every line was read.
    public var partialWording: [String]
    /// Sources taken out of this change, read next in a fresh session.
    public var later: [String]
    /// Originals archived in .raw/captured/ by this change.
    public var archived: Int

    public init(sources: [CoverageSource] = [], full: Int = 0, of: Int = 0, lines: Int = 0, rounds: Int = 0, continued: Int = 0,
                state: String = "complete", detail: CoverageDetail? = nil, partialWording: [String] = [], later: [String] = [], archived: Int = 0) {
        self.sources = sources; self.full = full; self.of = of; self.lines = lines; self.rounds = rounds; self.continued = continued
        self.state = state
        self.detail = detail; self.partialWording = partialWording; self.later = later; self.archived = archived
    }

    enum CodingKeys: String, CodingKey { case sources, full, of, lines, rounds, continued, state, detail, partialWording, later, archived }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        sources = c.lossyArray(CoverageSource.self, .sources)
        full = max(0, c.lossyInt(.full) ?? 0)
        of = max(0, c.lossyInt(.of) ?? 0)
        lines = max(0, c.lossyInt(.lines) ?? 0)
        rounds = max(0, c.lossyInt(.rounds) ?? 0)
        continued = max(0, c.lossyInt(.continued) ?? 0)
        state = c.lossy(String.self, .state) ?? "complete"
        detail = c.lossy(CoverageDetail.self, .detail)
        partialWording = c.lossyArray(String.self, .partialWording)
        later = c.lossyArray(String.self, .later)
        archived = max(0, c.lossyInt(.archived) ?? 0)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(sources, forKey: .sources)
        try c.encode(full, forKey: .full)
        try c.encode(of, forKey: .of)
        try c.encode(lines, forKey: .lines)
        try c.encode(rounds, forKey: .rounds)
        if continued > 0 { try c.encode(continued, forKey: .continued) }
        try c.encode(state, forKey: .state)
        try c.encodeIfPresent(detail, forKey: .detail)
        if !partialWording.isEmpty { try c.encode(partialWording, forKey: .partialWording) }
        if !later.isEmpty { try c.encode(later, forKey: .later) }
        if archived > 0 { try c.encode(archived, forKey: .archived) }
    }

    /// The coverage of one Review source (`ReviewSource.source`, vault-relative like `file`); by name when the paths differ.
    public func source(_ path: String?) -> CoverageSource? {
        guard let path else { return nil }
        if let exact = sources.first(where: { $0.file == path }) { return exact }
        let name = (path as NSString).lastPathComponent
        let byName = sources.filter { ($0.file as NSString).lastPathComponent == name }
        return byName.count == 1 ? byName[0] : nil
    }

    /// Sources taken out of this change, read next in a fresh session (the split Review's muted rows).
    public var laterSources: [CoverageSource] { sources.filter { $0.state == "later" } }

    /// Embedded images in the sources of this change (not text, not read).
    public var images: Int { sources.filter { $0.state != "later" && $0.state != "stopped" }.reduce(0) { $0 + $1.images } }
}

/// A source that couldn't be read in full (the hard stop): left out of the change, never approvable.
public struct StoppedSource: Codable, Equatable, Sendable, Identifiable {
    public var file: String
    public var sha256: String?
    /// Plain words, lowercase: "it isn’t valid UTF-8 text from line 412".
    public var reason: String
    public var at: Date?
    public var id: String { file }

    public init(file: String, sha256: String? = nil, reason: String, at: Date? = nil) {
        self.file = file; self.sha256 = sha256; self.reason = reason; self.at = at
    }

    enum CodingKeys: String, CodingKey { case file, sha256, reason, at }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        sha256 = c.lossy(String.self, .sha256)
        reason = c.lossy(String.self, .reason) ?? ""
        at = c.lossyDate(.at)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(file, forKey: .file)
        try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encode(reason, forKey: .reason)
        try c.encodeIfPresent(at.map(CoreDate.format), forKey: .at)
    }

    public var name: String { (file as NSString).lastPathComponent }
}

/// A stopped source still in inbox/ ("Held in inbox/"), from `GET /v1/held`.
public struct HeldSource: Codable, Equatable, Sendable, Identifiable {
    public var file: String
    public var sha256: String?
    public var reason: String
    public var at: Date?
    public var jobId: String?
    public var size: Int?
    public var id: String { file }

    public init(file: String, sha256: String? = nil, reason: String, at: Date? = nil, jobId: String? = nil, size: Int? = nil) {
        self.file = file; self.sha256 = sha256; self.reason = reason; self.at = at; self.jobId = jobId; self.size = size
    }

    enum CodingKeys: String, CodingKey { case file, sha256, reason, at, jobId, size }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        file = try c.decode(String.self, forKey: .file)
        sha256 = c.lossy(String.self, .sha256)
        reason = c.lossy(String.self, .reason) ?? ""
        at = c.lossyDate(.at)
        jobId = c.lossy(String.self, .jobId)
        size = c.lossyInt(.size)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(file, forKey: .file)
        try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encode(reason, forKey: .reason)
        try c.encodeIfPresent(at.map(CoreDate.format), forKey: .at)
        try c.encodeIfPresent(jobId, forKey: .jobId)
        try c.encodeIfPresent(size, forKey: .size)
    }

    public var name: String { (file as NSString).lastPathComponent }
}

/// "Batch 1 of 3": the queue was split into batches by size.
public struct BatchOf: Codable, Equatable, Sendable {
    public var index: Int
    public var total: Int
    public var tokens: Int

    public init(index: Int, total: Int, tokens: Int = 0) { self.index = index; self.total = total; self.tokens = tokens }

    enum CodingKeys: String, CodingKey { case index, total, tokens }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let index = c.lossyInt(.index), let total = c.lossyInt(.total), index >= 1, total >= index else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no batch index"))
        }
        self.index = index
        self.total = total
        tokens = max(0, c.lossyInt(.tokens) ?? 0)
    }
}

/// `StatusResponse.batchBudget`: the batch size in force and where it comes from.
public struct BatchBudget: Codable, Equatable, Sendable {
    public var tokens: Int
    public var contextWindow: Int
    public var model: String
    public var automatic: Bool

    public init(tokens: Int, contextWindow: Int = 0, model: String = "", automatic: Bool = true) {
        self.tokens = tokens; self.contextWindow = contextWindow; self.model = model; self.automatic = automatic
    }

    enum CodingKeys: String, CodingKey { case tokens, contextWindow, model, automatic }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let tokens = c.lossyInt(.tokens), tokens > 0 else {
            throw DecodingError.dataCorrupted(.init(codingPath: decoder.codingPath, debugDescription: "no tokens"))
        }
        self.tokens = tokens
        contextWindow = max(0, c.lossyInt(.contextWindow) ?? 0)
        model = c.lossy(String.self, .model) ?? ""
        automatic = c.lossy(Bool.self, .automatic) ?? true
    }
}

/// `POST /v1/held/retry` (and `POST /v1/batches/reread`): the re-read groups and the batch it started.
public struct RereadResult: Codable, Equatable, Sendable {
    public var id: String
    public var vaultPath: String
    public var perBatch: Int
    public var tokenBudget: Int?
    public var groups: Int
    public var started: [Job]
    public var waiting: Int

    public init(id: String = "", vaultPath: String = "", perBatch: Int = 0, tokenBudget: Int? = nil, groups: Int = 0,
                started: [Job] = [], waiting: Int = 0) {
        self.id = id; self.vaultPath = vaultPath; self.perBatch = perBatch; self.tokenBudget = tokenBudget; self.groups = groups
        self.started = started; self.waiting = waiting
    }

    enum CodingKeys: String, CodingKey { case id, vaultPath, perBatch, tokenBudget, groups, started, waiting }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = c.lossy(String.self, .id) ?? ""
        vaultPath = c.lossy(String.self, .vaultPath) ?? ""
        perBatch = c.lossyInt(.perBatch) ?? 0
        tokenBudget = c.lossyInt(.tokenBudget)
        // groups: RereadGroup[] in the contract; only the count is shown here.
        groups = c.lossy([JSONValue].self, .groups)?.count ?? c.lossyInt(.groups) ?? 0
        started = c.lossyArray(Job.self, .started)
        // waiting: a number or the groups not started yet.
        waiting = c.lossyInt(.waiting) ?? c.lossy([JSONValue].self, .waiting)?.count ?? 0
    }
}

// MARK: - Settings: batch size and detail level

/// Settings → Batching → "Batch size": Automatic (absent/null), Smaller (50K), Larger (200K).
public enum BatchSize: Equatable, Sendable {
    case automatic, smaller, larger
    case custom(Int)

    public static let smallerTokens = 50_000
    public static let largerTokens = 200_000
    public static let options: [BatchSize] = [.automatic, .smaller, .larger]

    public init(tokens: Int?) {
        switch tokens {
        case nil: self = .automatic
        case Self.smallerTokens?: self = .smaller
        case Self.largerTokens?: self = .larger
        case let t?: self = .custom(t)
        }
    }

    /// What `settings.batchSourceTokens` holds (nil = Automatic).
    public var tokens: Int? {
        switch self {
        case .automatic: return nil
        case .smaller: return Self.smallerTokens
        case .larger: return Self.largerTokens
        case .custom(let t): return t
        }
    }

    /// "Automatic", "Smaller (50K)", "Larger (200K)", "75K".
    public var label: String {
        switch self {
        case .automatic: return "Automatic"
        case .smaller: return "Smaller (50K)"
        case .larger: return "Larger (200K)"
        case .custom(let t): return FullReadWords.tokens(t)
        }
    }

    /// The menu's longer line for each choice (canvas card-settings).
    public var menuLabel: String {
        switch self {
        case .automatic: return "Automatic (30% of the model’s context, at most 100K)"
        case .smaller: return "Smaller (50K)"
        case .larger: return "Larger (200K, 1M-context models only)"
        case .custom(let t): return FullReadWords.tokens(t)
        }
    }
}

/// How much of a source goes into its page.
public enum DetailLevel: String, CaseIterable, Sendable {
    case highlights, detailed, nearComplete

    public var label: String {
        switch self {
        case .highlights: return "Highlights"
        case .detailed: return "Detailed"
        case .nearComplete: return "Near-complete"
        }
    }
}

/// `settings.detailLevel`: one level per source type. Kept as the raw object, so `other` and keys a newer
/// core adds survive a save; a type that is absent reads as its default.
public struct DetailLevels: Codable, Equatable, Sendable {
    public var raw: [String: JSONValue]

    /// The rows Settings shows (`other` keeps its default unless the core sets it).
    public static let rows: [(key: String, title: String)] = [("meeting", "Meetings and calls"),
                                                              ("conversation", "Conversations and chats"),
                                                              ("research", "Articles and research")]
    public static let defaults: [String: DetailLevel] = ["meeting": .detailed, "conversation": .detailed,
                                                         "research": .highlights, "other": .highlights]

    public init(raw: [String: JSONValue] = [:]) { self.raw = raw }

    public init(from decoder: Decoder) throws {
        guard case .object(let o) = try JSONValue(from: decoder) else {
            throw DecodingError.typeMismatch([String: JSONValue].self, .init(codingPath: decoder.codingPath, debugDescription: "not an object"))
        }
        raw = o
    }

    public func encode(to encoder: Encoder) throws { try JSONValue.object(raw).encode(to: encoder) }

    /// The level for a source type: its own value when it is one this build knows, else the default.
    public func level(_ type: String) -> DetailLevel {
        if case .string(let s)? = raw[type], let l = DetailLevel(rawValue: s) { return l }
        return Self.defaults[type] ?? .highlights
    }

    /// Sets one type, keeping every other key as it is.
    public mutating func set(_ type: String, _ level: DetailLevel) { raw[type] = .string(level.rawValue) }
}

extension Optional where Wrapped == DetailLevels {
    /// The level for a source type, absent settings included.
    public func level(_ type: String) -> DetailLevel { (self ?? DetailLevels()).level(type) }
}

// MARK: - Words

/// The words the app shows for full reads (canvas FullRead). Pure, so they are tested in DistillKit.
public enum FullReadWords {
    /// "96K", "1.5K", "800".
    public static func tokens(_ n: Int) -> String {
        if n >= 1000 {
            let k = Double(n) / 1000
            return k == k.rounded() || k >= 10 ? "\(Int(k.rounded()))K" : String(format: "%.1fK", k)
        }
        return "\(n)"
    }

    /// Text that many tokens hold, at about 2.6 bytes a token: 100K → 260.
    public static func kilobytes(_ tokens: Int) -> Int { Int((Double(tokens) * 2.6 / 1000).rounded()) }

    /// "4,870".
    public static func number(_ n: Int) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = Locale(identifier: "en_US")
        return f.string(from: NSNumber(value: n)) ?? "\(n)"
    }

    static func plural(_ n: Int, _ one: String, _ many: String? = nil) -> String {
        n == 1 ? "1 \(one)" : "\(number(n)) \(many ?? one + "s")"
    }

    /// "Sonnet (1M context): up to 100K tokens, about 260 KB of text".
    public static func budgetLine(_ b: BatchBudget) -> String {
        let model = ModelChoice.shortName(b.model)
        let window = b.contextWindow >= 1_000_000 && b.contextWindow % 1_000_000 == 0 ? "\(b.contextWindow / 1_000_000)M"
            : b.contextWindow > 0 ? tokens(b.contextWindow) : nil
        let who = model.isEmpty ? "" : model + (window.map { " (\($0) context)" } ?? "") + ": "
        return who + "up to \(tokens(b.tokens)) tokens, about \(kilobytes(b.tokens)) KB of text"
    }

    /// Batch size row's note: what it is for, then the budget in force when the core says it.
    public static func batchSizeNote(_ b: BatchBudget?) -> String {
        let base = "How much text one batch takes, so Claude can read every source to its last line in one session. More waits for the next batch, which starts right after."
        guard let b else { return base }
        return base + " " + budgetLine(b) + "."
    }

    public static let detailCaption = "Highlights: key points, decisions, actions. Detailed: also the discussion by topic: proposals, objections, reasons, numbers, dates, names, open questions. Near-complete: every topic, close to the source’s own words."
    public static let detailNote = "Each page is checked against its source before you review it; what is missing at this level is added."

    /// "Batch 1 of 3 · reading 9 sources into MyVault", or nil when the batch isn't one of several.
    public static func batchTitle(_ of: BatchOf?, sources: Int, vault: String) -> String? {
        guard let of, of.total > 1 else { return nil }
        return "Batch \(of.index) of \(of.total) · reading \(plural(sources, "source")) into \(vault)"
    }

    /// "About 96K tokens of text".
    public static func batchTokens(_ of: BatchOf?) -> String? {
        guard let of, of.tokens > 0 else { return nil }
        return "About \(tokens(of.tokens)) tokens of text"
    }

    /// Queue title while a batch of several runs: "9 in this batch · 14 in the next 2 batches".
    public static func queueTitle(inBatch: Int, waiting: Int, of: BatchOf?) -> String {
        var t = "\(inBatch) in this batch"
        guard waiting > 0 else { return t }
        if let of, of.total > of.index {
            let next = of.total - of.index
            t += " · \(waiting) in the next " + (next == 1 ? "batch" : "\(next) batches")
        } else {
            t += " · \(waiting) waiting"
        }
        return t
    }

    // Review

    /// ("Read in full", "9 of 9 sources · 4,870 lines", "counted by Distill from Claude’s reads; 2 needed a second round").
    public static func readLine(_ c: CoverageSummary, stopped: Int = 0) -> (title: String, text: String, quiet: String) {
        let inChange = !c.later.isEmpty || stopped > 0 ? " in this change" : ""
        let text = "\(c.full) of \(plural(c.of, "source"))\(inChange) · \(plural(c.lines, "line"))"
        var quiet = "counted by Distill from Claude’s reads"
        if c.continued > 0 { quiet += "; \(c.continued) needed a second round" }
        return ("Read in full", text, quiet)
    }

    /// ("Detail check", "each page checked against its source · 7 missing items were added before this review · 2 left out").
    public static func detailLine(_ d: CoverageDetail) -> (title: String, text: String) {
        var parts = ["each page checked against its source"]
        if d.added > 0 {
            parts.append(d.added == 1 ? "1 missing item was added before this review" : "\(d.added) missing items were added before this review")
        } else {
            parts.append("nothing missing")
        }
        if d.left > 0 { parts.append("\(d.left) left out") }
        if let note = d.note { parts.append(note) }
        return ("Detail check", parts.joined(separator: " · "))
    }

    /// ("Originals archived", "in your vault with this change", ".raw/captured/, byte for byte, …"), or nil when none were.
    public static func archivedLine(_ c: CoverageSummary) -> (title: String, text: String, quiet: String)? {
        guard c.archived > 0 else { return nil }
        return ("Originals archived", "in your vault with this change",
                ".raw/captured/, byte for byte, never changed or deleted; ledger records point to them")
    }

    /// "6 embedded images are not text and were not read.", or nil.
    public static func imagesLine(_ c: CoverageSummary) -> String? {
        let n = c.images
        guard n > 0 else { return nil }
        return n == 1 ? "1 embedded image is not text and was not read." : "\(n) embedded images are not text and were not read."
    }

    /// "The page for Tomasz and Jin still calls itself partial, though every line was read".
    public static func partialWordingLine(_ page: String) -> String {
        "The page for \(displayName(page)) still calls itself partial, though every line was read"
    }

    /// A source row's meta line: "644 lines · read in full · 1 image not read".
    public static func sourceMeta(_ s: CoverageSource) -> String {
        var parts: [String] = []
        let counted = s.lines > 1 || (s.lines == 1 && !isWholeFile(s.file))
        if counted { parts.append(plural(s.lines, "line")) }
        switch s.state {
        case "full": parts.append("read in full")
        case "later":
            if let to = s.readTo, to > 0 { parts.append("read up to line \(number(to)) in this session") }
            parts.append("next: a fresh session")
        case "partial": parts.append(s.read > 0 ? "read up to line \(number(s.read))" : "not read yet")
        case "unreadable", "stopped": parts.append("couldn’t be read")
        default: parts.append(s.state)
        }
        if s.images > 0 { parts.append(s.images == 1 ? "1 image not read" : "\(s.images) images not read") }
        return parts.joined(separator: " · ")
    }

    /// The part notice: ("2 sources are read next, in a fresh session", "Develop FE With AI, Tomasz and Jin", text).
    public static func laterNotice(_ later: [String]) -> (title: String, names: String, text: String)? {
        guard !later.isEmpty else { return nil }
        let title = later.count == 1 ? "1 source is read next, in a fresh session" : "\(later.count) sources are read next, in a fresh session"
        let names = later.map(displayName).joined(separator: ", ")
        let them = later.count == 1 ? "its last lines, so it was" : "their last lines, so they were"
        let it = later.count == 1 ? "it from the start and it comes" : "them again from the start and they come"
        return (title, names,
                "This session ran out of room before \(them) taken out of this change. Once you approve these, Claude reads \(it) back here as the next part.")
    }

    /// "Not added · couldn’t be read · 1 file".
    public static func stoppedTitle(_ n: Int) -> String { "Not added · couldn’t be read · \(plural(n, "file"))" }

    /// The reason as a sentence, then what it means: "It isn’t valid UTF-8 text from line 412. It is not part of …".
    public static func stoppedText(_ reason: String) -> String {
        sentence(reason) + " It is not part of this change, and nothing from it is in your vault."
    }

    public static let stoppedHint = "Fix the file, then Try again: Distill checks it and reads it in a batch of its own. Until then it stays in inbox/ and is never cleared."

    /// The footer while a source couldn't be read.
    public static func stoppedFooter(_ n: Int) -> String {
        n == 1 ? "The file that couldn’t be read is not in this change" : "The \(n) files that couldn’t be read are not in this change"
    }

    // Queue: held in inbox/

    public static let heldTitle = "Held in inbox/"
    public static let heldSubtitle = "couldn’t be read in full, so it isn’t in your knowledge base"
    public static let heldCaption = "A held file counts in the sidebar until it is read in full or you remove it. Clean up never clears it."
    public static let heldPill = "Couldn’t be read"

    /// The line under a held row: "It isn’t valid UTF-8 text from line 412. Fix the file, then Try again: …".
    public static func heldHint(_ reason: String) -> String {
        (reason.isEmpty ? "" : sentence(reason) + " ") + "Fix the file, then Try again: Distill reads it in a batch of its own."
    }

    /// "In inbox/ since 10:31 AM · 212 KB".
    public static func heldMeta(_ h: HeldSource, now: Date = Date()) -> String {
        heldSince(h.at, now: now) + (h.size.map { $0 > 0 ? " · " + ByteCountFormatter.string(fromByteCount: Int64($0), countStyle: .file) : "" } ?? "")
    }

    /// "In inbox/ since 10:40 AM" today, "In inbox/ since Oct 3" before.
    public static func heldSince(_ at: Date?, now: Date = Date(), calendar: Calendar = .current) -> String {
        guard let at else { return "In inbox/" }
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US")
        f.timeZone = calendar.timeZone
        f.dateFormat = calendar.isDate(at, inSameDayAs: now) ? "h:mm a" : "MMM d"
        return "In inbox/ since \(f.string(from: at))"
    }

    // helpers

    /// "Tomasz and Jin" from "inbox/Tomasz and Jin.md" or "wiki/sources/Tomasz and Jin.md".
    public static func displayName(_ path: String) -> String {
        let name = (path as NSString).lastPathComponent
        let ext = (name as NSString).pathExtension.lowercased()
        return ["md", "txt", "markdown"].contains(ext) ? (name as NSString).deletingPathExtension : name
    }

    /// The first letter up and a closing period: "it isn’t text" → "It isn’t text.".
    public static func sentence(_ s: String) -> String {
        let t = s.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = t.first else { return "" }
        let body = first.uppercased() + t.dropFirst()
        return [".", "!", "?", "…"].contains(where: body.hasSuffix) ? body : body + "."
    }

    private static func isWholeFile(_ path: String) -> Bool {
        ["pdf", "png", "jpg", "jpeg", "gif", "heic", "webp", "tiff"].contains((path as NSString).pathExtension.lowercased())
    }
}
