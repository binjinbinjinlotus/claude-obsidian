import AppKit
import WorkerCore

if CommandLine.arguments.contains("--snapshot") {
    MainActor.assumeIsolated { Snapshot.run(arguments: CommandLine.arguments) }
} else if CommandLine.arguments.contains("--run-once") {
    // Headless: batch the queue once, print the approval request, optionally
    // approve and resume. Used for scripting and end-to-end verification.
    MainActor.assumeIsolated { HeadlessRun.start(arguments: CommandLine.arguments) }
    RunLoop.main.run()
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
