#if os(macOS)
import Foundation

/// Polls the intake directory for top-level items and delivers each one to
/// the handler once it has "settled" — i.e. size + mtime haven't changed
/// between two consecutive scans separated by at least `settleInterval`.
///
/// Polling (2 s cadence) rather than FSEvents is intentional: the debounce
/// dominates the latency budget either way, and polling avoids a CF stream
/// lifecycle and cross-actor bridging. The intake folder is under
/// `~/Documents`, so system resources are not a concern at this cadence.
///
/// "Settled once, delivered once" — if a file is replaced (new inode or
/// changed size/mtime) the tracker resets and waits for it to settle again,
/// which covers the "user copies foo.zip, realises it's wrong, overwrites
/// with a fresh zip" case without losing the second ingest.
@MainActor
final class IntakeWatcher {
    struct Item: Sendable, Equatable {
        let url: URL
        let isDirectory: Bool
    }

    /// Handler invoked once per settled top-level item. Runs on the main
    /// actor so it can drive `ImportCoordinator` directly.
    typealias Handler = @MainActor (Item) async -> Void

    let directory: URL
    let pollInterval: TimeInterval
    let settleInterval: TimeInterval

    private struct Observation {
        var size: Int64
        var mtime: Date
        var itemCount: Int
        var steadyAt: Date
        var delivered: Bool
    }

    private var observations: [String: Observation] = [:]
    private var task: Task<Void, Never>?
    private let handler: Handler
    private let fileManager: FileManager

    init(
        directory: URL,
        pollInterval: TimeInterval = 2.0,
        settleInterval: TimeInterval = 2.0,
        fileManager: FileManager = .default,
        handler: @escaping Handler
    ) {
        self.directory = directory
        self.pollInterval = pollInterval
        self.settleInterval = settleInterval
        self.fileManager = fileManager
        self.handler = handler
    }

    /// Begin polling. Idempotent — calling `start` twice leaves the single
    /// existing task in place. Creates the intake directory if missing.
    func start() {
        guard task == nil else { return }
        try? fileManager.createDirectory(
            at: directory,
            withIntermediateDirectories: true
        )
        task = Task { [weak self] in
            guard let self else { return }
            while !Task.isCancelled {
                await self.scanOnce()
                let nanos = UInt64(self.pollInterval * 1_000_000_000)
                try? await Task.sleep(nanoseconds: nanos)
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
    }

    /// Public hook for tests: run one polling pass and return. Delivery
    /// happens inline so tests can await the handler without racing.
    func scanOnce() async {
        let now = Date()

        guard let children = try? fileManager.contentsOfDirectory(
            at: directory,
            includingPropertiesForKeys: Self.resourceKeys,
            options: [.skipsHiddenFiles]
        ) else {
            return
        }

        let livingPaths = Set(children.map { $0.standardizedFileURL.path })
        observations = observations.filter { livingPaths.contains($0.key) }

        for child in children {
            let path = child.standardizedFileURL.path
            let snapshot = stat(child)
            let existing = observations[path]

            if let existing,
               existing.size == snapshot.size,
               existing.mtime == snapshot.mtime,
               existing.itemCount == snapshot.itemCount
            {
                guard !existing.delivered,
                      now.timeIntervalSince(existing.steadyAt) >= settleInterval
                else {
                    continue
                }
                var updated = existing
                updated.delivered = true
                observations[path] = updated
                await handler(Item(url: child, isDirectory: snapshot.isDirectory))
            } else {
                observations[path] = Observation(
                    size: snapshot.size,
                    mtime: snapshot.mtime,
                    itemCount: snapshot.itemCount,
                    steadyAt: now,
                    delivered: false
                )
            }
        }
    }

    private struct Snapshot {
        let size: Int64
        let mtime: Date
        let itemCount: Int
        let isDirectory: Bool
    }

    private func stat(_ url: URL) -> Snapshot {
        let values = try? url.resourceValues(forKeys: Set(Self.resourceKeys))
        let isDirectory = values?.isDirectory ?? false
        if isDirectory {
            // Directory size alone doesn't reflect content changes on APFS,
            // so fold in the recursive file count + the latest inner mtime.
            // That's enough to notice "user is still copying files into this
            // folder" without walking the tree for every poll of a settled
            // import.
            let (count, latest) = Self.directoryStability(at: url, fileManager: fileManager)
            return Snapshot(size: 0, mtime: latest, itemCount: count, isDirectory: true)
        }
        let size = Int64(values?.fileSize ?? 0)
        let mtime = values?.contentModificationDate ?? .distantPast
        return Snapshot(size: size, mtime: mtime, itemCount: 0, isDirectory: false)
    }

    private static let resourceKeys: [URLResourceKey] = [
        .isDirectoryKey,
        .fileSizeKey,
        .contentModificationDateKey
    ]

    private static func directoryStability(
        at url: URL,
        fileManager: FileManager
    ) -> (fileCount: Int, latestMTime: Date) {
        guard let enumerator = fileManager.enumerator(
            at: url,
            includingPropertiesForKeys: [.contentModificationDateKey, .isRegularFileKey],
            options: [.skipsHiddenFiles]
        ) else {
            return (0, .distantPast)
        }

        var count = 0
        var latest: Date = .distantPast
        for case let fileURL as URL in enumerator {
            let values = try? fileURL.resourceValues(
                forKeys: [.contentModificationDateKey, .isRegularFileKey]
            )
            guard values?.isRegularFile == true else { continue }
            count += 1
            if let mtime = values?.contentModificationDate, mtime > latest {
                latest = mtime
            }
        }
        return (count, latest)
    }
}
#endif
