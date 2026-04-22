import Foundation
import Observation

/// Running log of what the auto-intake watcher has done recently. The Library
/// sidebar row (Phase E1b) binds to `events`; for E1a the log is populated
/// but not rendered.
///
/// Cap is intentional — the intake is noisy during bulk backfill and we don't
/// want an unbounded list pinned to main memory. 100 entries is enough to
/// span a full ChatGPT export ingest without overflowing the sidebar UI.
@MainActor
@Observable
final class IntakeActivityLog {
    enum Kind: Sendable, Equatable {
        case ingested(snapshotID: Int64, jsonFileCount: Int)
        case importerFailed(snapshotID: Int64, detail: String)
        case unrecognized(reason: String)
        case failed(detail: String)
    }

    struct Event: Identifiable, Sendable, Equatable {
        let id: UUID
        let timestamp: Date
        let source: String
        let kind: Kind
    }

    private(set) var events: [Event] = []
    private let cap: Int

    init(cap: Int = 100) {
        self.cap = cap
    }

    func record(source: String, kind: Kind) {
        events.append(
            Event(id: UUID(), timestamp: Date(), source: source, kind: kind)
        )
        if events.count > cap {
            events.removeFirst(events.count - cap)
        }
    }

    func clear() {
        events.removeAll()
    }
}
