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
            // dousha: vendored SpeechMore code was written under Swift 5
            // concurrency semantics. Pinned to .v5 for the baseline so the
            // upstream builds clean; Task 11 rewrites AppDelegate and can
            // drop this and adopt Swift 6 strict concurrency.
            swiftSettings: [.swiftLanguageMode(.v5)],
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
