// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "TranscriptKit",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "TranscriptKit", targets: ["TranscriptKit"])
    ],
    dependencies: [
        .package(path: "../SessionKit")
    ],
    targets: [
        .target(
            name: "TranscriptKit",
            dependencies: ["SessionKit"],
            exclude: ["Codecs/Antigravity/FORMAT.md"]
        )
    ]
)
