import XCTest
@testable import DistillKit

/// Queue entry DTO (readyAt / kind / problem) and the row and header formatting.
final class QueueRowsTests: XCTestCase {
    private let utc = TimeZone(identifier: "UTC")!
    private let en = Locale(identifier: "en_US")
    private func date(_ iso: String) -> Date { ISO8601DateFormatter().date(from: iso)! }
    /// DateFormatter puts a narrow no-break space before AM/PM (it keeps the time on one line).
    private func plain(_ s: String) -> String { s.replacingOccurrences(of: "\u{202F}", with: " ") }

    func testDecodesNewFields() throws {
        let json = #"""
        [{"path":"/q/a.png","name":"a.png","modified":"2026-10-02T03:04:00Z","size":36000,"settled":false,"readyAt":"2026-10-02T03:14:00Z","kind":"file"},
         {"path":"/q/Tea.md","name":"Tea.md","modified":"2026-10-02T03:04:00Z","size":10,"settled":true,"kind":"note"},
         {"path":"/q/x.pdf","name":"x.pdf","modified":"2026-10-02T03:04:00Z","size":1,"settled":true,"problem":"Distill can't read this file."},
         {"path":"/q/old.md","modified":"2026-10-02T03:04:00Z","size":1,"settled":true,"kind":"weird","readyAt":null,"problem":""}]
        """#
        let entries = try JSONDecoder.core.decode([QueueEntry].self, from: Data(json.utf8))
        XCTAssertEqual(entries[0].readyAt, date("2026-10-02T03:14:00Z"))
        XCTAssertEqual(entries[0].kind, .file)
        XCTAssertEqual(entries[1].kind, .note)
        XCTAssertNil(entries[1].readyAt)
        XCTAssertEqual(entries[2].problem, "Distill can't read this file.")
        XCTAssertEqual(entries[3].kind, .file, "unknown kinds fall back to file")
        XCTAssertNil(entries[3].problem, "an empty problem is no problem")
        XCTAssertEqual(entries[3].name, "old.md")

        let round = try JSONDecoder.core.decode([QueueEntry].self, from: JSONEncoder().encode(entries))
        XCTAssertEqual(round, entries)
    }

    func testStatus() {
        let waiting = QueueEntry(path: "/q/a.png", modified: date("2026-10-02T03:04:00Z"), size: 1, settled: false,
                                 readyAt: date("2026-10-02T03:14:00Z"))
        XCTAssertEqual(QueueRows.status(waiting, batchRunning: false), .readyAt(date("2026-10-02T03:14:00Z")))
        XCTAssertEqual(QueueRows.status(waiting, batchRunning: true), .nextBatch)
        var note = waiting
        note.kind = .note
        XCTAssertEqual(QueueRows.status(note, batchRunning: false), .ready, "notes are ready at once")
        var settled = waiting
        settled.settled = true
        settled.readyAt = nil
        XCTAssertEqual(QueueRows.status(settled, batchRunning: false), .ready)
        var broken = waiting
        broken.problem = "Can't read"
        XCTAssertEqual(QueueRows.status(broken, batchRunning: true), .problem("Can't read"))
        XCTAssertFalse(QueueRowStatus.inBatch.removable)
        XCTAssertTrue(QueueRowStatus.nextBatch.removable)
        XCTAssertEqual(QueueRowStatus.ready.tone, .green)
        XCTAssertEqual(QueueRowStatus.inBatch.tone, .blue)
        XCTAssertEqual(QueueRowStatus.problem("x").tone, .peach)
        XCTAssertEqual(QueueRowStatus.readyAt(Date()).tone, .gray)
    }

    func testPillTextIsAClockTime() {
        let now = date("2026-10-02T03:05:00Z")
        XCTAssertEqual(plain(QueueRows.pillText(.readyAt(date("2026-10-02T03:14:00Z")), now: now, locale: en, timeZone: utc)), "Ready at 3:14 AM")
        XCTAssertEqual(plain(QueueRows.pillText(.ready)), "Ready")
        XCTAssertEqual(plain(QueueRows.pillText(.inBatch)), "In batch")
        XCTAssertEqual(plain(QueueRows.pillText(.nextBatch)), "Next batch")
        XCTAssertEqual(plain(QueueRows.pillText(.problem("why"))), "Couldn’t read")
        XCTAssertEqual(QueueRows.pillHelp(.problem("why"), settleSeconds: 600), "why")
        XCTAssertEqual(QueueRows.pillHelp(.readyAt(now), settleSeconds: 600),
                       "Distill waits 10 min after a file last changes so half-written files aren't picked up. Process now skips the wait.")
        XCTAssertNil(QueueRows.pillHelp(.ready, settleSeconds: 600))
    }

    func testMetaLine() {
        let now = date("2026-10-02T03:30:00Z")
        let at = date("2026-10-02T03:04:00Z")
        let pasted = QueueEntry(path: "/q/Screenshot 2026-10-02 030432.png", modified: at, size: 36_000, settled: false)
        XCTAssertEqual(QueueRows.origin(pasted), .pasted)
        XCTAssertEqual(plain(QueueRows.meta(pasted, now: now, locale: en, timeZone: utc)), "Pasted at 3:04 AM · 36 KB")
        let clip = QueueEntry(path: "/q/Clipping 2026-10-02 030900 2.md", modified: at, size: 1, settled: false)
        XCTAssertEqual(QueueRows.origin(clip), .pasted)
        let dropped = QueueEntry(path: "/q/gongfu-brewing-guide.pdf", modified: at, size: 2_300_000, settled: true)
        XCTAssertEqual(plain(QueueRows.meta(dropped, now: now, locale: en, timeZone: utc)), "Dropped at 3:04 AM · 2.3 MB")
        let note = QueueEntry(path: "/q/Gyokuro at 60 °C.md", modified: at, size: 120, settled: true, kind: .note)
        XCTAssertEqual(QueueRows.title(note), "Gyokuro at 60 °C")
        XCTAssertEqual(plain(QueueRows.meta(note, now: now, locale: en, timeZone: utc)), "Written note · Added at 3:04 AM")
        let image = QueueEntry(path: "/q/Gyokuro at 60 °C image 1.png", modified: at, size: 2_000, settled: true, kind: .note)
        XCTAssertEqual(QueueRows.title(image), "Gyokuro at 60 °C image 1.png")
        XCTAssertEqual(plain(QueueRows.meta(image, now: now, locale: en, timeZone: utc)), "Added at 3:04 AM · 2 KB")
        // Another day shows the date too, so an old file never reads as just added.
        XCTAssertEqual(plain(QueueRows.clock(date("2026-09-03T02:12:00Z"), now: now, locale: en, timeZone: utc)), "Sep 3 at 2:12 AM")
    }

    func testVisibleHidesManifests() {
        let entries = ["a.md", "Tea.md", "Tea.distill.json", "Tea image 1.png"].map {
            QueueEntry(path: "/q/\($0)", modified: Date(), size: 1, settled: true)
        }
        XCTAssertEqual(QueueRows.visible(entries).map(\.name), ["a.md", "Tea.md", "Tea image 1.png"])
    }

    func testHeaderLine() {
        let now = date("2026-10-02T03:30:00Z")
        XCTAssertEqual(plain(QueueRows.nextBatchLine(date("2026-10-02T05:30:00Z"), intervalMinutes: 120, now: now, locale: en, timeZone: utc)),
                       "Next batch at 5:30 AM · every 2 hours")
        XCTAssertEqual(BatchInterval(totalMinutes: 60).phrase, "1 hour")
        XCTAssertEqual(BatchInterval(totalMinutes: 90).phrase, "1 hour 30 minutes")
        XCTAssertEqual(BatchInterval(totalMinutes: 1440).phrase, "1 day")
        XCTAssertEqual(BatchInterval(totalMinutes: 5).phrase, "5 minutes")
        XCTAssertEqual(BatchInterval(totalMinutes: 1).phrase, "1 minute")
    }
}
