// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "AgentKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "AgentKit", targets: ["AgentKit"])
    ],
    dependencies: [
        .package(path: "../SessionKit"),
        .package(path: "../SettingsKit"),
        .package(path: "../ProcessKit")
    ],
    targets: [
        .target(
            name: "AgentKit",
            dependencies: ["SessionKit", "SettingsKit", "ProcessKit"]
        )
    ]
)
