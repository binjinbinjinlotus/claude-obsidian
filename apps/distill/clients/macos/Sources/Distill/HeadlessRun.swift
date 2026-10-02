import Foundation
import WorkerCore

/// `Distill --run-once --vault PATH [--queue PATH] [--model ID]
///   [--product-root PATH] [--state-dir PATH] [--approve]`
@MainActor
enum HeadlessRun {
    static func start(arguments: [String]) {
        setvbuf(stdout, nil, _IOLBF, 0)
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let vaultPath = value("--vault") else { exit(fail("--vault is required")) }
        let stateDir = value("--state-dir").map { URL(fileURLWithPath: $0) } ?? WorkerPaths.supportDirectory
        let engine = WorkerEngine(
            settingsStore: .init(filename: "settings.json", directory: stateDir),
            jobStore: .init(filename: "jobs.json", directory: stateDir))
        var settings = engine.settings
        let vault = URL(fileURLWithPath: vaultPath).standardizedFileURL.path
        settings.upsert(VaultProfile(path: vault, queueDirectory: value("--queue") ?? VaultProfile.defaultQueueDirectory(forVault: vault)))
        settings.activeVaultPath = vault
        settings.autoProcessEnabled = false
        if let model = value("--model") { settings.model = model }
        if let root = value("--product-root") { settings.productRoot = root }
        engine.settings = settings

        if let problem = engine.problems.first { exit(fail(problem.description)) }
        engine.processQueue(force: true)
        guard let job = engine.jobs.first, job.state == .running else {
            exit(fail(engine.lastError ?? "Nothing to process in \(settings.activeVault!.queueDirectory)"))
        }
        print("job \(job.id) session \(job.sessionID) files \(job.files)")
        let approve = arguments.contains("--approve")
        Task { @MainActor in
            var approved = false
            while true {
                try? await Task.sleep(for: .seconds(2))
                guard let j = engine.job(job.id), j.state != .running else { continue }
                report(j)
                if j.state == .awaitingApproval, approve, !approved, j.approval?.canApplyPlan == true {
                    approved = true
                    print("approving \(j.approval!.plan!.approvalSHA256)")
                    engine.approve(j.id)
                    continue
                }
                exit(j.state == .failed ? 1 : 0)
            }
        }
    }

    static func report(_ job: Job) {
        print("state: \(job.state.rawValue)  cost: $\(String(format: "%.3f", job.totalCostUSD))")
        if let last = job.turns.last { print("last turn (\(last.author.rawValue)):\n\(last.text)") }
        if let a = job.approval {
            if let plan = a.plan { print("plan \(plan.operationID) valid=\(plan.valid) sha=\(plan.approvalSHA256)\n  " + plan.changedPaths.joined(separator: "\n  ")) }
            if let e = a.planError { print("plan error: \(e)") }
            if !a.questions.isEmpty { print("questions: \(a.questions)") }
            if !a.denials.isEmpty { print("denials: \(a.denials.map(\.display))") }
        }
        if !job.changedPaths.isEmpty { print("changed: \(job.changedPaths)") }
        if let e = job.error { print("error: \(e)") }
    }

    static func fail(_ message: String) -> Int32 {
        FileHandle.standardError.write(Data("error: \(message)\n".utf8))
        return 2
    }
}
