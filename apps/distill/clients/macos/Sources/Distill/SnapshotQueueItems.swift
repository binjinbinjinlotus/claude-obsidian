import AppKit
import SwiftUI
import DistillKit

// Snapshot states for v5 queue items (canvas v64: Main, MainLoading, MainEmpty, MainFolder, QueueItems
// cards, QueueRowView and QueueRefresh states). Ids match the boards' page ids.

extension StatesSnapshot {
    static func queueItemStates() {
        let f = Flow.intake
        let now = Date()
        func ago(_ minutes: Double) -> Date { now.addingTimeInterval(-minutes * 60) }

        var e = engine()
        e.queued = itemQueue(e, collapsedFolder: true)
        e.lastScanSeen = ago(1)
        main("queue", f, "Queue", "A note, a file, a folder and a Google Doc",
             "The queue lists what is really in the queue folder: a folder is one item (12 files · 3 folders), a .gdoc waits for Google Drive access. Refresh after Reveal in Finder, “checked at …”.",
             e, section: .queue) { QueueView() }
        e = engine()
        e.queued = itemQueue(e, collapsedFolder: true)
        e.lastScanSeen = ago(1)
        main("queue-900", f, "Queue", "Folder and Google Doc rows · smallest window (900 pt)",
             "The same queue at the window's minimum width: Refresh moves under the path when the line is too narrow.",
             e, section: .queue, size: CGSize(width: 900, height: 760)) { QueueView() }

        e = engine()
        e.queued = Array(itemQueue(e, collapsedFolder: false).dropFirst())
        e.refreshState = .found("2 new items found")
        main("queue-refreshed", f, "Queue", "Refresh found a folder and a Google Doc",
             "Refresh re-synced the list: “2 new items found” for 4 seconds; the folder's read-only tree is open (5 entries per folder, then “… N more”).",
             e, section: .queue) { QueueView(expandedPaths: [folderPath(e)]) }
        e = engine()
        e.queued = Array(itemQueue(e, collapsedFolder: false).dropFirst())
        e.refreshState = .found("2 new items found")
        main("queue-refreshed-900", f, "Queue", "Refresh result · smallest window (900 pt)",
             "The refresh result and the open tree at the window's minimum width.",
             e, section: .queue, size: CGSize(width: 900, height: 760)) { QueueView(expandedPaths: [folderPath(e)]) }

        for (id, size) in [("queue-running", mainSize), ("queue-running-900", CGSize(width: 900, height: 760))] {
            e = engine()
            let started = ago(2)
            let folder = "inbox/2026-10-04/Tea tasting trip"
            var batch = job(e, "job-folder-batch", .running,
                            files: ["inbox/2026-10-04/Gyokuro at 60 °C.md", "inbox/2026-10-04/Screenshot 15.32.12.png",
                                    folder + "/notes/day1-uji.md", folder + "/notes/day2-wazuka.md", folder + "/receipts/tea-shop.pdf"],
                            minutesAgo: 0)
            batch.folders = [folder]
            batch.createdAt = started
            MainQueueEntries.seed(folderEntry(path: vault(e) + "/" + folder, modified: ago(60)), path: folder, vaultPath: vault(e))
            e.jobs = [batch]
            e.queued = [gdocEntry(e, modified: ago(0.5))]
            e.lastScanSeen = ago(1)
            e.progress[batch.id] = CoreProgress(key: batch.id, kind: "batch", message: "Reading 3 sources",
                                                steps: ["Moved to inbox", "Read sources", "Drafting page changes", "Ready for review"],
                                                stepIndex: 2, startedAt: started, runnerID: "claude-code", model: "sonnet")
            main(id, f, "Queue", size == mainSize ? "Batch running with a folder" : "Batch running with a folder · smallest window (900 pt)",
                 "“3 in this batch · 1 waiting”: the folder is one In batch row (no ×); the Google Doc keeps waiting.",
                 e, section: .queue, size: size) { QueueView() }
        }

        refreshStates(f)
        rowStates(f)
        cardStates(f)
    }

    // MARK: fixtures

    static func folderPath(_ e: AppModel) -> String {
        (e.activeVault?.queueURL ?? URL(fileURLWithPath: "/q")).appendingPathComponent("Tea tasting trip").path
    }

