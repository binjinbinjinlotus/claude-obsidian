import Foundation

/// Reads a folder item that a batch already moved into the vault (`job.folders`), so the Queue's
/// in-batch row, Review and History can show the same counts and tree as the queue row. Read-only;
/// skips hidden files, symlinks and `.DS_Store`, like the core's walk.
public enum QueueFolderWalk {
    /// A folder entry ("12 files · 3 folders · 18.4 MB" and its tree), or nil when the folder is gone.
    public static func entry(at url: URL, maxEntries: Int = 500) -> QueueEntry? {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: url.path, isDirectory: &isDir), isDir.boolValue else { return nil }
        let keys: [URLResourceKey] = [.isDirectoryKey, .isSymbolicLinkKey, .fileSizeKey, .contentModificationDateKey]
        guard let walker = FileManager.default.enumerator(at: url, includingPropertiesForKeys: keys,
                                                          options: [.skipsHiddenFiles]) else { return nil }
        let base = url.standardizedFileURL.resolvingSymlinksInPath().path
        var tree: [QueueTreeEntry] = []
        var files = 0, folders = 0, total = 0
        var newest: Date?
        var truncated = false
        var dirSizes: [String: Int] = [:]
        for case let item as URL in walker {
            guard let v = try? item.resourceValues(forKeys: Set(keys)) else { continue }
            if v.isSymbolicLink == true { if v.isDirectory == true { walker.skipDescendants() }; continue }
            let full = item.standardizedFileURL.resolvingSymlinksInPath().path
            guard full.hasPrefix(base + "/") else { continue }
            let rel = String(full.dropFirst(base.count + 1))
            if item.lastPathComponent == ".DS_Store" { continue }
            if v.isDirectory == true {
                folders += 1
                if tree.count < maxEntries { tree.append(QueueTreeEntry(path: rel, kind: .dir)) } else { truncated = true }
                continue
            }
            let size = v.fileSize ?? 0
            files += 1
            total += size
            if let m = v.contentModificationDate, newest.map({ m > $0 }) ?? true { newest = m }
            var parent = (rel as NSString).deletingLastPathComponent
            while !parent.isEmpty { dirSizes[parent, default: 0] += size; parent = (parent as NSString).deletingLastPathComponent }
            let kind: QueueTreeEntry.Kind = item.pathExtension.lowercased() == "gdoc" ? .gdoc : .file
            if tree.count < maxEntries { tree.append(QueueTreeEntry(path: rel, size: size, kind: kind)) } else { truncated = true }
        }
        tree = tree.map { e in
            var e = e
            if e.kind == .dir { e.size = dirSizes[e.path] ?? 0 }
            return e
        }.sorted { $0.path < $1.path }
        return QueueEntry(path: url.path, modified: newest ?? Date.distantPast, size: total, settled: true, kind: .folder,
                          fileCount: files, folderCount: folders, tree: tree, treeTruncated: truncated)
    }
}
