import Darwin
import Foundation

// How the app finds (or starts) the one Distill core for a state dir.
// Mirrors apps/distill/cli/src/client.ts: read server.json + token; when no
// live server holds the lock, start `node <cli>/dist/main.js serve` detached
// with DISTILL_STATE_DIR set, log to <state>/server.log, and wait for
// server.json. Quitting the app never stops the core (the CLI may be using it).

// MARK: - State paths

public struct StatePaths: Equatable, Sendable {
    public var dir: URL
    public var settings: URL { dir.appendingPathComponent("settings.json") }
    public var jobs: URL { dir.appendingPathComponent("jobs.json") }
    public var serverLock: URL { dir.appendingPathComponent("server.json") }
    public var token: URL { dir.appendingPathComponent("token") }
    public var serverLog: URL { dir.appendingPathComponent("server.log") }

    public init(dir: URL) { self.dir = dir.standardizedFileURL }

    /// The app's state dir: `$DISTILL_STATE_DIR`, else
    /// `~/Library/Application Support/Distill`. Only the app entry point calls
    /// this; everything else takes explicit paths (tests use temp dirs).
    public static func resolve(environment: [String: String] = ProcessInfo.processInfo.environment) -> StatePaths {
        if let dir = environment["DISTILL_STATE_DIR"], !dir.isEmpty {
            return StatePaths(dir: URL(fileURLWithPath: (dir as NSString).expandingTildeInPath, isDirectory: true))
        }
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        return StatePaths(dir: base.appendingPathComponent("Distill", isDirectory: true))
    }
}

/// `<state dir>/server.json`, written by the core once it listens.
public struct ServerLock: Codable, Equatable, Sendable {
    public var pid: Int32
    public var port: Int
    public var startedAt: String
    public var version: String

    public init(pid: Int32, port: Int, startedAt: String = "", version: String = "") {
        self.pid = pid
        self.port = port
        self.startedAt = startedAt
        self.version = version
    }

    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        guard let pid = c.lossyInt(.pid), let port = c.lossyInt(.port) else {
            throw DecodingError.dataCorrupted(.init(codingPath: [], debugDescription: "server.json needs pid and port"))
        }
        self.pid = Int32(pid)
        self.port = port
        startedAt = c.lossy(String.self, .startedAt) ?? ""
        version = c.lossy(String.self, .version) ?? ""
    }
}

// MARK: - Injectable environment

/// The bits of the file system the launcher reads (injected in tests).
public protocol LauncherFileSystem: Sendable {
    func fileExists(_ path: String) -> Bool
    func isExecutable(_ path: String) -> Bool
    func contentsOfDirectory(_ path: String) -> [String]
    func read(_ path: String) -> Data?
}

public struct RealFileSystem: LauncherFileSystem {
    public init() {}
    public func fileExists(_ path: String) -> Bool { FileManager.default.fileExists(atPath: path) }
    public func isExecutable(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        return FileManager.default.fileExists(atPath: path, isDirectory: &isDir) && !isDir.boolValue
            && FileManager.default.isExecutableFile(atPath: path)
    }
    public func contentsOfDirectory(_ path: String) -> [String] {
        (try? FileManager.default.contentsOfDirectory(atPath: path)) ?? []
    }
    public func read(_ path: String) -> Data? { FileManager.default.contents(atPath: path) }
}

public struct NodeVersion: Comparable, CustomStringConvertible, Sendable {
    public var major: Int
    public var minor: Int
    public var patch: Int

    public init(major: Int, minor: Int = 0, patch: Int = 0) {
        self.major = major
        self.minor = minor
        self.patch = patch
    }

    /// "v22.22.1", "22.1", "v20.11.0\n".
    public init?(_ text: String) {
        var s = text.trimmingCharacters(in: .whitespacesAndNewlines)
        if s.hasPrefix("v") { s.removeFirst() }
        let parts = s.split(separator: ".").map { Int($0.prefix { $0.isNumber }) }
        guard let first = parts.first, let major = first else { return nil }
        self.init(major: major, minor: (parts.count > 1 ? parts[1] : 0) ?? 0, patch: (parts.count > 2 ? parts[2] : 0) ?? 0)
    }

    public static func < (a: NodeVersion, b: NodeVersion) -> Bool {
        (a.major, a.minor, a.patch) < (b.major, b.minor, b.patch)
    }

    public var description: String { "v\(major).\(minor).\(patch)" }
}

/// Runs `<node> --version`. Injected in tests.
public typealias NodeVersionProbe = @Sendable (String) -> NodeVersion?

