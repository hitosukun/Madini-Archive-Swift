import Foundation

/// Process-wide registry of `LRUTrackedCache` instances that should
/// drop their older half on memory-pressure warnings.
///
/// Each cache registers itself once during its lazy initialization
/// (each `LRUTrackedCache` is a `static let` on a private type, so
/// the registration happens the first time the owning view builds).
/// `MemoryPressureMonitor` calls `purgeAll()` when the OS posts a
/// warning. Holding registrations through `weak` references keeps
/// ownership in the cache's owning type — if a view tree is torn
/// down (only really possible in tests; the four MessageBubbleView
/// caches are static for the app's lifetime), the entry self-prunes.
final class CachePurgeCoordinator {
    /// Singleton because the four caches we currently register are
    /// all static. There's no scenario where two coordinators would
    /// be useful, and a singleton keeps registration syntax to one
    /// line at each cache's site.
    static let shared = CachePurgeCoordinator()

    /// One row per registered cache. The `purge` closure captures
    /// `weak cache` so the coordinator never extends the cache's
    /// lifetime — if the cache is gone the closure returns 0 and the
    /// row is pruned at next `purgeAll`.
    private struct Registration {
        weak var cache: AnyObject?
        let purge: () -> Int
        let name: String
    }

    private var registrations: [Registration] = []
    private let lock = NSLock()

    /// Register a cache so it participates in the next memory-pressure
    /// warning. Idempotent on the same instance — re-registering an
    /// already-tracked cache is harmless (creates a duplicate row that
    /// purges twice, but `LRUTrackedCache.purgeOldHalf` is itself
    /// idempotent on the second call). Caches typically register
    /// exactly once, in their owning type's initializer.
    func register<Value: AnyObject>(_ cache: LRUTrackedCache<Value>) {
        lock.lock()
        defer { lock.unlock() }
        registrations.append(Registration(
            cache: cache,
            purge: { [weak cache] in cache?.purgeOldHalf() ?? 0 },
            name: cache.name
        ))
    }

    /// Drop the older half of every currently-registered cache.
    /// Returns one (name, count) tuple per cache for diagnostics.
    /// Called by `MemoryPressureMonitor` on `.warning` events; tests
    /// invoke it directly. Not called from production code paths
    /// outside the pressure monitor.
    @discardableResult
    func purgeAll() -> [(name: String, removed: Int)] {
        lock.lock()
        defer { lock.unlock() }
        // Prune registrations whose cache has deallocated. This is
        // the only cleanup path; we do it here instead of on every
        // register call so the lock stays short on the hot path.
        registrations.removeAll(where: { $0.cache == nil })
        var results: [(String, Int)] = []
        results.reserveCapacity(registrations.count)
        for reg in registrations {
            results.append((reg.name, reg.purge()))
        }
        return results
    }

    /// Currently-tracked cache count. Used by tests to verify
    /// registration; production code should not depend on it.
    var registeredCount: Int {
        lock.lock()
        defer { lock.unlock() }
        return registrations.filter { $0.cache != nil }.count
    }

    /// Test-only hook to drop all registrations. Production caches
    /// are static lifetime; this is for unit tests that want a clean
    /// slate per test case.
    func _resetForTesting() {
        lock.lock()
        defer { lock.unlock() }
        registrations.removeAll()
    }
}

/// Wires `DispatchSource.makeMemoryPressureSource(.warning)` into
/// `CachePurgeCoordinator.shared.purgeAll()`.
///
/// Why DispatchSource and not a custom timer / thermalState polling:
/// macOS does not post `UIApplicationDidReceiveMemoryWarning`-class
/// notifications at the AppKit level, but the kernel-backed memory-
/// pressure DispatchSource is fully supported and is the canonical
/// macOS way to observe these events.
///
/// Lifetime: held by `AppServices`. Cancelled in `deinit` so a stale
/// source doesn't fire after the services container is torn down
/// (only relevant for tests that build short-lived `AppServices`
/// instances; in production the container lives for the app session).
final class MemoryPressureMonitor {
    private let source: DispatchSourceMemoryPressure
    private let coordinator: CachePurgeCoordinator

    /// - Parameter coordinator: defaults to the process-wide singleton.
    ///   Tests can pass a fresh coordinator instance to keep
    ///   registrations isolated.
    init(coordinator: CachePurgeCoordinator = .shared) {
        self.coordinator = coordinator
        let src = DispatchSource.makeMemoryPressureSource(
            eventMask: [.warning],
            queue: .main
        )
        src.setEventHandler { [weak coordinator] in
            // The handler runs on .main; coordinator.purgeAll is
            // thread-safe via its own lock so the queue choice is
            // for ergonomics (UI-side logging would be safe here)
            // rather than correctness.
            _ = coordinator?.purgeAll()
        }
        src.activate()
        self.source = src
    }

    deinit {
        source.cancel()
    }
}
