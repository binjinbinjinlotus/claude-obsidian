import AppKit
import SwiftUI
import WorkerCore

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
        let stateDir = URL(fileURLWithPath: state)
        let engine = WorkerEngine(
            settingsStore: .init(filename: "settings.json", directory: stateDir),
            jobStore: .init(filename: "jobs.json", directory: stateDir))
        engine.refreshQueue()
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
        exit(0)
    }

    private static func render<V: View>(_ view: V, size: CGSize, to url: URL) {
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
    @EnvironmentObject var engine: WorkerEngine
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: .constant(.queue), selectedJob: .constant(nil), openSettings: {})
            QueueView().frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .foregroundStyle(Theme.ink)
    }
}

private struct ReviewScreen: View {
    @EnvironmentObject var engine: WorkerEngine
    let jobID: String
    var body: some View {
        HStack(spacing: 0) {
            Sidebar(section: .constant(.review), selectedJob: .constant(jobID), openSettings: {})
            JobDetailView(jobID: jobID).frame(maxWidth: .infinity, maxHeight: .infinity).background(Theme.window)
        }
        .foregroundStyle(Theme.ink)
    }
}
