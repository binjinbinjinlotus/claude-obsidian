import XCTest
@testable import DistillKit

/// In-memory file system for node discovery.
struct FakeFileSystem: LauncherFileSystem {
    var files: [String: Data] = [:]
    var executables: Set<String> = []
    var directories: [String: [String]] = [:]

    func fileExists(_ path: String) -> Bool { files[path] != nil || executables.contains(path) || directories[path] != nil }
    func isExecutable(_ path: String) -> Bool { executables.contains(path) }
    func contentsOfDirectory(_ path: String) -> [String] { directories[path] ?? [] }
    func read(_ path: String) -> Data? { files[path] }
}

/// A fresh directory under the temp dir; every launcher test uses one so no
/// test can ever touch ~/Library/Application Support/Distill.
func makeTempStateDir(_ name: String = #function) throws -> StatePaths {
    let dir = FileManager.default.temporaryDirectory
        .appendingPathComponent("distill-tests-\(UUID().uuidString.prefix(8))", isDirectory: true)
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    let paths = StatePaths(dir: dir)
    let tmp = URL(fileURLWithPath: NSTemporaryDirectory()).resolvingSymlinksInPath().path
    precondition(paths.dir.resolvingSymlinksInPath().path.hasPrefix(tmp), "tests must use a temp state dir")
    return paths
}

final class NodeLocatorTests: XCTestCase {
    let home = "/Users/test"
    let nvm = "/Users/test/.nvm/versions/node"
    /// This machine's real nvm list: lexicographic order would pick v8.
    let installed = ["v12.20.1", "v14.15.5", "v18.20.4", "v20.11.0", "v22.22.1", "v24.21.0", "v8.17.0", ".DS_Store"]

    func locator(executables: Set<String>, versions: [String: String] = [:]) -> NodeLocator {
        var fs = FakeFileSystem()
        fs.directories[nvm] = installed
        fs.executables = executables
        return NodeLocator(home: home, fileSystem: fs, probe: { path in
            if let v = versions[path] { return NodeVersion(v) }
            // nvm paths report their folder's version
            let folder = URL(fileURLWithPath: path).deletingLastPathComponent().deletingLastPathComponent().lastPathComponent
            return NodeVersion(folder)
        })
    }

