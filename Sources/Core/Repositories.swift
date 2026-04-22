import Foundation

enum ConversationHeadlineSource: String, Hashable, Sendable {
    case prompt
    case title
    case firstMessage
    case untitled
}

struct ConversationHeadlineSummary: Hashable, Sendable {
    let primaryText: String
    let secondaryText: String?
    let source: ConversationHeadlineSource

    static func build(
        prompt: String?,
        title: String?,
        firstMessage: String?
    ) -> ConversationHeadlineSummary {
        let normalizedPrompt = normalize(prompt)
        let normalizedTitle = normalize(title)
        let normalizedFirstMessage = normalize(firstMessage)

        if let normalizedPrompt {
            return ConversationHeadlineSummary(
                primaryText: normalizedPrompt,
                secondaryText: secondaryText(
                    preferred: normalizedTitle,
                    fallback: normalizedFirstMessage,
                    excluding: normalizedPrompt
                ),
                source: .prompt
            )
        }

        if let normalizedTitle {
            return ConversationHeadlineSummary(
                primaryText: normalizedTitle,
                secondaryText: secondaryText(
                    preferred: normalizedFirstMessage,
                    fallback: nil,
                    excluding: normalizedTitle
                ),
                source: .title
            )
        }

        if let normalizedFirstMessage {
            return ConversationHeadlineSummary(
                primaryText: normalizedFirstMessage,
                secondaryText: nil,
                source: .firstMessage
            )
        }

        return ConversationHeadlineSummary(
            primaryText: "Untitled Conversation",
            secondaryText: nil,
            source: .untitled
        )
    }

    private static func normalize(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let collapsed = value
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else {
            return nil
        }

        return collapsed
    }

    private static func secondaryText(
        preferred: String?,
        fallback: String?,
        excluding primary: String
    ) -> String? {
        if let preferred, preferred != primary {
            return preferred
        }

        if let fallback, fallback != primary {
            return fallback
        }

        return nil
    }
}

struct FilterOption: Identifiable, Hashable, Sendable {
    let value: String
    let count: Int

    var id: String { value }
}

enum BookmarkTargetType: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case thread
    case prompt
    case virtualFragment = "virtual_fragment"
    case savedView = "saved_view"

    var id: String { rawValue }
}

enum ViewTargetType: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case virtualThread = "virtual_thread"

    var id: String { rawValue }
}

struct ConversationSummary: Identifiable, Hashable, Sendable {
    let id: String
    let headline: ConversationHeadlineSummary
    let source: String?
    let title: String?
    let model: String?
    let messageCount: Int
    let primaryTime: String?
    let isBookmarked: Bool

    var displayTitle: String {
        normalizedTitle ?? headline.primaryText
    }

