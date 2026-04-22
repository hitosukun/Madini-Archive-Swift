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
        // LaTeX typesetting for display-math blocks (`$$...$$`). Native
        // Swift port of iosMath — renders to CALayer, no WebView, works
        // on both macOS and iOS. We drive it via an NSViewRepresentable
        // wrapper in `MessageBubbleView.MathBlockView`.
        .package(url: "https://github.com/mgriebling/SwiftMath.git", from: "1.7.0"),
    ],
    targets: [
        .executableTarget(
            name: "MadiniArchive",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftMath", package: "SwiftMath"),
            ],
            path: "Sources",
            resources: [
                .process("Resources"),
            ]
        ),
        .testTarget(
            name: "MadiniArchiveTests",
            dependencies: [
                "MadiniArchive",
                .product(name: "GRDB", package: "GRDB.swift"),
            ],
            path: "Tests/MadiniArchiveTests"
        ),
    ]
)
