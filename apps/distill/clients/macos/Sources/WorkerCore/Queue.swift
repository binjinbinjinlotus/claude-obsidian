import Foundation

/// Files waiting in a queue directory. Batching happens on a schedule, not per file.
public enum QueueScanner {
    static let partialSuffixes = [".crdownload", ".part", ".download", ".tmp", ".partial"]

    public struct Entry: Equatable, Sendable {
        public var url: URL
        public var modified: Date
        public var size: Int
    }

    /// Top-level, non-hidden regular files. Folders are left for the user.
    public static func pending(in dir: URL) -> [Entry] {
        let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
        guard let urls = try? FileManager.default.contentsOfDirectory(
            at: dir, includingPropertiesForKeys: keys, options: [.skipsHiddenFiles]) else { return [] }
        return urls.compactMap { url in
            guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
            let name = url.lastPathComponent.lowercased()
            if partialSuffixes.contains(where: name.hasSuffix) { return nil }
            return Entry(url: url, modified: v.contentModificationDate ?? .distantPast, size: v.fileSize ?? 0)
        }
        .sorted { $0.modified < $1.modified }
    }

    /// Entries unmodified for at least `settle` seconds (still-copying files wait).
    public static func settled(_ entries: [Entry], settle: TimeInterval, now: Date = Date()) -> [Entry] {
        entries.filter { now.timeIntervalSince($0.modified) >= settle }
    }
}

public enum QueueMover {
    /// Moves settled queue files into `<vault>/inbox/` so provenance stays inside
    /// the vault. Returns vault-relative paths. When the queue *is* the inbox,
    /// files stay put and only unclaimed ones are returned.
    public static func claim(
        _ entries: [Entry], vault: VaultProfile, alreadyClaimed: Set<String>
    ) throws -> [String] {
        let fm = FileManager.default
        let inbox = vault.inboxURL.standardizedFileURL
        try fm.createDirectory(at: inbox, withIntermediateDirectories: true)
        let queueIsInbox = vault.queueURL.standardizedFileURL.path == inbox.path
        var claimed: [String] = []
        for entry in entries {
            let target: URL
            if queueIsInbox {
                target = entry.url.standardizedFileURL
            } else {
                target = uniqueDestination(for: entry.url.lastPathComponent, in: inbox)
                try fm.moveItem(at: entry.url, to: target)
            }
            let rel = "inbox/" + target.lastPathComponent
            if !alreadyClaimed.contains(rel) { claimed.append(rel) }
        }
        return claimed
    }

    public typealias Entry = QueueScanner.Entry

    public static func uniqueDestination(for name: String, in dir: URL) -> URL {
        let fm = FileManager.default
        var candidate = dir.appendingPathComponent(name)
        let base = (name as NSString).deletingPathExtension
        let ext = (name as NSString).pathExtension
        var n = 2
        while fm.fileExists(atPath: candidate.path) {
            let next = ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)"
            candidate = dir.appendingPathComponent(next)
            n += 1
        }
        return candidate
    }
}

/// Puts dropped files and pasted content into the queue directory.
/// Drops copy (the original stays where it was); pastes become new files.
public enum QueueIntake {
    @discardableResult
    public static func copyFiles(_ urls: [URL], into queue: URL) throws -> [URL] {
        let fm = FileManager.default
        try fm.createDirectory(at: queue, withIntermediateDirectories: true)
        var out: [URL] = []
        for url in urls {
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: url.path, isDirectory: &isDir), !isDir.boolValue else { continue }
            let dest = QueueMover.uniqueDestination(for: url.lastPathComponent, in: queue)
            try fm.copyItem(at: url, to: dest)
            out.append(dest)
        }
        return out
    }

    @discardableResult
    public static func write(_ data: Data, prefix: String, ext: String, into queue: URL, date: Date = Date()) throws -> URL {
        try FileManager.default.createDirectory(at: queue, withIntermediateDirectories: true)
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "yyyy-MM-dd HHmmss"
        let dest = QueueMover.uniqueDestination(for: "\(prefix) \(f.string(from: date)).\(ext)", in: queue)
        try data.write(to: dest, options: .atomic)
        return dest
    }
}
