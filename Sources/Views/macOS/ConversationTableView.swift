import SwiftUI
#if os(macOS)
import AppKit

/// Multi-column, sortable spreadsheet of every conversation currently
/// passing the sidebar filters. Reached by swiping RIGHT from the
/// plain library list — the opposite end of the horizontal-swipe
/// cascade from Viewer / Focus mode (see `ViewerModeSwipeGesture`).
///
/// **Why a separate view instead of extending `UnifiedConversationListView`.**
/// The normal list is a single-column `List` with inline card layout,
/// optimized for fast browsing. The "table view" the user asked for
/// is a different UX — denser, every field visible at once, sortable
/// by any column. SwiftUI's `Table` gives us that for free (column
/// headers with built-in sort-direction arrows, keyboard column
/// resize, cell-level text selection) at the cost of looking nothing
/// like the card list. Keeping them as two separate views means each
/// can use the control that matches its UX without compromises.
///
/// **Data flow.** Reads `viewModel.conversations` (already filtered by
/// the sidebar) and `viewModel.conversationTags` for per-row tag
/// chips. Rows are wrapped in a local `Row` struct so the
/// `KeyPathComparator` sort path has non-optional, easy-to-compare
/// fields (titles as `String`, dates as `String` for lexicographic
/// ISO sorting, prompt counts as `Int`, tags as comma-joined `String`).
///
/// **Sort persistence.** Selected column + ascending flag live in
/// `@AppStorage`, so reopening the app restores the user's last
/// choice. Stored as primitive types (string + bool) — serializing
/// `KeyPathComparator` directly would be fragile across Swift
/// versions.
///
/// **Opening a row.** Double-click: exit table mode AND open the
/// conversation in the reader tab. The right pane is collapsed in
/// table mode, so "open" is only meaningful if we also leave the
/// mode; otherwise the click would have no visible effect.
struct ConversationTableView: View {
    @Bindable var viewModel: LibraryViewModel
    let tabManager: ReaderTabManager
    /// Called when the user activates a row (double-click or Enter).
    /// The parent (`MacOSRootView`) uses this to flip `viewMode` back
    /// to `.default` so the opened conversation is actually visible in
    /// the reader pane.
    let onExitTableMode: () -> Void

    // MARK: - Persisted sort state

    /// Column id that drives the current sort. Stored as a plain
    /// string so `@AppStorage` can persist it. Kept in sync with the
    /// `sortOrder` binding below on every change.
    @AppStorage("conversationTable.sortColumn") private var sortColumnID: String = SortColumn.date.rawValue
    @AppStorage("conversationTable.sortAscending") private var sortAscending: Bool = false

    @State private var sortOrder: [KeyPathComparator<Row>] = [
        KeyPathComparator(\.dateSortKey, order: .reverse)
    ]

    /// Stable IDs for each sortable column. Raw string values are
    /// what ends up in `@AppStorage` — renaming a case breaks the
    /// persisted preference for existing users, so treat these like
    /// schema keys.
    private enum SortColumn: String {
        case title
        case date
        case model
        case tags
        case promptCount
    }

    /// Composite key for `.task(id:)` — combines the two pieces of
    /// `LibraryViewModel` state that invalidate the bulk-loaded row
    /// set (filter changes shrink/grow the matching rows; sort
    /// changes reorder the page boundaries so previously-loaded
    /// rows now belong to a different page slot).
    private struct TableLoadKey: Hashable {
        let filter: ArchiveSearchFilter
        let sortKey: ConversationSortKey
    }

    /// Multi-selection for contiguous highlighting. The user's
    /// primary action is a double-click (→ `onExitTableMode` + open
    /// in reader), so the selection is mostly a visual anchor while
    /// they browse / sort.
    @State private var selection = Set<String>()

    // MARK: - Rows

