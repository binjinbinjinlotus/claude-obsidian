import XCTest
import DistillKit
@testable import Distill

/// The owner's script save, through the app's own store against a running throwaway core:
/// `DISTILL_LIVE_STATE=<temp state dir>` holding one managed python3 collector (created from inline
/// code, renamed, allowed, test-run), its id in `<state>/collector.id`. Never the real state dir.
/// Edit → replace the code → Save, then the core's activity log has one `collector.script_saved`.
/// Skipped by default.
@MainActor
final class CollectorSaveLiveTests: XCTestCase {
    private func wait(_ what: String, timeout: TimeInterval = 10, _ ok: () -> Bool) {
        let deadline = Date().addingTimeInterval(timeout)
        while !ok() && Date() < deadline { RunLoop.main.run(until: Date().addingTimeInterval(0.05)) }
        XCTAssertTrue(ok(), what)
    }

    func testEditorSaveIsLogged() throws {
        guard let dir = ProcessInfo.processInfo.environment["DISTILL_LIVE_STATE"] else {
            throw XCTSkip("set DISTILL_LIVE_STATE to a temp core state dir")
        }
        let state = URL(fileURLWithPath: dir)
        struct Lock: Decodable { let port: Int }
        let lock = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: state.appendingPathComponent("server.json")))
        let token = try String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let id = try String(contentsOf: state.appendingPathComponent("collector.id"), encoding: .utf8).trimmingCharacters(in: .whitespacesAndNewlines)
        let e = AppModel(fixtureSettings: Settings(), jobs: [], queue: [], status: nil)
        e.useClientForTesting(CoreClient(endpoint: CoreEndpoint(port: lock.port, token: token)))
        let store = e.collectors
        store.load()
        wait("loaded") { store.collector(id) != nil }
        let c = try XCTUnwrap(store.collector(id))
        store.startEdit(c)
        wait("files loaded") { store.editing?.loaded != nil }
        XCTAssertEqual(store.editing?.v6, true)
        let code = "import os\nprint('replaced \\(Date().timeIntervalSince1970)')\n"
        store.editing?.code = code
        let activity = state.appendingPathComponent("activity/activity.jsonl")
        let before = (try? String(contentsOf: activity, encoding: .utf8)) ?? ""
        store.save(c)
        wait("saved") { store.editing == nil && store.busy[id] == nil }
        let script = try XCTUnwrap(store.collector(id)?.script?.source.filePath)
        XCTAssertEqual(try String(contentsOfFile: script, encoding: .utf8), code)
        let after = try String(contentsOf: activity, encoding: .utf8)
        let added = after.dropFirst(before.count).split(separator: "\n").map(String.init)
        print("NEW ENTRIES:\n" + added.joined(separator: "\n"))
        XCTAssertEqual(added.filter { $0.contains("\"collector.script_saved\"") }.count, 1, added.joined(separator: "\n"))
        XCTAssertFalse(after.contains("replaced"), "never the script text")
    }
}