    static let teaTree: [QueueTreeEntry] = {
        var t: [QueueTreeEntry] = [
            .init(path: "notes", size: 10_180, kind: .dir), .init(path: "notes/day1-uji.md", size: 4_000),
            .init(path: "notes/day2-wazuka.md", size: 6_000), .init(path: "notes/tasting-sheet.gdoc", size: 180, kind: .gdoc),
            .init(path: "photos", size: 17_000_000, kind: .dir), .init(path: "photos/IMG_2041.HEIC", size: 2_100_000),
        ]
        for i in 2...8 { t.append(.init(path: "photos/IMG_204\(i).HEIC", size: 2_128_571)) }
        t += [.init(path: "receipts", size: 220_000, kind: .dir), .init(path: "receipts/tea-shop.pdf", size: 220_000)]
        return t
    }()

    static func folderEntry(path: String, modified: Date, settled: Bool = true) -> QueueEntry {
        QueueEntry(path: path, modified: modified, size: 18_400_000, settled: settled, kind: .folder,
                   fileCount: 12, folderCount: 3, tree: teaTree)
    }

    static func gdocEntry(_ e: AppModel, modified: Date) -> QueueEntry {
        let dir = e.activeVault?.queueURL ?? URL(fileURLWithPath: "/q")
        return QueueEntry(path: dir.appendingPathComponent("Q3 tea club plan.gdoc").path, modified: modified, size: 180, settled: true, kind: .gdoc,
                          gdoc: .init(title: "Q3 tea club plan", url: "https://docs.google.com/document/d/1AbCdEf/edit", docId: "1AbCdEf"),
                          waiting: "google-drive")
    }

    /// Main: a written note, a screenshot waiting for its ready time, a folder, a Google Doc.
    static func itemQueue(_ e: AppModel, collapsedFolder: Bool) -> [QueueEntry] {
        let dir = e.activeVault?.queueURL ?? URL(fileURLWithPath: "/q")
        let now = Date()
        let note = QueueEntry(path: dir.appendingPathComponent("Gyokuro at 60 °C.md").path, modified: now.addingTimeInterval(-3600),
                              size: 900, settled: true, kind: .note,
                              note: .init(source: "In person", imageCount: 1))
        let shot = QueueEntry(path: dir.appendingPathComponent("Screenshot 15.32.12.png").path, modified: now.addingTimeInterval(-60),
                              size: 1_800_000, settled: false, readyAt: now.addingTimeInterval(540))
        return [note, shot, folderEntry(path: folderPath(e), modified: now.addingTimeInterval(-3700)), gdocEntry(e, modified: now.addingTimeInterval(-2800))]
    }

    // MARK: components

    private static func refreshStates(_ f: Flow) {
        let e = engine()
        let checked = QueueRefreshState.checked(Date().addingTimeInterval(-60))
        natural("queue-refresh-states", f, "Queue refresh", "QueueRefresh states",
                "Idle (“checked at …”), Checking… (disabled), Found, Nothing new, an item gone, and Can't read the queue folder.", e) {
            VStack(alignment: .leading, spacing: 14) {
                QueueRefresh(state: .idle, checked: checked)
                QueueRefresh(state: .checking, checked: checked)
                QueueRefresh(state: .found("2 new items found"), checked: checked)
                QueueRefresh(state: .nothing("Nothing new"), checked: checked)
                QueueRefresh(state: .nothing("1 item gone"), checked: checked)
                QueueRefresh(state: .error("Can’t read the queue folder"), checked: checked)
            }
            .padding(20).background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        }
    }