    func testCandidateOrderIsSettingsThenHighestNvmThenSystem() {
        let c = locator(executables: []).candidates(settingsNodePath: "~/bin/node")
        XCTAssertEqual(c.first, (("~/bin/node") as NSString).expandingTildeInPath)
        XCTAssertEqual(c[1], "\(nvm)/v24.21.0/bin/node")
        XCTAssertEqual(c[2], "\(nvm)/v22.22.1/bin/node")
        XCTAssertEqual(c.firstIndex(of: "\(nvm)/v8.17.0/bin/node"), c.count - 4, "v8 is the lowest nvm version")
        XCTAssertEqual(Array(c.suffix(3)), ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"])
        XCTAssertFalse(c.contains { $0.contains(".DS_Store") })
    }

    func testPicksHighestNvmNode() {
        let all = Set(installed.filter { $0.hasPrefix("v") }.map { "\(nvm)/\($0)/bin/node" })
        let result = locator(executables: all.union(["/usr/bin/node"])).locate(settingsNodePath: nil)
        XCTAssertEqual(try result.get().path, "\(nvm)/v24.21.0/bin/node")
        XCTAssertEqual(try result.get().version, NodeVersion(major: 24, minor: 21, patch: 0))
    }

    func testSettingsNodePathWinsWhenNewEnough() {
        let l = locator(executables: ["/custom/node", "\(nvm)/v24.21.0/bin/node"], versions: ["/custom/node": "v20.0.0"])
        XCTAssertEqual(try l.locate(settingsNodePath: "/custom/node").get().path, "/custom/node")
    }

    func testSkipsTooOldNodeAndFallsBackToHomebrew() {
        let l = locator(executables: ["/custom/node", "\(nvm)/v18.20.4/bin/node", "/opt/homebrew/bin/node"],
                        versions: ["/custom/node": "v16.1.0", "/opt/homebrew/bin/node": "v22.1.0"])
        XCTAssertEqual(try l.locate(settingsNodePath: "/custom/node").get().path, "/opt/homebrew/bin/node")
    }

    func testNotFoundListsTooOld() {
        let l = locator(executables: ["\(nvm)/v18.20.4/bin/node"])
        guard case .failure(.notFound(let tried, let tooOld)) = l.locate(settingsNodePath: nil) else { return XCTFail() }
        XCTAssertTrue(tried.contains("/usr/bin/node"))
        XCTAssertEqual(tooOld, ["\(nvm)/v18.20.4/bin/node (v18.20.4)"])
        XCTAssertTrue(NodeLocator.Failure.notFound(tried: tried, tooOld: tooOld).description.contains("Node.js 20 or newer"))
    }

    func testVersionParsing() {
        XCTAssertEqual(NodeVersion("v22.22.1\n"), NodeVersion(major: 22, minor: 22, patch: 1))
        XCTAssertEqual(NodeVersion("20"), NodeVersion(major: 20))
        XCTAssertNil(NodeVersion("node"))
        XCTAssertLessThan(NodeVersion("v8.17.0")!, NodeVersion("v24.0.0")!)
    }
}

final class CoreLauncherTests: XCTestCase {
    func launcher(_ paths: StatePaths, productRoot: String?, fs: any LauncherFileSystem = RealFileSystem(),
                  node: NodeLocator? = nil, spawner: @escaping CoreSpawner = { _, _, _, _ in throw CoreLauncher.Problem.spawnFailed("unused") },
                  alive: @escaping @Sendable (Int32) -> Bool = { _ in true }) -> CoreLauncher {
        CoreLauncher(paths: paths, bundledProductRoot: productRoot, environment: ["HOME": "/Users/test"], fileSystem: fs,
                     nodeLocator: node ?? NodeLocator(home: "/Users/test", fileSystem: FakeFileSystem(executables: ["/usr/bin/node"]),
                                                      probe: { _ in NodeVersion("v22.0.0") }),
                     spawner: spawner, isAlive: alive, startTimeout: 3)
    }

