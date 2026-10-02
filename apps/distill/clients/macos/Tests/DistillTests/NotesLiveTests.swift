import XCTest
import DistillKit
@testable import Distill

/// Against a running throwaway core: `DISTILL_LIVE_STATE=<temp state dir>`
/// (server.json + token there; never the real state dir). Uses the app's own
/// request builders so wire-shape mistakes show up. Skipped by default.
final class NotesLiveTests: XCTestCase {
    private func client() throws -> CoreClient {
        guard let dir = ProcessInfo.processInfo.environment["DISTILL_LIVE_STATE"] else {
            throw XCTSkip("set DISTILL_LIVE_STATE to a temp core state dir")
        }
        let state = URL(fileURLWithPath: dir)
        struct Lock: Decodable { let port: Int }
        let lock = try JSONDecoder().decode(Lock.self, from: Data(contentsOf: state.appendingPathComponent("server.json")))
        let token = try String(contentsOf: state.appendingPathComponent("token"), encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return CoreClient(endpoint: CoreEndpoint(port: lock.port, token: token))
    }

    func testAddNoteWithImageThenLabel() async throws {
        let client = try client()
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("distill-live-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let png = dir.appendingPathComponent("card.png")
        // 1×1 PNG
        try Data(base64Encoded: "iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==")!
            .write(to: png)
        var draft = ComposeDraft()
        draft.title = "Live note"
        draft.text = "Gyokuro at 60 °C.\n![[card.png]]"
        draft.source = "in-person"
        draft.sourceRef = "#tea-club"
        draft.images = [DraftImage(url: png)]
        let result = try await client.addNote(draft.request(suggest: false, vaultPath: nil))
        XCTAssertFalse(result.requestID.isEmpty)
        XCTAssertTrue(result.queued.contains { $0.hasSuffix(".png") }, "\(result.queued)")
        let queuedNote = try String(contentsOfFile: result.notePath, encoding: .utf8)
        XCTAssertTrue(queuedNote.contains("![[Live note image 1.png]]"), queuedNote)

        var step = LabelStep(requestID: result.requestID, title: draft.effectiveTitle, suggesting: false)
        step.add("tea, Tea Shops")
        let labeled = try await client.labelNote(requestID: step.requestID, labels: step.chosen)
        XCTAssertEqual(labeled.labels, ["tea", "tea-shops"])
        let note = try String(contentsOfFile: labeled.notePath.isEmpty ? result.notePath : labeled.notePath, encoding: .utf8)
        XCTAssertTrue(note.contains("tea-shops"), note)
    }

    func testClearingAShortcutReachesTheCore() async throws {
        let client = try client()
        var before = try await client.settings()
        SettingsEdits.setShortcut(.ask, KeyShortcut("ctrl+opt+space"), in: &before)
        SettingsEdits.setShortcut(.addNote, KeyShortcut("ctrl+opt+n"), in: &before)
        let synced = try await client.updateSettings(Settings.patch(from: try await client.settings(), to: before))
        XCTAssertEqual(synced.shortcuts?.ask, "ctrl+opt+space")
        var after = synced
        SettingsEdits.setShortcut(.ask, nil, in: &after)
        SettingsEdits.setLabeling(&after, autoLabelQueueFolder: false)
        let saved = try await client.updateSettings(Settings.patch(from: synced, to: after))
        XCTAssertNil(saved.shortcuts?.ask)
        XCTAssertEqual(saved.shortcuts?.addNote, "ctrl+opt+n")
        XCTAssertEqual(saved.labeling?.autoLabelQueueFolder, false)
    }

    func testLabelsRunnersAndHistoryRoutes() async throws {
        let client = try client()
        _ = try await client.labelReview()
        _ = try await client.labels()
        let runners = try await client.runners()
        XCTAssertTrue(runners.contains { $0.id == "claude-code" })
        _ = try await client.conversations()
    }
}
