import Foundation
import GRDB

/// Owns the per-vault index DatabaseQueue lifecycle. One queue per vault,
/// opened lazily on first use and held until the vault is unregistered or
/// the app shuts down.
///
/// Repositories never hold the queue map themselves — that would couple
/// repository code to filesystem path resolution. The coordinator is the
/// only piece of code that knows where a vault's index DB lives, opens
/// it, runs the schema bootstrap, and hands back a configured
/// `WikiPageRepository` plus a matching `WikiIndexer`.
@MainActor
final class WikiIndexCoordinator: ObservableObject {
    /// Where the per-vault index database lives. Defaults to
    /// `AppPaths.wikiIndexesDir`; overridable for tests.
    private let indexesDir: URL
    private var queues: [String: DatabaseQueue] = [:]
    private var repositories: [String: GRDBWikiPageRepository] = [:]

    init(indexesDir: URL = AppPaths.wikiIndexesDir) {
        self.indexesDir = indexesDir
    }

    /// Get (or open and bootstrap) the page repository for a vault.
    func pageRepository(for vault: WikiVault) throws -> GRDBWikiPageRepository {
        if let existing = repositories[vault.id] {
            return existing
        }
        let queue = try openQueue(for: vault)
        let repo = GRDBWikiPageRepository(dbQueue: queue)
        repositories[vault.id] = repo
        return repo
    }

    /// Convenience: build an indexer wired to this vault's repository.
    func indexer(for vault: WikiVault) throws -> WikiIndexer {
        let repo = try pageRepository(for: vault)
        return WikiIndexer(pageRepository: repo)
    }

    /// File URL of a vault's index database. Public for diagnostics; the
    /// indexer/repository do NOT need to know this.
    func indexDatabaseURL(for vault: WikiVault) -> URL {
        indexesDir.appendingPathComponent("\(vault.id).db")
    }

    /// Forget a vault. Closes the queue (GRDB releases the file handle on
    /// dealloc) and drops cached references. The .db file on disk stays
    /// — callers (e.g. settings UI) decide whether to delete it.
    func forgetVault(id: String) {
        queues.removeValue(forKey: id)
        repositories.removeValue(forKey: id)
    }

    // MARK: - Private

    private func openQueue(for vault: WikiVault) throws -> DatabaseQueue {
        if let existing = queues[vault.id] {
            return existing
        }
        try ensureIndexesDirExists()
        let dbURL = indexDatabaseURL(for: vault)
        let queue = try DatabaseQueue(path: dbURL.path)
        try queue.write { db in
            try GRDBWikiPageRepository.installSchema(in: db)
        }
        queues[vault.id] = queue
        return queue
    }

    private func ensureIndexesDirExists() throws {
        let fm = FileManager.default
        if !fm.fileExists(atPath: indexesDir.path) {
            try fm.createDirectory(
                at: indexesDir, withIntermediateDirectories: true
            )
        }
    }
}
