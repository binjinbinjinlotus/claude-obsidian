import Foundation

// v8 Clean up inbox (spec inbox-cleanup.md): what can go to the Trash, what stays and why. The core
// decides and moves; these are its answers and the words the app shows. v10 (full-read.md, section 4):
// "Clear inbox": only files read in full whose originals are archived in the vault go.

public struct InboxCleanupItem: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    /// file | note | folder
    public var kind: String
    public var members: [String]
    public var fileCount: Int
    public var size: Int
    public var jobId: String?
    public var addedAt: String?
    public var pages: [String]
    public var id: String { path }

    public init(path: String, kind: String = "file", members: [String] = [], fileCount: Int = 1, size: Int = 0, jobId: String? = nil,
                addedAt: String? = nil, pages: [String] = []) {
        self.path = path; self.kind = kind; self.members = members; self.fileCount = fileCount; self.size = size
        self.jobId = jobId; self.addedAt = addedAt; self.pages = pages
    }

    enum Keys: String, CodingKey { case path, kind, members, fileCount, size, jobId, addedAt, pages }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = try c.decode(String.self, forKey: .path)
        kind = c.lossy(String.self, .kind) ?? "file"
        members = c.lossyArray(String.self, .members)
        fileCount = c.lossy(Int.self, .fileCount) ?? 1
        size = c.lossy(Int.self, .size) ?? 0
        jobId = c.lossy(String.self, .jobId)
        addedAt = c.lossy(String.self, .addedAt)
        pages = c.lossyArray(String.self, .pages)
    }

    /// The name shown: the file or folder name.
    public var name: String { (path as NSString).lastPathComponent }
}

public struct InboxCleanupStay: Codable, Equatable, Sendable, Identifiable {
    public var path: String
    public var kind: String
    /// notAdded | changed | pageMissing | inReview | inQueue | unreadable; v10 notReadInFull | notArchived | held
    public var reason: String
    public var detail: String?
    public var fileCount: Int
    public var id: String { path }

    public init(path: String, kind: String = "file", reason: String, detail: String? = nil, fileCount: Int = 1) {
        self.path = path; self.kind = kind; self.reason = reason; self.detail = detail; self.fileCount = fileCount
    }

    enum Keys: String, CodingKey { case path, kind, reason, detail, fileCount }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = try c.decode(String.self, forKey: .path)
        kind = c.lossy(String.self, .kind) ?? "file"
        reason = c.lossy(String.self, .reason) ?? "notAdded"
        detail = c.lossy(String.self, .detail)
        fileCount = c.lossy(Int.self, .fileCount) ?? 1
    }

    public var name: String { (path as NSString).lastPathComponent }
    /// "changed since it was added".
    public var reasonWords: String { InboxCleanupWords.reason(reason) }
    /// Peach for a file that changed, lost its page or couldn't be read; grey for one that simply isn't ready.
    public var isWarning: Bool { InboxCleanupWords.isWarning(reason) }
}

public struct InboxCleanupPreview: Codable, Equatable, Sendable {
    public var vaultPath: String
    public var jobId: String?
    public var items: [InboxCleanupItem]
    public var stays: [InboxCleanupStay]

    public init(vaultPath: String = "", jobId: String? = nil, items: [InboxCleanupItem] = [], stays: [InboxCleanupStay] = []) {
        self.vaultPath = vaultPath; self.jobId = jobId; self.items = items; self.stays = stays
    }

    enum Keys: String, CodingKey { case vaultPath, jobId, items, stays }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        vaultPath = c.lossy(String.self, .vaultPath) ?? ""
        jobId = c.lossy(String.self, .jobId)
        items = c.lossy([Lossy<InboxCleanupItem>].self, .items).map { $0.compactMap(\.value) } ?? []
        stays = c.lossy([Lossy<InboxCleanupStay>].self, .stays).map { $0.compactMap(\.value) } ?? []
    }

    /// Files that would move (a note counts its manifest and images; a folder its files).
    public var fileCount: Int { items.reduce(0) { $0 + $1.fileCount } }
    public var stayFileCount: Int { stays.reduce(0) { $0 + $1.fileCount } }
    /// Stays counted by reason, in the board's order.
    public var staysByReason: [(reason: String, count: Int)] {
        InboxCleanupWords.order.compactMap { r in
            let n = stays.filter { $0.reason == r }.reduce(0) { $0 + $1.fileCount }
            return n > 0 ? (r, n) : nil
        }
    }
}

