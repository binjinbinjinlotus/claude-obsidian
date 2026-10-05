import Foundation

// Collectors v6 (contracts.ts → CollectorScriptStatus, CollectorManifestStatus, CollectorInstall,
// CollectorScriptFiles, CollectorScriptUpdate; spec collectors.md → "Script files and packages (v6)").
// A script Distill keeps is a real file in its own folder, with an optional package manifest whose
// packages install when the user allows the script. Decoded leniently like the rest of Collectors:
// states, triggers and results stay raw strings, so a newer core's values never fail a decode.

/// v6: the hash of each file a consent covered (`allowedFiles`).
public struct AllowedFiles: Codable, Hashable, Sendable {
    public var script: String
    public var manifest: String?
    public init(script: String, manifest: String? = nil) { self.script = script; self.manifest = manifest }
    enum Keys: String, CodingKey { case script, manifest }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        script = c.lossy(String.self, .script) ?? ""
        manifest = c.lossy(String.self, .manifest)
    }
}

/// v6: one package install in a managed script's folder (`npm install`, or a venv and `pip install`).
public struct CollectorInstall: Codable, Hashable, Sendable, Identifiable {
    public var id: String
    public var collectorId: String
    /// manual / allow / beforeRun (raw).
    public var trigger: String
    public var startedAt: Date
    public var endedAt: Date?
    public var durationMs: Double?
    /// running / success / failed / timedout / stopped (raw).
    public var result: String
    /// What ran, for display ("npm install --no-audit --no-fund").
    public var command: String
    public var manifestName: String
    public var manifestSha256: String
    public var clean: Bool
    public var exitCode: Int?
    public var signal: String?
    public var error: CollectorRunError?
    /// Interleaved stdout and stderr, the last 64 KB (only from `GET …/install` and the finished event).
    public var outputTail: String?
    /// The Node whose npm ran the install (package.json).
    public var runtime: CollectorRuntime?

    public var isRunning: Bool { result == "running" }

    public init(id: String, collectorId: String, trigger: String = "manual", startedAt: Date, endedAt: Date? = nil, durationMs: Double? = nil,
                result: String = "running", command: String = "", manifestName: String = "package.json", manifestSha256: String = "",
                clean: Bool = false, exitCode: Int? = nil, signal: String? = nil, error: CollectorRunError? = nil, outputTail: String? = nil) {
        self.id = id; self.collectorId = collectorId; self.trigger = trigger; self.startedAt = startedAt; self.endedAt = endedAt
        self.durationMs = durationMs; self.result = result; self.command = command; self.manifestName = manifestName
        self.manifestSha256 = manifestSha256; self.clean = clean; self.exitCode = exitCode; self.signal = signal; self.error = error
        self.outputTail = outputTail
    }

    enum Keys: String, CodingKey {
        case id, collectorId, trigger, startedAt, endedAt, durationMs, result, command, manifestName, manifestSha256, clean, exitCode, signal, error,
             outputTail, runtime
    }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let id = c.lossy(String.self, .id), !id.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .id, in: c, debugDescription: "an install needs an id")
        }
        self.id = id
        collectorId = c.lossy(String.self, .collectorId) ?? ""
        trigger = c.lossy(String.self, .trigger) ?? "manual"
        startedAt = c.lossyDate(.startedAt) ?? Date(timeIntervalSince1970: 0)
        endedAt = c.lossyDate(.endedAt)
        durationMs = c.lossyDouble(.durationMs)
        result = c.lossy(String.self, .result) ?? "failed"
        command = c.lossy(String.self, .command) ?? ""
        manifestName = c.lossy(String.self, .manifestName) ?? "package.json"
        manifestSha256 = c.lossy(String.self, .manifestSha256) ?? ""
        clean = c.lossy(Bool.self, .clean) ?? false
        exitCode = c.lossyInt(.exitCode)
        signal = c.lossy(String.self, .signal)
        error = c.lossy(CollectorRunError.self, .error)
        outputTail = c.lossy(String.self, .outputTail)
        runtime = c.lossy(CollectorRuntime.self, .runtime)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(id, forKey: .id)
        try c.encode(collectorId, forKey: .collectorId)
        try c.encode(trigger, forKey: .trigger)
        try c.encode(CoreDate.format(startedAt), forKey: .startedAt)
        try c.encodeIfPresent(endedAt.map(CoreDate.format), forKey: .endedAt)
        try c.encodeIfPresent(durationMs, forKey: .durationMs)
        try c.encode(result, forKey: .result)
        try c.encode(command, forKey: .command)
        try c.encode(manifestName, forKey: .manifestName)
        try c.encode(manifestSha256, forKey: .manifestSha256)
        if clean { try c.encode(true, forKey: .clean) }
        try c.encodeIfPresent(exitCode, forKey: .exitCode)
        try c.encodeIfPresent(signal, forKey: .signal)
        try c.encodeIfPresent(error, forKey: .error)
        try c.encodeIfPresent(outputTail, forKey: .outputTail)
        try c.encodeIfPresent(runtime, forKey: .runtime)
    }
}