public let probeNodeVersion: NodeVersionProbe = { path in
    let process = Process()
    process.executableURL = URL(fileURLWithPath: path)
    process.arguments = ["--version"]
    let out = Pipe()
    process.standardOutput = out
    process.standardError = FileHandle.nullDevice
    process.standardInput = FileHandle.nullDevice
    do { try process.run() } catch { return nil }
    let deadline = Date().addingTimeInterval(5)
    while process.isRunning && Date() < deadline { usleep(20_000) }
    if process.isRunning { process.terminate(); return nil }
    let data = out.fileHandleForReading.readDataToEndOfFile()
    return process.terminationStatus == 0 ? NodeVersion(String(decoding: data, as: UTF8.self)) : nil
}

// MARK: - Node discovery

public struct NodeLocation: Equatable, Sendable {
    public var path: String
    public var version: NodeVersion
}

/// GUI apps do not inherit the shell PATH (nvm, Homebrew), so node is looked up
/// in a fixed order: `settings.nodePath`, the highest `~/.nvm/versions/node/*/bin/node`,
/// /opt/homebrew/bin/node, /usr/local/bin/node, /usr/bin/node. The first one
/// that runs and reports version ≥ 20 wins.
public struct NodeLocator: Sendable {
    public static let minimumMajor = 20

    public var home: String
    public var fileSystem: any LauncherFileSystem
    public var probe: NodeVersionProbe

    public init(home: String = NSHomeDirectory(), fileSystem: any LauncherFileSystem = RealFileSystem(),
                probe: @escaping NodeVersionProbe = probeNodeVersion) {
        self.home = home
        self.fileSystem = fileSystem
        self.probe = probe
    }

    /// Candidate paths in priority order (existence not checked yet).
    public func candidates(settingsNodePath: String?) -> [String] {
        var out: [String] = []
        if let p = settingsNodePath?.trimmingCharacters(in: .whitespaces), !p.isEmpty {
            out.append((p as NSString).expandingTildeInPath)
        }
        let nvm = (home as NSString).appendingPathComponent(".nvm/versions/node")
        let versions = fileSystem.contentsOfDirectory(nvm)
            .compactMap { name in NodeVersion(name).map { (name, $0) } }
            .sorted { $0.1 > $1.1 } // highest first, by number (v8 < v24)
        out += versions.map { "\(nvm)/\($0.0)/bin/node" }
        out += ["/opt/homebrew/bin/node", "/usr/local/bin/node", "/usr/bin/node"]
        var seen = Set<String>()
        return out.filter { seen.insert($0).inserted }
    }

    public enum Failure: Error, Equatable, CustomStringConvertible, Sendable {
        /// `tooOld` lists candidates that ran but were older than v20.
        case notFound(tried: [String], tooOld: [String])

        public var description: String {
            switch self {
            case .notFound(let tried, let tooOld):
                var s = "Node.js \(NodeLocator.minimumMajor) or newer was not found. Install it (for example `brew install node` or nvm), or set its path in Settings → Advanced → node."
                if !tooOld.isEmpty { s += " Too old: \(tooOld.joined(separator: ", "))." }
                if !tried.isEmpty { s += " Looked in: \(tried.joined(separator: ", "))." }
                return s
            }
        }
    }

    public func locate(settingsNodePath: String?) -> Result<NodeLocation, Failure> {
        var tooOld: [String] = []
        let all = candidates(settingsNodePath: settingsNodePath)
        for path in all where fileSystem.isExecutable(path) {
            guard let version = probe(path) else { continue }
            if version.major >= Self.minimumMajor { return .success(NodeLocation(path: path, version: version)) }
            tooOld.append("\(path) (\(version))")
        }
        return .failure(.notFound(tried: all, tooOld: tooOld))
    }
}

// MARK: - Spawning

/// A started core process. `exitCode()` is nil while it runs.
public struct SpawnedCore: Sendable {
    public var pid: Int32
    public var exitCode: @Sendable () -> Int32?
    public init(pid: Int32, exitCode: @escaping @Sendable () -> Int32?) {
        self.pid = pid
        self.exitCode = exitCode
    }
}

public typealias CoreSpawner = @Sendable (_ executable: String, _ arguments: [String], _ environment: [String: String], _ logPath: String) throws -> SpawnedCore

