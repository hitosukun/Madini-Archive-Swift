# Raw Export Vault

Version: 2026-04-22  
Status: Phase A2 draft, implemented through `vault/phase-a1`

## Purpose

Raw Export Vault is Madini's local, durable storage layer for original export
packages from external LLM services. It stores the provider export as immutable,
content-addressed blobs, records snapshot provenance in SQLite, and exposes
bounded browse/search/restore APIs.

Vault is not the normalized conversation store. It does not replace
`conversations`, `messages`, or `search_idx`. It is the raw/provenance layer
that makes later normalization and UI reconstruction recoverable.

## Responsibilities

Vault owns:

- Detecting the likely export provider: ChatGPT, Claude, Gemini, or unknown.
- Copying export files into local content-addressed blob storage.
- Deduplicating blobs by SHA-256.
- Applying reversible LZFSE compression to suitable text-like files.
- Recording immutable import snapshots.
- Indexing selected text files for raw export provenance search.
- Restoring original bytes with decompression and SHA-256 verification.

Vault does not own:

- Normalizing export content into `conversations` or `messages`.
- Conversation-body full-text search. That belongs to `search_idx`.
- Project, tag, Saved View, Bookmark, or Virtual Thread semantics.
- UI state, selection state, or import progress presentation.
- Automatic summarization, scoring, or classification.

## Storage Layout

Default directories are provided by `AppPaths`:

- `AppPaths.rawExportsDir`
- `AppPaths.rawExportBlobsDir`
- `AppPaths.rawExportSnapshotsDir`

Blob path:

```text
raw_exports/blobs/<first-two-hash-chars>/<sha256>.blob
raw_exports/blobs/<first-two-hash-chars>/<sha256>.lzfse
```

Snapshot manifest path:

```text
raw_exports/snapshots/<provider>/<timestamp>-<manifest-hash-prefix>/manifest.json
```

Restore must prefer the canonical path derived from current storage settings,
hash, and compression. The database `stored_path` is a legacy/debug fallback and
must not be the primary restore source. This keeps Vault portable when the data
directory moves between machines or user homes.

## SQLite Schema

`GRDBRawExportVault.installSchema(in:)` installs the Vault schema. It is
idempotent and is called from `AppServices.bootstrapViewLayerSchema`.

### `raw_export_snapshots`

One row per user ingest operation.

```sql
CREATE TABLE IF NOT EXISTS raw_export_snapshots (
    id INTEGER PRIMARY KEY AUTOINCREMENT,
    provider TEXT NOT NULL,
    source_root TEXT,
    imported_at TEXT NOT NULL,
    manifest_hash TEXT NOT NULL,
    file_count INTEGER NOT NULL,
    new_blob_count INTEGER NOT NULL,
    reused_blob_count INTEGER NOT NULL,
    original_bytes INTEGER NOT NULL,
    stored_bytes INTEGER NOT NULL,
    manifest_path TEXT NOT NULL
);

CREATE INDEX IF NOT EXISTS idx_raw_export_snapshots_provider_time
ON raw_export_snapshots(provider, imported_at DESC, id DESC);
```

### `raw_export_blobs`

One row per unique original file hash.

```sql
CREATE TABLE IF NOT EXISTS raw_export_blobs (
    hash TEXT PRIMARY KEY,
    size_bytes INTEGER NOT NULL,
    stored_size_bytes INTEGER NOT NULL,
    mime_type TEXT,
    compression TEXT NOT NULL,
    stored_path TEXT NOT NULL,
    created_at TEXT NOT NULL
);
```

`hash` is the SHA-256 of the original uncompressed bytes.

### `raw_export_files`

One row per file inside a snapshot.

```sql
CREATE TABLE IF NOT EXISTS raw_export_files (
    snapshot_id INTEGER NOT NULL,
    relative_path TEXT NOT NULL,
    blob_hash TEXT NOT NULL,
    size_bytes INTEGER NOT NULL,
    mime_type TEXT,
    role TEXT NOT NULL,
    compression TEXT NOT NULL,
    stored_path TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (snapshot_id, relative_path),
    FOREIGN KEY(snapshot_id) REFERENCES raw_export_snapshots(id) ON DELETE CASCADE,
    FOREIGN KEY(blob_hash) REFERENCES raw_export_blobs(hash)
);

CREATE INDEX IF NOT EXISTS idx_raw_export_files_blob
ON raw_export_files(blob_hash);
```

