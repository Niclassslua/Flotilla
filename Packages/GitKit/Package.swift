// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "GitKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "GitKit", targets: ["GitKit"])
    ],
    targets: [
        .target(name: "GitKit")
    ]
)
