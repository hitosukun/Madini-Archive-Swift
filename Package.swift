// swift-tools-version: 5.9

import PackageDescription

let package = Package(
    name: "MadiniArchive",
    platforms: [
        .macOS(.v14),
        .iOS(.v17),
    ],
    dependencies: [
        .package(url: "https://github.com/groue/GRDB.swift", from: "7.0.0"),
    ],
    targets: [
        .executableTarget(
            name: "MadiniArchive",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Sources",
            resources: [
                .process("Resources"),
            ]
        ),
    ]
)
