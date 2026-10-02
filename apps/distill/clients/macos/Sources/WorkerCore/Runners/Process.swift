import Foundation

public struct ProcessOutput: Sendable {
    public var status: Int32
    public var stdout: Data
    public var stderr: Data
}

/// Runs a subprocess off the main thread. GUI apps inherit a minimal PATH,
/// so callers pass explicit executables and environment.
public final class ProcessRunner: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false

    public init() {}

    public static var basePath: String {
        let home = FileManager.default.homeDirectoryForCurrentUser.path
        return ["\(home)/.local/bin", "/opt/homebrew/bin", "/usr/local/bin",
                "/usr/bin", "/bin", "/usr/sbin", "/sbin"].joined(separator: ":")
    }

    public func run(
        executable: String, arguments: [String], cwd: String,
        stdin: Data? = nil, environment extra: [String: String] = [:]
    ) async throws -> ProcessOutput {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: executable)
        p.arguments = arguments
        p.currentDirectoryURL = URL(fileURLWithPath: cwd)
        var env = ProcessInfo.processInfo.environment
        let execDir = URL(fileURLWithPath: executable).deletingLastPathComponent().path
        env["PATH"] = "\(execDir):\(Self.basePath)"
        for (k, v) in extra { env[k] = v }
        p.environment = env
        let out = Pipe(), err = Pipe(), inp = Pipe()
        p.standardOutput = out
        p.standardError = err
        p.standardInput = inp

        let alreadyCancelled = lock.withLock {
            if !cancelled { process = p }
            return cancelled
        }
        if alreadyCancelled { throw RunnerError.cancelled }

        return try await withCheckedThrowingContinuation { cont in
            DispatchQueue.global(qos: .userInitiated).async {
                do { try p.run() } catch {
                    cont.resume(throwing: RunnerError.launchFailed(error.localizedDescription))
                    return
                }
                if let stdin { inp.fileHandleForWriting.write(stdin) }
                try? inp.fileHandleForWriting.close()
                // Drain both pipes concurrently so a full buffer never deadlocks.
                var errData = Data()
                let group = DispatchGroup()
                group.enter()
                DispatchQueue.global().async {
                    errData = err.fileHandleForReading.readDataToEndOfFile()
                    group.leave()
                }
                let outData = out.fileHandleForReading.readDataToEndOfFile()
                group.wait()
                p.waitUntilExit()
                if self.isCancelled {
                    cont.resume(throwing: RunnerError.cancelled)
                } else {
                    cont.resume(returning: ProcessOutput(
                        status: p.terminationStatus, stdout: outData, stderr: errData))
                }
            }
        }
    }

    private var isCancelled: Bool {
        lock.lock(); defer { lock.unlock() }
        return cancelled
    }

    public func cancel() {
        lock.lock()
        cancelled = true
        let p = process
        lock.unlock()
        if let p, p.isRunning { p.terminate() }
    }
}
