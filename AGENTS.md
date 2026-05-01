# Madini Repository Rules

## Design Philosophy
Madini is a local archive browser for long-term accumulation of LLM logs.
It is not primarily an editor, an auto-summary tool, or a judgment engine.
Its main purpose is to support rereading, exploration, comparison, and reconstruction over time.

This is the SwiftUI implementation, and **it is the canonical user-facing application**. macOS is the primary platform; iOS and other platforms are derived from this codebase. The repository is a mono-repo: the Swift app under `Sources/` and a Python importer core under `Python/` ship together. Python's role is bounded — it parses provider export JSON (Claude / ChatGPT / Gemini) and writes to `archive.db`. The Swift app is read-only against `archive.db` and owns the schema. Schema decisions are made on Swift's terms; the Python importer is updated to match. An older standalone Python prototype historically lived at `~/Madini_Dev` and that path remains as a last-resort fallback in the importer driver, but the in-repo `Python/` copy is canonical going forward.

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
- The SQLite schema is owned by the Swift codebase. Breaking changes are allowed when they serve the Mac-first design, as long as `DatabaseMigrator` migrations upgrade existing Swift databases. The Python importer (`Python/`) is updated in the same change to match — the in-repo Python core is treated as a co-located worker, not an independent product. Legacy Python-era databases (from before the mono-repo) may still be ingested via a one-way import migration.

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
| `StatsRepository` | Bounded aggregations for the Dashboard / `.stats` mode (source / model / monthly / daily / hour×weekday). Pure derived view — no caching, no persisted intermediates. | `GRDBStatsRepository` |
| `RawSourceRepository` | Raw source and provenance access | `GRDBRawSourceRepository` |
| `ViewService` | Virtual Thread build, Saved View CRUD, Recent Filter | `GRDBViewService` |
| `ImportService` | File parse + DB registration + raw source preservation | `GRDBImportService` |

WHERE-clause assembly is centralized in `Database/SearchFilterSQL.swift` so the conversation-list, search, and Stats paths translate `ArchiveSearchFilter` through one helper. Add new repositories with the same call pattern (`SearchFilterSQL.makeWhereClause(filter:options:)`) to keep filter semantics consistent across the codebase.

### Adding a New Repository
1. Define the protocol in `Core/Repositories.swift` with all necessary DTOs.
2. Create `Database/GRDB<Name>Repository.swift` with the GRDB implementation.
3. Add a property to `AppServices` and wire it in `init`.
4. Access from views via `services.<repository>`.

