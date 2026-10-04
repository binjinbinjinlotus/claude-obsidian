import XCTest
@testable import Distill
@testable import DistillKit

/// Collectors drafts in the app: schedules, the settings patch, the next run and the sidebar count.
@MainActor
final class CollectorsLogicTests: XCTestCase {
    private let text = CollectorText(home: "/Users/mei")

    func testScheduleDraft() {
        var d = ScheduleDraft(CollectorSchedule(cron: "0 7 * * *"))
        XCTAssertEqual(d.preset, .daily)
        XCTAssertEqual(d.hour, 7)
        XCTAssertEqual(d.cron, "0 7 * * *")
        d.preset = .weekdays
        XCTAssertEqual(d.cron, "0 7 * * 1-5")
        d.setCron("30 8 * * 1,3,5")
        XCTAssertEqual(d.preset, .custom)
        XCTAssertEqual(d.cron, "30 8 * * 1,3,5")
        d.setCron("0 * * * *")
        XCTAssertEqual(d.preset, .hourly)
        XCTAssertEqual(ScheduleDraft(CollectorSchedule(cron: "30 * * * *")).preset, .custom)
    }

    func testPatchSendsOnlyChanges() {
        let c = Collector(id: "c", kind: .folder, name: "Inbox", vaultPath: "/v",
                          folder: FolderCollectorSettings(source: "/Users/mei/Distill Inbox"))
        var d = CollectorDraft(c, text: text)
        XCTAssertEqual(d.folderPath, "~/Distill Inbox")
        XCTAssertTrue(d.patch(from: c, text: text).isEmpty)
        d.folderPath = "~/Other"
        d.afterCollect = "move"
        let p = d.patch(from: c, text: text)
        XCTAssertEqual(p.folder, FolderPatch(source: "/Users/mei/Other", afterCollect: "move"))
        XCTAssertNil(p.schedule)

        let s = Collector(id: "s", kind: .script, name: "S", vaultPath: "/v",
                          script: ScriptCollectorSettings(source: .inline("echo 1"), interpreter: .zsh))
        var sd = CollectorDraft(s, text: text)
        XCTAssertTrue(sd.scriptInline)
        sd.timeoutSeconds = 60
        XCTAssertEqual(sd.patch(from: s, text: text).script, ScriptPatch(timeoutSeconds: 60))
        sd.code = "echo 2"
        XCTAssertEqual(sd.patch(from: s, text: text).script?.source, .inline("echo 2"))
    }

    func testNextRunOfPresets() {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 2, hour: 9, minute: 31))! // a Friday
        let hourly = CollectorsStore.nextRun(ScheduleDraft(preset: .hourly), after: now, calendar: cal)
        XCTAssertEqual(cal.component(.hour, from: hourly!), 10)
        let weekdays = CollectorsStore.nextRun(ScheduleDraft(preset: .weekdays, hour: 9, minute: 0), after: now, calendar: cal)!
        XCTAssertEqual(cal.component(.weekday, from: weekdays), 2) // Monday
        XCTAssertNil(CollectorsStore.nextRun(ScheduleDraft(preset: .custom, customCron: "0 8 1 * *"), after: now, calendar: cal))
    }

    func testAlertCountAndEvents() {
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        let s = e.collectors
        var a = Collector(id: "a", kind: .folder, name: "A", vaultPath: "/v")
        a.status = CollectorStatus(needsAttention: true)
        let b = Collector(id: "b", kind: .folder, name: "B", vaultPath: "/v")
        s.apply(a, deleted: false)
        s.apply(b, deleted: false)
        XCTAssertEqual(s.phase, .loaded)
        XCTAssertEqual(s.alertCount, 1)
        s.phase = .unavailable
        XCTAssertEqual(s.alertCount, 0)
        s.phase = .loaded
        s.apply(a, deleted: true)
        XCTAssertEqual(s.collectors.map(\.id), ["b"])

        let run = CollectorRun(id: "r", collectorId: "b", kind: .script, startedAt: Date(), result: .running)
        s.runStarted(run)
        XCTAssertEqual(s.live["b"]?.id, "r")
        s.runOutput(collectorId: "b", runId: "r", stream: "stdout", text: "hi\n")
        s.runOutput(collectorId: "b", runId: "r", stream: "stderr", text: "oops\n")
        XCTAssertEqual(s.output["r"]?.stdout, "hi\n")
        XCTAssertEqual(s.output["r"]?.stderr, "oops\n")
        var done = run
        done.result = .nothing
        s.runFinished(done)
        XCTAssertNil(s.live["b"])
        XCTAssertEqual(s.runs["b"]?.first?.result, .nothing)
        XCTAssertNil(s.output["r"])
    }

    func testConsentCodeIsReadAgainWhenTheScriptChanges() throws {
        let file = FileManager.default.temporaryDirectory.appendingPathComponent("distill-consent-\(UUID().uuidString).zsh")
        defer { try? FileManager.default.removeItem(at: file) }
        try "echo v1\n".write(to: file, atomically: true, encoding: .utf8)
        let s = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil).collectors
        var c = Collector(id: "s", kind: .script, name: "S", vaultPath: "/v",
                          script: ScriptCollectorSettings(source: .file(file.path), interpreter: .zsh))
        c.status = CollectorStatus(currentSha256: "aaa", needsConsent: true)
        XCTAssertEqual(s.code(c), "echo v1\n")
        RunLoop.main.run(until: Date().addingTimeInterval(0.05)) // the cache fills
        XCTAssertEqual(s.code(c), "echo v1\n")
        try "echo v2\n".write(to: file, atomically: true, encoding: .utf8)
        c.status?.currentSha256 = "bbb"
        XCTAssertEqual(s.code(c), "echo v2\n", "a new hash reads the file again")
    }
}