/// posix_spawn in a new session (so it outlives the app and is not tied to its
/// process group), stdin from /dev/null, stdout+stderr appended to the log.
public let spawnDetachedCore: CoreSpawner = { executable, arguments, environment, logPath in
    var attr: posix_spawnattr_t?
    posix_spawnattr_init(&attr)
    defer { posix_spawnattr_destroy(&attr) }
    posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID | POSIX_SPAWN_CLOEXEC_DEFAULT))

    var actions: posix_spawn_file_actions_t?
    posix_spawn_file_actions_init(&actions)
    defer { posix_spawn_file_actions_destroy(&actions) }
    posix_spawn_file_actions_addopen(&actions, 0, "/dev/null", O_RDONLY, 0)
    posix_spawn_file_actions_addopen(&actions, 1, logPath, O_WRONLY | O_APPEND | O_CREAT, 0o600)
    posix_spawn_file_actions_adddup2(&actions, 1, 2)

    let argv = ([executable] + arguments).map { strdup($0) } + [nil]
    let envp = environment.map { strdup("\($0.key)=\($0.value)") } + [nil]
    defer {
        argv.forEach { free($0) }
        envp.forEach { free($0) }
    }
    var pid: pid_t = 0
    let rc = posix_spawn(&pid, executable, &actions, &attr, argv, envp)
    guard rc == 0 else { throw CoreLauncher.Problem.spawnFailed(String(cString: strerror(rc))) }

    // Reap the child so an early exit is visible (and no zombie is left).
    let box = ExitBox()
    let child = pid
    Thread.detachNewThread {
        var status: Int32 = 0
        while waitpid(child, &status, 0) == -1 && errno == EINTR {}
        let exited = (status & 0x7f) == 0
        box.set(exited ? (status >> 8) & 0xff : 128 + (status & 0x7f))
    }
    return SpawnedCore(pid: pid, exitCode: { box.get() })
}

final class ExitBox: @unchecked Sendable {
    private let lock = NSLock()
    private var code: Int32?
    func set(_ c: Int32) { lock.lock(); code = c; lock.unlock() }
    func get() -> Int32? { lock.lock(); defer { lock.unlock() }; return code }
}

/// True when a process with this pid exists (EPERM: exists, owned by someone else).
public let isPidAlive: @Sendable (Int32) -> Bool = { pid in
    guard pid > 0 else { return false }
    return kill(pid, 0) == 0 || errno == EPERM
}

// MARK: - Launcher

public struct CoreLauncher: Sendable {
    public enum Problem: Error, Equatable, CustomStringConvertible, Sendable {
        case node(NodeLocator.Failure)
        case productRootUnknown
        case cliNotBuilt(String)
        case spawnFailed(String)
        case exited(code: Int32, log: String, logPath: String)
        case timedOut(seconds: Int, logPath: String)
        case noToken(String)

        public var description: String {
            switch self {
            case .node(let f): return f.description
            case .productRootUnknown:
                return "Distill does not know where the claude-obsidian checkout is. Rebuild the app with apps/distill/clients/macos/scripts/build-app.sh, or set Product root."
            case .cliNotBuilt(let path):
                return "The Distill core is not built (\(path) is missing). Run `npm ci && npm run build --workspaces` in apps/distill, or rebuild the app."
            case .spawnFailed(let m): return "Could not start the Distill core: \(m)"
            case .exited(let code, let log, let logPath):
                return "The Distill core exited (code \(code)) before it was ready. Log: \(logPath)" + (log.isEmpty ? "" : "\n\(log)")
            case .timedOut(let s, let logPath): return "Timed out after \(s) s waiting for the Distill core. Log: \(logPath)"
            case .noToken(let path): return "The Distill core is running but there is no API token at \(path)."
            }
        }
    }

    public var paths: StatePaths
    /// Info.plist `ClaudeObsidianProductRoot` (the checkout the app was built from).
    public var bundledProductRoot: String?
    public var environment: [String: String]
    public var fileSystem: any LauncherFileSystem
    public var nodeLocator: NodeLocator
    public var spawner: CoreSpawner
    public var isAlive: @Sendable (Int32) -> Bool
    public var startTimeout: TimeInterval

    public init(paths: StatePaths,
                bundledProductRoot: String? = nil,
                environment: [String: String] = ProcessInfo.processInfo.environment,
                fileSystem: any LauncherFileSystem = RealFileSystem(),
                nodeLocator: NodeLocator = NodeLocator(),
                spawner: @escaping CoreSpawner = spawnDetachedCore,
                isAlive: @escaping @Sendable (Int32) -> Bool = isPidAlive,
                startTimeout: TimeInterval = 20) {
        self.paths = paths
        self.bundledProductRoot = bundledProductRoot
        self.environment = environment
        self.fileSystem = fileSystem
        self.nodeLocator = nodeLocator
        self.spawner = spawner
        self.isAlive = isAlive
        self.startTimeout = startTimeout
    }

    // MARK: Discovery

    public func readLock() -> ServerLock? {
        fileSystem.read(paths.serverLock.path).flatMap { try? JSONDecoder().decode(ServerLock.self, from: $0) }
    }