## SQLite Schema Evolution
- The Swift codebase owns the schema. Table and column names may be changed or added as the design demands, but every change must ship with a `DatabaseMigrator` registered migration that upgrades in place.
- Use `ifNotExists: true` on all `CREATE TABLE` and `CREATE INDEX` statements so bootstrap stays idempotent.
- Never modify an already-released migration block. Add a new migration instead — migrator ordering is how we preserve upgrade paths for existing users.
- The FTS5 virtual table `search_idx` tokenizer is a deliberate design choice, not a compatibility freeze. Changing it (or the column set) requires: (1) a new migration that rebuilds the index from `conversations` + `messages`, (2) UI progress feedback for large libraries (10x–100x today's scale), and (3) an updated spec note describing why the change was made.
- `primary_time` is a derived expression: `COALESCE(NULLIF(TRIM(source_created_at),''), NULLIF(TRIM(imported_at),''), NULLIF(TRIM(date_str),''))`. This precedence order must be consistent across all query paths.
- Legacy Python-era databases (pre-mono-repo) may be ingested via a one-way import migration. The live schema is owned by Swift; the in-repo Python importer is updated in lock-step rather than driving schema changes from its side.

## Import Rules
- The Swift app is read-only against `archive.db`. All write-side parsing and ingestion lives in the Python importer at `Python/` (`split_chatlog.py` + `archive_store.py`).
- Drag-and-drop in the Swift UI shells out to the Python importer via `JSONImporter` (see `Sources/Services/JSONImporter.swift`). Resolution priority for the importer directory: `MADINI_IMPORTER_DIR` env var → `Python/` inside the app bundle (for `.app` builds) → `Python/` relative to the working directory (for `swift run` from the repo) → `~/Madini_Dev` (legacy fallback).
- Every text-based import must store a `raw_sources` record with the original text.
- Conversation deduplication uses MD5 hash of `title + full_text`, stored in `conversations.hash`.
- If a conversation already exists (hash collision), update provenance metadata (`model`, `source_file`, `raw_source_id`, `source_created_at`) without overwriting the conversation body.
- Parser format detection (in the Python core) follows this order: if `mapping` key exists → ChatGPT; if `chat_messages` → Claude; if `time` + `title` → Gemini; `.md` / `.markdown` suffix → Markdown.
- Schema-shaping changes (new column, new block kind in `messages.content_json`, new provider) ship as a single change touching both `Database/GRDB*.swift` (Swift read path + migration) and `Python/` (writer). Do not land one side without the other.

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

## Localization
- **Two languages: English (source) and Japanese.** `developmentLanguage` is `en` in `project.yml`; `Info.plist` declares `CFBundleLocalizations = ("en", "ja")`. Any other system locale falls back to English. The fallback is the *source* language — i.e. the bare strings written in `Text("...")` literals — which is why we treat English as the canonical form even when a piece of UI was originally drafted in Japanese.
- **String Catalog (`Sources/Resources/Localizable.xcstrings`) is the single source of truth.** No `*.lproj/Localizable.strings`, no per-language directory. The catalog is compiled into `en.lproj/Localizable.strings` and `ja.lproj/Localizable.strings` at build time by Xcode's Strings Catalog compiler — verified by `LOCALIZATION_PREFERS_STRING_CATALOGS = YES` in the target's base settings.
- **Key naming follows SwiftUI literal style.** The English string itself is the catalog key — e.g. `Text("Add tag")` looks up `"Add tag"` in the catalog and returns "タグを追加" under the `ja` localization. Don't introduce structured keys like `tag.action.add` unless you have a specific reason (key collisions, very long literals); Apple's tooling and the SwiftUI auto-extraction flow assume the literal-as-key convention.
- **For non-`Text(...)` call sites use `String(localized: "...")`.** Plain-`String` returning code (e.g. `var subtitle: String { ... }`, NSWindow titles, AppKit toolbar labels, alert titles fed to `.failed("...")` enum cases) does NOT auto-localize. Wrap the literal in `String(localized: ...)` so the same key is registered in the catalog. `LocalizedStringKey`-typed properties (e.g. `IdentityPreferenceRole.sectionTitle`) are the alternative when the value is consumed by a SwiftUI initializer that accepts `LocalizedStringKey`.
- **Resources directory is a group, not a folder reference.** `project.yml` has `Sources/Resources` listed without `type: folder` so each file is processed by the matching Build Rule. With `type: folder` the catalog is bundled uncompiled and `LocalizedStringKey` lookups silently miss at runtime — verified empirically. Keep this in mind when adding new resource directories.
- **Coverage at public release.**
  - **Done (P0):** all hardcoded Japanese strings in Swift have been replaced with English literals + ja translations in the catalog (~95 keys). Files touched: `IdentityPreferencesStore`, `IdentityPreferencesView`, `ConversationTagsEditor`, `ConversationTableView`, `ReaderWorkspaceView`, `MessageBubbleView`, `ArchiveInspectorFilePreviewPane`, `TextPreviewWindow`, `RawTranscriptImageView`, `MiddlePaneMode`, `StatsContentPane`, `DesignMockRootView` (search prompt + find bar), `ConversationDetailView` (export menu), `ForeignLanguageBlockView`.
  - **Done (P1):** menu bar — every command in `MadiniArchiveApp.AppCommands` is registered in the catalog (~21 keys covering the View, Library, Archive, Find, and File > Close items).
  - **Done (Python):** importer print statements (`split_chatlog.py`, `archive_store.py`) rewritten to neutral English. Auto-generated Gemini titles (`Geminiの記録` → `Gemini log`), filter description fallbacks (`すべての会話` → `All conversations`), and date-range separators (`〜` → `–`) all converted. Non-translated content matchers (`"自分"` Markdown role keyword, `"送信したメッセージ"` Gemini parser, `"マイアクティビティ"` Google Takeout filename) deliberately retained — they pattern-match real export content, not UI strings.
- **Pending (post-public-release).**
  - **P2 (≈80 strings):** UI surfaces beyond the dev-language alignment — `DesignMockRootView` empty states & sort controls, `MacOSRootView` drop zone & reader picker, `ArchiveInspectorPane` snapshot deletion alerts, `MessageBubbleView` avatar tooltips & pin controls. These are already English in source, but no ja translations exist yet — Japanese locale shows English fallback.
  - **P3 (≈50 strings):** search filters, saved views, identity preferences additional fields — same status as P2.
  - **P4 (≈20 strings):** `.help(...)` tooltips throughout. Lowest priority because they only surface on hover.
  - **iOS root (`IOSRootView.swift`, ≈18 strings):** iOS UI is not yet shipped; localize when iOS is brought online.
  - **Python output structuring:** today the Swift app captures Python stdout/stderr verbatim and surfaces it in toasts. Both Python output and the Swift toast surface are English-only. A future change should restructure `split_chatlog.py` to emit machine-readable status (e.g. JSON lines `{"level":"info","key":"imported_count","value":3}`), let `JSONImporter.swift` parse those, and look up the localized message via the catalog. This lets Japanese locale show `「{N} 件の会話を取り込みました」` while keeping Python provider-agnostic.
- **When adding a new UI string.** Use a `Text("...")` / `Button("...")` / `Label("...", systemImage: ...)` literal if you can — SwiftUI auto-localizes via `LocalizedStringKey`. For `String`-returning code paths, use `String(localized: "...")`. After the next build, open `Sources/Resources/Localizable.xcstrings` in Xcode and add the `ja` translation; alternatively edit the JSON directly in the form documented in this file's git history. The catalog is plain JSON — no Xcode required to author.

## Reader Typography
- **The reader pane (`MessageBubbleView`) is the right-pane conversation viewer.** Its typography was originally tuned for Japanese-only content, then audited and selectively widened for English when localization landed. The audit lives in commit history; the rules below capture the persistent decisions.
- **Done at public release (Phase 1 of the typography hardening).**
  - **Long-URL wrapping** — `Sources/Views/Shared/LineBreakHints.softWrap(_:inMarkdown:)` injects zero-width spaces (`U+200B`) after path-like delimiters (`/ . - _ ? & = : ; , # @`) inside non-CJK runs longer than 24 characters. Applied at `paragraphView`, `headingView`, `listItemView`, `blockquoteView`, `CodeBlockView`, and `TableBlockView.cellText`. The markdown-aware variant (default) skips `[label](url)` link bodies and `<https://…>` autolinks so URL targets stay clickable; code blocks call the verbatim variant (`inMarkdown: false`). The ZWSPs are invisible at render time but give CoreText break opportunities CoreText otherwise won't take inside Latin tokens. Tradeoff: ZWSPs come along when copying text — acceptable for an archive viewer; the alternative was visible bubble overflow on English URLs.
  - **Heading padding** — `MessageBubbleView.headingView` uses `padding(.top, level <= 2 ? 8 : 4)` and `padding(.bottom, 4)` (was `6/2` and `2`) so English headings with ascenders / descenders (H, l, g, y) clear the next paragraph.
  - **Table cell padding** — `TableBlockView` cells use `padding(.vertical, 8)` (was `6`) so descenders clear the row separator.
  - **Ordered list marker width** — `listItemView` uses `frame(minWidth: ordered ? 28 : 14)` (was `22`) so `100.` fits at the body font size.
- **Pending (Phase 2, post-public release).**
  - Consider bumping `bodyFontSize` from 15 to 16 if English readers report eye strain. Japanese is fine at 15; the change would be locale-conditional or universal.
  - Add a small left padding inside the blockquote container so English italic text doesn't sit directly on the accent bar.
  - Tune `ConversationDetailView.swift`'s `Divider().padding(.vertical, 12)` (~line 215) up to 14 or so if English prompt-divider density feels cramped at scale.
- **Pending (Phase 3, future / advanced).**
  - **Locale-aware `lineSpacing`.** Today the reader uses `Layout.bodyLineSpacing = 5` applied uniformly via `scaledBodyLineSpacing`. This was tuned against Japanese prose. For English-only locales 3–4 might read cleaner. Implementation would thread `Locale.current.language.languageCode` (or an environment value derived from it) through `MessageBubbleView` and pick the constant per-language. **Note for the implementer:** the Phase-1 audit mistakenly reported "no explicit `.lineSpacing` in the reader" — actually `Layout.bodyLineSpacing = 5` exists and is applied at `paragraphView`, `listItemView`, `blockquoteView`, etc. Use that as the canonical baseline when introducing a locale-aware variant.
  - **Per-script font sizing.** Detect CJK characters in a message body (Hiragana / Katakana / CJK Unified Ideographs ranges) and pick `15.5pt` for CJK-dominant content vs `16pt` for Latin-dominant — CJK glyphs are optically heavier and 15.5pt CJK ≈ 16pt Latin for perceived weight.
  - **URL auto-link with middle truncation.** Detect bare URLs in prose (currently only markdown-link syntax becomes clickable) and render via SwiftUI `Link` with `truncationMode(.middle)` so `https://example.com/very/long/path/file.swift` shows as `https://example.com/…/file.swift`. Less aggressive than ZWSP injection but only applies to recognizable URLs.
- **Why ZWSP and not other approaches.** SwiftUI's `Text` on macOS does not expose `.lineBreakMode(.byCharWrapping)` (the API is iOS-only via UIKit). `Text.lineBreakStrategy` exposes `.standard` / `.pushOut` / `.hangulWordPriority`, none of which break inside non-CJK Latin tokens. `Text.allowsTightening(true)` shrinks letter spacing rather than wrapping. `Text.minimumScaleFactor(...)` font-shrinks the entire run. Markdown-stage rewriting would require a full custom parser since `AttributedString(markdown:)` runs after our string is already built. ZWSP injection is the cheapest robust mechanism that survives across SwiftUI's `Text` rendering, and the markdown-aware skips preserve URL fidelity for clickable links.
- **Adding a new render path?** If you introduce a new block type (e.g. callouts, footnote refs, embedded media captions) and it accepts user-controlled text, route the input through `LineBreakHints.softWrap(_:)` at the call site. Markdown-aware path is the default; pass `inMarkdown: false` only for verbatim content like code or pre-tokenized strings.

## Window Model
- **Madini is single-window by design.** The main conversation surface (`WindowGroup` in `MadiniArchiveApp.swift`) is intended to run as exactly one window at a time. File > "New Window" / ⌘N is disabled by replacing SwiftUI's `.newItem` command group with a single anchor "Close" Button. The File menu is preserved in the menu bar so macOS HIG / accessibility tooling has something to inspect.
- **File menu shape (3 items): Close (anchor) + Close (AppKit auto) + Close All (AppKit auto).** All three dispatch to `NSWindow.performClose(_:)` against the key window, so the visible duplication is functionally inert — pressing any of them, or ⌘W from anywhere, closes the window. The shape is not the canonical macOS one (which would be just "Close" + "Close All"), but it is what SwiftUI's command system actually produces given the constraints below.
- **Why we don't suppress the duplicate.** The duplicate Close arises because `.newItem` non-emptiness is what keeps the File menu visible AND what causes AppKit to auto-inject its standard Close + Close All. A series of attempts to clean up the surplus item were tried and discarded — see the inline note in `MadiniAppDelegate.applicationDidFinishLaunching` for the full record:
  - Empty `.newItem { }` (no anchor) — collapses the entire File menu, including AppKit's auto pair.
  - `.commandsRemoved()` on the WindowGroup — does not remove AppKit's auto pair.
  - Anchor with `Divider()` / hidden Button / `Button("")` — same collapse as empty.
  - Post-launch `NSApp.mainMenu` surgery to `removeItem(anchor)` — SwiftUI's reactive command system reacts within a few seconds by removing the entire File menu top-level item from `mainMenu.items`, which is worse than the duplicate.
  - Post-launch surgery using `anchor.isHidden = true` — SwiftUI un-hides on next rebuild (or AppKit ignores `isHidden` for items with `keyEquivalent`), so the anchor reappears.
  - Re-running surgery on `NSMenuDelegate.menuNeedsUpdate(_:)` — does not help because by the time the user clicks File, SwiftUI may already have removed the menu from the bar.
- **This is the bottom of the SwiftUI/AppKit constraint.** SwiftUI's reactive ownership of items it publishes via `Commands` is fundamental and cannot be safely mutated from AppKit without provoking a rebuild that removes more than we wanted. The 3-item File menu is the cleanest stable state reachable today. If a future SwiftUI release exposes a public way to keep `.newItem` non-empty while suppressing the SwiftUI-side item — or to remove AppKit's auto-injected Close pair declaratively — the anchor and this entire note should be revisited.
- **Why single-window:** the per-window isolation that SwiftUI's `WindowGroup` provides today is incidental — `AppServices`, `ArchiveEvents`, `IntakeService`, `IdentityPreferencesStore`, and `BodyTextSizePreference` are all held at the App level (single instance shared across windows), while `DesignMockRootView`'s `@State` / `@StateObject` happen to be per-window. The arrangement works, but only because nobody's hit a case where the assumed sharing pattern (single DB queue, single intake watcher, app-wide preferences) collides with the assumed isolation pattern (per-window selection, layout, search). Rather than maintain that boundary by accident — and rather than commit to per-window-isolating those services — we narrow the surface to one main window. This also matches the SwiftUI-migration decision to drop browser-tab-style multiplicity, and it lines up with the convention for archive viewers on macOS (Console.app, Disk Utility).
- **Allowed exceptions:** the `Settings` Scene (⌘,) is a separate, system-managed window and is preserved. Ad-hoc helper windows constructed directly via `NSWindow(contentViewController:)` for one-off previews — currently `RawTranscriptImageView` (image gallery) and `TextPreviewWindow` (head-truncated text preview) — are also allowed; they are short-lived, read-only, and do not host the main conversation surface.
- **Changing this policy requires real work, not just unbinding ⌘N.** If a future change wants multiple main windows, `AppServices` / `ArchiveEvents` / `IntakeService` need an explicit per-window-vs-app-wide review (which DB queue does each window own? does the intake watcher run once or per-window? do bookmark notifications cross windows?). Add a follow-up section to this rule before re-enabling `.newItem`.

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
- Evolve the SQLite schema through `DatabaseMigrator` migrations, with a legacy-import path when older databases exist.

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
- Do not rename or drop SQLite tables / columns without a `DatabaseMigrator` migration.
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
