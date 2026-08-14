// swift-tools-version: 6.0
import PackageDescription

let package = Package(
    name: "PersistenceKit",
    platforms: [.macOS(.v15)],
    products: [
        .library(name: "PersistenceKit", targets: ["PersistenceKit"])
    ],
    dependencies: [
        .package(path: "../SessionKit"),
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "6.29.0")
    ],
    targets: [
        .target(
            name: "PersistenceKit",
            dependencies: [
                "SessionKit",
                .product(name: "GRDB", package: "GRDB.swift")
            ]
        )
    ]
)
