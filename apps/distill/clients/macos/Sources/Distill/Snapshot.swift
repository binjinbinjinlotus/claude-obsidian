import AppKit
import SwiftUI
import DistillKit

/// `Distill --snapshot OUT_DIR --state-dir DIR`
/// Renders the main screens offscreen to PNGs (design QA without a display).
/// The state dir supplies settings.json / jobs.json; nothing is run.
@MainActor
enum Snapshot {
    static func run(arguments: [String]) -> Never {
        func value(_ flag: String) -> String? {
            guard let i = arguments.firstIndex(of: flag), i + 1 < arguments.count else { return nil }
            return arguments[i + 1]
        }
        guard let out = value("--snapshot"), let state = value("--state-dir") else {
            FileHandle.standardError.write(Data("usage: --snapshot OUT --state-dir DIR\n".utf8))
            exit(2)
        }
        let engine = fixtureModel(stateDir: URL(fileURLWithPath: state))
        let outDir = URL(fileURLWithPath: out)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        let size = CGSize(width: 1120, height: 720)
        render(QueueScreen().environmentObject(engine), size: size, to: outDir.appendingPathComponent("queue.png"))
        if let job = engine.pendingApprovals.first {
            render(ReviewScreen(jobID: job.id).environmentObject(engine), size: size, to: outDir.appendingPathComponent("review.png"))
        }
        render(SettingsView().environmentObject(engine), size: CGSize(width: 720, height: 820), to: outDir.appendingPathComponent("settings.png"))
        render(HStack(spacing: 24) {
            FloatingFace(dropState: DropState()).environmentObject(engine)
            FloatingFace(dropState: { let s = DropState(); s.targeted = true; return s }()).environmentObject(engine)
        }.padding(20).background(Color(hex: 0xEAE8E3)), size: CGSize(width: 260, height: 130), to: outDir.appendingPathComponent("floating.png"))
        renderV3(engine: engine, size: size, outDir: outDir)
        exit(0)
    }

    /// Fixture data straight from the files in DIR (read-only, no core needed).
    /// The queue listing here is for snapshots only; the live app gets the
    /// queue from the core.
    static func fixtureModel(stateDir: URL) -> AppModel {
        let settings = (try? Data(contentsOf: stateDir.appendingPathComponent("settings.json")))
            .flatMap { try? JSONDecoder.core.decode(Settings.self, from: $0) } ?? Settings()
        let jobs = (try? Data(contentsOf: stateDir.appendingPathComponent("jobs.json")))
            .flatMap { try? JSONDecoder.core.decode([Job].self, from: $0) } ?? []
        var queue: [QueueEntry] = []
        if let vault = settings.activeVault {
            let keys: [URLResourceKey] = [.isRegularFileKey, .contentModificationDateKey, .fileSizeKey]
            let urls = (try? FileManager.default.contentsOfDirectory(at: vault.queueURL, includingPropertiesForKeys: keys,
                                                                     options: [.skipsHiddenFiles])) ?? []
            queue = urls.compactMap { url in
                guard let v = try? url.resourceValues(forKeys: Set(keys)), v.isRegularFile == true else { return nil }
                let modified = v.contentModificationDate ?? .distantPast
                return QueueEntry(path: url.path, modified: modified, size: v.fileSize ?? 0,
                                  settled: Date().timeIntervalSince(modified) >= Double(settings.settleSeconds))
            }
            .sorted { $0.modified < $1.modified }
        }
        let status = StatusResponse(
            activeVault: settings.activeVault, queueCount: queue.count,
            pendingApprovals: jobs.filter { $0.state == .awaitingApproval }.count,
            runningJobs: jobs.filter { $0.state == .running }.count,
            nextBatchAt: Date().addingTimeInterval(Double(max(1, settings.batchIntervalMinutes) * 60)))
        return AppModel(fixtureSettings: settings, jobs: jobs, queue: queue, status: status)
    }

    static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
        let renderer = ImageRenderer(content: view.frame(width: size.width, height: size.height)
            .environment(\.colorScheme, .light).environment(\.snapshotMode, true))
        renderer.scale = 2
        guard let image = renderer.nsImage, let tiff = image.tiffRepresentation,
              let png = NSBitmapImageRep(data: tiff)?.representation(using: .png, properties: [:]) else { return }
        try? png.write(to: url)
        print(url.path)
    }
}

/// Main window with a fixed section, for snapshots.
private struct QueueScreen: View {
    @EnvironmentObject var engine: AppModel
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: .constant(.queue), selectedJob: .constant(nil), openSettings: {})
            QueueView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .foregroundStyle(Theme.ink)
    }
}

private struct ReviewScreen: View {
    @EnvironmentObject var engine: AppModel
    let jobID: String
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: .constant(.review), selectedJob: .constant(jobID), openSettings: {})
            JobDetailView(jobID: jobID).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .foregroundStyle(Theme.ink)
    }
}
