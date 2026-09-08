// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TranscriptKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TranscriptKit", targets: ["TranscriptKit"])
    ],
    dependencies: [
        .package(path: "../SessionKit")
    ],
    targets: [
        .target(
            name: "TranscriptKit",
            dependencies: ["SessionKit"]
        )
    ]
)