    var body: some View {
        // `Table` only *reports* the column-header click back through
        // the `sortOrder` binding — it does not sort the rows for us.
        // Apply the comparator ourselves so clicking a column header
        // actually reorders the visible list. `.sorted(using:)` takes
        // a variadic `Sequence` of comparators; our binding is a
        // single-comparator array so the effective sort key is always
        // the most recently clicked column.
        let rows = buildRows().sorted(using: sortOrder)

        // Active-filter chips used to render above the column headers
        // in this view's own VStack; they've moved to the unified top
        // bar so the full pane height can be devoted to the table.
        //
        // The TableColumnBuilder result for 5 columns with cell
        // closures produces a deeply nested generic type that the
        // Swift type-checker can't resolve within its default time
        // budget. Hoisting the column list into a helper @
        // TableColumnBuilder property with an explicit return type
        // gives the compiler a concrete boundary to solve against,
        // which sidesteps the timeout.
        // Wrap the Table in a `ScrollViewReader` so the title-pulldown
        // reveal hook below can drive `proxy.scrollTo(id)`. SwiftUI
        // `Table` does NOT auto-scroll when its `selection` binding
        // changes programmatically (only on user click), so the older
        // "just set `selection = [id]`" approach highlighted the row
        // off-screen and never moved the scrollview to it. The proxy
        // path works because Table forwards `scrollTo` through its
        // underlying `NSScrollView` when the target id matches a row's
        // `Identifiable.id`.
        ScrollViewReader { proxy in
            Table(rows, selection: $selection, sortOrder: $sortOrder) {
                tableColumns
            }
            // Horizontal swipe → `MiddlePaneMode` cascade is now handled
            // exclusively by the single `ViewerModeSwipeGesture` installed
            // on `MacOSRootView.workspaceSplitView`. The earlier
            // dedicated-to-the-table second monitor was removed because
            // running two monitors over the same event produced double
            // transitions (the "swipe on left pane skips default and
            // jumps to viewer" report). `NSEvent.addLocalMonitorForEvents`
            // runs before the responder chain so Table's internal
            // `NSScrollView` doesn't swallow the event — one monitor at
            // the workspace level is enough.
            .contextMenu(forSelectionType: String.self) { ids in
                if let id = ids.first {
                    Button("開く") { openConversation(id: id) }
                }
            } primaryAction: { ids in
                // Double-click (or Enter) fires the primaryAction closure.
                // Open the first selected row and exit table mode so the
                // opened conversation is actually visible in the reader.
                if let id = ids.first {
                    openConversation(id: id)
                }
            }
            .onAppear { syncSortOrderFromStorage() }
            .onChange(of: sortOrder) { _, newValue in
                persistSortOrder(newValue)
            }
            // Title-pulldown "reveal active conversation" hook. The
            // default card list observes the same key and drives
            // `proxy.scrollTo(id, anchor: .top)`; here we do both —
            // update `selection` so the row carries the standard
            // selection highlight ("you are here"), AND fire
            // `proxy.scrollTo` so the row is actually in the visible
            // region. Defer the scroll one runloop turn so Table has
            // a chance to mount the target row (it's bulk-loaded but
            // still virtualized — the underlying `NSTableView` only
            // realizes rows in the viewport plus a small buffer).
            .onChange(of: viewModel.pendingListScrollConversationID) { _, newValue in
                guard let id = newValue else { return }
                selection = [id]
                Task { @MainActor in
                    try? await Task.sleep(nanoseconds: 30_000_000)
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .center)
                    }
                    viewModel.pendingListScrollConversationID = nil
                }
            }
            // Scroll-on-mount: if this table appears while a
            // conversation is already selected (e.g. the user switched
            // from `.default` → `.table` on a card they were reading),
            // land on that row with selection highlight. The
            // `.onChange` above only fires for changes *after* mount;
            // if the reveal token was raised before this view
            // materialized (which is the common race on mode switch)
            // the scroll request would go unheard.
            //
            // Two things must happen before the scroll can land:
            //   1. The bulk load (`.task(id:)` below) must have paged
            //      in the target row — the table starts with whatever
            //      subset the default list had loaded, which may not
            //      include a row the user scrolled to deep in the set.
            //   2. NSTableView needs a runloop turn after the row
            //      appears to realize it under `proxy.scrollTo`.
            // Poll `conversations` for the id up to ~1.2s, then scroll
            // twice with a gap. A pure sleep-then-scroll missed rows
            // the bulk walk hadn't reached yet.
            .task {
                let id = viewModel.pendingListScrollConversationID
                    ?? viewModel.selectedConversationId
                guard let id else { return }
                for _ in 0..<30 {
                    if viewModel.conversations.contains(where: { $0.id == id }) {
                        break
                    }
                    try? await Task.sleep(nanoseconds: 40_000_000)
                }
                try? await Task.sleep(nanoseconds: 60_000_000)
                selection = [id]
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .center)
                }
                try? await Task.sleep(nanoseconds: 80_000_000)
                proxy.scrollTo(id, anchor: .center)
                if viewModel.pendingListScrollConversationID == id {
                    viewModel.pendingListScrollConversationID = nil
                }
            }
            // Bulk-load every conversation passing the current filters.
            // The normal `List` view pages in 100-at-a-time via a
            // tail-cell `.onAppear` trigger, but SwiftUI `Table` doesn't
            // mount rows the same way — the scroll trigger never fires —
            // and the user wants the table to show every row regardless
            // of scrolling.
            //
            // Keyed on `(filter, sortKey)` so a sidebar checkbox toggle
            // or sort-menu change cancels the in-flight bulk walk and
            // starts a fresh one against the new filter. Without the id
            // key, the task only fired once on first appear —
            // `LibraryViewModel`'s debounced `reloadNow()` would replace
            // `conversations` with just the new filter's first page, and
            // rows that lived past the first page (e.g. "claude" rows
            // under a recent gpt-4o top page) never loaded into the
            // table.
            .task(id: TableLoadKey(filter: viewModel.filter, sortKey: viewModel.sortKey)) {
                await viewModel.loadAllConversations()
            }
            // Guaranteed exit path. The workspace-level
            // `ViewerModeSwipeGesture` — which exits every other mode —
            // relies on an `NSEvent.scrollWheel` local monitor, and
            // SwiftUI's `Table` hands its scroll events to an internal
            // `NSScrollView` whose handling reaches the monitor
            // inconsistently; users report "swipe to go back doesn't
            // work in table mode". Wiring an `onExitCommand` here means
            // the Escape key is always a reliable way out regardless of
            // whether the swipe path triggered.
            .onExitCommand {
                onExitTableMode()
            }
            // Same escape, bound as a keyboard shortcut on an invisible
            // button so it also works before the Table has keyboard
            // focus (Escape via `onExitCommand` requires first-responder
            // status).
            .background(
                Button(action: onExitTableMode) { EmptyView() }
                    .keyboardShortcut(.escape, modifiers: [])
                    .frame(width: 0, height: 0)
                    .opacity(0)
            )
        } // ScrollViewReader
    }

    // MARK: - Columns

    @TableColumnBuilder<Row, KeyPathComparator<Row>>
    private var tableColumns: some TableColumnContent<Row, KeyPathComparator<Row>> {
        TableColumn("タイトル", value: \Row.title) { (row: Row) in
            TitleCell(row: row)
        }
        .width(min: 200, ideal: 360)

        TableColumn("日付", value: \Row.dateSortKey) { (row: Row) in
            DateCell(row: row)
        }
        .width(min: 110, ideal: 160, max: 220)

        TableColumn("モデル", value: \Row.model) { (row: Row) in
            ModelCell(row: row)
        }
        .width(min: 80, ideal: 140, max: 220)

        TableColumn("タグ", value: \Row.tagsSortKey) { (row: Row) in
            TagsCell(row: row)
        }
        .width(min: 100, ideal: 200)

        TableColumn("プロンプト数", value: \Row.promptCount) { (row: Row) in
            PromptCountCell(row: row)
        }
        .width(min: 80, ideal: 100, max: 140)
    }

    // MARK: - Row construction

    private func buildRows() -> [Row] {
        viewModel.conversations.map { summary in
            let tags = (viewModel.conversationTags[summary.id] ?? [])
                .map(\.name)
                .sorted()
            // Model column: prefer the concrete model string when
            // present (e.g. "gpt-5-4-thinking"); fall back to the
            // source brand (e.g. "claude", "gemini") so Claude/Gemini
            // rows aren't all "—". Display text is capitalized when
            // it came from the source so the column doesn't mix
            // lowercase brand names with model version strings.
            let modelDisplay: String
            if let m = summary.model, !m.isEmpty {
                modelDisplay = m
            } else if let s = summary.source, !s.isEmpty {
                modelDisplay = s.capitalized
            } else {
                modelDisplay = "—"
            }
            return Row(
                id: summary.id,
                title: summary.displayTitle,
                dateSortKey: summary.primaryTime ?? "",
                dateDisplay: Self.formatDate(summary.primaryTime),
                model: modelDisplay,
                source: summary.source,
                rawModel: summary.model,
                tags: tags,
                tagsSortKey: tags.joined(separator: ","),
                promptCount: summary.messageCount,
                isBookmarked: summary.isBookmarked
            )
        }
    }

    // MARK: - Actions

    private func openConversation(id: String) {
        // Setting `selectedConversationId` triggers `MacOSRootView`'s
        // `onChange` observer, which resolves the summary and calls
        // `tabManager.openConversation(...)` — same path the normal
        // list uses, so tab-state stays consistent between the two
        // entry points.
        viewModel.selectedConversationId = id
        // Exit table mode so the reader becomes visible. Without
        // this the tab would open behind a zero-width detail column
        // and the user would see nothing change.
        onExitTableMode()
    }

    // MARK: - Sort persistence

    /// Convert the primitive `@AppStorage` values into the comparator
    /// array SwiftUI `Table` binds to. Called once on first appear —
    /// after that, user interactions flow the other direction
    /// (`persistSortOrder` below).
    private func syncSortOrderFromStorage() {
        let column = SortColumn(rawValue: sortColumnID) ?? .date
        let order: SortOrder = sortAscending ? .forward : .reverse
        sortOrder = [comparator(for: column, order: order)]
    }

    /// Decompose the current `KeyPathComparator` back into primitive
    /// storage. The comparator's `keyPath` is `AnyKeyPath`; we match
    /// against the known paths to recover the column identifier.
    private func persistSortOrder(_ order: [KeyPathComparator<Row>]) {
        guard let first = order.first else { return }
        let column = columnID(for: first.keyPath)
        sortColumnID = column.rawValue
        sortAscending = (first.order == .forward)
    }

    private func comparator(for column: SortColumn, order: SortOrder) -> KeyPathComparator<Row> {
        switch column {
        case .title:
            return KeyPathComparator(\Row.title, order: order)
        case .date:
            return KeyPathComparator(\Row.dateSortKey, order: order)
        case .model:
            return KeyPathComparator(\Row.model, order: order)
        case .tags:
            return KeyPathComparator(\Row.tagsSortKey, order: order)
        case .promptCount:
            return KeyPathComparator(\Row.promptCount, order: order)
        }
    }

    private func columnID(for keyPath: AnyKeyPath) -> SortColumn {
        switch keyPath {
        case \Row.title: return .title
        case \Row.dateSortKey: return .date
        case \Row.model: return .model
        case \Row.tagsSortKey: return .tags
        case \Row.promptCount: return .promptCount
        default: return .date
        }
    }

    // MARK: - Date formatting

    /// Collapse the `primaryTime` ISO-ish string down to `YYYY-MM-DD
    /// HH:MM`. Full second / timezone precision isn't useful in a
    /// scannable table. Fallback to the raw string if parsing fails —
    /// better than showing an empty cell.
    private static func formatDate(_ raw: String?) -> String {
        guard let raw, !raw.isEmpty else { return "—" }
        let trimmed = raw.replacingOccurrences(of: "T", with: " ")
        if trimmed.count >= 16 {
            return String(trimmed.prefix(16))
        }
        return trimmed
    }

    // MARK: - Row model

    /// Flattened, non-optional, `Comparable`-friendly projection of a
    /// `ConversationSummary` for the SwiftUI `Table`. Built once per
    /// render inside `buildRows()` — fast because the underlying
    /// summary list is short (pageful, not the whole archive) and the
    /// tag lookup is an O(1) dictionary hit.
    struct Row: Identifiable {
        let id: String
        let title: String
        let dateSortKey: String
        let dateDisplay: String
        /// Display text for the model column — already resolved to a
        /// concrete string (model name, capitalized source brand, or
        /// "—"). This is what the user sees AND sorts on.
        let model: String
        /// Original source brand ("chatgpt" / "claude" / "gemini" / …)
        /// preserved separately so the cell can pick a color even when
        /// `model` came from the source fallback.
        let source: String?
        /// Original model string (nil for source-only rows). Kept so
        /// `SourceAppearance.color(forModel:)` can distinguish e.g.
        /// `gpt-*` from `claude-*` when both would map to the same
        /// source color family.
        let rawModel: String?
        let tags: [String]
        let tagsSortKey: String
        let promptCount: Int
        let isBookmarked: Bool
    }
}

