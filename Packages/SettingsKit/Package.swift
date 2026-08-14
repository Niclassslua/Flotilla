// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "SettingsKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "SettingsKit", targets: ["SettingsKit"])
    ],
    targets: [
        .target(name: "SettingsKit")
    ]
)