    private static func rowStates(_ f: Flow) {
        let e = engine()
        let now = Date()
        let dir = e.activeVault?.queueURL ?? URL(fileURLWithPath: "/q")
        let folder = folderEntry(path: folderPath(e), modified: now.addingTimeInterval(-3700))
        var changing = QueueEntry(path: dir.appendingPathComponent("Scans 2026-10").path, modified: now.addingTimeInterval(-120), size: 9_200_000,
                                  settled: false, readyAt: now.addingTimeInterval(480), kind: .folder, fileCount: 4, folderCount: 0,
                                  tree: [.init(path: "scan-1.pdf", size: 2_300_000)])
        changing.changing = true
        var big = QueueEntry(path: dir.appendingPathComponent("Photo library export").path, modified: now, size: 6_200_000_000, settled: true,
                             kind: .folder, problem: "too big", fileCount: 1240, folderCount: 41, tree: [.init(path: "IMG_0001.HEIC", size: 4_000_000)])
        let deep = QueueEntry(path: dir.appendingPathComponent("Archive").path, modified: now, size: 40_000, settled: true,
                              kind: .folder, problem: "too deep", fileCount: 3, folderCount: 9, tree: [.init(path: "a", kind: .dir)])
        let empty = QueueEntry(path: dir.appendingPathComponent("New Folder").path, modified: now, size: 0, settled: true,
                               kind: .folder, problem: "empty folder", fileCount: 0, folderCount: 0, tree: [])
        let doc = gdocEntry(e, modified: now.addingTimeInterval(-2800))
        let broken = QueueEntry(path: dir.appendingPathComponent("Untitled document.gdoc").path, modified: now, size: 3, settled: true,
                                kind: .gdoc, problem: "no link inside")
        let file = QueueEntry(path: dir.appendingPathComponent("gongfu-brewing-guide.pdf").path, modified: now.addingTimeInterval(-5400),
                              size: 2_300_000, settled: true)
        big.changing = false
        func row(_ entry: QueueEntry, batchRunning: Bool = false, inBatch: Bool = false, expanded: Bool = false) -> some View {
            let status = inBatch ? QueueRowStatus.inBatch : QueueRows.status(entry, batchRunning: batchRunning)
            return QueueRowView(title: QueueRows.title(entry), meta: QueueRows.meta(entry, inBatch: inBatch, batchRunning: batchRunning),
                                tileName: entry.name, status: status, help: QueueRows.pillHelp(status, settleSeconds: 600),
                                kind: entry.kind, expanded: expanded, tree: QueueTree.lines(entry.tree ?? []),
                                hint: QueueRows.hint(entry, batchRunning: batchRunning || inBatch),
                                onRemove: {}, onOpenLink: QueueRows.googleDocURL(entry).map { _ in {} })
                .frame(width: 760)
                .padding(6).background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
                .overlay(RoundedRectangle(cornerRadius: 16).strokeBorder(Color(hex: 0xECEAE5)))
        }
        natural("queue-row-states", f, "Queue row", "QueueRowView: files, folders and Google Docs",
                "File; folder; folder expanded; folder still changing; too big, too deep, empty folder; folder in a batch; Google Doc waiting; Google Doc while a batch runs; pointer unreadable.", e) {
            VStack(alignment: .leading, spacing: 14) {
                row(file)
                row(folder)
                row(folder, expanded: true)
                row(changing)
                row(big)
                row(deep)
                row(empty)
                row(folder, inBatch: true)
                row(doc)
                row(doc, batchRunning: true)
                row(broken)
            }
        }
    }

    private static func cardStates(_ f: Flow) {
        var e = engine()
        natural("queue-card-settings", f, "Settings → Batching", "The queue check",
                "New last row on the Batching page: Check the queue folder for changes, every 5 minutes by default; Off leaves Refresh and the check when the window opens.", e) {
            BatchingSettings().frame(width: 560).padding(22)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        }

        let folder = "inbox/2026-10-04/Tea tasting trip"
        let files = [folder + "/notes/day1-uji.md", folder + "/notes/day2-wazuka.md", folder + "/photos/IMG_2041.HEIC", folder + "/receipts/tea-shop.pdf",
                     "inbox/2026-10-04/Screenshot 15.32.12.png"]
        e = engine()
        MainQueueEntries.seed(folderEntry(path: vault(e) + "/" + folder, modified: Date()), path: folder, vaultPath: vault(e))
        var review = awaiting(e, files: files)
        review.folders = [folder]
        e.jobs = [review]
        let usage: [String: [String]] = [files[0]: ["Uji tea farms"], files[1]: ["Wazuka", "Tea tasting trip 2026"],
                                         files[2]: ["Tea tasting trip 2026"], files[3]: [], files[4]: ["Tea tasting trip 2026"]]
        natural("queue-card-review", f, "Review", "A folder as one source",
                "Sources in this batch: the folder once, with Show files open: each file and the pages it was used in; the .gdoc inside is not read.", e) {
            JobSourcesView(job: review, mode: .review, openFolders: [folder], fixtureUsage: usage)
                .frame(width: 516).padding(22)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        }

        e = engine()
        MainQueueEntries.seed(folderEntry(path: vault(e) + "/" + folder, modified: Date()), path: folder, vaultPath: vault(e))
        var done = job(e, "job-folder-done", .completed, files: files, minutesAgo: 30, changed: changePaths, op: "op-20261004-0341-a1b2")
        done.folders = [folder]
        e.jobs = [done]
        natural("queue-card-history", f, "History → Jobs", "Sources: a folder with its tree",
                "The folder is one source row with its file count and inbox location; it expands to the same read-only tree as the queue row.", e) {
            JobSourcesView(job: done, mode: .history, openFolders: [folder])
                .frame(width: 516).padding(22)
                .background(RoundedRectangle(cornerRadius: 16).fill(Color.white))
        }
    }
}
