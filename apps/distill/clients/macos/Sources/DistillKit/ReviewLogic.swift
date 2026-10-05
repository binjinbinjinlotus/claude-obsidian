import Foundation

// Pure logic behind the v6 Review (summary line, groups that fold, picking sources and the Approve
// options) and the queue's label line. No UI here; the views in the app target only draw what this says.

// MARK: - Label line

/// One label line's state (canvas: LabelLine `state`).
public enum LabelLineState: String, CaseIterable, Sendable {
    case waiting, suggesting, suggested, confirmed, own, failed, editing, none

    /// A queue file's line; nil = no line (no labels object: notes, folders, Google Docs, binary files, labeling off).
    public init?(queue labels: QueueLabels?) {
        guard let labels else { return nil }
        switch labels.state {
        case .waiting: self = .waiting
        case .suggesting: self = .suggesting
        case .suggested: self = labels.labels.isEmpty ? .none : .suggested
        case .confirmed: self = .confirmed
        case .own: self = .own
        case .failed: self = .failed
        case .skipped: self = .none
        }
    }

    /// A source's line in Review.
    public init(review source: ReviewSource) {
        switch source.state {
        case .waiting: self = .waiting
        case .suggesting: self = .suggesting
        case .failed: self = .failed
        case nil:
            if source.labels.isEmpty { self = .none } else { self = source.by == .ai ? .suggested : .confirmed }
        }
    }
}

public enum QueueLabelText {
    /// The note after a failed suggestion's chips: "tried 3 times" once Distill stopped retrying by itself.
    public static func note(_ labels: QueueLabels?) -> String? {
        guard let labels, labels.state == .failed, labels.attempts >= 3 else { return nil }
        return "tried \(labels.attempts) times"
    }

    /// The status pill's help on a row held for labels.
    public static let heldHelp = "Its labels are not in yet, so a batch that started left it here. It goes in the next batch."

    /// "3 files wait for labels" (nil when none).
    public static func held(_ count: Int) -> String? {
        count <= 0 ? nil : (count == 1 ? "1 file waits for labels" : "\(count) files wait for labels")
    }

    /// The toast after Process now when files are still being labeled (nil = nothing to say).
    /// `started`: the sources of the batch that started (nil when none); `held`: rows still held for labels;
    /// `rows`: every row in the queue; `next`: "7:30 AM" for "(or at 7:30 AM)".
    public static func processToast(started: Int?, held: Int, rows: Int, next: String?) -> (title: String, detail: String)? {
        guard held > 0 else { return nil }
        if let started {
            let files = started == 1 ? "1 file" : "\(started) files"
            let notes = held == 1 ? "1 note is" : "\(held) notes are"
            return ("Started a batch with \(files)", "\(notes) still being labeled; they’ll go in the next batch.")
        }
        guard held >= rows else { return nil }
        let all = held == 1 ? "The file is" : "All \(held) files are"
        let when = next.map { " (or at \($0))" } ?? ""
        return ("Nothing to batch yet", "\(all) still being labeled. Distill starts the batch when their labels are in\(when).")
    }
}

// MARK: - Summary and groups

/// What a batch changes, read from the plan's `changed_paths` and its `sources`.
public struct ReviewSummary: Equatable, Sendable {
    public var sourcePages: [String] = []
    public var concepts: [String] = []
    public var entities: [String] = []
    /// New wiki pages that are not sources, concepts or entities.
    public var otherNew: [String] = []
    /// Existing wiki pages the change rewrites (index, overview, log, hot cache, ledgers…).
    public var updated: [String] = []
    /// Paths outside wiki/ (the raw manifest, journals…).
    public var bookkeeping: [String] = []
    public var removed: Int = 0

    /// - Parameters:
    ///   - exists: whether a wiki page is already in the vault (only a batch still in Review can tell; History passes nil,
    ///     so concepts and entities count as new and every other page as updated).
    public static func make(changedPaths: [String], sources: [ReviewSource]?, exists: ((String) -> Bool)? = nil) -> ReviewSummary {
        var out = ReviewSummary()
        let kept = (sources ?? []).filter { !$0.removed }
        let sourceSet = Set(kept.map(\.page))
        let removedSet = Set((sources ?? []).filter(\.removed).map(\.page))
        out.removed = removedSet.count
        var seen = Set<String>()
        for path in changedPaths where seen.insert(path).inserted {
            if removedSet.contains(path) { continue }
            if sourceSet.contains(path) || (sources == nil && path.hasPrefix("wiki/sources/")) {
                out.sourcePages.append(path)
                continue
            }
            guard path.hasPrefix("wiki/") else { out.bookkeeping.append(path); continue }
            // The vault's own bookkeeping pages (index, overview, log, hot cache, meta/ledgers) always read as updated.
            let isNew = isVaultBookkeeping(path) ? false : exists.map { !$0(path) }
            if path.hasPrefix("wiki/concepts/") && isNew != false { out.concepts.append(path) }
            else if path.hasPrefix("wiki/entities/") && isNew != false { out.entities.append(path) }
            else if isNew == true { out.otherNew.append(path) }
            else { out.updated.append(path) }
        }
        // A source page the plan doesn't list yet (labels still attaching) still counts.
        for page in kept.map(\.page) where !seen.contains(page) { out.sourcePages.append(page) }
        return out
    }

