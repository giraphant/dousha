// swift-tools-version:6.0
import PackageDescription

// Directory layout groups targets by role:
//   Sources/Common/   bottom of the graph — libraries everything imports
//   Sources/Engines/  one streaming ASR client per provider
//   Sources/Apps/     the macOS app shell
//   Sources/Tools/    developer-facing executables, never shipped
let package = Package(
    name: "Dousha",
    platforms: [.macOS(.v14)],
    products: [
        // Headless smoke harness against the real Doubao servers.
        .executable(name: "smoke-cli",     targets: ["SmokeCLI"]),
        .executable(name: "Dousha",        targets: ["Dousha"]),
    ],
    targets: [
        .target(name: "ConcurrencySupport", path: "Sources/Common/ConcurrencySupport"),
        .target(
            name: "ASRSupport",
            dependencies: ["ConcurrencySupport"],
            path: "Sources/Common/ASRSupport",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .target(
            name: "DoubaoASR",
            dependencies: ["ConcurrencySupport", "ASRSupport"],
            path: "Sources/Engines/DoubaoASR",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "SonioxASR",
            dependencies: ["ConcurrencySupport", "ASRSupport"],
            path: "Sources/Engines/SonioxASR"
        ),
        .target(
            name: "SmokeCLISupport",
            dependencies: ["ASRSupport", "DoubaoASR"],
            path: "Sources/Tools/SmokeCLISupport"
        ),
        .executableTarget(
            name: "SmokeCLI",
            dependencies: ["DoubaoASR", "SmokeCLISupport"],
            path: "Sources/Tools/SmokeCLI"
        ),
        .executableTarget(
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
        ),
        .testTarget(
            name: "DoushaTests",
            dependencies: ["Dousha", "DoubaoASR", "SonioxASR", "ASRSupport", "ConcurrencySupport"],
            path: "Tests/DoushaTests"
        ),
    ]
)
