# Madini Repository Rules

## Design Philosophy
Madini is a local archive browser for long-term accumulation of LLM logs.
It is not primarily an editor, an auto-summary tool, or a judgment engine.
Its main purpose is to support rereading, exploration, comparison, and reconstruction over time.

This is the SwiftUI (macOS / iOS) implementation. It shares the same SQLite schema and data directory as the Python version and must remain compatible with it.

## Core Principles
- Preserve originals by default, with explicit exceptions for storage-heavy binaries.
- Prefer portable and standard formats over closed internal formats.
- Keep the system local-first.
- Separate body data from views, caches, and UI state.
- Design for 10x and 100x log growth, not just current convenience.
- Support human judgment rather than replacing it with automatic evaluation.

## Original Preservation
- Keep raw source by default for text-based imports. Normalized data must not be treated as the only source of truth.
- Large non-text attachments or binaries do not need to be inlined into the main body database if that would make storage or sync impractical; in those cases, preserve durable references and provenance such as path, hash, type, size, and related metadata.
- Treat normalized tables as a derived layer, not as a replacement for the original source.
- Preserve provenance needed for recovery and export, including `source_format`, `source_path`, `source_hash`, `source_created_at`, and `imported_at`.
- Do not overwrite original timestamps with import-time timestamps.
- Do not silently discard branches, attachments, candidates, or tool/system metadata unless there is an explicit, documented reason.
- If rendering interprets Markdown, math, or HTML, prefer designs that can still return to a raw/plain view.

## Portability
- Prefer SQL, JSON, Markdown, HTML, and filesystem-based assets.
- Avoid internal-only storage designs that are hard to inspect, migrate, or export.
- New persistent structures should have a plausible export path before they are adopted.
- Users must be able to keep and move their data without being locked into Madini.
- The SQLite schema must remain compatible with the Python version. Do not rename tables or columns without a migration path that both versions can consume.

## Scale Resistance
- Assume logs will continue to grow for years.
- Avoid interactive paths that depend on repeated full-table scans when indexed or incremental designs are possible.
- Prefer indexed or FTS-based search paths over repeated `LIKE` scans for interactive search.
- Do not make O(total_messages) work a default part of common interactive paths when bounded, incremental, paginated, or indexed alternatives are available.
- Prefer lazy loading, pagination, indexed search, bounded previews, rebuildable caches, and append-friendly storage.
- Treat preview generation, counts, and filter updates as incremental or bounded problems whenever possible.
- Before adding a feature, ask whether it remains usable at 10x and 100x current data volume.
- Favor durable structure over short-term convenience hacks.
- All list queries must accept `offset` and `limit` parameters. Never fetch all rows by default.

## Separation of Layers
- Raw layer: imported source and provenance (`raw_sources` table).
- Normalize layer: shared conversation/message representation derived from raw data (`conversations`, `messages`).
- View layer: Saved Views, Recent Filters, Bookmarks, and Virtual Thread definitions (`saved_filters`, `bookmarks`, `bookmark_tags`, `bookmark_tag_links`).
- Cache layer: search indexes, previews, and other rebuildable derived artifacts (`search_idx` FTS5).
- UI layer: SwiftUI `@State`, `@Observable`, `NavigationPath`, scroll position, panel state, and theme state.
- Saved Views are named filter definitions and related metadata, not stored result bodies.
- Recent Filters are lightweight reuse history, not durable copies of body text.
- Bookmarks are user annotation or selection state independent from canonical body data.
- Virtual Threads are derived reading views or query results, not duplicated canonical conversations.
- View features should store definitions, state, and metadata, not duplicated body text.
- Virtual Threads should remain derived views unless there is a strong, explicit reason to persist more.

## Repository Pattern and Service Layer

### Boundary Rules
- All database access from UI code must go through protocol-typed repository or service interfaces defined in `Core/Repositories.swift`.
- UI files must never `import GRDB` or reference GRDB types directly.
- SQL statements belong exclusively inside `Database/GRDB*.swift` implementation files.
- `AppServices` is the single dependency container. It creates all repository implementations and is injected into the SwiftUI environment via `@EnvironmentObject`.
- When adding a new data access need, first add a method to the appropriate protocol in `Repositories.swift`, then implement it in the corresponding `GRDB*.swift` file. Do not add ad hoc database calls in views or view models.

### Repository Inventory
| Protocol | Responsibility | Implementation |
|----------|---------------|----------------|
| `ConversationRepository` | Paginated listing, detail fetch, filter options | `GRDBConversationRepository` |
| `SearchRepository` | Keyword search (FTS5-first) | `GRDBSearchRepository` |
| `BookmarkRepository` | Bookmark CRUD, tag membership | `GRDBBookmarkRepository` |
| `RawSourceRepository` | Raw source and provenance access | `GRDBRawSourceRepository` |
| `ViewService` | Virtual Thread build, Saved View CRUD, Recent Filter | `GRDBViewService` |
| `ImportService` | File parse + DB registration + raw source preservation | `GRDBImportService` |

### Adding a New Repository
1. Define the protocol in `Core/Repositories.swift` with all necessary DTOs.
2. Create `Database/GRDB<Name>Repository.swift` with the GRDB implementation.
3. Add a property to `AppServices` and wire it in `init`.
4. Access from views via `services.<repository>`.

