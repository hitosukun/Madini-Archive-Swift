// swift-tools-version:5.9
// TEMPORARY — Phase 2 benchmark only. Delete after the report is final.
import PackageDescription

let package = Package(
    name: "ParseBenchmark",
    platforms: [.macOS(.v14)],
    targets: [
        .executableTarget(
            name: "ParseBenchmark",
            path: "Sources/ParseBenchmark"
        )
    ]
)
