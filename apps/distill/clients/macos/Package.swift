// swift-tools-version:5.10
import PackageDescription

let package = Package(
    name: "Distill",
    platforms: [.macOS(.v14)],
    products: [
        .executable(name: "Distill", targets: ["Distill"]),
    ],
    targets: [
        // UI-free client of the Distill core (apps/distill/core): contract DTOs,
        // the HTTP + event-stream client, and the launcher that finds node and
        // starts `distill serve`. The core owns all state and behavior.
        .target(name: "DistillKit"),
        // AppKit/SwiftUI shell: windows, floating icon, paste/drop intake.
        .executableTarget(name: "Distill", dependencies: ["DistillKit"]),
        .testTarget(name: "DistillKitTests", dependencies: ["DistillKit"]),
        // UI-free logic of the app target (labels, shortcuts, settings edits).
        .testTarget(name: "DistillTests", dependencies: ["Distill", "DistillKit"]),
    ]
)