    private var normalizedTitle: String? {
        guard let title else {
            return nil
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct ConversationDetail: Sendable {
    let summary: ConversationSummary
    let messages: [Message]
}

struct Message: Identifiable, Hashable, Sendable {
    let id: String
    let role: MessageRole
    let content: String

    var isUser: Bool { role == .user }
}

enum MessageRole: String, Codable, Hashable, Sendable {
    case user
    case assistant
    case system
    case tool

    init(databaseValue: String?) {
        guard let databaseValue else {
            self = .assistant
            return
        }

        self = MessageRole(rawValue: databaseValue.lowercased()) ?? .assistant
    }
}

enum ConversationSortKey: Hashable, Sendable {
    case dateAsc
    case dateDesc
    /// Sort by the conversation's prompt count (stored as `prompt_count` in
    /// GRDB, surfaced as `messageCount` on `ConversationSummary`). "Most
    /// prompts first" — useful for finding the long, substantive threads.
    case promptCountDesc
    /// Fewest prompts first — the inverse; surfaces one-off questions.
    case promptCountAsc
}

struct ArchiveSearchFilter: Codable, Hashable, Sendable {
    var keyword: String
    var sources: Set<String>
    var models: Set<String>
    /// Filter by `conversations.source_file` — the absolute path of the JSON
    /// file the conversation was imported from. Drives the per-file checkbox
    /// list under the sidebar's archive.db entry.
    var sourceFiles: Set<String>
    var bookmarkedOnly: Bool
    var dateFrom: String?
    var dateTo: String?
    var roles: Set<MessageRole>
    var bookmarkTags: [String]

    init(
        keyword: String = "",
        source: String? = nil,
        model: String? = nil,
        sources: Set<String> = [],
        models: Set<String> = [],
        sourceFiles: Set<String> = [],
        bookmarkedOnly: Bool = false,
        dateFrom: String? = nil,
        dateTo: String? = nil,
        roles: Set<MessageRole> = [],
        bookmarkTags: [String] = []
    ) {
        self.keyword = keyword
        self.sources = sources.isEmpty ? Set(source.map { [$0] } ?? []) : sources
        self.models = models.isEmpty ? Set(model.map { [$0] } ?? []) : models
        self.sourceFiles = sourceFiles
        self.bookmarkedOnly = bookmarkedOnly
        self.dateFrom = dateFrom
        self.dateTo = dateTo
        self.roles = roles
        self.bookmarkTags = bookmarkTags
    }

    private enum CodingKeys: String, CodingKey {
        case keyword
        case source
        case model
        case sources
        case models
        case sourceFiles
        case bookmarkedOnly
        case dateFrom
        case dateTo
        case roles
        case bookmarkTags

        // Legacy Python-side filter keys we still want to tolerate.
        case promptContains
        case service
    }

    init(from decoder: any Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)

        let legacyKeyword = try container.decodeIfPresent(String.self, forKey: .promptContains)
        let keyword = try container.decodeIfPresent(String.self, forKey: .keyword) ?? legacyKeyword ?? ""

        let legacySource = try container.decodeIfPresent([String].self, forKey: .service)?.first
        let source = try container.decodeIfPresent(String.self, forKey: .source) ?? legacySource
        let sources = Set(try container.decodeIfPresent([String].self, forKey: .sources) ?? source.map { [$0] } ?? [])
        let model = try container.decodeIfPresent(String.self, forKey: .model)
        let models = Set(try container.decodeIfPresent([String].self, forKey: .models) ?? model.map { [$0] } ?? [])
        let sourceFiles = Set(try container.decodeIfPresent([String].self, forKey: .sourceFiles) ?? [])

        let rolesArray = try container.decodeIfPresent([MessageRole].self, forKey: .roles) ?? []

        self.init(
            keyword: keyword,
            sources: sources,
            models: models,
            sourceFiles: sourceFiles,
            bookmarkedOnly: try container.decodeIfPresent(Bool.self, forKey: .bookmarkedOnly) ?? false,
            dateFrom: try container.decodeIfPresent(String.self, forKey: .dateFrom),
            dateTo: try container.decodeIfPresent(String.self, forKey: .dateTo),
            roles: Set(rolesArray),
            bookmarkTags: try container.decodeIfPresent([String].self, forKey: .bookmarkTags) ?? []
        )
    }

    func encode(to encoder: any Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(keyword, forKey: .keyword)
        try container.encode(Array(sources).sorted(), forKey: .sources)
        try container.encode(Array(models).sorted(), forKey: .models)
        try container.encode(Array(sourceFiles).sorted(), forKey: .sourceFiles)
        try container.encodeIfPresent(source, forKey: .source)
        try container.encodeIfPresent(model, forKey: .model)
        try container.encode(bookmarkedOnly, forKey: .bookmarkedOnly)
        try container.encodeIfPresent(dateFrom, forKey: .dateFrom)
        try container.encodeIfPresent(dateTo, forKey: .dateTo)
        try container.encode(Array(roles).sorted { $0.rawValue < $1.rawValue }, forKey: .roles)
        try container.encode(bookmarkTags, forKey: .bookmarkTags)
    }

    var normalizedKeyword: String {
        keyword.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    var hasMeaningfulFilters: Bool {
        !normalizedKeyword.isEmpty
            || !sources.isEmpty
            || !models.isEmpty
            || !sourceFiles.isEmpty
            || bookmarkedOnly
            || normalized(dateFrom) != nil
            || normalized(dateTo) != nil
            || !roles.isEmpty
            || !bookmarkTags.isEmpty
    }

    private func normalized(_ value: String?) -> String? {
        guard let value else {
            return nil
        }

        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    var source: String? {
        get { sources.count == 1 ? sources.first : nil }
        set { sources = Set(newValue.map { [$0] } ?? []) }
    }

    var model: String? {
        get { models.count == 1 ? models.first : nil }
        set { models = Set(newValue.map { [$0] } ?? []) }
    }
}

struct ConversationListQuery: Hashable, Sendable {
    let offset: Int
    let limit: Int
    let sortBy: ConversationSortKey
    let filter: ArchiveSearchFilter

    init(
        offset: Int,
        limit: Int,
        sortBy: ConversationSortKey = .dateDesc,
        filter: ArchiveSearchFilter = ArchiveSearchFilter(),
        source: String? = nil,
        model: String? = nil
    ) {
        self.offset = offset
        self.limit = limit
        self.sortBy = sortBy
        if source != nil || model != nil {
            self.filter = ArchiveSearchFilter(source: source, model: model)
        } else {
            self.filter = filter
        }
    }
}

struct SearchQuery: Hashable, Sendable {
    let filter: ArchiveSearchFilter
    let offset: Int
    let limit: Int

    init(
        filter: ArchiveSearchFilter,
        offset: Int,
        limit: Int
    ) {
        self.filter = filter
        self.offset = offset
        self.limit = limit
    }

    var normalizedText: String {
        filter.normalizedKeyword
    }
}

struct SearchResult: Identifiable, Hashable, Sendable {
    let conversationID: String
    let headline: ConversationHeadlineSummary
    let title: String?
    let source: String?
    let model: String?
    let messageCount: Int
    let primaryTime: String?
    let snippet: String
    let isBookmarked: Bool

    var id: String { conversationID }

    var displayTitle: String {
        normalizedTitle ?? headline.primaryText
    }

    private var normalizedTitle: String? {
        guard let title else {
            return nil
        }

        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}

struct BookmarkTarget: Hashable, Sendable {
    let targetType: BookmarkTargetType
    let targetID: String
    let payload: [String: String]

    init(
        targetType: BookmarkTargetType,
        targetID: String,
        payload: [String: String] = [:]
    ) {
        self.targetType = targetType
        self.targetID = targetID
        self.payload = payload
    }
}

struct BookmarkState: Hashable, Sendable {
    let targetType: BookmarkTargetType
    let targetID: String
    let payload: [String: String]
    let isBookmarked: Bool
    let updatedAt: String?
}

struct BookmarkListEntry: Identifiable, Hashable, Sendable {
    let bookmarkID: Int
    let targetType: BookmarkTargetType
    let targetID: String
    let payload: [String: String]
    let label: String
    let title: String?
    let source: String?
    let model: String?
    let primaryTime: String?
    let updatedAt: String?

    var id: Int { bookmarkID }
}

struct SavedFilterEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let kind: String
    let targetType: ViewTargetType
    let name: String
    let filters: ArchiveSearchFilter
    let createdAt: String
    let updatedAt: String
    let lastUsedAt: String
    /// Unified Recent/Saved model. Pinned entries rank above non-pinned and
    /// are exempted from automatic eviction until the total also exceeds the
    /// unified cap.
    var pinned: Bool = false
}

typealias SavedViewEntry = SavedFilterEntry

struct VirtualThreadPreview: Hashable, Sendable {
    let title: String
    let count: Int
}

struct VirtualThreadItem: Identifiable, Hashable, Sendable {
    let id: String
    let conversationID: String
    let messageIndex: Int
    let title: String
    let snippet: String
    let source: String?
    let model: String?
    let primaryTime: String?
}

struct VirtualThread: Hashable, Sendable {
    let title: String
    let filters: ArchiveSearchFilter
    let items: [VirtualThreadItem]
}

/// A (source, model) pair with its conversation count — used to build the
/// sidebar facet tree in one DB round-trip instead of N+1.
struct SourceModelFacet: Sendable, Hashable {
    let source: String
    let model: String?
    let count: Int
}

enum ProjectOrigin: String, Codable, Hashable, Sendable {
    case canonicalImport = "canonical_import"
    case userCreated = "user_created"
}

enum MembershipOrigin: String, Codable, Hashable, Sendable {
    case canonicalImport = "canonical_import"
    case manualAdd = "manual_add"
    case acceptedSuggestion = "accepted_suggestion"
}

enum SuggestionState: String, Codable, Hashable, Sendable {
    case pending
    case accepted
    case dismissed
}

struct Project: Identifiable, Hashable, Sendable {
    let id: String
    let name: String
    let origin: ProjectOrigin
    let createdAt: Date
    let updatedAt: Date
}

struct ProjectMembership: Hashable, Sendable {
    let threadId: String
    let projectId: String
    let origin: MembershipOrigin
    let assignedAt: Date
}

struct ProjectSuggestion: Hashable, Sendable {
    let threadId: String
    let targetProjectId: String
    let score: Double
    let reason: [String]
    let state: SuggestionState
    let createdAt: Date
    let updatedAt: Date
}

struct ProjectCounts: Hashable, Sendable {
    let all: Int
    let byProject: [String: Int]
    let inbox: Int
    let orphans: Int
}

enum ProjectRepositoryError: Error, Sendable {
    case emptyProjectID
    case emptyProjectName
}

enum RawExportProvider: String, Codable, Hashable, Sendable {
    case chatGPT = "chatgpt"
    case claude
    case gemini
    case unknown
}

struct RawExportVaultResult: Hashable, Sendable {
    let provider: RawExportProvider
    let snapshotID: Int64
    let totalFiles: Int
    let newBlobs: Int
    let reusedBlobs: Int
    let originalBytes: Int64
    let storedBytes: Int64
    let manifestURL: URL
    /// `true` when the ingest was a no-op because an existing snapshot with
    /// the same stable content hash was found. The returned `snapshotID`
    /// points to that prior snapshot, and byte / blob counts are zero.
    let wasDuplicate: Bool
}

struct RawExportSnapshotSummary: Identifiable, Hashable, Sendable {
    let id: Int64
    let provider: RawExportProvider
    let sourceRoot: String?
    let importedAt: String
    let manifestHash: String
    let fileCount: Int
    let newBlobCount: Int
    let reusedBlobCount: Int
    let originalBytes: Int64
    let storedBytes: Int64
    let manifestPath: String
}

struct RawExportSearchResult: Identifiable, Hashable, Sendable {
    let snapshotID: Int64
    let blobHash: String
    let provider: RawExportProvider
    let relativePath: String
    let snippet: String

    var id: String {
        "\(snapshotID):\(relativePath):\(blobHash)"
    }
}

/// One file-level record inside a snapshot. This is the metadata view — the
/// actual bytes live behind `loadBlob(hash:)` / `loadFile(...)`.
struct RawExportFileEntry: Identifiable, Hashable, Sendable {
    let snapshotID: Int64
    let relativePath: String
    let blobHash: String
    /// Byte length of the original (uncompressed) file.
    let sizeBytes: Int64
    /// Byte length on disk. Differs from `sizeBytes` when `compression` is
    /// anything other than `"none"`.
    let storedSizeBytes: Int64
    let mimeType: String?
    /// `"conversation" | "metadata" | "manifest" | "asset" | "other"`.
    let role: String
    /// `"none" | "lzfse"`. Additional codecs can be added later without
    /// breaking callers — `RawExportVaultError.unsupportedCompression` will
    /// fire if an unknown value is encountered during restore.
    let compression: String
    /// Absolute path to the blob on disk. Present so tests and tooling can
    /// assert filesystem layout; normal callers should prefer `loadBlob`.
    let storedPath: String

    var id: String { "\(snapshotID):\(relativePath)" }
}

/// A file's metadata plus its decompressed bytes. The bytes are hash-verified
/// against `entry.blobHash` before being returned, so a successful return
/// implies integrity.
struct RawExportFilePayload: Sendable {
    let entry: RawExportFileEntry
    let data: Data
}

/// Errors surfaced by the restore / read side of the Vault. `ingest` still
/// throws generic errors (I/O, GRDB) — this enum is specifically for the
/// read path where we can describe the failure precisely.
enum RawExportVaultError: Error, Sendable, Equatable {
    case snapshotNotFound(snapshotID: Int64)
    case fileNotFound(snapshotID: Int64, relativePath: String)
    case blobNotFound(hash: String)
    case blobFileMissing(hash: String, path: String)
    case decompressionFailed(hash: String)
    case hashMismatch(expected: String, actual: String)
    case unsupportedCompression(String)
}

struct RawAssetHit: Identifiable, Hashable, Sendable {
    let snapshotID: Int64
    let sourceRelativePath: String
    let assetRelativePath: String
    let blobHash: String
    let kind: String
    let sizeBytes: Int64
    let storedSizeBytes: Int64
    let mimeType: String?
    let compression: String

    var id: String {
        "\(snapshotID):\(sourceRelativePath):\(assetRelativePath)"
    }
}

protocol ConversationRepository: Sendable {
    func fetchIndex(query: ConversationListQuery) async throws -> [ConversationSummary]
    func fetchDetail(id: String) async throws -> ConversationDetail?
    func fetchHeadline(id: String) async throws -> ConversationHeadlineSummary?
    func count(query: ConversationListQuery) async throws -> Int
    func fetchSources(filter: ArchiveSearchFilter?) async throws -> [FilterOption]
    func fetchModels(filter: ArchiveSearchFilter?) async throws -> [FilterOption]
    /// Single-query facet fetch: returns every (source, model) combination with
    /// its conversation count, evaluated under the given filter with BOTH the
    /// source and model filters excluded (so all sources/models remain visible).
    /// Callers pivot the flat list into the sidebar tree structure.
    func fetchSourceModelFacets(filter: ArchiveSearchFilter?) async throws -> [SourceModelFacet]
    /// Per-imported-file conversation counts. Evaluated under the given filter
    /// with the sourceFiles dimension removed (so every file always stays
    /// visible in the sidebar regardless of which checkboxes are ticked).
    func fetchSourceFileFacets(filter: ArchiveSearchFilter?) async throws -> [FilterOption]
}

extension ConversationRepository {
    func fetchSources() async throws -> [FilterOption] {
        try await fetchSources(filter: nil)
    }

    func fetchModels(source: String?) async throws -> [FilterOption] {
        try await fetchModels(filter: ArchiveSearchFilter(source: source))
    }
}

protocol SearchRepository: Sendable {
    func search(query: SearchQuery) async throws -> [SearchResult]
    func count(query: SearchQuery) async throws -> Int
}

protocol ProjectRepository: Sendable {
    func listProjects(offset: Int, limit: Int) async throws -> [Project]
    func project(id: String) async throws -> Project?
    func upsertCanonicalProject(id: String, name: String) async throws -> Project
    func createUserProject(name: String) async throws -> Project
    func renameProject(id: String, to name: String) async throws
    func deleteProject(id: String) async throws
    func threadCounts() async throws -> ProjectCounts
}

protocol ProjectMembershipRepository: Sendable {
    func membership(threadId: String) async throws -> ProjectMembership?
    func setMembership(_ membership: ProjectMembership) async throws
    func removeMembership(threadId: String) async throws
    func threadsInProject(projectId: String, offset: Int, limit: Int) async throws -> [ConversationSummary]
    func unassignedThreads(hasSuggestion: Bool, offset: Int, limit: Int) async throws -> [ConversationSummary]
}

protocol ProjectSuggestionRepository: Sendable {
    func topPendingSuggestion(threadId: String) async throws -> ProjectSuggestion?
    func suggestions(threadId: String) async throws -> [ProjectSuggestion]
    func upsertSuggestion(_ suggestion: ProjectSuggestion) async throws
    func markAccepted(threadId: String, targetProjectId: String) async throws
    func markDismissed(threadId: String, targetProjectId: String) async throws
    func dismissedTokens(projectId: String) async throws -> [String: Int]
}

protocol RawExportVault: Sendable {
    // MARK: Ingest

    func ingest(_ urls: [URL]) async throws -> RawExportVaultResult?

    // MARK: Browse

    func listSnapshots(offset: Int, limit: Int) async throws -> [RawExportSnapshotSummary]
    func search(
        query: String,
        provider: RawExportProvider?,
        offset: Int,
        limit: Int
    ) async throws -> [RawExportSearchResult]

    // MARK: Restore

    /// Fetch a single snapshot summary by its database ID.
    /// Returns `nil` when the snapshot does not exist.
    func getSnapshot(id: Int64) async throws -> RawExportSnapshotSummary?

    /// Page through the files that belong to a snapshot. Ordered by
    /// `relative_path ASC` so results are stable across calls.
    /// Throws `RawExportVaultError.snapshotNotFound` when the snapshot is
    /// unknown — ingest never creates empty snapshots, so an unknown ID is
    /// treated as a contract break rather than "empty page".
    func listFiles(
        snapshotID: Int64,
        offset: Int,
        limit: Int
    ) async throws -> [RawExportFileEntry]

    /// Read a blob by its SHA-256 hash. Transparently decompresses LZFSE.
    /// The returned bytes are verified against `hash` before return.
    /// Throws `RawExportVaultError.blobNotFound` / `.blobFileMissing` /
    /// `.decompressionFailed` / `.hashMismatch` on integrity failures.
    func loadBlob(hash: String) async throws -> Data

    /// Read a specific file from a snapshot: looks up the file row, fetches
    /// the blob, verifies integrity, and returns both metadata and bytes.
    /// Throws `RawExportVaultError.snapshotNotFound` when the snapshot is
    /// unknown, or `.fileNotFound` when the snapshot exists but does not
    /// contain the given relative path.
    func loadFile(
        snapshotID: Int64,
        relativePath: String
    ) async throws -> RawExportFilePayload
}

protocol RawAssetResolver: Sendable {
    /// Resolve one asset reference inside a snapshot. `reference` can be an
    /// exact relative path or the basename seen in an export JSON field.
    /// Returns `nil` when the snapshot exists but no asset matches.
    func resolveAsset(
        snapshotID: Int64,
        reference: String
    ) async throws -> RawAssetHit?

    /// Page through the assets referenced by one textual export file.
    /// Throws `RawExportVaultError.snapshotNotFound` when the snapshot is
    /// unknown.
    func assetsReferencedBy(
        snapshotID: Int64,
        sourceRelativePath: String,
        offset: Int,
        limit: Int
    ) async throws -> [RawAssetHit]
}

protocol BookmarkRepository: Sendable {
    func setBookmark(target: BookmarkTarget, bookmarked: Bool) async throws -> BookmarkState
    func fetchBookmarkStates(targets: [BookmarkTarget]) async throws -> [BookmarkState]
    func listBookmarks() async throws -> [BookmarkListEntry]
}

struct TagEntry: Identifiable, Hashable, Sendable {
    let id: Int
    let name: String
    let isSystem: Bool
    let systemKey: String?
    let usageCount: Int
    let createdAt: String
    let updatedAt: String
}

struct ConversationTagBinding: Sendable {
    let conversationID: String
    let tags: [TagEntry]
    /// The bookmark row backing the binding, if any. `nil` means the
    /// conversation has no bookmark yet — tagging it will create one.
    let bookmarkID: Int?
}

protocol TagRepository: Sendable {
    func listTags() async throws -> [TagEntry]
    func createTag(name: String) async throws -> TagEntry
    func renameTag(id: Int, name: String) async throws -> TagEntry
    func deleteTag(id: Int) async throws
    func bindings(forConversationIDs ids: [String]) async throws -> [String: ConversationTagBinding]
    /// Look up a single tag by name (case-insensitive). Returns `nil` when no
    /// tag matches — avoids loading the whole tag table into memory just to
    /// resolve an id by name.
    func findTagByName(_ name: String) async throws -> TagEntry?
    /// Attach a tag to the conversation's bookmark, creating the bookmark
    /// on the fly when one does not exist yet. Returns the bookmark row id.
    @discardableResult
    func attachTag(tagID: Int, toConversationID conversationID: String, payload: [String: String]) async throws -> Int
    func detachTag(tagID: Int, fromConversationID conversationID: String) async throws
}

protocol ViewService: Sendable {
    func listRecentFilters(targetType: ViewTargetType) async throws -> [SavedFilterEntry]
    func saveRecentFilter(filters: ArchiveSearchFilter, targetType: ViewTargetType) async throws -> SavedFilterEntry?
    func listSavedViews(targetType: ViewTargetType) async throws -> [SavedViewEntry]
    func saveSavedView(
        name: String,
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType,
        id: Int?
    ) async throws -> SavedViewEntry?
    func deleteSavedView(id: Int, targetType: ViewTargetType) async throws -> Bool

    // MARK: Unified Recent/Pinned filters

    /// Unified filter history: pinned entries ranked first (by `last_used_at`
    /// desc), then unpinned recents, capped to `limit`.
    func listUnifiedFilters(targetType: ViewTargetType, limit: Int) async throws -> [SavedFilterEntry]
    /// Toggle the pinned flag on a saved_filters row regardless of `kind`.
    @discardableResult
    func togglePinnedFilter(id: Int, targetType: ViewTargetType) async throws -> Bool
    /// Delete any saved_filters row by id/target (pinned or recent).
    @discardableResult
    func deleteFilter(id: Int, targetType: ViewTargetType) async throws -> Bool
    func buildVirtualThreadPreview(
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType
    ) async throws -> VirtualThreadPreview
    func buildVirtualThread(
        title: String,
        filters: ArchiveSearchFilter,
        targetType: ViewTargetType
    ) async throws -> VirtualThread
}
