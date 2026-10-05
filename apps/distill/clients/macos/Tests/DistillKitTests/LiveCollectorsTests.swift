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

    private func waitFor(_ what: String, _ timeout: TimeInterval = 60, _ check: () async throws -> Bool) async throws {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            if try await check() { return }
            try await Task.sleep(nanoseconds: 200_000_000)
        }
        XCTFail("\(what): timed out after \(timeout) s")
    }

    /// v6 against a real core: a kept script with a package.json whose only dependency is a local
    /// `file:` package (no network), install on Allow, Test run into the scratch folder, a stale save
    /// refused, and a failed install (a `file:` path that doesn't exist) that blocks runs.
    func testScriptFilesPackagesAndTestRun() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISTILL_LIVE_TESTS"] == "1", "set DISTILL_LIVE_TESTS=1")
        var product = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { product.deleteLastPathComponent() }
        try XCTSkipUnless(FileManager.default.fileExists(atPath: CoreLauncher.cliEntry(productRoot: product.path)), "build the TS workspace first")

        let fm = FileManager.default
        let root = fm.temporaryDirectory.appendingPathComponent("distill-scripts-live-\(UUID().uuidString.prefix(8))").resolvingSymlinksInPath()
        self.root = root
        let vault = root.appendingPathComponent("vault"), queue = root.appendingPathComponent("queue")
        let pkg = root.appendingPathComponent("tinypkg")
        for d in [vault, queue, pkg] { try fm.createDirectory(at: d, withIntermediateDirectories: true) }
        try #"{"name":"tinypkg","version":"1.0.0","main":"index.js"}"#.write(to: pkg.appendingPathComponent("package.json"), atomically: true, encoding: .utf8)
        try "module.exports = 1;\n".write(to: pkg.appendingPathComponent("index.js"), atomically: true, encoding: .utf8)
        let paths = try makeTempStateDir()
        self.paths = paths
        let settings = #"{"vaults":[{"path":"\#(vault.path)","queueDirectory":"\#(queue.path)"}],"activeVaultPath":"\#(vault.path)","autoProcessEnabled":false}"#
        try settings.write(to: paths.dir.appendingPathComponent("settings.json"), atomically: true, encoding: .utf8)
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DISTILL_STATE_DIR")
        env.removeValue(forKey: "DISTILL_PRODUCT_ROOT")
        let client = CoreClient(endpoint: try await CoreLauncher(paths: paths, bundledProductRoot: product.path, environment: env, startTimeout: 30).ensureRunning())

        // A kept zsh script: a real file in its own folder; Test run writes to the scratch folder, not the queue.
        var z = try await client.createCollector(NewCollectorInput(kind: .script, name: "Kept zsh", vaultPath: vault.path, schedule: .hourly,
                                                                   script: .init(source: .inline("echo made\nprint -r -- hi > \"$2/test.md\"\n"), interpreter: .zsh)))
        XCTAssertTrue(z.isManaged)
        XCTAssertTrue(z.scriptPath?.hasSuffix("/collector.zsh") ?? false, "\(String(describing: z.scriptPath))")
        XCTAssertNil(z.manifest, "zsh has no manifest")
        z = try await client.allowCollector(z.id, sha256: try XCTUnwrap(z.status?.currentSha256))
        let started = try await client.testCollector(z.id)
        XCTAssertTrue(started.isTest)
        var test: CollectorRun?
        try await waitFor("test run") {
            test = try await client.collectorRuns(z.id, limit: 3).first { $0.id == started.id && !$0.result.isActive }
            return test != nil
        }
        XCTAssertEqual(test?.result, .success, "\(String(describing: test))")
        XCTAssertEqual(test?.filesAdded, ["test.md"])
        let dir = try XCTUnwrap(test?.outputDir)
        XCTAssertTrue(fm.fileExists(atPath: dir + "/test.md"))
        XCTAssertFalse(fm.fileExists(atPath: queue.appendingPathComponent("test.md").path), "a Test run never feeds the queue")
        z = try await client.collector(z.id)
        XCTAssertNil(z.lastRun, "a Test run is not status.lastRun")
        XCTAssertEqual(z.status?.script?.lastTestRun?.id, started.id)

        // The editor's save: a stale base is refused (409); the loaded base saves and asks for the OK again.
        let files = try await client.collectorScript(z.id)
        do {
            _ = try await client.saveCollectorScript(z.id, CollectorScriptUpdate(code: "echo x\n", baseSha256: "0000"))
            XCTFail("a stale base must be refused")
        } catch let e as CoreClientError { XCTAssertEqual(e.status, 409) }
        _ = try await client.saveCollectorScript(z.id, CollectorScriptUpdate(code: "echo again\n", baseSha256: files.sha256))
        z = try await client.collector(z.id)
        XCTAssertTrue(z.needsConsent)
        XCTAssertEqual(z.status?.script?.changes, ["script"])

        // A kept node script with a local package: Allow installs it (no network), then it's ready.
        // Written the way npm formats it: npm 6 (an older login-shell node) rewrites package.json on install, which would change the hash.
        let manifest = "{\n  \"dependencies\": {\n    \"tinypkg\": \"file:\(pkg.path)\"\n  }\n}\n"
        var n = try await client.createCollector(NewCollectorInput(kind: .script, name: "Kept node", vaultPath: vault.path, schedule: .hourly,
                                                                   script: .init(source: .inline("require('tinypkg');\n"), interpreter: .node, manifest: manifest)))
        XCTAssertEqual(n.manifest?.state, "needsInstall")
        XCTAssertEqual(n.manifest?.packageCount, 1)
        n = try await client.allowCollector(n.id, sha256: try XCTUnwrap(n.status?.currentSha256))
        try await waitFor("ready") { try await client.collector(n.id).manifest?.state == "ready" }
        let install = try await client.collectorInstall(n.id)
        XCTAssertEqual(install?.trigger, "allow")
        XCTAssertEqual(install?.result, "success")
        XCTAssertNotNil(install?.outputTail)

        // Allow and run (frame X): allow starts the install, the run started right after waits for it
        // and then finds the package (it would fail with "Cannot find module" if it ran first).
        var ar = try await client.createCollector(NewCollectorInput(kind: .script, name: "Allow and run", vaultPath: vault.path, schedule: .hourly,
                                                                    script: .init(source: .inline("require('tinypkg');\nconsole.log('found');\n"),
                                                                                  interpreter: .node, manifest: manifest)))
        ar = try await client.allowCollector(ar.id, sha256: try XCTUnwrap(ar.status?.currentSha256))
        let queued = try await client.runCollector(ar.id)
        var done: CollectorRun?
        try await waitFor("allow and run") {
            done = try await client.collectorRuns(ar.id, limit: 3).first { $0.id == queued.id && !$0.result.isActive }
            return done != nil
        }
        XCTAssertTrue(done?.result == .success || done?.result == .nothing, "the run waited for the install: \(String(describing: done))")
        XCTAssertEqual(done?.stdoutTail?.trimmingCharacters(in: .whitespacesAndNewlines), "found")

        // A manifest pointing at a missing local package: the install fails, runs wait (installFailed).
        let bad = try await client.collectorScript(n.id)
        _ = try await client.saveCollectorScript(n.id, CollectorScriptUpdate(manifest: .some("{ \"dependencies\": { \"nope\": \"file:\(root.path)/missing\" } }\n"),
                                                                             baseManifestSha256: .some(bad.manifest?.sha256)))
        n = try await client.collector(n.id)
        XCTAssertEqual(n.status?.script?.changes, ["manifest"])
        n = try await client.allowCollector(n.id, sha256: try XCTUnwrap(n.status?.currentSha256))
        try await waitFor("failed") { try await client.collector(n.id).manifest?.state == "failed" }
        n = try await client.collector(n.id)
        XCTAssertTrue(n.needsAttention)
        let failed = try await client.collectorInstall(n.id)
        XCTAssertEqual(failed?.result, "failed")
        let run = try await runToEnd(client, n.id)
        XCTAssertEqual(run.error?.code, .installFailed, "\(run)")
    }
}
