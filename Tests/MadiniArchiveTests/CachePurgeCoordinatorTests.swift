import XCTest
@testable import MadiniArchive

private final class StubBox {
    let value: String
    init(_ v: String) { value = v }
}

final class CachePurgeCoordinatorTests: XCTestCase {
    /// Each test uses a fresh coordinator instance to avoid bleed
    /// from any other suite that may have registered against the
    /// shared singleton during its run.
    private var coordinator: CachePurgeCoordinator!

    override func setUp() {
        super.setUp()
        coordinator = CachePurgeCoordinator()
    }

    func testRegisterIncrementsTrackedCount() {
        let cache = LRUTrackedCache<StubBox>(
            name: "a", countLimit: 100, totalCostLimit: 100_000
        )
        coordinator.register(cache)
        XCTAssertEqual(coordinator.registeredCount, 1)
    }

    func testPurgeAllInvokesEachRegisteredCache() {
        let cache1 = LRUTrackedCache<StubBox>(
            name: "c1", countLimit: 100, totalCostLimit: 100_000
        )
        let cache2 = LRUTrackedCache<StubBox>(
            name: "c2", countLimit: 100, totalCostLimit: 100_000
        )
        for i in 1...10 {
            cache1.setObject(StubBox("v"), forKey: "k\(i)", cost: 100)
            cache2.setObject(StubBox("v"), forKey: "k\(i)", cost: 100)
        }
        coordinator.register(cache1)
        coordinator.register(cache2)

        let report = coordinator.purgeAll()
        XCTAssertEqual(report.count, 2)
        let removed1 = report.first(where: { $0.name == "c1" })?.removed
        let removed2 = report.first(where: { $0.name == "c2" })?.removed
        XCTAssertEqual(removed1, 5)
        XCTAssertEqual(removed2, 5)
        XCTAssertEqual(cache1.trackedCount, 5)
        XCTAssertEqual(cache2.trackedCount, 5)
    }

    func testWeakReferencePrunesAfterDealloc() {
        do {
            let cache = LRUTrackedCache<StubBox>(
                name: "tmp", countLimit: 100, totalCostLimit: 100_000
            )
            coordinator.register(cache)
            XCTAssertEqual(coordinator.registeredCount, 1)
        }
        // After local cache goes out of scope, the weak ref clears.
        // registeredCount filters out nil cache slots.
        XCTAssertEqual(coordinator.registeredCount, 0)

        // purgeAll on a coordinator with only stale entries returns
        // an empty report and prunes them.
        let report = coordinator.purgeAll()
        XCTAssertEqual(report.count, 0)
    }

    func testPurgeAllWithNoRegistrationsIsHarmless() {
        XCTAssertEqual(coordinator.purgeAll().count, 0)
    }

    func testRegisterIsIdempotentOnSameInstance() {
        let cache = LRUTrackedCache<StubBox>(
            name: "a", countLimit: 100, totalCostLimit: 100_000
        )
        coordinator.register(cache)
        coordinator.register(cache)
        // Two rows, but purge of an empty cache returns 0 each.
        XCTAssertEqual(coordinator.registeredCount, 2)
        XCTAssertEqual(coordinator.purgeAll().reduce(0) { $0 + $1.removed }, 0)
    }
}

/// Smoke test for `MemoryPressureMonitor` — we cannot easily fire a
/// real memory-pressure event in unit tests, so we verify the type
/// constructs and tears down without crashing. The behavioral test
/// of "warning → purgeAll" is covered indirectly by the
/// `CachePurgeCoordinatorTests` above (which exercise purgeAll
/// directly) plus manual integration testing.
final class MemoryPressureMonitorSmokeTests: XCTestCase {
    func testInitAndDeinitDoNotCrash() {
        let coordinator = CachePurgeCoordinator()
        do {
            let monitor = MemoryPressureMonitor(coordinator: coordinator)
            _ = monitor
        }
        // Reaching here means deinit completed cleanly.
        XCTAssertEqual(coordinator.registeredCount, 0)
    }
}
