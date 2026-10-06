// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "CompanionKit",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "CompanionKit", targets: ["CompanionKit"])
    ],
    dependencies: [
        .package(path: "../SessionKit"),
        .package(path: "../TranscriptKit")
    ],
    targets: [
        .target(
            name: "CompanionKit",
            dependencies: ["SessionKit", "TranscriptKit"]
        ),
        .testTarget(
            name: "CompanionKitTests",
            dependencies: ["CompanionKit", "SessionKit", "TranscriptKit"]
        )
    ]
)
