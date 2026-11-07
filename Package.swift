// swift-tools-version: 6.0

import PackageDescription

let package = Package(
    name: "SessionDock",
    platforms: [
        .macOS(.v14),
    ],
    products: [
        .executable(name: "SessionDock", targets: ["SessionDock"]),
        .library(name: "SessionDockCore", targets: ["SessionDockCore"]),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift.git", from: "7.12.0"),
    ],
    targets: [
        .target(
            name: "SessionDockCore",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources/SessionDockCore"
        ),
        .executableTarget(
            name: "SessionDock",
            dependencies: ["SessionDockCore"],
            path: "Sources/SessionDock"
        ),
        .testTarget(
            name: "SessionDockCoreTests",
            dependencies: ["SessionDockCore"],
            path: "Tests/SessionDockCoreTests"
        ),
    ]
)