`role` is currently one of:

- `conversation`
- `metadata`
- `manifest`
- `asset`
- `other`

### `raw_export_search_idx`

FTS5 index for raw export text files.

```sql
CREATE VIRTUAL TABLE IF NOT EXISTS raw_export_search_idx
USING fts5(
    snapshot_id UNINDEXED,
    blob_hash UNINDEXED,
    provider UNINDEXED,
    relative_path,
    content,
    tokenize="unicode61"
);
```

This is not the main conversation full-text index. It is a provenance search
index over selected export files. Do not present it as complete conversation
search.

Current indexing rules:

- `conversation`, `metadata`, and `manifest` roles are indexed if they are
  UTF-8 and at most 200 MB.
- Other text-like files (`text/*`, `.md`, `.txt`, `.csv`, `.xml`) are indexed
  only up to 20 MB.
- Binary assets, PDFs, images, and giant duplicate HTML exports are not treated
  as the primary conversation search surface.

### `raw_export_asset_links`

Backing table for `RawAssetResolver`. Rows map textual export files to asset
files stored in the same snapshot.

```sql
CREATE TABLE IF NOT EXISTS raw_export_asset_links (
    snapshot_id INTEGER NOT NULL,
    source_relative_path TEXT NOT NULL,
    asset_relative_path TEXT NOT NULL,
    blob_hash TEXT,
    kind TEXT NOT NULL,
    created_at TEXT NOT NULL,
    PRIMARY KEY (snapshot_id, source_relative_path, asset_relative_path),
    FOREIGN KEY(snapshot_id) REFERENCES raw_export_snapshots(id) ON DELETE CASCADE
);

CREATE INDEX IF NOT EXISTS idx_raw_export_asset_links_asset
ON raw_export_asset_links(snapshot_id, asset_relative_path);
```

UI should go through `RawAssetResolver`, not query this table directly.

## Snapshot Manifest

Each ingest writes a JSON manifest next to the snapshot.

Shape:

```json
{
  "provider": "chatgpt",
  "sourceRoot": "/path/to/original/export",
  "importedAt": "2026-04-22 12:00:00",
  "fileCount": 2,
  "originalBytes": 12345,
  "storedBytes": 6789,
  "files": [
    {
      "relativePath": "conversations-0001.json",
      "blobHash": "<sha256>",
      "sizeBytes": 12345,
      "mimeType": "application/json",
      "role": "conversation",
      "compression": "lzfse",
      "storedPath": "/absolute/debug/fallback/path"
    }
  ]
}
```

`manifest_hash` in SQLite is the SHA-256 of the manifest JSON bytes. It is not
currently a uniqueness constraint. Reingesting the same export creates a new
snapshot row but reuses existing blobs.

## Provider Detection

Provider detection lives in `RawExportProviderDetector` and is shared by Vault
and `JSONImportFileResolver`.

Priority:

1. Directory-shaped hints.
2. JSON header sniffing.
3. `.unknown`.

Directory hints:

- ChatGPT: root `conversations-*.json` chunks or `export_manifest.json`.
- Claude: root `conversations.json` plus `projects.json` for strict directory
  detection.
- Gemini: recursive Takeout activity JSON containing `header`, `Gemini`,
  `time`, and `title` markers in the first 64 KiB.

Header sniffing:

- ChatGPT: first JSON array element has `mapping`.
- Claude: first JSON array element has `chat_messages`.
- Gemini: first JSON array element has `time` and `title`.

Resolver note:

`JSONImportFileResolver` may still hand root `conversations.json` to the
importer even when strict Claude directory detection does not claim the folder.
That preserves importer compatibility for partial Claude exports.

## Public Service Contract

The protocol lives in `Sources/Core/Repositories.swift`.

Ingest:

- `ingest(_ urls: [URL]) async throws -> RawExportVaultResult?`

Browse:

- `listSnapshots(offset:limit:) async throws -> [RawExportSnapshotSummary]`
- `search(query:provider:offset:limit:) async throws -> [RawExportSearchResult]`

Restore:

- `getSnapshot(id:) async throws -> RawExportSnapshotSummary?`
- `listFiles(snapshotID:offset:limit:) async throws -> [RawExportFileEntry]`
- `loadBlob(hash:) async throws -> Data`
- `loadFile(snapshotID:relativePath:) async throws -> RawExportFilePayload`

Asset resolution:

