import AppKit
import DistillKit

if CommandLine.arguments.contains("--snapshot") {
    MainActor.assumeIsolated { Snapshot.run(arguments: CommandLine.arguments) }
} else if CommandLine.arguments.contains("--run-once") {
    // Retired with the Swift engine: the core owns batching now.
    FileHandle.standardError.write(Data("""
    error: --run-once moved to the Distill core. Use the CLI (`distill status`, `distill note add`)
    against a running core, or the dev script for a headless batch:
      node --import tsx apps/distill/core/src/dev/run-once.ts --vault PATH --state-dir TEMP_DIR [--approve]

    """.utf8))
    exit(2)
} else {
    // AppKit lifecycle so the floating panel, main window, and menus are all
    // owned by one delegate; SwiftUI is used for window content.
    MainActor.assumeIsolated {
        let app = NSApplication.shared
        let delegate = AppDelegate()
        app.delegate = delegate
        app.setActivationPolicy(.regular)
        app.run()
    }
}
