#if os(macOS)
import XCTest
@testable import MadiniArchive

/// Covers the settle-debounce + delivered-once contract of `IntakeWatcher`.
/// Uses a 0-second settle interval so the test doesn't have to wait for
/// wall-clock stability — that only affects when a file is considered
/// stable, not the correctness of the bookkeeping.
@MainActor
final class IntakeWatcherTests: XCTestCase {
    private var tempRoot: URL!

    override func setUp() async throws {
        let base = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
            .appendingPathComponent("MadiniIntakeWatcherTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        tempRoot = base
    }

    override func tearDown() async throws {
        if let tempRoot {
            try? FileManager.default.removeItem(at: tempRoot)
        }
        tempRoot = nil
    }

    func testFirstScanMarksItemsButDoesNotDeliverBeforeSettleInterval() async throws {
        try Data("[]".utf8).write(to: tempRoot.appendingPathComponent("a.json"))

        var delivered: [String] = []
        let watcher = IntakeWatcher(
            directory: tempRoot,
            pollInterval: 0.01,
            // Large enough that the single-scan pass below can't satisfy it.
            settleInterval: 3600,
            handler: { item in
                delivered.append(item.url.lastPathComponent)
            }
        )

        await watcher.scanOnce()
        XCTAssertTrue(delivered.isEmpty, "First scan should only record; delivery waits for settle")
    }

    func testSettledFileIsDeliveredExactlyOnce() async throws {
        let file = tempRoot.appendingPathComponent("stable.json")
        try Data("[]".utf8).write(to: file)

        var delivered: [URL] = []
        let watcher = IntakeWatcher(
            directory: tempRoot,
            pollInterval: 0.01,
            // 0s settle → any scan where size+mtime matches the previous
            // observation counts as stable.
            settleInterval: 0,
            handler: { item in
                delivered.append(item.url)
            }
        )

        await watcher.scanOnce()
        await watcher.scanOnce()
        await watcher.scanOnce()

        XCTAssertEqual(delivered.count, 1)
        XCTAssertEqual(delivered.first?.lastPathComponent, "stable.json")
    }

    func testReplacingAlreadyDeliveredFileTriggersRedeliveryAfterSettle() async throws {
        let file = tempRoot.appendingPathComponent("stable.json")
        try Data("[]".utf8).write(to: file)

        var delivered: [URL] = []
        let watcher = IntakeWatcher(
            directory: tempRoot,
            pollInterval: 0.01,
            settleInterval: 0,
            handler: { item in
                delivered.append(item.url)
            }
        )

        await watcher.scanOnce()
        await watcher.scanOnce()
        XCTAssertEqual(delivered.count, 1)

        // Rewrite the file with different bytes. The documented contract
        // (see IntakeWatcher header) is that a replaced file settles again
        // and gets re-delivered — that's the "user drops wrong export, then
        // overwrites it with the right one" case.
        try Data("[{}]".utf8).write(to: file)
        await watcher.scanOnce()
        await watcher.scanOnce()

        XCTAssertEqual(
            delivered.count, 2,
            "Overwriting a delivered file with fresh bytes should trigger a second delivery"
        )
    }

    func testScansThatSeeIdenticalStateDoNotRedeliver() async throws {
        let file = tempRoot.appendingPathComponent("stable.json")
        try Data("[]".utf8).write(to: file)

        var delivered: [URL] = []
        let watcher = IntakeWatcher(
            directory: tempRoot,
            pollInterval: 0.01,
            settleInterval: 0,
            handler: { item in
                delivered.append(item.url)
            }
        )

        // Five polls with no filesystem changes between them — only the
        // first post-settle scan should fire.
        for _ in 0..<5 {
            await watcher.scanOnce()
        }

        XCTAssertEqual(delivered.count, 1)
    }

    func testRemovingAndRecreatingFileDeliversAgain() async throws {
        let file = tempRoot.appendingPathComponent("reset.json")
        try Data("[]".utf8).write(to: file)

        var delivered: [URL] = []
        let watcher = IntakeWatcher(
            directory: tempRoot,
            pollInterval: 0.01,
            settleInterval: 0,
            handler: { item in
                delivered.append(item.url)
            }
        )

        await watcher.scanOnce()
        await watcher.scanOnce()
        XCTAssertEqual(delivered.count, 1)

        try FileManager.default.removeItem(at: file)
        await watcher.scanOnce()

        try Data("[]".utf8).write(to: file)
        await watcher.scanOnce()
        await watcher.scanOnce()

        XCTAssertEqual(
            delivered.count, 2,
            "Delete + re-create should drop the observation and allow a second delivery"
        )
    }
}
#endif
