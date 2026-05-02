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
        // GFM markdown rendering for the Wiki reader (Phase A). Obsidian's
        // [[wikilink]] syntax is not supported natively; we preprocess
        // those into standard `[text](wiki://...)` links before handing
        // the body to MarkdownUI, so MarkdownUI never sees Obsidian-only
        // syntax.
        .package(url: "https://github.com/gonzalezreal/swift-markdown-ui", from: "2.4.0"),
    ],
    targets: [
        .executableTarget(
            name: "MadiniArchive",
            dependencies: [
                .product(name: "GRDB", package: "GRDB.swift"),
                .product(name: "SwiftMath", package: "SwiftMath"),
                .product(name: "MarkdownUI", package: "swift-markdown-ui"),
            ],
            path: "Sources",
            resources: [
                .process("Resources"),
            ],
            // `SPM_BUILD` gates direct `Bundle.module` references in
            // the source tree. It's defined only in the SPM build so
            // that the Xcode app target (which has no `Bundle.module`
            // accessor because resources are copied into the main
            // bundle) compiles cleanly. See `BundledResources` for
            // the matching lookup shim.
            swiftSettings: [
                .define("SPM_BUILD")
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