## SQLite Schema Compatibility
- Table names and column names must match the Python version exactly.
- Use `ifNotExists: true` on all `CREATE TABLE` and `CREATE INDEX` statements.
- New columns must be added via `DatabaseMigrator` registered migrations, never by modifying existing migration blocks.
- The FTS5 virtual table `search_idx` uses `tokenize="unicode61"`. Do not change the tokenizer.
- `primary_time` is a derived expression: `COALESCE(NULLIF(TRIM(source_created_at),''), NULLIF(TRIM(imported_at),''), NULLIF(TRIM(date_str),''))`. This precedence order must be consistent across all query paths.

## Import Rules
- Import logic lives in `ImportService` and parser files under `Import/`, not in UI code.
- The UI collects file URLs and passes them to `ImportService.importFiles()`. Nothing else.
- Every text-based import must store a `raw_sources` record with the original text.
- Conversation deduplication uses MD5 hash of `title + full_text`, stored in `conversations.hash`.
- If a conversation already exists (hash collision), update provenance metadata (`model`, `source_file`, `raw_source_id`, `source_created_at`) without overwriting the conversation body.
- Parser format detection follows this order: if `mapping` key exists → ChatGPT; if `chat_messages` → Claude; if `time` + `title` → Gemini; `.md` / `.markdown` suffix → Markdown.

## SwiftUI Rules

### Platform Branching
- Use `#if os(macOS)` / `#if os(iOS)` for platform-specific views.
- macOS uses `NavigationSplitView`. iOS uses `NavigationStack`.
- Shared components go in `Views/Shared/`. Platform-specific views go in `Views/macOS/` or `Views/iOS/`.
- Business logic must not differ between platforms. Only layout and navigation patterns differ.

### State Management
- `AppServices` is `@MainActor` and injected as `@EnvironmentObject`.
- View-local state uses `@State`. Cross-view shared state uses `@Observable` view models if needed.
- Do not store UI state (scroll position, selected tab, expanded/collapsed) in SQLite.
- Navigation state belongs to SwiftUI's `NavigationPath` or `@State`, not to the database.

### Async Patterns
- Repository methods are `async throws`. Call them from `.task {}` modifiers or `Task {}` blocks.
- Never call synchronous GRDB methods from the main thread. Always use `async` wrappers.
- Show `ProgressView` during loading. Show `ContentUnavailableView` for empty or error states.

## Do
- Preserve original metadata before adding convenience transforms.
- Keep body data, view state, cache state, and UI state in separate layers.
- Store Saved Views as filter definitions and related metadata.
- Keep Recent Filters lightweight and bounded.
- Keep Bookmarks independent from body storage and message content.
- Treat search indexes and previews as rebuildable caches.
- Prefer read-only reconstruction of views from canonical data.
- Make data structures easy to inspect with standard tools.
- Prefer archive-browsing features over editing-oriented features.
- Add new data access through repository protocols, not ad hoc SQL in views.
- Use pagination (`offset` + `limit`) for all list queries.
- Keep the SQLite schema compatible with the Python version.

## Don't
- Do not treat normalized text as a full substitute for raw source.
- Do not write UI state or display-only derived strings back into canonical body data.
- Do not overwrite source-created timestamps with import timestamps.
- Do not persist duplicated result bodies for Saved Views, Recent Filters, or Virtual Threads when filter definitions are sufficient.
- Do not add closed, opaque formats when standard formats are sufficient.
- Do not add automatic scoring, ranking, or summary features that frame AI output as authoritative by default.
- Do not `import GRDB` in any file outside `Database/` and `Core/AppServices.swift`.
- Do not write SQL in view files or view model files.
- Do not fetch all rows without `LIMIT`. Every list query must be paginated.
- Do not add SwiftData or Core Data. GRDB is the single database layer.
- Do not rename SQLite tables or columns without a dual-version migration path.
- Do not put import parsing logic in UI code.

## Not Yet
- Do not prioritize aggressive auto-summary pipelines.
- Do not prioritize automatic evaluation or grading of AI outputs.
- Do not turn Madini into a general-purpose editor before archive integrity is strong.
- Do not add convenience features that weaken provenance, portability, or scale resistance.
- Do not optimize display polish at the cost of losing original structure or metadata.
- Do not add iCloud sync before local data integrity is fully verified.
- Do not add Spotlight integration before search repository is complete.

## File Organization Rules
- `Core/` contains protocol definitions and the dependency container. No GRDB types here except in `AppServices.swift`.
- `Database/` contains all GRDB implementations. Every file here starts with `GRDB` prefix.
- `Import/` contains parsers and import orchestration. Each parser is a separate file.
- `Views/Shared/` contains components used on both macOS and iOS.
- `Views/macOS/` and `Views/iOS/` contain platform-specific layouts.
- `Utilities/` contains helpers that do not depend on GRDB or SwiftUI.
- Do not create a `Models/` directory with GRDB-annotated structs. Domain types live in `Core/Repositories.swift` as plain Swift structs. GRDB-specific row mapping lives inside `Database/` implementations.
