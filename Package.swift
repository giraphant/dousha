// swift-tools-version:6.0
import PackageDescription

let package = Package(
    name: "Dousha",
    platforms: [.macOS(.v14)],
    products: [
        .library(name: "TalkerCommonSync", targets: ["TalkerCommonSync"])
    ],
    targets: [
        .target(name: "TalkerCommonSync", path: "Sources/TalkerCommonSync")
    ]
)