/// What ran a script or an install: "Node 22.22.1", "Node 22.22.1 with tsx", "python3 (.venv)", "python3", "zsh".
public struct CollectorRuntime: Codable, Hashable, Sendable {
    public var label: String
    /// The interpreter's absolute path.
    public var path: String
    public var version: String?

    public init(label: String, path: String, version: String? = nil) {
        self.label = label; self.path = path; self.version = version
    }

    enum Keys: String, CodingKey { case label, path, version }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        guard let label = c.lossy(String.self, .label), !label.isEmpty else {
            throw DecodingError.dataCorruptedError(forKey: .label, in: c, debugDescription: "a runtime needs a label")
        }
        self.label = label
        path = c.lossy(String.self, .path) ?? ""
        version = c.lossy(String.self, .version)
    }

    /// "python3 (.venv) · ~/…/.venv/bin/python3": the label and where it is, home as `~`, long paths shortened.
    public func line(home: String = NSHomeDirectory()) -> String {
        guard !path.isEmpty else { return label }
        var p = path
        if !home.isEmpty, p.hasPrefix(home + "/") { p = "~" + p.dropFirst(home.count) }
        let parts = p.split(separator: "/", omittingEmptySubsequences: true)
        if parts.count > 4 { p = (p.hasPrefix("~") ? "~/…/" : "/…/") + parts.suffix(3).joined(separator: "/") }
        return "\(label) · \(p)"
    }
}

/// v6: package.json (node, typescript) or requirements.txt (python3) of a managed script.
public struct CollectorManifestStatus: Codable, Hashable, Sendable {
    public var name: String
    public var path: String
    public var exists: Bool
    public var hasDependencies: Bool
    public var packageCount: Int
    public var sha256: String?
    public var installedSha256: String?
    public var needsInstall: Bool
    public var installing: Bool
    /// The newest install (without its output).
    public var lastInstall: CollectorInstall?
    /// none / ready / installing / failed / needsInstall (raw).
    public var state: String

    public init(name: String, path: String = "", exists: Bool = true, hasDependencies: Bool = false, packageCount: Int = 0,
                sha256: String? = nil, installedSha256: String? = nil, needsInstall: Bool = false, installing: Bool = false,
                lastInstall: CollectorInstall? = nil, state: String = "none") {
        self.name = name; self.path = path; self.exists = exists; self.hasDependencies = hasDependencies; self.packageCount = packageCount
        self.sha256 = sha256; self.installedSha256 = installedSha256; self.needsInstall = needsInstall; self.installing = installing
        self.lastInstall = lastInstall; self.state = state
    }

