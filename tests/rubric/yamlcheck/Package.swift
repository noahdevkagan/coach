// swift-tools-version:5.10
import PackageDescription

// Rubric YAML rig: compiles the app's REAL Rubric.swift (via symlink)
// against the same pinned Yams the app uses, then checks parsing,
// builder round-trips, and custom-signal derivation.
let package = Package(
    name: "yamlcheck",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/jpsim/Yams.git", from: "5.0.0")
    ],
    targets: [
        .executableTarget(
            name: "yamlcheck",
            dependencies: ["Yams"],
            path: "Sources/yamlcheck"
        )
    ]
)
