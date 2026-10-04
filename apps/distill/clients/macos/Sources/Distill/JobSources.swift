import AppKit
import SwiftUI
import DistillKit

/// A batch's sources on Review and History (canvas: QueueItems cards 2 and 3). A folder shows once:
/// on Review with its files and the pages each one was used in (Show files), on History with its
/// file count, its inbox location and the same read-only tree as the queue row.
struct JobSourcesView: View {
    enum Mode { case review, history }

    let job: Job
    var mode: Mode
    /// Snapshots: folders that start open.
    var openFolders: Set<String> = []
    @State private var opened: Set<String>?
    @State private var usage: [String: [String]]?

    private var open: Set<String> { opened ?? openFolders }

    var body: some View {
        let sources = job.sources
        VStack(alignment: .leading, spacing: 8) {
            Text(mode == .review ? "SOURCES IN THIS BATCH · \(sources.count)" : "SOURCES")
                .font(Theme.body(10, .heavy)).tracking(0.6).foregroundStyle(Theme.faint)
            VStack(alignment: .leading, spacing: 6) {
                ForEach(sources, id: \.self) { source in
                    switch source {
                    case .file(let path): fileRow(path)
                    case .folder(let path, let files): folderRow(path, files: files)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .task(id: "\(job.id)|\(job.state.rawValue)|\(job.updatedAt.timeIntervalSince1970)") { loadUsage() }
    }

    // MARK: rows

    private func fileRow(_ path: String) -> some View {
        let name = (path as NSString).lastPathComponent
        let style = FileStyle.tile(for: name)
        return Button { reveal(path) } label: {
            HStack(spacing: 8) {
                Tile(text: style.0, fill: style.1, ink: style.2, size: 22)
                Text(name).font(Theme.body(13)).foregroundStyle(Theme.ink).lineLimit(1).truncationMode(.middle)
                if mode == .review, let pages = usage?[path] { usageText(pages).font(Theme.body(12)).lineLimit(1) }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help("Show \(name) in Finder")
    }

    @ViewBuilder private func folderRow(_ path: String, files: [String]) -> some View {
        let entry = folderEntry(path, files: files)
        let isOpen = open.contains(path)
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Image(systemName: "folder").font(.system(size: 12, weight: .medium)).foregroundStyle(Color(hex: 0x8A5A00))
                Text(entry.name + "/").font(Theme.body(13, mode == .review ? .semibold : .regular)).lineLimit(1)
                Text(folderMeta(entry, path: path)).font(Theme.body(12.5)).foregroundStyle(Theme.muted).lineLimit(1)
                Spacer(minLength: 0)
                if mode == .review {
                    Button(isOpen ? "Hide files" : "Show files") { toggle(path) }
                        .buttonStyle(.plain).font(Theme.body(12, .semibold)).foregroundStyle(Theme.primary).fixedSize()
                } else {
                    Image(systemName: isOpen ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .bold)).foregroundStyle(Theme.faint)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture { if mode == .history { toggle(path) } }
            .contextMenu { Button("Show in Finder") { reveal(path) } }
            .accessibilityElement(children: .combine)
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { toggle(path) }
            if isOpen {
                if mode == .review {
                    reviewFiles(path, entry: entry, files: files).padding(.leading, 22)
                } else {
                    QueueTreeView(lines: QueueTree.lines(entry.tree ?? [], truncated: entry.treeTruncated)).padding(.leading, 22)
                }
            }
        }
    }

    /// Each file with the pages it was used in ("not used" only when every page could be read);
    /// a .gdoc inside: "not read: needs Google Drive access".
    private func reviewFiles(_ path: String, entry: QueueEntry, files: [String]) -> some View {
        let gdocs = (entry.tree ?? []).filter { $0.kind == .gdoc }.map(\.path)
        return VStack(alignment: .leading, spacing: 2) {
            ForEach(files, id: \.self) { file in
                HStack(spacing: 0) {
                    Text(inside(file, folder: path)).foregroundStyle(Theme.muted)
                    if let pages = usage?[file] { usageText(pages) }
                }
                .font(Theme.body(12)).lineLimit(1).truncationMode(.middle)
            }
            ForEach(gdocs, id: \.self) { g in
                Text("\(g) · not read: needs Google Drive access").font(Theme.body(12)).foregroundStyle(Color(hex: 0x8A5A00)).lineLimit(1)
            }
            if files.isEmpty && gdocs.isEmpty {
                Text("No files from this folder were given to the AI.").font(Theme.body(12)).foregroundStyle(Theme.faint)
            }
        }
    }

    private func usageText(_ pages: [String]) -> Text {
        if pages.isEmpty { return Text(" · not used").foregroundColor(Theme.faint) }
        var t = Text(" · used in ").foregroundColor(Theme.muted)
        for (i, p) in pages.enumerated() {
            if i > 0 { t = t + Text(", ").foregroundColor(Theme.muted) }
            t = t + Text(p).fontWeight(.semibold).foregroundColor(Theme.ink)
        }
        return t
    }

    // MARK: data

    private func folderEntry(_ path: String, files: [String]) -> QueueEntry {
        MainQueueEntries.folder(path, files: files, vaultPath: job.vaultPath)
    }

    /// Review: "folder · 12 files · 3 folders"; History: "· 12 files · in inbox/2026-10-04/".
    private func folderMeta(_ e: QueueEntry, path: String) -> String {
        let files = QueueRows.count(e.fileCount ?? 0, "file")
        if mode == .history {
            let dir = (path as NSString).deletingLastPathComponent
            return "· \(files)" + (dir.isEmpty ? "" : " · in \(dir)/")
        }
        var parts = ["folder", files]
        if let f = e.folderCount, f > 0 { parts.append(QueueRows.count(f, "folder")) }
        return parts.joined(separator: " · ")
    }

    private func inside(_ file: String, folder: String) -> String {
        file.hasPrefix(folder + "/") ? String(file.dropFirst(folder.count + 1)) : file
    }

    private func toggle(_ path: String) {
        var s = open
        if s.contains(path) { s.remove(path) } else { s.insert(path) }
        withAnimation(.easeOut(duration: 0.15)) { opened = s }
    }

    private func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: job.vaultPath).appendingPathComponent(path)])
    }

    /// Which pages use each source (Review only; see SourceUsage for the heuristic).
    private func loadUsage() {
        guard mode == .review else { return }
        let changed = job.state == .completed ? job.changedPaths : (job.approval?.plan?.changedPaths ?? [])
        let pages: [(path: String, text: String)]?
        if job.state == .completed {
            pages = SourceUsage.vaultPages(job.vaultPath, changed: changed)
        } else if let bundle = job.approval?.bundlePath {
            pages = SourceUsage.bundlePages(bundle, changed: changed)
        } else {
            pages = nil
        }
        guard let pages, !pages.isEmpty else { usage = nil; return }
        var out: [String: [String]] = [:]
        for file in job.files where !file.hasSuffix(QueueRows.manifestSuffix) {
            out[file] = SourceUsage.pages(using: file, in: pages)
        }
        usage = out
    }
}

/// Folder entries read from the vault, cached per path for the life of the app (a moved-in folder
/// doesn't change under a batch; History reads it again after a restart).
@MainActor
enum MainQueueEntries {
    private static var cache: [String: QueueEntry] = [:]

    static func folder(_ path: String, files: [String], vaultPath: String) -> QueueEntry {
        let key = vaultPath + "|" + path
        if let hit = cache[key] { return hit }
        let entry = QueueView.batchEntry(.folder(path: path, files: files), vaultPath: vaultPath)
        if entry.tree != nil { cache[key] = entry } // read from disk; a missing folder is tried again
        return entry
    }
}