    public func readToken() -> String? {
        guard let data = fileSystem.read(paths.token.path) else { return nil }
        let token = String(decoding: data, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return token.isEmpty ? nil : token
    }

    /// The lock of a core whose process is alive and listening on a port.
    public func liveLock() -> ServerLock? {
        guard let lock = readLock(), lock.port > 0, isAlive(lock.pid) else { return nil }
        return lock
    }

    /// Endpoint of a running core, without starting one.
    public func liveEndpoint() -> CoreEndpoint? {
        guard let lock = liveLock(), let token = readToken() else { return nil }
        return CoreEndpoint(port: lock.port, token: token, pid: lock.pid)
    }

    /// settings.json read-only, for what is needed before a core runs (nodePath,
    /// productRoot). The core stays the only writer.
    public func storedSettings() -> Settings? {
        fileSystem.read(paths.settings.path).flatMap { try? JSONDecoder.core.decode(Settings.self, from: $0) }
    }

    /// `$DISTILL_PRODUCT_ROOT`, else the bundled root, else settings.productRoot.
    public func productRoot() -> String? {
        let options = [environment["DISTILL_PRODUCT_ROOT"], bundledProductRoot, storedSettings()?.productRoot]
        return options.compactMap { $0 }.first { !$0.isEmpty }
    }

    public static func cliEntry(productRoot: String) -> String {
        URL(fileURLWithPath: productRoot).appendingPathComponent("apps/distill/cli/dist/main.js").path
    }

    /// Fixed PATH for the core and the tools it runs (GUI apps get a minimal one).
    public static func childPath(nodeDirectory: String, home: String) -> String {
        [nodeDirectory, "\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin", "/usr/bin", "/bin", "/usr/sbin", "/sbin"]
            .reduce(into: [String]()) { if !$0.contains($1) { $0.append($1) } }
            .joined(separator: ":")
    }

    // MARK: Start

    /// The `node` + arguments + environment that start the core (also used by tests).
    public func launchCommand() -> Result<(node: NodeLocation, arguments: [String], environment: [String: String]), Problem> {
        guard let root = productRoot() else { return .failure(.productRootUnknown) }
        let entry = Self.cliEntry(productRoot: root)
        guard fileSystem.fileExists(entry) else { return .failure(.cliNotBuilt(entry)) }
        switch nodeLocator.locate(settingsNodePath: storedSettings()?.nodePath) {
        case .failure(let f): return .failure(.node(f))
        case .success(let node):
            var env = environment
            env["DISTILL_STATE_DIR"] = paths.dir.path
            env["PATH"] = Self.childPath(nodeDirectory: (node.path as NSString).deletingLastPathComponent, home: nodeLocator.home)
            return .success((node, [entry, "serve"], env))
        }
    }

    /// The endpoint of the running core, starting one when none is alive.
    public func ensureRunning() async throws -> CoreEndpoint {
        if let endpoint = liveEndpoint() { return endpoint }
        let command: (node: NodeLocation, arguments: [String], environment: [String: String])
        switch launchCommand() {
        case .failure(let p): throw p
        case .success(let c): command = c
        }
        try FileManager.default.createDirectory(at: paths.dir, withIntermediateDirectories: true,
                                                attributes: [.posixPermissions: 0o700])
        let logPath = paths.serverLog.path
        let logOffset = (try? FileManager.default.attributesOfItem(atPath: logPath)[.size] as? Int) ?? 0
        let child = try spawner(command.node.path, command.arguments, command.environment, logPath)
        let deadline = Date().addingTimeInterval(startTimeout)
        while true {
            if let endpoint = liveEndpoint() { return endpoint }
            if let code = child.exitCode() {
                // Another client (the CLI) may have won the race: its server is fine.
                try? await Task.sleep(nanoseconds: 200_000_000)
                if let endpoint = liveEndpoint() { return endpoint }
                if let lock = liveLock() { _ = lock; throw Problem.noToken(paths.token.path) }
                throw Problem.exited(code: code, log: Self.tail(logPath, from: logOffset), logPath: logPath)
            }
            if Date() > deadline { throw Problem.timedOut(seconds: Int(startTimeout), logPath: logPath) }
            try await Task.sleep(nanoseconds: 100_000_000)
        }
    }

    static func tail(_ path: String, from offset: Int, lines: Int = 15) -> String {
        guard let data = FileManager.default.contents(atPath: path), data.count > offset else { return "" }
        let text = String(decoding: data.suffix(from: offset), as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        return text.split(separator: "\n", omittingEmptySubsequences: false).suffix(lines).joined(separator: "\n")
    }
}
