import Foundation

/// "used in" for Review's sources (queue-and-batching.md "Review"). The core keeps no source → page
/// map, so this is a heuristic over the changed pages' text: a page uses a source when it mentions the
/// source's vault path ("inbox/2026-10-04/Tea tasting trip/notes/day1-uji.md") or its path from the batch
/// folder ("Tea tasting trip/notes/day1-uji.md"; the prompt gives the runner paths relative to the folder
/// each input is in). Read-only; nothing here writes.
public enum SourceUsage {
    /// Changed paths that count as pages (Markdown, not the log, hot cache, index or ledgers).
    public static func isPage(_ path: String) -> Bool {
        guard path.lowercased().hasSuffix(".md") else { return false }
        if path.hasPrefix(".raw/") || path.hasPrefix(".vault-meta/") || path.hasPrefix("wiki/meta/") { return false }
        return !["wiki/log.md", "wiki/hot.md", "wiki/index.md"].contains(path)
    }

    /// The page's title for "used in": its file stem.
    public static func title(_ page: String) -> String {
        ((page as NSString).lastPathComponent as NSString).deletingPathExtension
    }

    /// Titles of the pages that mention `file` (vault-relative), in page order.
    public static func pages(using file: String, in pages: [(path: String, text: String)]) -> [String] {
        var needles = [file]
        // The path from the folder the input sits in ("inbox/<date>/"): "<folder>/<inside>" or the file name.
        let parts = file.split(separator: "/")
        if parts.count >= 3, parts[0] == "inbox" { needles.append(parts.dropFirst(2).joined(separator: "/")) }
        needles = needles.filter { $0.contains("/") } // a bare name is too loose to call "used"
        return pages.filter { p in needles.contains { p.text.contains($0) } }.map { title($0.path) }
    }

    /// The pages a batch waiting for approval would write, from its transaction bundle (`writes` with
    /// inline `content` or a `content_file` next to the bundle). nil when the bundle can't be read in full.
    public static func bundlePages(_ bundlePath: String, changed: [String]) -> [(path: String, text: String)]? {
        let url = URL(fileURLWithPath: bundlePath)
        guard let data = try? Data(contentsOf: url), data.count < 64 * 1024 * 1024,
              let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let writes = root["writes"] as? [[String: Any]] else { return nil }
        var out: [(String, String)] = []
        for w in writes {
            guard let path = w["path"] as? String, isPage(path) else { continue }
            if let text = w["content"] as? String {
                out.append((path, text))
            } else if let file = w["content_file"] as? String {
                let f = file.hasPrefix("/") ? URL(fileURLWithPath: file) : url.deletingLastPathComponent().appendingPathComponent(file)
                guard let text = try? String(contentsOf: f, encoding: .utf8) else { return nil }
                out.append((path, text))
            }
        }
        let pages = Set(changed.filter(isPage))
        return out.filter { pages.isEmpty || pages.contains($0.0) }.map { (path: $0.0, text: $0.1) }
    }

    /// An applied batch's pages, read from the vault. nil when one can't be read (then nothing says "not used").
    public static func vaultPages(_ vaultPath: String, changed: [String]) -> [(path: String, text: String)]? {
        var out: [(path: String, text: String)] = []
        for path in changed where isPage(path) {
            guard let text = try? String(contentsOf: URL(fileURLWithPath: vaultPath).appendingPathComponent(path), encoding: .utf8) else { return nil }
            out.append((path: path, text: text))
        }
        return out
    }
}