    /// wiki/index.md, overview.md, log.md, hot.md and anything under wiki/meta/.
    static func isVaultBookkeeping(_ path: String) -> Bool {
        if path.hasPrefix("wiki/meta/") { return true }
        return ["wiki/index.md", "wiki/overview.md", "wiki/log.md", "wiki/hot.md"].contains(path)
    }

    /// The parts of the summary line, number first: [(22, "new source pages"), (3, "new concepts"), …].
    public var parts: [(Int, String)] {
        var p: [(Int, String)] = []
        func add(_ n: Int, _ one: String, _ many: String) { if n > 0 { p.append((n, n == 1 ? one : many)) } }
        add(sourcePages.count, "new source page", "new source pages")
        add(concepts.count, "new concept", "new concepts")
        add(entities.count, "new entity", "new entities")
        add(otherNew.count, "new page", "new pages")
        add(updated.count, "page updated", "pages updated")
        add(removed, "removed", "removed")
        return p
    }

    /// "22 new source pages · 3 new concepts · 1 new entity · 6 pages updated".
    public var line: String { parts.map { "\($0.0) \($0.1)" }.joined(separator: " · ") }

    /// The New pages group: entities first, then concepts, then other new pages.
    public var newPages: [String] { entities + concepts + otherNew }

    /// "3 concepts · 1 entity".
    public var newPagesSummary: String {
        var p: [String] = []
        if !concepts.isEmpty { p.append(concepts.count == 1 ? "1 concept" : "\(concepts.count) concepts") }
        if !entities.isEmpty { p.append(entities.count == 1 ? "1 entity" : "\(entities.count) entities") }
        if !otherNew.isEmpty { p.append(otherNew.count == 1 ? "1 other page" : "\(otherNew.count) other pages") }
        return p.joined(separator: " · ")
    }

    /// "Index, Overview, Log, Hot cache, 2 ledgers · plus 2 bookkeeping files".
    public var updatedSummary: String {
        var names: [String] = []
        var ledgers = 0
        for path in updated {
            if path.hasPrefix("wiki/meta/ledgers/") { ledgers += 1; continue }
            names.append(Self.pageName(path))
        }
        if names.count > 6 { names = Array(names.prefix(5)) + ["\(updated.count - ledgers - 5) more"] }
        if ledgers > 0 { names.append(ledgers == 1 ? "1 ledger" : "\(ledgers) ledgers") }
        var text = names.joined(separator: ", ")
        if !bookkeeping.isEmpty {
            let files = bookkeeping.count == 1 ? "1 bookkeeping file" : "\(bookkeeping.count) bookkeeping files"
            text += text.isEmpty ? files : " · plus \(files)"
        }
        return text
    }

    /// Updated rows plus the bookkeeping files.
    public var updatedCount: Int { updated.count + bookkeeping.count }

    /// A page's display name: "Hot cache" for hot.md, "Index" for index.md, the file stem otherwise.
    public static func pageName(_ path: String) -> String {
        let stem = ((path as NSString).lastPathComponent as NSString).deletingPathExtension
        switch stem.lowercased() {
        case "hot": return "Hot cache"
        case "index", "overview", "log": return stem.prefix(1).uppercased() + stem.dropFirst()
        default: return stem
        }
    }

    /// "wiki/concepts" for "wiki/concepts/Water temperature.md".
    public static func directory(_ path: String) -> String { (path as NSString).deletingLastPathComponent }

    /// entity | concept | "" for a ReviewChangeRow.
    public static func kind(_ path: String) -> String {
        if path.hasPrefix("wiki/entities/") { return "entity" }
        if path.hasPrefix("wiki/concepts/") { return "concept" }
        return ""
    }
}

/// The Sources group's folded line: "Most used labels: #tea-club 8 · #tasting 8 · … · 2 new: #shading, #sourcing".
public struct LabelUsage: Equatable, Sendable {
    public var top: [(name: String, count: Int)]
    public var new: [String]

    public static func == (a: LabelUsage, b: LabelUsage) -> Bool {
        a.new == b.new && a.top.map(\.name) == b.top.map(\.name) && a.top.map(\.count) == b.top.map(\.count)
    }

    /// `known`: the vault's labels (nil when not loaded: every label counts as known).
    public static func make(_ sources: [ReviewSource], known: Set<String>?, limit: Int = 4) -> LabelUsage {
        var counts: [String: Int] = [:]
        var order: [String] = []
        for s in sources where !s.removed {
            for l in s.labels {
                if counts[l] == nil { order.append(l) }
                counts[l, default: 0] += 1
            }
        }
        let isNew = { (l: String) in known.map { !$0.contains(l) } ?? false }
        let existing = order.filter { !isNew($0) }
            .sorted { a, b in
                counts[a]! != counts[b]! ? counts[a]! > counts[b]! : order.firstIndex(of: a)! < order.firstIndex(of: b)!
            }
        return LabelUsage(top: existing.prefix(limit).map { ($0, counts[$0]!) }, new: order.filter(isNew))
    }