    enum Keys: String, CodingKey { case name, path, exists, hasDependencies, packageCount, sha256, installedSha256, needsInstall, installing, lastInstall, state }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        name = c.lossy(String.self, .name) ?? "package.json"
        path = c.lossy(String.self, .path) ?? ""
        exists = c.lossy(Bool.self, .exists) ?? false
        hasDependencies = c.lossy(Bool.self, .hasDependencies) ?? false
        packageCount = c.lossyInt(.packageCount) ?? 0
        sha256 = c.lossy(String.self, .sha256)
        installedSha256 = c.lossy(String.self, .installedSha256)
        needsInstall = c.lossy(Bool.self, .needsInstall) ?? false
        installing = c.lossy(Bool.self, .installing) ?? false
        lastInstall = c.lossy(CollectorInstall.self, .lastInstall)
        state = c.lossy(String.self, .state) ?? (installing ? "installing" : needsInstall ? "needsInstall" : "none")
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(name, forKey: .name)
        try c.encode(path, forKey: .path)
        try c.encode(exists, forKey: .exists)
        try c.encode(hasDependencies, forKey: .hasDependencies)
        try c.encode(packageCount, forKey: .packageCount)
        try c.encodeIfPresent(sha256, forKey: .sha256)
        try c.encodeIfPresent(installedSha256, forKey: .installedSha256)
        try c.encode(needsInstall, forKey: .needsInstall)
        try c.encode(installing, forKey: .installing)
        try c.encodeIfPresent(lastInstall, forKey: .lastInstall)
        try c.encode(state, forKey: .state)
    }
}

/// v6: `status.script`: where the script lives, its packages, what changed since the OK, the newest test run.
public struct CollectorScriptStatus: Codable, Hashable, Sendable {
    public var path: String
    public var dir: String?
    public var managed: Bool
    public var manifest: CollectorManifestStatus?
    /// "script" and/or "manifest" (raw); empty when never allowed, or allowed before v6.
    public var changes: [String]
    /// The newest test run (without files and output tails).
    public var lastTestRun: CollectorRun?

    public init(path: String, dir: String? = nil, managed: Bool = false, manifest: CollectorManifestStatus? = nil,
                changes: [String] = [], lastTestRun: CollectorRun? = nil) {
        self.path = path; self.dir = dir; self.managed = managed; self.manifest = manifest; self.changes = changes; self.lastTestRun = lastTestRun
    }

    enum Keys: String, CodingKey { case path, dir, managed, manifest, changes, lastTestRun }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        path = c.lossy(String.self, .path) ?? ""
        dir = c.lossy(String.self, .dir)
        managed = c.lossy(Bool.self, .managed) ?? false
        manifest = c.lossy(CollectorManifestStatus.self, .manifest)
        changes = c.lossyArray(String.self, .changes)
        lastTestRun = c.lossy(CollectorRun.self, .lastTestRun)
    }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encode(path, forKey: .path)
        try c.encodeIfPresent(dir, forKey: .dir)
        try c.encode(managed, forKey: .managed)
        try c.encodeIfPresent(manifest, forKey: .manifest)
        if !changes.isEmpty { try c.encode(changes, forKey: .changes) }
        try c.encodeIfPresent(lastTestRun, forKey: .lastTestRun)
    }
}

/// v6: `GET /v1/collectors/:id/script`.
public struct CollectorScriptFiles: Codable, Hashable, Sendable {
    public struct Manifest: Codable, Hashable, Sendable {
        public var name: String
        public var path: String
        /// nil when there is none yet.
        public var text: String?
        public var sha256: String?
        public init(name: String, path: String = "", text: String? = nil, sha256: String? = nil) {
            self.name = name; self.path = path; self.text = text; self.sha256 = sha256
        }
        enum Keys: String, CodingKey { case name, path, text, sha256 }
        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: Keys.self)
            name = c.lossy(String.self, .name) ?? "package.json"
            path = c.lossy(String.self, .path) ?? ""
            text = c.lossy(String.self, .text)
            sha256 = c.lossy(String.self, .sha256)
        }
    }
    public var collectorId: String
    public var interpreter: CollectorInterpreter
    public var managed: Bool
    public var path: String
    public var dir: String?
    /// nil when it can't be read (`problem` says why).
    public var code: String?
    /// sha256 of the script alone: send it back as `baseSha256`.
    public var sha256: String?
    public var problem: String?
    /// Managed scripts with a manifest kind (not zsh).
    public var manifest: Manifest?

    public init(collectorId: String, interpreter: CollectorInterpreter, managed: Bool, path: String, dir: String? = nil,
                code: String? = nil, sha256: String? = nil, problem: String? = nil, manifest: Manifest? = nil) {
        self.collectorId = collectorId; self.interpreter = interpreter; self.managed = managed; self.path = path; self.dir = dir
        self.code = code; self.sha256 = sha256; self.problem = problem; self.manifest = manifest
    }

    enum Keys: String, CodingKey { case collectorId, interpreter, managed, path, dir, code, sha256, problem, manifest }
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: Keys.self)
        collectorId = c.lossy(String.self, .collectorId) ?? ""
        interpreter = c.lossy(CollectorInterpreter.self, .interpreter) ?? .zsh
        managed = c.lossy(Bool.self, .managed) ?? false
        path = c.lossy(String.self, .path) ?? ""
        dir = c.lossy(String.self, .dir)
        code = c.lossy(String.self, .code)
        sha256 = c.lossy(String.self, .sha256)
        problem = c.lossy(String.self, .problem)
        manifest = c.lossy(Manifest.self, .manifest)
    }
}

