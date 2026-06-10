// swift-tools-version:6.0
import PackageDescription

// QUA-209 (Windows port): the four core targets below build on Windows as
// well as macOS. The Dousha app target (AppKit/Carbon/Speech) and its test
// target (@testable imports the app) are macOS-only — Package.swift is
// evaluated on the build host, so they are simply absent when building on
// Windows. Framework links are .when(.macOS)-conditional for the same reason.

var products: [Product] = [
    .library(name: "TalkerCommonSync", targets: ["TalkerCommonSync"]),
    .library(name: "ASRSupport",       targets: ["ASRSupport"]),
    .library(name: "DoubaoASR",        targets: ["DoubaoASR"]),
    .library(name: "SonioxASR",        targets: ["SonioxASR"]),
    // Headless test harness — builds on every platform; the Windows port's
    // smoke-test entry point (QUA-209).
    .executable(name: "dousha-cli",    targets: ["DoushaCLI"]),
]

var targets: [Target] = [
    .target(name: "TalkerCommonSync", path: "Sources/TalkerCommonSync"),
    .target(
        name: "ASRSupport",
        dependencies: ["TalkerCommonSync"],
        path: "Sources/ASRSupport",
        linkerSettings: [
            .linkedFramework("AVFoundation", .when(platforms: [.macOS]))
        ]
    ),
    .target(
        name: "DoubaoASR",
        dependencies: ["TalkerCommonSync", "ASRSupport"],
        path: "Sources/DoubaoASR",
        linkerSettings: [
            .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
            .linkedFramework("AudioToolbox", .when(platforms: [.macOS]))
        ]
    ),
    // SonioxASR no longer touches AVFoundation (QUA-209) — pure Foundation + WS.
    .target(
        name: "SonioxASR",
        dependencies: ["TalkerCommonSync", "ASRSupport"],
        path: "Sources/SonioxASR"
    ),
    .executableTarget(
        name: "DoushaCLI",
        dependencies: ["DoubaoASR"],
        path: "Sources/DoushaCLI"
    ),
]

#if !os(Windows)
products.append(.executable(name: "Dousha", targets: ["Dousha"]))
targets.append(.executableTarget(
    name: "Dousha",
    dependencies: ["DoubaoASR", "SonioxASR", "ASRSupport"],
    path: "Sources/Dousha",
    // dousha (QUA-159): adopts Swift 6 strict concurrency. The UI /
    // controller layer (AppDelegate, FloatingWindow, FloatingHUDModel,
    // AppFocusTracker, the hotkey dispatcher) is @MainActor; the event-tap
    // monitors are main-runloop-confined @unchecked Sendable; Preferences
    // is UserDefaults-backed @unchecked Sendable. No more .v5 fallback.
    linkerSettings: [
        .linkedFramework("Carbon"),
        .linkedFramework("Cocoa"),
        .linkedFramework("Speech"),
        .linkedFramework("AVFoundation")
    ]
))
targets.append(.testTarget(
    name: "DoushaTests",
    dependencies: ["Dousha", "DoubaoASR", "SonioxASR", "ASRSupport", "TalkerCommonSync"],
    path: "Tests/DoushaTests"
))
#endif

let package = Package(
    name: "Dousha",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
