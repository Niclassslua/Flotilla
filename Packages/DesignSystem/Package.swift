// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "DesignSystem",
    platforms: [.macOS(.v15), .iOS(.v18)],
    products: [
        .library(name: "DesignSystem", targets: ["DesignSystem"])
    ],
    dependencies: [
        .package(path: "../SessionKit")
    ],
    targets: [
        .target(
            name: "DesignSystem",
            dependencies: ["SessionKit"],
            resources: [.process("Resources")]
        )
    ]
)
