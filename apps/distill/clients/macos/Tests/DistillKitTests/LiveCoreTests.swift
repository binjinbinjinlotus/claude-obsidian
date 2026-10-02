import XCTest
@testable import DistillKit

/// End-to-end against a real core started by `CoreLauncher` in a TEMP state
/// dir (never the user's). Opt-in, because it needs the built TS workspace
/// and node ≥ 20:
///
///     (cd apps/distill && npm ci && npm run build --workspaces)
///     DISTILL_LIVE_TESTS=1 swift test --package-path apps/distill/clients/macos --filter LiveCoreTests
final class LiveCoreTests: XCTestCase {
    var paths: StatePaths?

    override func tearDown() {
        // Stop the core this test started (and only that one: the pid comes from the temp dir).
        guard let paths, let data = FileManager.default.contents(atPath: paths.serverLock.path),
              let lock = try? JSONDecoder().decode(ServerLock.self, from: data) else { return }
        kill(lock.pid, SIGTERM)
        let deadline = Date().addingTimeInterval(5)
        while FileManager.default.fileExists(atPath: paths.serverLock.path) && Date() < deadline { usleep(50_000) }
        try? FileManager.default.removeItem(at: paths.dir)
    }

    func testLaunchesCoreAndTalksToIt() async throws {
        try XCTSkipUnless(ProcessInfo.processInfo.environment["DISTILL_LIVE_TESTS"] == "1", "set DISTILL_LIVE_TESTS=1")
        // <root>/apps/distill/clients/macos/Tests/DistillKitTests/LiveCoreTests.swift
        var root = URL(fileURLWithPath: #filePath)
        for _ in 0..<7 { root.deleteLastPathComponent() }
        let productRoot = root.path
        let entry = CoreLauncher.cliEntry(productRoot: productRoot)
        try XCTSkipUnless(FileManager.default.fileExists(atPath: entry), "build the TS workspace first (\(entry))")

        let paths = try makeTempStateDir()
        self.paths = paths
        var env = ProcessInfo.processInfo.environment
        env.removeValue(forKey: "DISTILL_STATE_DIR")
        env.removeValue(forKey: "DISTILL_PRODUCT_ROOT")
        // Minimal PATH, as a GUI app gets: node must be found without the shell's nvm setup.
        env["PATH"] = "/usr/bin:/bin"
        let launcher = CoreLauncher(paths: paths, bundledProductRoot: productRoot, environment: env, startTimeout: 30)

        let endpoint = try await launcher.ensureRunning()
        XCTAssertGreaterThan(endpoint.port, 0)
        XCTAssertEqual(launcher.liveEndpoint(), endpoint)
        let client = CoreClient(endpoint: endpoint)

        let status = try await client.status()
        XCTAssertFalse(status.version.isEmpty)
        XCTAssertTrue(status.problems.contains { $0.code == "noVault" || $0.message.contains("vault") }, "\(status.problems)")

        // Events: a settings change made through the API comes back on the stream.
        let stream = client.events()
        let received = Task { () -> Settings? in
            for try await event in stream { if case .settings(let s) = event { return s } }
            return nil
        }
        try await Task.sleep(nanoseconds: 300_000_000)
        let saved = try await client.updateSettings(["batchIntervalMinutes": .number(42)])
        XCTAssertEqual(saved.batchIntervalMinutes, 42)
        let echoed = try await received.value
        received.cancel()
        XCTAssertEqual(echoed?.batchIntervalMinutes, 42)

        // Error shape from the real server.
        do {
            _ = try await client.addQueueFiles(["/tmp/nothing.md"])
            XCTFail("no vault: expected 409")
        } catch let e as CoreClientError {
            XCTAssertEqual(e.status, 409)
            XCTAssertEqual(e.code, "no_vault")
        }

        // Bad token is rejected.
        do {
            _ = try await CoreClient(endpoint: CoreEndpoint(port: endpoint.port, token: "wrong-token-wrong-token")).status()
            XCTFail("expected 401")
        } catch let e as CoreClientError {
            XCTAssertEqual(e.status, 401)
        }

        // v3 routes exist on this core (no 404 "no route" / 501).
        let progress = try await client.listProgress()
        XCTAssertTrue(progress.isEmpty)
        try await client.cancelAsk(conversationID: UUID().uuidString.lowercased()) // idle: no-op
        for call in [{ try await client.deleteJob("job-missing") }, { _ = try await client.jobResume("job-missing") }] as [() async throws -> Void] {
            do { try await call(); XCTFail("expected an error") } catch let e as CoreClientError {
                XCTAssertFalse(e.isNotAvailable, "\(e)")
                XCTAssertEqual(e.status, 404)
            }
        }
        do { try await client.removeQueueEntry(path: "/tmp/nothing.md"); XCTFail("expected an error") } catch let e as CoreClientError {
            XCTAssertFalse(e.isNotAvailable, "\(e)")
        }
        _ = try await client.conversations()

        // A second ensureRunning reuses the live core instead of starting another.
        let again = try await launcher.ensureRunning()
        XCTAssertEqual(again, endpoint)
    }
}