- `RawAssetResolver.resolveAsset(snapshotID:reference:) async throws -> RawAssetHit?`
- `RawAssetResolver.assetsReferencedBy(snapshotID:sourceRelativePath:offset:limit:) async throws -> [RawAssetHit]`

`RawAssetResolver` returns metadata and blob identity only. Callers that need
bytes should pass `RawAssetHit.assetRelativePath` to
`RawExportVault.loadFile(snapshotID:relativePath:)`.

All list APIs must remain paginated with `offset` and `limit`.

Restore contract:

- `loadBlob` transparently decompresses LZFSE.
- Returned bytes are always SHA-256 verified against the requested hash.
- Unknown blob hash throws `RawExportVaultError.blobNotFound`.
- Missing blob file throws `RawExportVaultError.blobFileMissing`.
- Corrupt compressed payload throws `RawExportVaultError.decompressionFailed`.
- Hash mismatch throws `RawExportVaultError.hashMismatch`.
- Unknown snapshot in `listFiles` or `loadFile` throws
  `RawExportVaultError.snapshotNotFound`.
- Existing snapshot plus missing relative path throws
  `RawExportVaultError.fileNotFound`.
- `getSnapshot(id:)` returns `nil` for an unknown snapshot.

## Import Pipeline Contract

Current implementation:

- macOS drop handling calls Vault ingest and JSON import from `MacOSRootView`.
- `JSONImportFileResolver` decides which JSON files are passed to the importer.
- Vault stores original files; the importer writes normalized conversations.

Target Phase B contract:

1. Move this orchestration into an `ImportCoordinator`.
2. Resolve provider/export shape once.
3. Run Vault ingest before normalized import.
4. If Vault ingest fails, do not proceed silently.
5. If Vault succeeds and normalized import fails, keep the Vault snapshot and
   surface that only normalization failed.
6. Treat reingest as a valid snapshot event while reporting reused blobs and
   duplicate manifest hints to the UI.

Vault success and normalized import success are related but not identical.
Original preservation should not be rolled back only because normalization
fails.

## Relationship To Existing Search

`search_idx`:

- Main conversation search.
- Populated by normalized import.
- Used by `GRDBSearchRepository`.
- User-facing "archive search" surface.

`raw_export_search_idx`:

- Raw export file search.
- Populated by Vault ingest.
- Used by `RawExportVault.search`.
- Provenance/debug/recovery surface.

Do not merge these indexes without an explicit migration and UI contract.

## Relationship To Project, Tag, And Saved View

Vault is raw/provenance storage. It should not create or mutate:

- `projects`
- `project_memberships`
- `project_suggestions`
- `bookmark_tags`
- `saved_filters`
- UI state

Project/tag/Saved View features operate on normalized conversation identity or
user annotations. They may refer to Vault provenance later, but Vault must not
become an annotation engine.

## Legacy Python Prototype (Informational)

An earlier Python prototype exists but is unpublished and is not a peer of the
Swift implementation. It no longer constrains schema decisions here.

Treat the Python artifact as a one-way legacy data source:

- If a user has a pre-existing Python-era SQLite database, a future migration
  may ingest it into the Swift-owned schema.
- The Swift app does not guarantee its writes will be readable by the Python
  prototype, and is not required to.
- `raw_export_search_idx` and the main `search_idx` may diverge structurally
  from any Python-era shape; the only constraint is that the Swift
  `DatabaseMigrator` can upgrade in place.

## Maintenance Notes

- `raw_export_search_idx` can be rebuilt from `raw_export_files` plus blob
  restore, but no rebuild command exists yet.
- SQLite `OPTIMIZE` / `VACUUM` strategy for large Vault growth is not yet
  defined.
- `stored_path` remains for debug and legacy fallback; restore should derive
  canonical paths first.
- Blob cleanup is intentionally not automatic. A successful Vault snapshot is
  considered useful provenance even if later normalization fails.

## Next Phases

Phase B: Import Coordinator

- Centralize macOS drop import orchestration.
- Make Vault/import success and failure states explicit.
- Add reingest detection surface.

Phase C: Raw Asset Resolver

- Extract asset reference resolution out of Vault storage. Implemented as
  `RawAssetResolver` / `GRDBRawAssetResolver`.
- Populate and query `raw_export_asset_links`.
- Return asset payloads through restore APIs without mixing them into canonical
  message bodies.

Phase D: UI

- Snapshot list.
- Provider-scoped raw export search.
- Import history and diff summary.
- Asset preview/reconstruction.
