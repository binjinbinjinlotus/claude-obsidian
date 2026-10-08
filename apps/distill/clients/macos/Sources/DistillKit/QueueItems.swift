import Foundation

// v5 queue items (queue-and-batching.md "Folders, Google Docs and syncing"): folder and Google Doc
// rows, the read-only folder tree, Refresh wording and the queue check interval. Pure formatting.

extension QueueRows {
    /// The hint under a waiting Google Doc row (not while a batch runs, as on the board).
    public static let googleDocHint = "Distill can’t open Google Docs yet, so this waits here and isn’t processed. To include it now, download it as .docx or PDF and drop that."

    /// "12 files · 3 folders · 18.4 MB · moved in at 2:40 AM"; "4 files · 9.2 MB · a file changed at 3:05 AM"
    /// while the wait runs; no time when the folder has a problem or a batch is reading it.
    static func folderMeta(_ entry: QueueEntry, now: Date, inBatch: Bool, locale: Locale, timeZone: TimeZone) -> String {
        var parts: [String] = []
        let files = entry.fileCount ?? 0
        parts.append(count(files, "file", locale: locale))
        if let folders = entry.folderCount, folders > 0 { parts.append(count(folders, "folder", locale: locale)) }
        if entry.size > 0 { parts.append(bytes(entry.size)) }
        if !inBatch, entry.problem == nil {
            let when = at(entry.modified, now: now, locale: locale, timeZone: timeZone)
            if !entry.settled || entry.changing { parts.append("a file changed \(when)") } else if entry.waiting == nil { parts.append("moved in \(when)") }
        }
        return parts.joined(separator: " · ")
    }

    /// "Google Doc · needs Google Drive access · added 2:55 AM" (no time while a batch runs);
    /// "Google Doc · no link inside" when the pointer can't be read.
    static func gdocMeta(_ entry: QueueEntry, now: Date, batchRunning: Bool, locale: Locale, timeZone: TimeZone) -> String {
        if entry.gdoc == nil || entry.problem != nil { return "Google Doc · no link inside" }
        var parts = ["Google Doc", "needs Google Drive access"]
        if !batchRunning { parts.append("added " + clock(entry.modified, now: now, locale: locale, timeZone: timeZone)) }
        return parts.joined(separator: " · ")
    }

    /// The Google Docs link of a gdoc row, only when it is https on docs.google.com or drive.google.com
    /// (the core checks too; the app never opens anything else from a pointer file).
    public static func googleDocURL(_ entry: QueueEntry) -> URL? {
        guard entry.kind == .gdoc, let raw = entry.gdoc?.url, let url = URL(string: raw),
              url.scheme?.lowercased() == "https",
              let host = url.host?.lowercased(), host == "docs.google.com" || host == "drive.google.com" else { return nil }
        return url
    }

    /// Show the hint under a Google Doc row: waiting, and no batch running (the board drops it then).
    public static func hint(_ entry: QueueEntry, batchRunning: Bool) -> String? {
        entry.kind == .gdoc && entry.waiting != nil && entry.problem == nil && !batchRunning ? googleDocHint : nil
    }

    /// "1 file", "12 files", "1,240 files".
    public static func count(_ n: Int, _ unit: String, locale: Locale = .current) -> String {
        let f = NumberFormatter()
        f.numberStyle = .decimal
        f.locale = locale
        let s = f.string(from: NSNumber(value: n)) ?? "\(n)"
        return "\(s) \(unit)\(n == 1 ? "" : "s")"
    }

    /// "18.4 MB", "4 KB".
    public static func bytes(_ n: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(n), countStyle: .file)
    }
}

// MARK: - The folder tree

/// One line of a folder's read-only tree (QueueRowView, History).
public struct QueueTreeLine: Equatable, Hashable, Sendable {
    public enum Kind: Sendable { case dir, file, gdoc, more, truncated }
    /// 0 = directly inside the folder item.
    public var depth: Int
    /// "notes/", "day1-uji.md", "… 7 more".
    public var name: String
    /// "3 files", "4 KB", "not read", "seen before · 4 KB", "14.9 MB".
    public var detail: String
    public var kind: Kind

    public init(depth: Int, name: String, detail: String, kind: Kind) {
        self.depth = depth; self.name = name; self.detail = detail; self.kind = kind
    }
}

