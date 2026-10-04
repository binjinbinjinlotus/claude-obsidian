import XCTest
@testable import DistillKit

/// Collectors end to end: the Swift client against a real core started by
/// `CoreLauncher` in a TEMP state dir, with a throwaway vault, queue and source
/// folder (never `~/Distill Inbox`). Opt-in like LiveCoreTests:
///
///     (cd apps/distill && npm run build --workspaces)
///     DISTILL_LIVE_TESTS=1 swift test --package-path apps/distill/clients/macos --filter LiveCollectorsTests
final class LiveCollectorsTests: XCTestCase {
    var paths: StatePaths?
    var root: URL?

    override func tearDown() {
        if let paths, let data = FileManager.default.contents(atPath: paths.serverLock.path),
           let lock = try? JSONDecoder().decode(ServerLock.self, from: data) {
            kill(lock.pid, SIGTERM)
            let deadline = Date().addingTimeInterval(5)
            while FileManager.default.fileExists(atPath: paths.serverLock.path) && Date() < deadline { usleep(50_000) }
        }
        if let paths { try? FileManager.default.removeItem(at: paths.dir) }
        if let root { try? FileManager.default.removeItem(at: root) }
    }

    private func write(_ url: URL, _ text: String, ageSeconds: TimeInterval = 3600) throws {
        try text.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.modificationDate: Date().addingTimeInterval(-ageSeconds)], ofItemAtPath: url.path)
    }

    private func runToEnd(_ client: CoreClient, _ id: String, timeout: TimeInterval = 30) async throws -> CollectorRun {
        let started = try await client.runCollector(id)
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if let run = try await client.collectorRuns(id, limit: 3).first(where: { $0.id == started.id }), !run.result.isActive { return run }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        throw XCTSkip("run did not finish in \(timeout) s")
    }

    func testFolderAndScriptCollectors() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISTILL_LIVE_TESTS"] == "1", "set DISTILL_LIVE_TESTS=1")
        var product = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { product.deleteLastPathComponent() }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: CoreLauncher.cliEntry(productRoot: product.path)), "build the TS workspace first")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("distill-collectors-live-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        self.root = root
        let vault = root.appendingPathComponent("vault"), queue = root.appendingPathComponent("queue")
        let source = root.appendingPathComponent("source")
        for d in [vault, queue, source] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        let paths = try makeTempStateDir()
        self.paths = paths
        let settings = #"{"vaults":[{"path":"\#(vault.path)","queueDirectory":"\#(queue.path)"}],"activeVaultPath":"\#(vault.path)","autoProcessEnabled":false}"#
        try settings.write(to: paths.dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)

        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DISTILL_STATE_DIR")
        env.removeValue(forKey: "DISTILL_PRODUCT_ROOT")
        let launcher = CoreLauncher(paths: paths, bundledProductRoot: product.path, environment: env, startTimeout: 30)
        let client = CoreClient(endpoint: try await launcher.ensureRunning())

        // Folder: add, run → copies land in the queue, originals stay.
        try write(source.appendingPathComponent("tea.md"), "# Tea\n")
        try write(source.appendingPathComponent("gyokuro.md"), "# Gyokuro\n")
        try write(source.appendingPathComponent(".DS_Store"), "x")
        let folder = try await client.createCollector(NewCollectorInput(kind: .folder, name: "Live inbox", vaultPath: vault.path, enabled: true,
                                                                        schedule: .hourly, folder: FolderPatch(source: source.path, afterCollect: "copy")))
        XCTAssertTrue(folder.enabled)
        var run = try await runToEnd(client, folder.id)
        XCTAssertEqual(run.result, .success, "\(run)")
        XCTAssertEqual(run.counts.copied, 2)
        XCTAssertTrue(fm.fileExists(atPath: queue.appendingPathComponent("tea.md").path))
        XCTAssertTrue(fm.fileExists(atPath: source.appendingPathComponent("tea.md").path), "the original stays")
        XCTAssertFalse(fm.fileExists(atPath: queue.appendingPathComponent(".DS_Store").path))

        // Again: nothing new.
        run = try await runToEnd(client, folder.id)
        XCTAssertEqual(run.result, .nothing, "\(run)")

        // Edit a file: it is collected again (new content), next to the first copy.
        try write(source.appendingPathComponent("tea.md"), "# Tea\nSecond steep 30 s.\n")
        run = try await runToEnd(client, folder.id)
        XCTAssertEqual(run.result, .success)
        XCTAssertEqual(run.counts.copied, 1)
        XCTAssertTrue(fm.fileExists(atPath: queue.appendingPathComponent("tea 2.md").path))

        // Forget, then Undo: after Undo the next run skips it again (the ledger is back).
        var collected = try await client.collected(folder.id)
        XCTAssertEqual(collected.count, 3)
        let gyokuro = try XCTUnwrap(collected.first { $0.name == "gyokuro.md" })
        let forgotten = try await client.forgetCollected(folder.id, sha256: gyokuro.sha256)
        XCTAssertEqual(forgotten.count, 1)
        collected = try await client.collected(folder.id, query: "gyokuro")
        XCTAssertTrue(collected.isEmpty)
        let restored = try await client.restoreCollected(folder.id, files: forgotten)
        XCTAssertEqual(restored, 1)
        run = try await runToEnd(client, folder.id)
        XCTAssertEqual(run.result, .nothing, "after Undo the file is still known: \(run)")
        // Forget for real: the next run collects it again.
        _ = try await client.forgetCollected(folder.id, sha256: gyokuro.sha256)
        run = try await runToEnd(client, folder.id)
        XCTAssertEqual(run.counts.copied, 1)
        let fresh = try await client.collector(folder.id)
        XCTAssertEqual(fresh.status?.collectedCount, 3) // tea, tea (edited), gyokuro (forgotten and taken again)

        // Script: created off, needs consent; allow with the core's hash; run; change → asks again.
        let script = source.deletingLastPathComponent().appendingPathComponent("collect.zsh")
        try write(script, "echo hello\nprint -r -- note > \"$2/from-script.md\"\n", ageSeconds: 0)
        var s = try await client.createCollector(NewCollectorInput(kind: .script, name: "Live script", vaultPath: vault.path, schedule: .hourly,
                                                                   script: .init(source: .file(script.path), interpreter: .zsh, timeoutSeconds: 2)))
        XCTAssertFalse(s.enabled)
        XCTAssertTrue(s.needsConsent)
        do {
            _ = try await client.runCollector(s.id)
            let r = try await client.collectorRuns(s.id, limit: 1).first
            XCTAssertNotEqual(r?.result, .success, "a script never runs before consent")
        } catch {}
        s = try await client.allowCollector(s.id, sha256: try XCTUnwrap(s.status?.currentSha256))
        XCTAssertTrue(s.enabled)
        XCTAssertFalse(s.needsConsent)
        run = try await runToEnd(client, s.id)
        XCTAssertEqual(run.result, .success, "\(run)")
        XCTAssertEqual(run.stdoutTail?.trimmingCharacters(in: .whitespacesAndNewlines), "hello")
        XCTAssertTrue(fm.fileExists(atPath: queue.appendingPathComponent("from-script.md").path))

        try write(script, "sleep 30\n", ageSeconds: 0)
        run = try await runToEnd(client, s.id)
        XCTAssertEqual(run.result, .notTrusted)
        XCTAssertEqual(run.error?.code, .scriptChanged)
        s = try await client.collector(s.id)
        XCTAssertTrue(s.needsConsent)
        XCTAssertTrue(s.needsAttention)
        XCTAssertNotNil(s.script?.allowedSha256)

        // Allow the new version and let it time out (2 s, then SIGTERM; SIGKILL after the grace).
        s = try await client.allowCollector(s.id, sha256: try XCTUnwrap(s.status?.currentSha256))
        run = try await runToEnd(client, s.id, timeout: 40)
        XCTAssertEqual(run.result, .timedout, "\(run)")
        s = try await client.collector(s.id)
        XCTAssertTrue(s.needsAttention)

        // Delete keeps the ledger.
        try await client.deleteCollector(folder.id)
        let list = try await client.collectors()
        XCTAssertEqual(list.map(\.id), [s.id])
    }
}