/// v6: `PUT /v1/collectors/:id/script`. `manifest` and `baseManifestSha256` tell "not sent" (nil) from an
/// explicit null (`.some(nil)`: remove the manifest / it didn't exist when the editor loaded it).
public struct CollectorScriptUpdate: Encodable, Hashable, Sendable {
    public var code: String?
    public var manifest: String??
    public var baseSha256: String?
    public var baseManifestSha256: String??

    public init(code: String? = nil, manifest: String?? = nil, baseSha256: String? = nil, baseManifestSha256: String?? = nil) {
        self.code = code; self.manifest = manifest; self.baseSha256 = baseSha256; self.baseManifestSha256 = baseManifestSha256
    }
    public var isEmpty: Bool { code == nil && manifest == nil }

    enum Keys: String, CodingKey { case code, manifest, baseSha256, baseManifestSha256 }
    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: Keys.self)
        try c.encodeIfPresent(code, forKey: .code)
        if let manifest {
            if let m = manifest { try c.encode(m, forKey: .manifest) } else { try c.encodeNil(forKey: .manifest) }
        }
        try c.encodeIfPresent(baseSha256, forKey: .baseSha256)
        if let baseManifestSha256 {
            if let b = baseManifestSha256 { try c.encode(b, forKey: .baseManifestSha256) } else { try c.encodeNil(forKey: .baseManifestSha256) }
        }
    }
}

// MARK: - CoreClient (v6 routes)

extension CoreClient {
    /// The script's text and its package manifest.
    public func collectorScript(_ id: String) async throws -> CollectorScriptFiles {
        try await getPlain("/v1/collectors/\(Self.segment(id))/script")
    }

    /// Save a managed script's code and/or manifest. 409 (`invalid_state`) when a file changed on disk since
    /// the `base…` hashes were read, or for the user's own file. A saved change needs consent again.
    public func saveCollectorScript(_ id: String, _ update: CollectorScriptUpdate) async throws -> CollectorScriptFiles {
        try await sendPlain("PUT", "/v1/collectors/\(Self.segment(id))/script", body: update)
    }

    /// Install the manifest's packages (needs a current consent; 409 while a run or install goes).
    public func installCollectorPackages(_ id: String, clean: Bool = false) async throws -> CollectorInstall {
        let body: JSONValue = clean ? .object(["clean": .bool(true)]) : .object([:])
        return try await sendWrapped("POST", "/v1/collectors/\(Self.segment(id))/install", body: body, CollectorInstall.self, key: "install")
    }

    /// Stop a running install; nil when none runs.
    public func stopCollectorInstall(_ id: String) async throws -> CollectorInstall? {
        try await sendWrapped("POST", "/v1/collectors/\(Self.segment(id))/install/stop", body: JSONValue.object([:]),
                              CollectorInstall?.self, key: "install")
    }

    /// The newest install with its output; nil when there was none.
    public func collectorInstall(_ id: String) async throws -> CollectorInstall? {
        try await getWrapped("/v1/collectors/\(Self.segment(id))/install", CollectorInstall?.self, key: "install")
    }

    /// Test run (scripts): like Run now, into Distill's scratch folder instead of the queue.
    public func testCollector(_ id: String) async throws -> CollectorRun {
        try await sendWrapped("POST", "/v1/collectors/\(Self.segment(id))/test", body: JSONValue.object([:]), CollectorRun.self, key: "run")
    }
}
