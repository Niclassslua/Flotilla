// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "HooksKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "HooksKit", targets: ["HooksKit"])
    ],
    dependencies: [
        .package(path: "../SessionKit"),
        .package(path: "../ProcessKit")
    ],
    targets: [
        .target(
            name: "HooksKit",
            dependencies: ["SessionKit", "ProcessKit"]
        )
    ]
)
