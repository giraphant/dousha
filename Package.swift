// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dousha",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TalkerCommonSync", targets: ["TalkerCommonSync"]),
        .library(name: "DoubaoASR",        targets: ["DoubaoASR"])
    ],
    targets: [
        .target(name: "TalkerCommonSync", path: "Sources/TalkerCommonSync"),
        .target(
            name: "DoubaoASR",
            dependencies: ["TalkerCommonSync"],
            path: "Sources/DoubaoASR",
            linkerSettings: [
                .linkedFramework("AVFoundation"),
                .linkedFramework("AudioToolbox")
            ]
        )
    ]
)
