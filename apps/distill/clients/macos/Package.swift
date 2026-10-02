// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Distill",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Distill", targets: ["Distill"]),
    ],
    targets: [
        // UI-free core: settings, queue batching, claude -p runner, job kinds,
        // approval state machine. Everything testable lives here.
        .target(name: "WorkerCore"),
        // AppKit/SwiftUI shell: windows, floating icon, paste/drop intake.
        .executableTarget(name: "Distill", dependencies: ["WorkerCore"]),
        .testTarget(name: "WorkerCoreTests", dependencies: ["WorkerCore"]),
    ]
)
