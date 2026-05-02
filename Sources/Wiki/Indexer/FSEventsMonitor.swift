import Foundation

#if os(macOS)
import CoreServices

/// Watches a vault directory for filesystem changes via FSEvents and
/// emits them on a serial dispatch queue. macOS-only — iOS does not have
/// equivalent kernel-level events for arbitrary user paths.
///
/// Caller responsibilities:
/// - Hold a strong reference to the monitor for as long as it should run.
/// - Drive the index update logic from the handler (the monitor only
///   reports events; it does not parse or persist).
final class FSEventsMonitor: @unchecked Sendable {
    enum Event: Sendable {
        case createdOrModified(path: String)
        case removed(path: String)
        case renamed(path: String)
    }

    typealias Handler = @Sendable (Event) -> Void

    private let vaultPath: String
    private let handler: Handler
    private let queue: DispatchQueue
    private var stream: FSEventStreamRef?

    init(vaultPath: String, handler: @escaping Handler) {
        self.vaultPath = vaultPath
        self.handler = handler
        self.queue = DispatchQueue(label: "wiki.fsevents.\(UUID().uuidString)")
    }

    deinit {
        stop()
    }

    func start() {
        guard stream == nil else { return }

        var context = FSEventStreamContext(
            version: 0,
            info: Unmanaged.passUnretained(self).toOpaque(),
            retain: nil,
            release: nil,
            copyDescription: nil
        )

        let flags = FSEventStreamCreateFlags(
            kFSEventStreamCreateFlagFileEvents |
            kFSEventStreamCreateFlagNoDefer |
            kFSEventStreamCreateFlagWatchRoot
        )

        guard let stream = FSEventStreamCreate(
            kCFAllocatorDefault,
            { (_, info, numEvents, eventPaths, eventFlags, _) in
                guard let info = info else { return }
                let monitor = Unmanaged<FSEventsMonitor>
                    .fromOpaque(info).takeUnretainedValue()
                let pathsPtr = eventPaths.bindMemory(
                    to: UnsafePointer<CChar>.self, capacity: numEvents
                )
                for i in 0..<numEvents {
                    let path = String(cString: pathsPtr[i])
                    let flags = Int(eventFlags[i])
                    monitor.dispatchEvent(path: path, rawFlags: flags)
                }
            },
            &context,
            [vaultPath] as CFArray,
            FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
            0.5, // latency in seconds — trades responsiveness for batching
            flags
        ) else {
            return
        }

        FSEventStreamSetDispatchQueue(stream, queue)
        FSEventStreamStart(stream)
        self.stream = stream
    }

    func stop() {
        guard let stream else { return }
        FSEventStreamStop(stream)
        FSEventStreamInvalidate(stream)
        FSEventStreamRelease(stream)
        self.stream = nil
    }

    // MARK: - Event classification

    private func dispatchEvent(path: String, rawFlags: Int) {
        // Only watch markdown files. The indexer cares about .md content;
        // attachments (images) are referenced by wikilinks but their file
        // changes don't drive index updates in Phase A.
        let lowered = path.lowercased()
        guard lowered.hasSuffix(".md") else { return }

        let removed = (rawFlags & kFSEventStreamEventFlagItemRemoved) != 0
        let renamed = (rawFlags & kFSEventStreamEventFlagItemRenamed) != 0
        let created = (rawFlags & kFSEventStreamEventFlagItemCreated) != 0
        let modified = (rawFlags & kFSEventStreamEventFlagItemModified) != 0

        // FSEvents will sometimes coalesce flags for a single path
        // (e.g. created+modified together). Resolve to one event by
        // checking removal first — if the file is gone, "modified" is
        // moot — then renames, then create/modify.
        if removed {
            handler(.removed(path: path))
        } else if renamed {
            handler(.renamed(path: path))
        } else if created || modified {
            handler(.createdOrModified(path: path))
        }
    }
}
#endif