public struct InboxCleanupResult: Codable, Equatable, Sendable {
    public struct Moved: Codable, Equatable, Sendable {
        public var path: String
        public var fileCount: Int
        public init(path: String, fileCount: Int = 1) { self.path = path; self.fileCount = fileCount }
    }
    public struct Failed: Codable, Equatable, Sendable {
        public var path: String
        public var error: String
        public init(path: String, error: String) { self.path = path; self.error = error }
    }
    public var moved: [Moved]
    public var stayed: [InboxCleanupStay]
    public var failed: [Failed]
    /// finder (Put Back works) | rename | none
    public var method: String

    public init(moved: [Moved] = [], stayed: [InboxCleanupStay] = [], failed: [Failed] = [], method: String = "none") {
        self.moved = moved; self.stayed = stayed; self.failed = failed; self.method = method
    }

    enum Keys: String, CodingKey { case moved, stayed, failed, method }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        moved = c.lossy([Lossy<Moved>].self, .moved).map { $0.compactMap(\.value) } ?? []
        stayed = c.lossy([Lossy<InboxCleanupStay>].self, .stayed).map { $0.compactMap(\.value) } ?? []
        failed = c.lossy([Lossy<Failed>].self, .failed).map { $0.compactMap(\.value) } ?? []
        method = c.lossy(String.self, .method) ?? "none"
    }

    public var movedFiles: Int { moved.reduce(0) { $0 + $1.fileCount } }
}

public enum InboxCleanupWords {
    public static let order = ["inReview", "inQueue", "notAdded", "notReadInFull", "notArchived", "changed", "pageMissing", "unreadable", "held"]

    /// Reasons shown in peach.
    public static func isWarning(_ r: String) -> Bool { ["changed", "pageMissing", "unreadable", "held"].contains(r) }

    public static func reason(_ r: String) -> String {
        switch r {
        case "notAdded": return "not added yet"
        case "changed": return "changed since it was added"
        case "pageMissing": return "its page is missing"
        case "inReview": return "waiting in Review"
        case "inQueue": return "in the queue, not batched yet"
        case "unreadable": return "can’t be read"
        case "notReadInFull": return "not read in full yet"
        case "notArchived": return "not archived yet"
        case "held": return "couldn’t be read"
        default: return r
        }
    }

    static func files(_ n: Int) -> String { n == 1 ? "1 file" : "\(n) files" }

    /// "Clear inbox · 22 files", or nil when nothing can go.
    public static func button(_ p: InboxCleanupPreview?) -> String? {
        guard let p, p.fileCount > 0 else { return nil }
        return "Clear inbox · \(files(p.fileCount))"
    }

    /// The Settings → Batching row and the vault-wide sheet.
    public static let title = "Clear inbox"

    /// "Clear 21 files from inbox?"
    public static func confirmTitle(_ n: Int) -> String { "Clear \(files(n)) from inbox?" }
    public static func moveButton(_ n: Int) -> String { "Clear \(n) from inbox" }
    public static let confirmText = "Their originals are archived in your vault (.raw/captured/), byte for byte, and are never changed or deleted. Every one was read in full. The inbox copies go to the Trash."
    /// "Will clear · 21 files, all archived".
    public static func willClear(_ n: Int) -> String { "Will clear · \(files(n)), all archived" }

    /// "Cleared 20 files from inbox" + what stayed and why.
    public static func resultTitle(_ r: InboxCleanupResult) -> String {
        r.movedFiles == 0 ? "Nothing was cleared" : "Cleared \(files(r.movedFiles)) from inbox"
    }

    public static func resultText(_ r: InboxCleanupResult) -> String {
        var parts: [String] = []
        let stayed = r.stayed.count + r.failed.count
        if stayed > 0 {
            let list = r.stayed.prefix(3).map { "\($0.name) \($0.reason == "changed" ? "changed, so it was left alone" : reason($0.reason))" }
                + r.failed.prefix(2).map { "\(($0.path as NSString).lastPathComponent) couldn’t be moved" }
            parts.append("\(stayed) stayed in inbox/: " + list.joined(separator: "; ") + (stayed > 5 ? "; …" : "") + ".")
        }
        if r.movedFiles > 0 {
            parts.append(r.method == "finder" ? "Put Back in the Trash returns a file to inbox/." : "To get a file back, drag it out of the Trash.")
        }
        return parts.joined(separator: " ")
    }

    /// The History footer when nothing can go: "2 files stay in inbox/" or "No inbox files left".
    public static func nothingLine(_ p: InboxCleanupPreview?) -> String? {
        guard let p, p.fileCount == 0 else { return nil }
        let n = p.stayFileCount
        return n == 0 ? "No inbox files left" : "\(files(n)) stay\(n == 1 ? "s" : "") in inbox/"
    }
}
