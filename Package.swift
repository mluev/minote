// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "Minote",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .executable(name: "Minote", targets: ["Minote"]),
        .library(name: "MinoteKit", targets: ["MinoteKit"]),
        .library(name: "MinoteEditor", targets: ["MinoteEditor"]),
    ],
    targets: [
        // Platform-agnostic core: notes, naming, file storage, library state.
        // Foundation-only so the iOS app can share it.
        .target(name: "MinoteKit"),

        // Writing-surface look shared by the Mac and iOS apps: theme, fonts,
        // geometry and the Markdown styler. AppKit or UIKit underneath.
        .target(name: "MinoteEditor", dependencies: ["MinoteKit"]),

        // The macOS app. UI code defaults to the main actor.
        .executableTarget(
            name: "Minote",
            dependencies: ["MinoteKit", "MinoteEditor"],
            swiftSettings: [.defaultIsolation(MainActor.self)]
        ),

        .testTarget(name: "MinoteKitTests", dependencies: ["MinoteKit"]),
        .testTarget(name: "MinoteEditorTests", dependencies: ["MinoteEditor", "MinoteKit"]),
    ],
    swiftLanguageModes: [.v6]
)
