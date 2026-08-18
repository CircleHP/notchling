// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "Notchling",
    platforms: [.macOS(.v14)], // .v14 for the Observation framework (@Observable)
    products: [
        .executable(name: "Notchling", targets: ["Notchling"]),
        .executable(name: "notchling-hook", targets: ["notchling-hook"]),
    ],
    // No external dependencies: the widget's window, notch shape and per-screen presentation are all in
    // Sources/Notchling/UI. See docs/external-displays.md for what that layer has to guarantee.
    targets: [
        .executableTarget(
            name: "Notchling",
            path: "Sources/Notchling",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        // Deliberately dependency-free: this runs on PreToolUse, in the hot path of every tool call.
        .executableTarget(
            name: "notchling-hook",
            path: "Sources/notchling-hook",
            swiftSettings: [.swiftLanguageMode(.v5)]
        ),
        .testTarget(
            name: "NotchlingTests",
            dependencies: ["Notchling"],
            path: "Tests/NotchlingTests"
        ),
    ]
)
