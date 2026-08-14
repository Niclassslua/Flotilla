// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "TerminalKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "TerminalKit", targets: ["TerminalKit"])
    ],
    dependencies: [
        .package(path: "../ProcessKit"),
        .package(url: "https://github.com/migueldeicaza/SwiftTerm.git", from: "1.2.0")
    ],
    targets: [
        .target(
            name: "TerminalKit",
            dependencies: [
                "ProcessKit",
                .product(name: "SwiftTerm", package: "SwiftTerm")
            ]
        )
    ]
)
