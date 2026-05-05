import Foundation

/// Thread-safe `NSCache` wrapper that maintains a side-table of access
/// times so we can do **partial** eviction on memory pressure.
///
/// Why this exists: `NSCache` is byte-aware via `totalCostLimit` and
/// thread-safe out of the box, but its internal LRU ordering is not
/// exposed. When the OS posts a memory-pressure warning, the only
/// publicly-supported response is `removeAllObjects()` — a full purge
/// that triggers a re-parse storm across every visible message in the
/// reader (Phase 1 / 2 root-cause analysis identified this as the main
/// freeze source). This wrapper adds an `accessTime` dictionary keyed
/// alongside the NSCache so a coordinator can selectively drop the
/// older half on warning, leaving the recently-used entries warm.
///
/// Locking: a single `NSLock` guards both the NSCache and the
/// accessTime dict. `NSCache` is internally thread-safe but our
/// invariant ("an entry is in the cache iff it has an access time")
/// requires the pair of mutations to be atomic. The lock is held only
/// for the duration of dictionary mutations and is never held across
/// expensive work.
///
/// Drift: NSCache may evict entries autonomously (memory warning,
/// totalCostLimit overflow). When that happens our accessTime dict
/// still holds the key. The drift is bounded:
///   - re-inserting the same key overwrites the access time entry,
///   - a `object(forKey:)` miss removes the stale entry,
///   - `purgeOldHalf` cleans up by issuing `removeObject` for half the
///     keys (no-op for already-evicted ones).
/// We accept a small bookkeeping overhead in exchange for not having
/// to wire an `NSCacheDelegate` (whose `cache(_:willEvictObject:)`
/// callback is delivered on arbitrary threads and would deadlock the
/// lock if it tried to mutate accessTime).
final class LRUTrackedCache<Value: AnyObject>: @unchecked Sendable {
    private let underlying: NSCache<NSString, Value>
    private var accessTime: [String: UInt64] = [:]
    private var counter: UInt64 = 0
    private let lock = NSLock()
    let name: String

    /// - Parameters:
    ///   - name: human-readable label for diagnostics (used by
    ///     `CachePurgeCoordinator` to identify the cache in logs).
    ///   - countLimit: passed straight to `NSCache.countLimit`. Set to
    ///     `0` to leave unlimited; we still typically set both
    ///     `countLimit` and `totalCostLimit` as belt-and-suspenders.
    ///   - totalCostLimit: passed to `NSCache.totalCostLimit`. The
    ///     primary eviction trigger introduced in Phase 3a.
    init(name: String, countLimit: Int, totalCostLimit: Int) {
        self.name = name
        let cache = NSCache<NSString, Value>()
        cache.countLimit = countLimit
        cache.totalCostLimit = totalCostLimit
        self.underlying = cache
    }

    /// Insert or replace a value, updating its access time. `cost` is
    /// the byte-cost estimate used by `NSCache.totalCostLimit` — see
    /// `CacheCostEstimation` for typical values.
    func setObject(_ value: Value, forKey key: String, cost: Int) {
        lock.lock()
        defer { lock.unlock() }
        underlying.setObject(value, forKey: key as NSString, cost: cost)
        counter &+= 1
        accessTime[key] = counter
    }

    /// Look up a value. Updates the access time on hit; on miss, also
    /// removes any stale `accessTime` entry (NSCache may have evicted
    /// it autonomously since the last visit).
    func object(forKey key: String) -> Value? {
        lock.lock()
        defer { lock.unlock() }
        if let v = underlying.object(forKey: key as NSString) {
            counter &+= 1
            accessTime[key] = counter
            return v
        }
        accessTime.removeValue(forKey: key)
        return nil
    }

    /// Explicit removal. Used by tests and by `purgeOldHalf`.
    func removeObject(forKey key: String) {
        lock.lock()
        defer { lock.unlock() }
        underlying.removeObject(forKey: key as NSString)
        accessTime.removeValue(forKey: key)
    }

    /// Drop the older half of the tracked entries. Triggered by
    /// `CachePurgeCoordinator` on memory-pressure warning. A full
    /// `removeAllObjects()` is intentionally avoided — see the file
    /// header for the freeze rationale.
    ///
    /// "Half" is computed against the live `accessTime` size, not the
    /// NSCache's count, so stale entries (NSCache evicted but
    /// accessTime not yet pruned) get cleaned up too. Returns the
    /// number of entries removed for diagnostics.
    @discardableResult
    func purgeOldHalf() -> Int {
        lock.lock()
        defer { lock.unlock() }
        guard !accessTime.isEmpty else { return 0 }
        // Sort by access time ascending; the front is least-recently-used.
        let sorted = accessTime.sorted { $0.value < $1.value }
        let halfCount = sorted.count / 2
        guard halfCount > 0 else { return 0 }
        for (key, _) in sorted.prefix(halfCount) {
            underlying.removeObject(forKey: key as NSString)
            accessTime.removeValue(forKey: key)
        }
        return halfCount
    }

    /// Drop everything. Reserved for unit tests and for the rare case
    /// where the caller has independent reason (e.g. config change
    /// that invalidates every entry). Not used by the warning path.
    func removeAllObjects() {
        lock.lock()
        defer { lock.unlock() }
        underlying.removeAllObjects()
        accessTime.removeAll(keepingCapacity: true)
    }

    /// Tracked-entry count. May lag behind the NSCache's true count
    /// when NSCache has auto-evicted but `object(forKey:)` hasn't
    /// observed the miss yet. Tests use this for lightweight
    /// assertions; production code should not depend on exactness.
    var trackedCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return accessTime.count
    }
}