// MARK: - Cell views
//
// Each column's cell lives in its own tiny `View` struct rather than
// inline inside the `Table` builder. SwiftUI's Table builder is a
// result builder that produces a variadic-generic type; feeding it
// five columns with non-trivial inline closures pushes the type
// checker past its time budget ("the compiler is unable to type-check
// this expression in reasonable time"). Extracting cells into named
// structs keeps each closure a one-liner and compiles fast.

private struct TitleCell: View {
    let row: ConversationTableView.Row

    var body: some View {
        Text(row.title)
            .lineLimit(1)
            .truncationMode(.tail)
    }
}

private struct DateCell: View {
    let row: ConversationTableView.Row

    var body: some View {
        Text(row.dateDisplay)
            .foregroundStyle(.secondary)
            .monospacedDigit()
    }
}

/// Color-codes the model column by brand (gpt → green, claude → orange,
/// gemini → blue) so the user can scan services at a glance. Falls back
/// to `.secondary` for unknown entries and the en-dash placeholder.
private struct ModelCell: View {
    let row: ConversationTableView.Row

    var body: some View {
        Text(row.model)
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    private var tint: Color {
        // Prefer the concrete model name for tint resolution — a row
        // with model="gpt-5-4-thinking" should stay green even if its
        // source field happens to be missing.
        if let m = row.rawModel, !m.isEmpty {
            return SourceAppearance.color(forModel: m)
        }
        if let s = row.source, !s.isEmpty {
            return SourceAppearance.color(for: s)
        }
        return .secondary
    }
}

/// Chip-strip rather than comma text — tags already read as chips
/// everywhere else in the UI (sidebar, list card header), so the
/// table should match. `Row.tagsSortKey` (comma-joined) drives the
/// column sort alphabetically; these chips are the prettier
/// presentation of the same data.
private struct TagsCell: View {
    let row: ConversationTableView.Row

    var body: some View {
        if row.tags.isEmpty {
            Text("—")
                .foregroundStyle(.tertiary)
        } else {
            HStack(spacing: 4) {
                ForEach(row.tags, id: \.self) { name in
                    Text("#\(name)")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 1)
                        .background(
                            Capsule().fill(Color.secondary.opacity(0.12))
                        )
                }
            }
            .lineLimit(1)
        }
    }
}

private struct PromptCountCell: View {
    let row: ConversationTableView.Row

    var body: some View {
        Text("\(row.promptCount)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
    }
}

#endif
