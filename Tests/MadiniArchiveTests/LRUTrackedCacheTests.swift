import XCTest
@testable import MadiniArchive

private final class Box {
    let value: String
    init(_ value: String) { self.value = value }
}

final class LRUTrackedCacheTests: XCTestCase {
    // MARK: - Basic put/get

    func testSetAndGetReturnsValue() {
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        cache.setObject(Box("hello"), forKey: "k1", cost: 100)
        XCTAssertEqual(cache.object(forKey: "k1")?.value, "hello")
    }

    func testGetMissReturnsNil() {
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        XCTAssertNil(cache.object(forKey: "missing"))
    }

    func testRemoveDropsValue() {
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        cache.setObject(Box("v"), forKey: "k", cost: 100)
        cache.removeObject(forKey: "k")
        XCTAssertNil(cache.object(forKey: "k"))
        XCTAssertEqual(cache.trackedCount, 0)
    }

    // MARK: - LRU ordering / purgeOldHalf

    func testPurgeOldHalfDropsOlderEntries() {
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        // Insert k1..k10 in order; k1 is oldest, k10 newest.
        for i in 1...10 {
            cache.setObject(Box("v\(i)"), forKey: "k\(i)", cost: 100)
        }
        XCTAssertEqual(cache.trackedCount, 10)

        let removed = cache.purgeOldHalf()
        XCTAssertEqual(removed, 5)
        XCTAssertEqual(cache.trackedCount, 5)

        // k1..k5 should be gone; k6..k10 remain.
        for i in 1...5 {
            XCTAssertNil(cache.object(forKey: "k\(i)"), "k\(i) should be purged")
        }
        for i in 6...10 {
            XCTAssertNotNil(cache.object(forKey: "k\(i)"), "k\(i) should remain")
        }
    }

    func testPurgeOldHalfHonorsAccessOrderNotInsertOrder() {
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        // Insert k1, k2, k3 in order — k1 is oldest by insert time.
        cache.setObject(Box("v1"), forKey: "k1", cost: 100)
        cache.setObject(Box("v2"), forKey: "k2", cost: 100)
        cache.setObject(Box("v3"), forKey: "k3", cost: 100)
        cache.setObject(Box("v4"), forKey: "k4", cost: 100)
        // Touch k1 — now k2 is the oldest by access time.
        _ = cache.object(forKey: "k1")

        cache.purgeOldHalf()
        // Half of 4 = 2; the two oldest by access (k2, k3) are dropped.
        XCTAssertNotNil(cache.object(forKey: "k1"), "k1 was touched, should survive")
        XCTAssertNil(cache.object(forKey: "k2"), "k2 was oldest after touch")
        XCTAssertNil(cache.object(forKey: "k3"), "k3 was second-oldest after touch")
        XCTAssertNotNil(cache.object(forKey: "k4"), "k4 was newest, should survive")
    }

    func testPurgeOnEmptyCacheIsNoOp() {
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        XCTAssertEqual(cache.purgeOldHalf(), 0)
    }

    func testPurgeOnSingleEntryIsNoOp() {
        // halfCount = 1/2 = 0 → no eviction
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        cache.setObject(Box("v"), forKey: "k", cost: 100)
        XCTAssertEqual(cache.purgeOldHalf(), 0)
        XCTAssertNotNil(cache.object(forKey: "k"))
    }

    // MARK: - Replacement updates access time

    func testRepeatedSetMakesEntryFreshest() {
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        cache.setObject(Box("v1"), forKey: "k1", cost: 100)
        cache.setObject(Box("v2"), forKey: "k2", cost: 100)
        // Re-set k1 → k1 is now newest.
        cache.setObject(Box("v1-new"), forKey: "k1", cost: 100)

        cache.purgeOldHalf()
        // halfCount = 2/2 = 1; oldest is k2.
        XCTAssertNil(cache.object(forKey: "k2"))
        XCTAssertEqual(cache.object(forKey: "k1")?.value, "v1-new")
    }

    // MARK: - removeAllObjects

    func testRemoveAllClearsTrackedCount() {
        let cache = LRUTrackedCache<Box>(
            name: "test", countLimit: 100, totalCostLimit: 1_000_000
        )
        for i in 1...5 {
            cache.setObject(Box("v"), forKey: "k\(i)", cost: 100)
        }
        cache.removeAllObjects()
        XCTAssertEqual(cache.trackedCount, 0)
        XCTAssertNil(cache.object(forKey: "k1"))
    }

    // MARK: - Concurrency smoke test

    func testConcurrentAccessDoesNotCrash() {
        let cache = LRUTrackedCache<Box>(
            name: "concurrent", countLimit: 1000, totalCostLimit: 10_000_000
        )
        let queue = DispatchQueue.global(qos: .userInitiated)
        let group = DispatchGroup()
        let iterations = 200
        for i in 0..<iterations {
            group.enter()
            queue.async {
                let key = "k\(i % 50)"
                cache.setObject(Box("v\(i)"), forKey: key, cost: 100)
                _ = cache.object(forKey: key)
                if i % 7 == 0 { _ = cache.purgeOldHalf() }
                group.leave()
            }
        }
        XCTAssertEqual(group.wait(timeout: .now() + 5), .success)
        // No crash; cache remains queryable.
        _ = cache.trackedCount
    }
}