    public var isEmpty: Bool { top.isEmpty && new.isEmpty }
}

// MARK: - Picking and Approve

/// Sources are picked one by one (all at first); the view keeps the *unpicked* pages per job, so a source
/// that arrives later starts picked.
public enum ReviewPicking {
    /// Sources not removed, in order.
    public static func active(_ sources: [ReviewSource]) -> [ReviewSource] { sources.filter { !$0.removed } }

    /// The picked source pages.
    public static func picked(_ sources: [ReviewSource], unpicked: Set<String>) -> [String] {
        active(sources).map(\.page).filter { !unpicked.contains($0) }
    }

    /// Every source not removed is picked.
    public static func allPicked(_ sources: [ReviewSource], unpicked: Set<String>) -> Bool {
        picked(sources, unpicked: unpicked).count == active(sources).count
    }

    /// The approve body: `pages` only for a subset, `labels` only for "later".
    public static func options(_ sources: [ReviewSource]?, unpicked: Set<String>, later: Bool = false) -> ApproveOptions {
        var o = ApproveOptions(labels: later ? .later : nil)
        if let sources, !allPicked(sources, unpicked: unpicked) { o.pages = picked(sources, unpicked: unpicked) }
        return o
    }

    /// "Approve & apply" when everything is picked, "Approve 8 sources" for a subset, "Approve the rebuilt change".
    public static func approveTitle(_ approval: ApprovalRequest?, unpicked: Set<String>) -> String {
        if approval?.rebuilt != nil { return "Approve the rebuilt change" }
        guard let sources = approval?.sources, !allPicked(sources, unpicked: unpicked) else { return "Approve & apply" }
        let n = picked(sources, unpicked: unpicked).count
        return n == 1 ? "Approve 1 source" : "Approve \(n) sources"
    }

    /// The chevron menu offers "Approve, review labels later" when the core prepared the unconfirmed change,
    /// or when a subset is picked (the batch's session rebuilds it anyway).
    public static func offersLater(_ approval: ApprovalRequest?, unpicked: Set<String>) -> Bool {
        guard let approval, let sources = approval.sources, !active(sources).isEmpty else { return false }
        return approval.unconfirmed != nil || !allPicked(sources, unpicked: unpicked)
    }

    /// The menu's first item: "Approve 8 sources".
    public static func menuApproveTitle(_ approval: ApprovalRequest?, unpicked: Set<String>) -> String {
        let n = picked(approval?.sources ?? [], unpicked: unpicked).count
        return n == 1 ? "Approve 1 source" : "Approve \(n) sources"
    }

    /// Why Approve is off right now (nil = it can be pressed).
    public static func blocker(_ approval: ApprovalRequest?, unpicked: Set<String>) -> String? {
        guard let approval else { return "" }
        if let labels = approval.labels, labels.state == .confirming { return "Saving your labels into the change and checking it again…" }
        if let labels = approval.labels, labels.state == .suggesting { return "Approve when the labels are in" }
        if let sources = approval.sources, !active(sources).isEmpty, picked(sources, unpicked: unpicked).isEmpty {
            return "Pick at least one source"
        }
        return nil
    }

    /// The Sources header: "8 of 22 picked · 1 removed", or the given tail ("one page per note · labels suggested").
    public static func sourcesSummary(_ sources: [ReviewSource], unpicked: Set<String>, selectable: Bool, tail: String) -> String {
        var parts: [String] = []
        let active = active(sources).count
        let removed = sources.count - active
        if selectable { parts.append("\(picked(sources, unpicked: unpicked).count) of \(active) picked") }
        if removed > 0 { parts.append("\(removed) removed") }
        if !(selectable && removed > 0), !tail.isEmpty { parts.append(tail) }
        return parts.joined(separator: " · ")
    }
}

// MARK: - Several batches, parts

public enum ReviewBatches {
    /// Oldest first: the oldest batch was built against the oldest vault and should go in first.
    public static func ordered(_ jobs: [Job]) -> [Job] { jobs.sorted { ($0.createdAt, $0.id) < ($1.createdAt, $1.id) } }

    /// A tab's subtitle: "14 left" after a part applied, otherwise "3 sources".
    public static func tabSubtitle(_ job: Job) -> String {
        if let after = ApplyTimeline.tabSubtitle(job) { return after }
        if let sources = job.approval?.sources {
            let n = sources.filter { !$0.removed }.count
            if !(job.parts ?? []).isEmpty { return "\(n) left" }
            return n == 1 ? "1 source" : "\(n) sources"
        }
        let n = job.sources.count
        return n == 1 ? "1 source" : "\(n) sources"
    }

    /// "8 sources at 11:52 PM · ingest-…-part-1 · labels left to review".
    public static func partLine(_ part: JobPart, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String {
        let n = part.pages.count
        var line = "\(n == 1 ? "1 source" : "\(n) sources") \(QueueRows.at(part.at, now: now, locale: locale, timeZone: timeZone))"
        if !part.operationID.isEmpty { line += " · \(part.operationID)" }
        if part.labels == .later { line += " · labels left to review" }
        return line
    }
}
