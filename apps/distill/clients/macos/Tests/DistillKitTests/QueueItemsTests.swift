import XCTest
@testable import DistillKit

/// v5 queue items: folder and Google Doc entries, the tree, Refresh wording, the scan route and event,
/// the queue check setting, job folders and collector subfolders.
final class QueueItemsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let en = Locale(identifier: "en_US")
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    static let folderJSON = #"""
    {"path":"/q/Tea tasting trip","name":"Tea tasting trip","modified":"2026-10-04T02:40:00Z","size":19293798,"settled":true,
     "kind":"folder","fileCount":12,"folderCount":3,"treeTruncated":false,
     "tree":[{"path":"notes","size":10240,"kind":"dir"},{"path":"notes/day1-uji.md","size":4096,"kind":"file"},
             {"path":"notes/day2-wazuka.md","size":6144,"kind":"file"},{"path":"notes/tasting-sheet.gdoc","size":180,"kind":"gdoc"},
             {"path":"photos","size":17000000,"kind":"dir"},
             {"path":"photos/IMG_2041.HEIC","size":2100000,"kind":"file"},{"path":"photos/IMG_2042.HEIC","size":2100000,"kind":"file"},
             {"path":"photos/IMG_2043.HEIC","size":2100000,"kind":"file"},{"path":"photos/IMG_2044.HEIC","size":2100000,"kind":"file"},
             {"path":"photos/IMG_2045.HEIC","size":2100000,"kind":"file"},{"path":"photos/IMG_2046.HEIC","size":2100000,"kind":"file"},
             {"path":"photos/IMG_2047.HEIC","size":2100000,"kind":"file", "seenBefore": true},
             {"path":"receipts/tea-shop.pdf","size":220000,"kind":"file"},{"path":"x","kind":"weird"},{"size":3}]}
    """#

    func testDecodesFolderAndGoogleDocEntries() throws {
        let json = "[\(Self.folderJSON),"
            + #"""
            {"path":"/q/Q3 tea club plan.gdoc","name":"Q3 tea club plan.gdoc","modified":"2026-10-04T02:55:00Z","size":180,"settled":true,
             "kind":"gdoc","gdoc":{"title":"Q3 tea club plan","url":"https://docs.google.com/document/d/abc/edit","docId":"abc"},"waiting":"google-drive"},
            {"path":"/q/Untitled document.gdoc","name":"Untitled document.gdoc","modified":"2026-10-04T02:55:00Z","size":3,"settled":true,
             "kind":"gdoc","problem":"no link inside","fileCount":"many","tree":"nope","waiting":""}]
            """#
        let entries = try JSONDecoder.core.decode([QueueEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries.count, 3)
        let folder = entries[0]
        XCTAssertEqual(folder.kind, .folder)
        XCTAssertEqual(folder.fileCount, 12)
        XCTAssertEqual(folder.folderCount, 3)
        XCTAssertEqual(folder.tree?.count, 14, "a tree entry without a path is dropped; an unknown kind reads as file")
        XCTAssertEqual(folder.tree?.first(where: { $0.path == "x" })?.kind, .file)
        XCTAssertEqual(folder.tree?.first(where: { $0.path.hasSuffix("2047.HEIC") })?.seenBefore, true)
        let doc = entries[1]
        XCTAssertEqual(doc.kind, .gdoc)
        XCTAssertEqual(doc.gdoc?.title, "Q3 tea club plan")
        XCTAssertEqual(doc.waiting, "google-drive")
        let broken = entries[2]
        XCTAssertNil(broken.gdoc)
        XCTAssertNil(broken.fileCount, "a mistyped field takes its default")
        XCTAssertNil(broken.tree)
        XCTAssertNil(broken.waiting, "an empty waiting is no waiting")

        let round = try JSONDecoder.core.decode([QueueEntry].self, from: JSONEncoder().encode(entries))
        XCTAssertEqual(round, entries)
    }

    func testFolderRowText() throws {
        let folder = try JSONDecoder.core.decode(QueueEntry.self, from: Data(Self.folderJSON.utf8))
        let now = date("2026-10-04T03:41:00Z")
        XCTAssertEqual(plain(QueueRows.meta(folder, now: now, locale: en, timeZone: utc)), "12 files · 3 folders · 19.3 MB · moved in at 2:40 AM")
        XCTAssertEqual(plain(QueueRows.meta(folder, now: now, inBatch: true, locale: en, timeZone: utc)), "12 files · 3 folders · 19.3 MB")
        XCTAssertEqual(QueueRows.title(folder), "Tea tasting trip")
        XCTAssertEqual(QueueRows.status(folder, batchRunning: false), .ready)

        var changing = folder
        changing.settled = false
        changing.readyAt = date("2026-10-04T03:15:00Z")
        changing.folderCount = 0
        changing.modified = date("2026-10-04T03:05:00Z")
        XCTAssertEqual(plain(QueueRows.meta(changing, now: now, locale: en, timeZone: utc)), "12 files · 19.3 MB · a file changed at 3:05 AM")
        XCTAssertEqual(QueueRows.status(changing, batchRunning: false), .readyAt(date("2026-10-04T03:15:00Z")))

        var big = folder
        big.problem = "too big"
        big.fileCount = 1240
        XCTAssertEqual(plain(QueueRows.meta(big, now: now, locale: en, timeZone: utc)), "1,240 files · 3 folders · 19.3 MB", "no time on a problem row")
        XCTAssertEqual(QueueRows.pillText(QueueRows.status(big, batchRunning: true)), "Too big", "a problem beats the batch")
        XCTAssertEqual(QueueRows.pillHelp(.problem("too big"), settleSeconds: 600),
                       "A folder item can hold up to 200 files and 500 MB. Split it into smaller folders.")
        XCTAssertEqual(QueueRows.pillText(.problem("too deep")), "Too deep")
        XCTAssertEqual(QueueRows.pillText(.problem("empty folder")), "Empty folder")
        XCTAssertEqual(QueueRows.pillText(.problem("Distill can't read this folder.")), "Couldn’t read")
    }

    func testGoogleDocRowText() {
        let now = date("2026-10-04T03:41:00Z")
        let doc = QueueEntry(path: "/q/Q3 tea club plan.gdoc", modified: date("2026-10-04T02:55:00Z"), size: 180, settled: true, kind: .gdoc,
                             gdoc: .init(title: "Q3 tea club plan", url: "https://docs.google.com/document/d/abc/edit", docId: "abc"),
                             waiting: "google-drive")
        XCTAssertEqual(QueueRows.title(doc), "Q3 tea club plan")
        XCTAssertEqual(plain(QueueRows.meta(doc, now: now, locale: en, timeZone: utc)), "Google Doc · needs Google Drive access · added 2:55 AM")
        XCTAssertEqual(QueueRows.meta(doc, now: now, batchRunning: true, locale: en, timeZone: utc), "Google Doc · needs Google Drive access")
        XCTAssertEqual(QueueRows.status(doc, batchRunning: false), .waiting("google-drive"))
        XCTAssertEqual(QueueRows.status(doc, batchRunning: true), .waiting("google-drive"), "it keeps waiting while a batch runs")
        XCTAssertEqual(QueueRows.pillText(.waiting("google-drive")), "Waiting")
        XCTAssertEqual(QueueRowStatus.waiting("google-drive").tone, .amber)
        XCTAssertTrue(QueueRowStatus.waiting("google-drive").removable)
        XCTAssertEqual(QueueRows.hint(doc, batchRunning: false), QueueRows.googleDocHint)
        XCTAssertNil(QueueRows.hint(doc, batchRunning: true), "the board drops the hint while a batch runs")
        XCTAssertEqual(QueueRows.googleDocURL(doc)?.absoluteString, "https://docs.google.com/document/d/abc/edit")

        var evil = doc
        evil.gdoc?.url = "file:///etc/passwd"
        XCTAssertNil(QueueRows.googleDocURL(evil), "only https Google links open")
        evil.gdoc?.url = "https://docs.google.com.evil.example/x"
        XCTAssertNil(QueueRows.googleDocURL(evil))

        let broken = QueueEntry(path: "/q/Untitled document.gdoc", modified: now, size: 3, settled: true, kind: .gdoc, problem: "no link inside")
        XCTAssertEqual(QueueRows.title(broken), "Untitled document")
        XCTAssertEqual(QueueRows.meta(broken, now: now), "Google Doc · no link inside")
        XCTAssertEqual(QueueRows.pillText(QueueRows.status(broken, batchRunning: false)), "Couldn’t read")
        XCTAssertNil(QueueRows.googleDocURL(broken))
        XCTAssertNil(QueueRows.hint(broken, batchRunning: false))
    }

    func testTreeShowsFiveEntriesPerFolderThenMore() throws {
        let folder = try JSONDecoder.core.decode(QueueEntry.self, from: Data(Self.folderJSON.utf8))
        let lines = QueueTree.lines(folder.tree ?? [])
        let text = lines.map { String(repeating: "  ", count: $0.depth) + "\($0.name) · \($0.detail)" }
        XCTAssertEqual(text, [
            "notes/ · 3 files",
            "  day1-uji.md · 4 KB",
            "  day2-wazuka.md · 6 KB",
            "  tasting-sheet.gdoc · not read",
            "photos/ · 7 files",
            "  IMG_2041.HEIC · 2.1 MB",
            "  IMG_2042.HEIC · 2.1 MB",
            "  IMG_2043.HEIC · 2.1 MB",
            "  IMG_2044.HEIC · 2.1 MB",
            "  IMG_2045.HEIC · 2.1 MB",
            "  … 2 more · 4.2 MB",
            "receipts/ · 1 file",
            "  tea-shop.pdf · 220 KB",
            "x · Zero KB",
        ])
        XCTAssertEqual(lines[4].kind, .dir)
        XCTAssertEqual(lines[10].kind, .more)

        let seen = QueueTree.lines([QueueTreeEntry(path: "a.md", size: 4, seenBefore: true)], perFolder: 5)
        XCTAssertEqual(seen.first?.detail, "seen before · 4 bytes")
        let cut = QueueTree.lines([QueueTreeEntry(path: "a.md", size: 4)], truncated: true)
        XCTAssertEqual(cut.last?.kind, .truncated)
    }

    func testRefreshWording() {
        let at = date("2026-10-04T03:41:00Z")
        XCTAssertEqual(QueueRefreshState.result(QueueScanResult(added: 2, checkedAt: at)), .found("2 new items found"))
        XCTAssertEqual(QueueRefreshState.result(QueueScanResult(added: 1, removed: 1, checkedAt: at)), .found("1 new item found · 1 item gone"))
        XCTAssertEqual(QueueRefreshState.result(QueueScanResult(removed: 1, checkedAt: at)), .nothing("1 item gone"))
        XCTAssertEqual(QueueRefreshState.result(QueueScanResult(changed: 2, checkedAt: at)), .nothing("2 items changed"))
        XCTAssertEqual(QueueRefreshState.result(QueueScanResult(checkedAt: at)), .nothing("Nothing new"))
        XCTAssertEqual(QueueRefreshState.result(QueueScanResult(added: 3, checkedAt: at, problem: "EACCES")), .error("Can’t read the queue folder"),
                       "a problem beats what was found")
        XCTAssertEqual(plain(QueueRefreshState.checked(at, now: at, locale: en, timeZone: utc) ?? ""), "checked at 3:41 AM")
        XCTAssertEqual(plain(QueueRefreshState.checked(at, now: date("2026-10-05T09:00:00Z"), locale: en, timeZone: utc) ?? ""), "checked Oct 4 at 3:41 AM")
        XCTAssertNil(QueueRefreshState.checked(nil))
    }

    func testQueueScanIntervalLabels() {
        XCTAssertEqual(QueueScanInterval.options.map(QueueScanInterval.label), ["Every minute", "Every 5 min", "Every 15 min", "Every hour", "Off"])
        XCTAssertEqual(QueueScanInterval.label(30), "Every 30 min", "a value the CLI set shows as it is")
        XCTAssertEqual(QueueScanInterval.label(120), "Every 2 hours")
    }

    func testSettingsQueueScanMinutesIsLenientAndNeverWrittenUnlessSet() throws {
        let absent = try JSONDecoder.core.decode(Settings.self, from: Data(#"{"taskDefaults":{}}"#.utf8))
        XCTAssertNil(absent.queueScanMinutes)
        XCTAssertEqual(absent.resolvedQueueScanMinutes, 5)
        XCTAssertNil(absent.jsonObject()["queueScanMinutes"], "absent stays absent on save")
        let off = try JSONDecoder.core.decode(Settings.self, from: Data(#"{"queueScanMinutes":0}"#.utf8))
        XCTAssertEqual(off.resolvedQueueScanMinutes, 0)
        let wrong = try JSONDecoder.core.decode(Settings.self, from: Data(#"{"queueScanMinutes":"soon"}"#.utf8))
        XCTAssertNil(wrong.queueScanMinutes)
        let huge = try JSONDecoder.core.decode(Settings.self, from: Data(#"{"queueScanMinutes":99999}"#.utf8))
        XCTAssertEqual(huge.queueScanMinutes, 1440)
        var edited = absent
        edited.queueScanMinutes = 15
        XCTAssertEqual(Settings.patch(from: absent, to: edited), ["queueScanMinutes": .number(15)])
    }

    func testStatusScanTimesAndJobFolders() throws {
        let status = try JSONDecoder.core.decode(StatusResponse.self, from: Data(
            #"{"version":"1","queueCount":2,"lastQueueScanAt":"2026-10-04T03:41:00Z","nextQueueScanAt":null}"#.utf8))
        XCTAssertEqual(status.lastQueueScanAt, date("2026-10-04T03:41:00Z"))
        XCTAssertNil(status.nextQueueScanAt)

        let job = try JSONDecoder.core.decode(Job.self, from: Data(#"""
        {"id":"job-1","vaultPath":"/v","state":"completed","files":["inbox/2026-10-04/Tea tasting trip/notes/day1-uji.md",
         "inbox/2026-10-04/Screenshot.png","inbox/2026-10-04/Tea tasting trip/receipts/tea-shop.pdf","inbox/2026-10-04/Gyokuro.distill.json"],
         "folders":["inbox/2026-10-04/Tea tasting trip", 3, "inbox/2026-10-04/Only gdocs"]}
        """#.utf8))
        XCTAssertEqual(job.folders, ["inbox/2026-10-04/Tea tasting trip", "inbox/2026-10-04/Only gdocs"])
        XCTAssertEqual(job.sources, [
            .folder(path: "inbox/2026-10-04/Tea tasting trip", files: ["inbox/2026-10-04/Tea tasting trip/notes/day1-uji.md",
                                                                       "inbox/2026-10-04/Tea tasting trip/receipts/tea-shop.pdf"]),
            .file("inbox/2026-10-04/Screenshot.png"),
            .folder(path: "inbox/2026-10-04/Only gdocs", files: []),
        ])
        let old = Job(id: "old", vaultPath: "/v", files: ["inbox/a.md", "inbox/b.md"])
        XCTAssertEqual(old.sources, [.file("inbox/a.md"), .file("inbox/b.md")], "a job from before v5 lists every file")
        let round = try JSONDecoder.core.decode(Job.self, from: JSONEncoder().encode(job))
        XCTAssertEqual(round.folders, job.folders)
    }

    func testQueueScannedEvent() throws {
        let event = try CoreEvent.decode(Data(#"""
        {"type":"queue.scanned","result":{"added":1,"removed":0,"changed":0,"checkedAt":"2026-10-04T03:41:00Z","trigger":"periodic",
         "addedEntries":[{"path":"/q/a.md","modified":"2026-10-04T03:40:00Z","size":1,"settled":true}],"removedEntries":[],"changedEntries":[],
         "entries":[{"path":"/q/a.md","modified":"2026-10-04T03:40:00Z","size":1,"settled":true}]}}
        """#.utf8))
        guard case .queueScanned(let r) = event else { return XCTFail("\(event)") }
        XCTAssertEqual(r.trigger, .periodic)
        XCTAssertEqual(r.addedEntries.map(\.path), ["/q/a.md"])
        XCTAssertEqual(r.entries?.count, 1)
        let odd = try JSONDecoder.core.decode(QueueScanResult.self, from: Data(#"{"added":"x","trigger":"later"}"#.utf8))
        XCTAssertEqual(odd.added, 0)
        XCTAssertEqual(odd.trigger, .periodic, "an unknown trigger reads as periodic")
        XCTAssertNil(odd.entries)
    }

    func testCollectorSubfoldersAndFolderRunLines() throws {
        let old = try JSONDecoder.core.decode(FolderCollectorSettings.self, from: Data(#"{"source":"/in","afterCollect":"copy"}"#.utf8))
        XCTAssertNil(old.includeSubfolders)
        XCTAssertFalse(old.subfolders, "a collector saved before v5 keeps subfolders off")
        let on = try JSONDecoder.core.decode(FolderCollectorSettings.self, from: Data(#"{"source":"/in","includeSubfolders":true}"#.utf8))
        XCTAssertTrue(on.subfolders)
        let patch = try JSONDecoder.core.decode(JSONValue.self, from: JSONEncoder().encode(FolderPatch(includeSubfolders: false)))
        XCTAssertEqual(patch, .object(["includeSubfolders": .bool(false)]))

        let folder = CollectorRunFile(name: "Tea tasting trip/", outcome: .copied, queueName: "Tea tasting trip", kind: "folder", fileCount: 12, newCount: 5)
        XCTAssertEqual(CollectorText.runFileName(folder), "Tea tasting trip/ (folder · 5 new of 12 files)")
        let waiting = CollectorRunFile(name: "Scans", outcome: .waiting, reason: "still downloading", kind: "folder", fileCount: 4)
        XCTAssertEqual(CollectorText.runFileName(waiting), "Scans/ (folder · 4 files)")
        let gdoc = CollectorRunFile(name: "Q3 tea club plan.gdoc", outcome: .copied)
        XCTAssertEqual(CollectorText.runFileName(gdoc), "Q3 tea club plan.gdoc (waits in the queue: needs Google Drive access)")
        let decoded = try JSONDecoder.core.decode(CollectorRunFile.self, from: Data(
            #"{"name":"tea-notes/","kind":"folder","fileCount":12,"newCount":4,"outcome":"moved"}"#.utf8))
        XCTAssertEqual(CollectorText.runFileName(decoded), "tea-notes/ (folder · 4 new of 12 files)")
    }

    func testSourceUsageMatchesPathsNotBareNames() {
        let pages: [(path: String, text: String)] = [
            (path: "wiki/sources/Uji tea farms.md", text: "source: inbox/2026-10-04/Tea tasting trip/notes/day1-uji.md"),
            (path: "wiki/Wazuka.md", text: "From Tea tasting trip/notes/day2-wazuka.md and day1-uji.md"),
        ]
        XCTAssertEqual(SourceUsage.pages(using: "inbox/2026-10-04/Tea tasting trip/notes/day1-uji.md", in: pages), ["Uji tea farms"])
        XCTAssertEqual(SourceUsage.pages(using: "inbox/2026-10-04/Tea tasting trip/notes/day2-wazuka.md", in: pages), ["Wazuka"])
        XCTAssertEqual(SourceUsage.pages(using: "inbox/2026-10-04/Tea tasting trip/receipts/tea-shop.pdf", in: pages), [])
        XCTAssertFalse(SourceUsage.isPage("wiki/log.md"))
        XCTAssertFalse(SourceUsage.isPage("wiki/meta/ledgers/sources.md"))
        XCTAssertTrue(SourceUsage.isPage("wiki/Wazuka.md"))
    }

    func testFolderWalkReadsAMovedFolder() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distill-walk-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let fm = FileManager.default
        try fm.createDirectory(at: dir.appendingPathComponent("notes/deep"), withIntermediateDirectories: true)
        try Data(count: 10).write(to: dir.appendingPathComponent("notes/a.md"))
        try Data(count: 5).write(to: dir.appendingPathComponent("notes/deep/b.md"))
        try Data(count: 3).write(to: dir.appendingPathComponent("plan.gdoc"))
        try Data(count: 7).write(to: dir.appendingPathComponent(".DS_Store"))
        let e = try XCTUnwrap(QueueFolderWalk.entry(at: dir))
        XCTAssertEqual(e.kind, .folder)
        XCTAssertEqual(e.fileCount, 3)
        XCTAssertEqual(e.folderCount, 2)
        XCTAssertEqual(e.size, 18)
        XCTAssertEqual(e.tree?.map(\.path), ["notes", "notes/a.md", "notes/deep", "notes/deep/b.md", "plan.gdoc"])
        XCTAssertEqual(e.tree?.first?.size, 15)
        XCTAssertEqual(e.tree?.last?.kind, .gdoc)
        XCTAssertNil(QueueFolderWalk.entry(at: dir.appendingPathComponent("missing")))
    }
}
