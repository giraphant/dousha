// swift-tools-version:6.0
import PackageDescription

// QUA-209 (Windows port): the four core targets below build on Windows as
// well as macOS. The Dousha app target (AppKit/Carbon/Speech) and its test
// target (@testable imports the app) are macOS-only — Package.swift is
// evaluated on the build host, so they are simply absent when building on
// Windows. Framework links are .when(.macOS)-conditional for the same reason.

var products: [Product] = [
    .library(name: "ConcurrencySupport", targets: ["ConcurrencySupport"]),
    .library(name: "ASRSupport",       targets: ["ASRSupport"]),
    .library(name: "DoubaoASR",        targets: ["DoubaoASR"]),
    .library(name: "SonioxASR",        targets: ["SonioxASR"]),
    // Headless smoke harness — builds on every platform; the Windows port's
    // smoke-test entry point (QUA-209).
    .executable(name: "smoke-cli",     targets: ["SmokeCLI"]),
]

// Directory layout groups targets by role (not platform):
//   Sources/Common/   bottom of the graph — libraries everything imports
//   Sources/Engines/  one streaming ASR client per provider
//   Sources/Apps/     user-facing shells, one per platform
//   Sources/Tools/    developer-facing executables, never shipped
var targets: [Target] = [
    .target(name: "ConcurrencySupport", path: "Sources/Common/ConcurrencySupport"),
    .target(
        name: "ASRSupport",
        dependencies: ["ConcurrencySupport"],
        path: "Sources/Common/ASRSupport",
        linkerSettings: [
            .linkedFramework("AVFoundation", .when(platforms: [.macOS]))
        ]
    ),
    .target(
        name: "DoubaoASR",
        dependencies: ["ConcurrencySupport", "ASRSupport"],
        path: "Sources/Engines/DoubaoASR",
        linkerSettings: [
            .linkedFramework("AVFoundation", .when(platforms: [.macOS])),
            .linkedFramework("AudioToolbox", .when(platforms: [.macOS]))
        ]
    ),
    // SonioxASR no longer touches AVFoundation (QUA-209) — pure Foundation + WS.
    .target(
        name: "SonioxASR",
        dependencies: ["ConcurrencySupport", "ASRSupport"],
        path: "Sources/Engines/SonioxASR"
    ),
    .executableTarget(
        name: "SmokeCLI",
        dependencies: ["DoubaoASR"],
        path: "Sources/Tools/SmokeCLI"
    ),
]

#if os(Windows)
// The Windows shell (QUA-209): tray + hold-to-talk hook + waveIn + clipboard paste.
// Windows-only by construction (WinSDK); absent from the graph elsewhere.
products.append(.executable(name: "dousha-win", targets: ["DoushaWin"]))
targets.append(.executableTarget(
    name: "DoushaWin",
    dependencies: ["DoubaoASR", "ASRSupport", "ConcurrencySupport"],
    path: "Sources/Apps/DoushaWin",
    linkerSettings: [
        // Precompiled by llvm-rc from Resources/Windows/DoushaWin.rc.
        // COFF .res files are architecture-neutral and link directly into
        // the PE, so both local SwiftPM builds and GitHub packaging get the
        // Explorer/tray icon without a build-tool plugin.
        .unsafeFlags(["Resources/Windows/DoushaWin.res"])
    ]
))
targets.append(.testTarget(
    name: "DoushaWinTests",
    dependencies: ["DoushaWin"],
    path: "Tests/DoushaWinTests"
))
#else
products.append(.executable(name: "Dousha", targets: ["Dousha"]))
targets.append(.executableTarget(
    name: "Dousha",
    dependencies: ["DoubaoASR", "SonioxASR", "ASRSupport"],
    path: "Sources/Apps/Dousha",
    // dousha (QUA-159): adopts Swift 6 strict concurrency. The UI /
    // controller layer (AppDelegate, FloatingWindow, FloatingHUDModel,
    // AppFocusTracker, the hotkey dispatcher) is @MainActor; the event-tap
    // monitors are main-runloop-confined @unchecked Sendable; Preferences
    // is UserDefaults-backed @unchecked Sendable. No more .v5 fallback.
    linkerSettings: [
        .linkedFramework("AudioToolbox"),
        .linkedFramework("AVFoundation"),
        .linkedFramework("Carbon"),
        .linkedFramework("Cocoa"),
        .linkedFramework("CoreAudio"),
        .linkedFramework("IOKit"),
        .linkedFramework("Speech")
    ]
))
targets.append(.testTarget(
    name: "DoushaTests",
    dependencies: ["Dousha", "DoubaoASR", "SonioxASR", "ASRSupport", "ConcurrencySupport"],
    path: "Tests/DoushaTests"
))
#endif

let package = Package(
    name: "Dousha",
    platforms: [.macOS(.v14)],
    products: products,
    targets: targets
)
