// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dousha",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TalkerCommonSync", targets: ["TalkerCommonSync"]),
        .library(name: "ASRSupport",       targets: ["ASRSupport"]),
        .library(name: "DoubaoASR",        targets: ["DoubaoASR"]),
        .library(name: "SonioxASR",        targets: ["SonioxASR"]),
        .executable(name: "Dousha",        targets: ["Dousha"])
    ],
    targets: [
        .target(name: "TalkerCommonSync", path: "Sources/TalkerCommonSync"),
        .target(
            name: "ASRSupport",
            dependencies: ["TalkerCommonSync"],
            path: "Sources/ASRSupport",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .target(
            name: "DoubaoASR",
            dependencies: ["TalkerCommonSync", "ASRSupport"],
            path: "Sources/DoubaoASR",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox")
            ]
        ),
        .target(
            name: "SonioxASR",
            dependencies: ["TalkerCommonSync", "ASRSupport"],
            path: "Sources/SonioxASR",
            linkerSettings: [
                .linkedFramework("AVFoundation")
            ]
        ),
        .executableTarget(
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
        )
        ,
        .testTarget(
            name: "DoushaTests",
            dependencies: ["Dousha", "DoubaoASR", "SonioxASR", "ASRSupport", "TalkerCommonSync"],
            path: "Tests/DoushaTests"
        )
    ]
)