    func writeServer(_ paths: StatePaths, port: Int, pid: Int32 = 4242, token: String = String(repeating: "a", count: 64)) throws {
        try Data(#"{"pid":\#(pid),"port":\#(port),"startedAt":"2026-10-01T12:00:00Z","version":"0.1.0"}"#.utf8).write(to: paths.serverLock)
        try Data(token.utf8).write(to: paths.token)
    }

    func testLiveEndpointNeedsAliveLockAndToken() throws {
        let paths = try makeTempStateDir()
        XCTAssertNil(launcher(paths, productRoot: nil).liveEndpoint())
        try writeServer(paths, port: 5123)
        XCTAssertEqual(launcher(paths, productRoot: nil).liveEndpoint(),
                       CoreEndpoint(port: 5123, token: String(repeating: "a", count: 64), pid: 4242))
        XCTAssertNil(launcher(paths, productRoot: nil, alive: { _ in false }).liveEndpoint(), "stale server.json")
    }

    func testLaunchCommandProblems() throws {
        let paths = try makeTempStateDir()
        guard case .failure(.productRootUnknown) = launcher(paths, productRoot: nil).launchCommand() else { return XCTFail() }
        guard case .failure(.cliNotBuilt(let entry)) = launcher(paths, productRoot: "/nowhere").launchCommand() else { return XCTFail() }
        XCTAssertEqual(entry, "/nowhere/apps/distill/cli/dist/main.js")
    }

    func testLaunchCommandSetsStateDirAndPath() throws {
        let paths = try makeTempStateDir()
        let fs = FakeFileSystem(files: ["/prod/apps/distill/cli/dist/main.js": Data()])
        let node = NodeLocator(home: "/Users/test", fileSystem: FakeFileSystem(executables: ["/opt/homebrew/bin/node"]),
                               probe: { _ in NodeVersion("v22.0.0") })
        let cmd = try launcher(paths, productRoot: "/prod", fs: fs, node: node).launchCommand().get()
        XCTAssertEqual(cmd.node.path, "/opt/homebrew/bin/node")
        XCTAssertEqual(cmd.arguments, ["/prod/apps/distill/cli/dist/main.js", "serve"])
        XCTAssertEqual(cmd.environment["DISTILL_STATE_DIR"], paths.dir.path)
        XCTAssertTrue(cmd.environment["PATH"]!.hasPrefix("/opt/homebrew/bin:/Users/test/.local/bin:"))
    }

    func testStoredSettingsSupplyNodePathAndProductRoot() throws {
        let paths = try makeTempStateDir()
        try Data(#"{"productRoot":"/from-settings","nodePath":"/my/node"}"#.utf8).write(to: paths.settings)
        let l = launcher(paths, productRoot: nil)
        XCTAssertEqual(l.productRoot(), "/from-settings")
        XCTAssertEqual(launcher(paths, productRoot: "/bundled").productRoot(), "/bundled")
        XCTAssertEqual(l.storedSettings()?.nodePath, "/my/node")
    }

    /// Real temp files, fake spawner that "starts a server" by writing server.json.
    func testEnsureRunningSpawnsAndWaitsForServerJSON() async throws {
        let paths = try makeTempStateDir()
        let real = RealFileSystem()
        let root = paths.dir.appendingPathComponent("prod").path
        let entry = CoreLauncher.cliEntry(productRoot: root)
        try FileManager.default.createDirectory(atPath: (entry as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: entry, contents: Data())
        let spawned = ExitBox()
        let l = launcher(paths, productRoot: root, fs: real, spawner: { exe, args, env, log in
            XCTAssertEqual(exe, "/usr/bin/node")
            XCTAssertEqual(args.last, "serve")
            XCTAssertEqual(env["DISTILL_STATE_DIR"], paths.dir.path)
            XCTAssertEqual(log, paths.serverLog.path)
            spawned.set(1)
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.3) { try? self.writeServer(paths, port: 6001) }
            return SpawnedCore(pid: 99, exitCode: { nil })
        })
        let endpoint = try await l.ensureRunning()
        XCTAssertEqual(endpoint.port, 6001)
        XCTAssertEqual(spawned.get(), 1)
    }

    func testEnsureRunningReportsEarlyExitWithLog() async throws {
        let paths = try makeTempStateDir()
        let root = paths.dir.appendingPathComponent("prod").path
        let entry = CoreLauncher.cliEntry(productRoot: root)
        try FileManager.default.createDirectory(atPath: (entry as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: entry, contents: Data())
        let l = launcher(paths, productRoot: root, spawner: { _, _, _, log in
            try Data("distill serve: boom\n".utf8).write(to: URL(fileURLWithPath: log))
            return SpawnedCore(pid: 99, exitCode: { 1 })
        })
        do {
            _ = try await l.ensureRunning()
            XCTFail("expected a failure")
        } catch let p as CoreLauncher.Problem {
            guard case .exited(let code, let log, _) = p else { return XCTFail("\(p)") }
            XCTAssertEqual(code, 1)
            XCTAssertEqual(log, "distill serve: boom")
        }
    }

    func testChildExitAfterLosingTheRaceStillConnects() async throws {
        let paths = try makeTempStateDir()
        let root = paths.dir.appendingPathComponent("prod").path
        let entry = CoreLauncher.cliEntry(productRoot: root)
        try FileManager.default.createDirectory(atPath: (entry as NSString).deletingLastPathComponent, withIntermediateDirectories: true)
        FileManager.default.createFile(atPath: entry, contents: Data())
        let l = launcher(paths, productRoot: root, spawner: { _, _, _, _ in
            // The CLI's server wins: ours exits with "already running" while server.json appears.
            DispatchQueue.global().asyncAfter(deadline: .now() + 0.1) { try? self.writeServer(paths, port: 7002) }
            return SpawnedCore(pid: 99, exitCode: { 1 })
        })
        let endpoint = try await l.ensureRunning()
        XCTAssertEqual(endpoint.port, 7002)
    }
}
