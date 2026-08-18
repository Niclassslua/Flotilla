// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "MarkdownParser",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "MarkdownParser", targets: ["MarkdownParser"])
    ],
    targets: [
        .target(name: "MarkdownParser")
    ]
)