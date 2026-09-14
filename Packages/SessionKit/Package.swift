// swift-tools-version: 6.2
import PackageDescription

let package = Package(
    name: "SessionKit",
    platforms: [.macOS(.v15), .iOS(.v26)],
    products: [
        .library(name: "SessionKit", targets: ["SessionKit"])
    ],
    targets: [
        .target(name: "SessionKit")
    ]
)
