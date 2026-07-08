// swift-tools-version:5.10
import PackageDescription

// ASR regression rig: compiles the app's REAL ParakeetTranscriber.swift
// (via symlink) against the same pinned FluidAudio the app uses, feeds
// scripted audio through it in real time, and emits UTT lines for scoring.
let package = Package(
    name: "ParakeetRig",
    platforms: [.macOS(.v14)],
    dependencies: [
        .package(url: "https://github.com/FluidInference/FluidAudio", exact: "0.15.5")
    ],
    targets: [
        .executableTarget(
            name: "rig",
            dependencies: [.product(name: "FluidAudio", package: "FluidAudio")],
            path: "Sources/rig"
        )
    ]
)