public enum QueueTree {
    /// Rebuilds the hierarchy from the core's flat, path-sorted list. Every folder shows its first
    /// `perFolder` entries, then "… N more" with their total size. A `.gdoc` reads "not read"; an entry
    /// the collector took before reads "seen before". When the core cut the list, a last line says so.
    public static func lines(_ tree: [QueueTreeEntry], truncated: Bool = false, perFolder: Int = 5) -> [QueueTreeLine] {
        final class Node {
            var entry: QueueTreeEntry
            var children: [Node] = []
            init(_ e: QueueTreeEntry) { entry = e }
        }
        let root = Node(QueueTreeEntry(path: "", kind: .dir))
        var dirs: [String: Node] = ["": root]
        func dir(_ path: String) -> Node {
            if let d = dirs[path] { return d }
            let node = Node(QueueTreeEntry(path: path, kind: .dir))
            dirs[path] = node
            parent(of: path).children.append(node)
            return node
        }
        func parent(of path: String) -> Node {
            guard let slash = path.lastIndex(of: "/") else { return root }
            return dir(String(path[..<slash]))
        }
        for raw in tree {
            let path = raw.path.split(separator: "/").joined(separator: "/")
            guard !path.isEmpty else { continue }
            var e = raw
            e.path = path
            if e.kind == .dir {
                if let existing = dirs[path] { existing.entry = e } else {
                    let node = Node(e)
                    dirs[path] = node
                    parent(of: path).children.append(node)
                }
            } else {
                parent(of: path).children.append(Node(e))
            }
        }
        func fileCount(_ n: Node) -> Int { n.children.reduce(0) { $0 + ($1.entry.kind == .dir ? fileCount($1) : 1) } }
        func size(_ n: Node) -> Int {
            if n.entry.kind != .dir { return n.entry.size }
            return n.entry.size > 0 ? n.entry.size : n.children.reduce(0) { $0 + size($1) }
        }
        var out: [QueueTreeLine] = []
        func walk(_ n: Node, depth: Int) {
            let sorted = n.children.sorted { $0.entry.path.localizedStandardCompare($1.entry.path) == .orderedAscending }
            for (i, child) in sorted.enumerated() {
                if i == perFolder {
                    let rest = sorted[i...]
                    out.append(QueueTreeLine(depth: depth, name: "… \(rest.count) more",
                                             detail: QueueRows.bytes(rest.reduce(0) { $0 + size($1) }), kind: .more))
                    break
                }
                let name = String(child.entry.path.split(separator: "/").last ?? "")
                switch child.entry.kind {
                case .dir:
                    out.append(QueueTreeLine(depth: depth, name: name + "/", detail: QueueRows.count(fileCount(child), "file"), kind: .dir))
                    walk(child, depth: depth + 1)
                case .gdoc:
                    out.append(QueueTreeLine(depth: depth, name: name, detail: "not read", kind: .gdoc))
                case .file:
                    let s = QueueRows.bytes(child.entry.size)
                    out.append(QueueTreeLine(depth: depth, name: name, detail: child.entry.seenBefore ? "seen before · \(s)" : s, kind: .file))
                }
            }
        }
        walk(root, depth: 0)
        if truncated {
            out.append(QueueTreeLine(depth: 0, name: "… the list stops here", detail: "too many entries to show", kind: .truncated))
        }
        return out
    }
}

// MARK: - Batches: a folder is one source

/// One source of a batch as the Queue, Review and History show it: a file, or a folder item with the
/// files the batch took from it (`job.folders`, v5). A note's `.distill.json` sidecar is not a source.
public enum BatchSource: Equatable, Hashable, Sendable {
    case file(String)
    /// `path`: vault-relative folder ("inbox/2026-10-04/Tea tasting trip"); `files`: its files in `job.files`.
    case folder(path: String, files: [String])

    public var path: String {
        switch self {
        case .file(let p): return p
        case .folder(let p, _): return p
        }
    }

    public var name: String { (path as NSString).lastPathComponent }
}

extension Job {
    /// The batch's sources, a folder once (in the order it first appears). Jobs from before v5 have no
    /// `folders` and list every file, as before.
    public var sources: [BatchSource] {
        let folders = (self.folders ?? []).map { $0.hasSuffix("/") ? String($0.dropLast()) : $0 }
        var out: [BatchSource] = []
        var seen = Set<String>()
        var byFolder: [String: [String]] = [:]
        for file in files where !file.hasSuffix(QueueRows.manifestSuffix) {
            if let folder = folders.first(where: { file.hasPrefix($0 + "/") }) {
                byFolder[folder, default: []].append(file)
                if seen.insert(folder).inserted { out.append(.folder(path: folder, files: [])) }
            } else {
                out.append(.file(file))
            }
        }
        // A folder whose files are all seen before or .gdoc pointers still counts once.
        for folder in folders where !seen.contains(folder) { out.append(.folder(path: folder, files: [])) }
        return out.map {
            if case .folder(let p, _) = $0 { return .folder(path: p, files: byFolder[p] ?? []) }
            return $0
        }
    }
}

// MARK: - Refresh and the queue check

/// QueueRefresh's state (canvas: QueueRefresh).
public enum QueueRefreshState: Equatable, Sendable {
    case idle
    case checking
    /// Green: new items.
    case found(String)
    /// Gray: nothing new, or only items gone or changed.
    case nothing(String)
    /// Peach: "Can't read the queue folder".
    case error(String)

    /// The result a scan shows for 4 seconds after Refresh.
    public static func result(_ r: QueueScanResult) -> QueueRefreshState {
        if r.problem != nil { return .error("Can’t read the queue folder") }
        let gone = r.removed > 0 ? (r.removed == 1 ? "1 item gone" : "\(r.removed) items gone") : nil
        if r.added > 0 {
            let found = r.added == 1 ? "1 new item found" : "\(r.added) new items found"
            return .found(gone.map { "\(found) · \($0)" } ?? found)
        }
        if let gone { return .nothing(gone) }
        if r.changed > 0 { return .nothing(r.changed == 1 ? "1 item changed" : "\(r.changed) items changed") }
        return .nothing("Nothing new")
    }

    /// "checked at 3:41 AM" ("checked Oct 3 at 3:41 AM" on another day); nil before the first scan.
    public static func checked(_ date: Date?, now: Date = Date(), locale: Locale = .current, timeZone: TimeZone = .current) -> String? {
        date.map { "checked " + QueueRows.at($0, now: now, locale: locale, timeZone: timeZone) }
    }
}

/// Settings → Batching → "Check the queue folder for changes".
public enum QueueScanInterval {
    /// The menu, in order (minutes; 0 = Off).
    public static let options = [1, 5, 15, 60, 0]

    /// "Every minute", "Every 5 min", "Every hour", "Off"; a value the CLI set ("Every 30 min", "Every 2 hours") as it is.
    public static func label(_ minutes: Int) -> String {
        switch minutes {
        case ...0: return "Off"
        case 1: return "Every minute"
        case 60: return "Every hour"
        case let m where m % 60 == 0: return "Every \(m / 60) hours"
        default: return "Every \(minutes) min"
        }
    }
}
