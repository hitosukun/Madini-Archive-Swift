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

    @State private var sortOrder: [KeyPathComparator<LibraryConversationRow>] = [
        KeyPathComparator(\.dateSortKey, order: .reverse)
    ]

    /// Local, table-only selection state.
    ///
    /// Earlier revisions bound the `Table` selection to
    /// `viewModel.selectedConversationIDs` — the same set the card
    /// `List` uses. That sharing had a subtle side effect: every
    /// single-click in the table wrote the clicked row's id into the
    /// shared global, which `MacOSRootView` also observes via
    /// `selectedConversationId` (a `.first` shim over the same set).
    /// Depending on the observation order, a plain click could trip
    /// the reader-tab-open path even though the user only wanted to
    /// highlight a row in the grid. Keeping the table's selection
    /// local is sufficient because the "open this conversation"
    /// pathway (double-click / context menu / primaryAction) writes
    /// `viewModel.selectedConversationId` explicitly — the global
    /// only needs to be touched when the user actually asks to open.
    ///
    /// The drag payload still needs to cover multi-row drags, so the
    /// `TableRow.draggable` closure below reads this local set when
    /// composing the dragged id list.
    @State private var tableSelection: Set<String> = []

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

    var body: some View {
        // `Table` only *reports* the column-header click back through
        // the `sortOrder` binding — it does not sort the rows for us.
        // Apply the comparator ourselves so clicking a column header
        // actually reorders the visible list. `.sorted(using:)` takes
        // a variadic `Sequence` of comparators; our binding is a
        // single-comparator array so the effective sort key is always
        // the most recently clicked column.
        let rows = viewModel.conversationRows.sorted(using: sortOrder)

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
            // Explicit-row-builder `Table` init (`Table(of:selection:sortOrder:) { columns } rows: { ... }`)
            // rather than the data-driven `Table(rows, selection:, sortOrder:) { columns }` shorthand,
            // because only the explicit form lets us attach `TableRow.draggable(...)` per row.
            //
            // Why that matters: the cell-level `.draggable` modifier
            // inside a `TableColumn`'s content closure is unreliable
            // — `NSTableView` intercepts `mouseDown` before the cell's
            // SwiftUI gesture recognizer arms, so the drag never
            // starts. `TableRow.draggable` hooks into the row's
            // underlying `NSTableRowView` drag source, which is the
            // path Apple's sample code uses and the only one that
            // actually initiates drags on macOS 14+.
            //
            // `viewModel.draggedConversationIDs(for:)` on the
            // view-model still keys off `selectedConversationIDs` (the
            // card list's global selection), so we compute the drag
            // payload inline here against the table's local selection:
            // if the row under the cursor is part of the current
            // multi-select, drag the whole set; otherwise just the
            // one row.
            Table(of: LibraryConversationRow.self, selection: $tableSelection, sortOrder: $sortOrder) {
                tableColumns
            } rows: {
                ForEach(rows) { row in
                    TableRow(row)
                        .draggable(ConversationDragPayload(
                            ids: tableSelection.contains(row.id)
                                ? Array(tableSelection)
                                : [row.id]
                        ))
                }
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
                tableSelection = [id]
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
            // Three things must happen before the scroll can land:
            //   1. The bulk load (`.task(id:)` below) must have paged
            //      in the target row — the table starts with whatever
            //      subset the default list had loaded, which may not
            //      include a row the user scrolled to deep in the set.
            //   2. NSTableView must have laid out its initial rows.
            //      On first mount this is several hundred ms on large
            //      sets because the Table ingests the whole `rows`
            //      array up front.
            //   3. `proxy.scrollTo` has to run on a tick where the
            //      target id has a realized row — pre-layout calls
            //      are silently dropped.
            // Poll for row presence, then fan out the scroll attempt
            // across a widening schedule (80ms, 200ms, 500ms). Each
            // retry sets selection again so the highlight lands even
            // if only the later attempt wins. One call would be
            // enough if layout timing were predictable, but it isn't
            // — cheaper to fire three times than to pick a magic
            // number and have it fail on slower hardware.
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
                for delayMs: UInt64 in [80, 200, 500] {
                    try? await Task.sleep(nanoseconds: delayMs * 1_000_000)
                    tableSelection = [id]
                    proxy.scrollTo(id, anchor: .center)
                }
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
            // `Table`'s internal `NSScrollView` handles horizontal
            // trackpad swipes aggressively enough that the workspace-
            // level monitor can miss them when focus sits inside the
            // table. Install a table-local monitor here so "left swipe
            // to go back to default mode" still works while the grid is
            // first responder.
            .background(
                TableExitSwipeMonitor(onTrigger: onExitTableMode)
                    .frame(width: 0, height: 0)
                    .allowsHitTesting(false)
            )
        } // ScrollViewReader
    }

    // MARK: - Columns

    @TableColumnBuilder<LibraryConversationRow, KeyPathComparator<LibraryConversationRow>>
    private var tableColumns: some TableColumnContent<LibraryConversationRow, KeyPathComparator<LibraryConversationRow>> {
        // Each cell installs a `TagDragPayload` drop target so the user
        // can drag a tag chip from the sidebar Tags section onto any
        // part of a row and attach it to that conversation. We put the
        // drop on every cell (instead of once per row) because SwiftUI
        // `Table` doesn't expose a row-level `.dropDestination` hook —
        // the only row-level drop API on `TableRowContent` is the
        // reorder-offset variant, which doesn't fit a "drop onto this
        // row" gesture. Per-cell drops give the user the full row as a
        // target: wherever the cursor is when they let go, the cell
        // under the cursor catches the drop and forwards to the same
        // `attachTag` handler keyed by the row's id.
        //
        // Each cell owns a local `@State var isTargeted` for drop
        // highlighting. Coordinating a single "row is targeted" flag
        // across cells would require a shared binding at this view
        // level with custom coalescing (SwiftUI's per-destination
        // isTargeted callback fires on every cursor tick and multiple
        // cells may toggle in/out simultaneously as the cursor
        // crosses column boundaries). Per-cell highlight is visually
        // acceptable: the cell directly under the cursor lights up,
        // which is still a clear "this row will receive the drop"
        // signal.
        TableColumn("タイトル", value: \LibraryConversationRow.title) { (row: LibraryConversationRow) in
            TitleCell(row: row)
                .modifier(RowTagDropModifier { name in attachTag(named: name, to: row.id) })
        }
        .width(min: 200, ideal: 360)

        TableColumn("日付", value: \LibraryConversationRow.dateSortKey) { (row: LibraryConversationRow) in
            DateCell(row: row)
                .modifier(RowTagDropModifier { name in attachTag(named: name, to: row.id) })
        }
        .width(min: 110, ideal: 160, max: 220)

        TableColumn("モデル", value: \LibraryConversationRow.model) { (row: LibraryConversationRow) in
            ModelCell(row: row)
                .modifier(RowTagDropModifier { name in attachTag(named: name, to: row.id) })
        }
        .width(min: 80, ideal: 140, max: 220)

        TableColumn("タグ", value: \LibraryConversationRow.tagsSortKey) { (row: LibraryConversationRow) in
            TagsCell(row: row)
                .modifier(RowTagDropModifier { name in attachTag(named: name, to: row.id) })
        }
        .width(min: 100, ideal: 200)

        TableColumn("プロンプト数", value: \LibraryConversationRow.promptCount) { (row: LibraryConversationRow) in
            PromptCountCell(row: row)
                .modifier(RowTagDropModifier { name in attachTag(named: name, to: row.id) })
        }
        .width(min: 80, ideal: 100, max: 140)
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

    /// Sidebar-tag → table-row drop handler. Mirrors the list side's
    /// `onAttachTag` closure (see `MacOSRootView.conversationRow`),
    /// delegating to the same view-model entry point so tag writes go
    /// through a single persistence path regardless of which surface
    /// the user dropped onto. Fire-and-forget — the Table does not
    /// await the attach and will re-render from the view model's
    /// next `conversationTags` update.
    private func attachTag(named name: String, to conversationID: String) {
        Task {
            await viewModel.attachTag(
                named: name,
                toConversation: conversationID
            )
        }
    }

    // MARK: - Sort persistence

    private func syncSortOrderFromStorage() {
        let column = SortColumn(rawValue: sortColumnID) ?? .date
        let order: SortOrder = sortAscending ? .forward : .reverse
        sortOrder = [comparator(for: column, order: order)]
    }

    private func persistSortOrder(_ order: [KeyPathComparator<LibraryConversationRow>]) {
        guard let first = order.first else { return }
        let column = columnID(for: first.keyPath)
        sortColumnID = column.rawValue
        sortAscending = (first.order == .forward)
    }

    private func comparator(for column: SortColumn, order: SortOrder) -> KeyPathComparator<LibraryConversationRow> {
        switch column {
        case .title:
            return KeyPathComparator(\LibraryConversationRow.title, order: order)
        case .date:
            return KeyPathComparator(\LibraryConversationRow.dateSortKey, order: order)
        case .model:
            return KeyPathComparator(\LibraryConversationRow.model, order: order)
        case .tags:
            return KeyPathComparator(\LibraryConversationRow.tagsSortKey, order: order)
        case .promptCount:
            return KeyPathComparator(\LibraryConversationRow.promptCount, order: order)
        }
    }

    private func columnID(for keyPath: AnyKeyPath) -> SortColumn {
        switch keyPath {
        case \LibraryConversationRow.title: return .title
        case \LibraryConversationRow.dateSortKey: return .date
        case \LibraryConversationRow.model: return .model
        case \LibraryConversationRow.tagsSortKey: return .tags
        case \LibraryConversationRow.promptCount: return .promptCount
        default: return .date
        }
    }
}

private struct TableExitSwipeMonitor: NSViewRepresentable {
    let onTrigger: () -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(onTrigger: onTrigger)
    }

    func makeNSView(context: Context) -> NSView {
        context.coordinator.install()
        return NSView(frame: .zero)
    }

    func updateNSView(_ nsView: NSView, context: Context) {
        context.coordinator.onTrigger = onTrigger
    }

    static func dismantleNSView(_ nsView: NSView, coordinator: Coordinator) {
        coordinator.uninstall()
    }

    final class Coordinator {
        var onTrigger: () -> Void
        private var monitor: Any?
        private var accumulatedDX: CGFloat = 0
        private var accumulatedDY: CGFloat = 0
        private var hasArmedThisGesture = false

        init(onTrigger: @escaping () -> Void) {
            self.onTrigger = onTrigger
        }

        deinit { uninstall() }

        func install() {
            guard monitor == nil else { return }
            monitor = NSEvent.addLocalMonitorForEvents(matching: .scrollWheel) { [weak self] event in
                guard let self else { return event }
                return self.handle(event)
            }
        }

        func uninstall() {
            if let monitor {
                NSEvent.removeMonitor(monitor)
                self.monitor = nil
            }
        }

        private func handle(_ event: NSEvent) -> NSEvent? {
            // This monitor exists only while table mode is mounted, so
            // we don't need an additional "is the table focused?"
            // gate here. In practice that focus check was too brittle:
            // the first responder often sat on an internal clip/scroll
            // view while the user was clearly interacting with the
            // table, so left swipes only produced rubber-banding and
            // never armed the exit transition.
            guard event.hasPreciseScrollingDeltas else {
                return event
            }

            switch event.phase {
            case .began:
                accumulatedDX = event.scrollingDeltaX
                accumulatedDY = event.scrollingDeltaY
                hasArmedThisGesture = false
            case .changed:
                accumulatedDX += event.scrollingDeltaX
                accumulatedDY += event.scrollingDeltaY
            case .ended, .cancelled:
                let armed = hasArmedThisGesture
                accumulatedDX = 0
                accumulatedDY = 0
                hasArmedThisGesture = false
                if armed {
                    DispatchQueue.main.async { [weak self] in
                        self?.onTrigger()
                    }
                }
                return armed ? nil : event
            default:
                return event
            }

            if hasArmedThisGesture {
                return nil
            }

            guard accumulatedDX < 0,
                  abs(accumulatedDX) >= ViewerModeSwipeGesture.triggerThreshold,
                  abs(accumulatedDX) > abs(accumulatedDY) * ViewerModeSwipeGesture.dominanceRatio else {
                return event
            }

            hasArmedThisGesture = true
            return nil
        }
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
    let row: LibraryConversationRow

    var body: some View {
        Text(row.title)
            .lineLimit(1)
            .truncationMode(.tail)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

private struct DateCell: View {
    let row: LibraryConversationRow

    var body: some View {
        Text(row.dateDisplay)
            .foregroundStyle(.secondary)
            .monospacedDigit()
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Color-codes the model column by brand (gpt → green, claude → orange,
/// gemini → blue) so the user can scan services at a glance. Falls back
/// to `.secondary` for unknown entries and the en-dash placeholder.
private struct ModelCell: View {
    let row: LibraryConversationRow

    var body: some View {
        Text(row.model)
            .foregroundStyle(tint)
            .lineLimit(1)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
    let row: LibraryConversationRow

    var body: some View {
        if row.tags.isEmpty {
            Text("—")
                .foregroundStyle(.tertiary)
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
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
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
        }
    }
}

private struct PromptCountCell: View {
    let row: LibraryConversationRow

    var body: some View {
        Text("\(row.promptCount)")
            .monospacedDigit()
            .foregroundStyle(.secondary)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
    }
}

/// Attaches a `TagDragPayload` drop destination to a table cell, with a
/// subtle accent-tinted background while the cell is targeted. Applied
/// per cell (see `tableColumns` in `ConversationTableView`) because
/// SwiftUI `Table` doesn't expose a row-level drop hook for the "drop
/// onto this row" shape (the one on `TableRowContent` is a reorder
/// variant). Each cell keeps its own `isTargeted` so the highlight is
/// self-contained; coordinating a single row-wide flag would require
/// shared mutable state and careful coalescing of the many per-tick
/// isTargeted callbacks SwiftUI fires during a drag.
private struct RowTagDropModifier: ViewModifier {
    let onAttach: (String) -> Void

    @State private var isTargeted: Bool = false

    func body(content: Content) -> some View {
        content
            .background(
                // Inset slightly from the cell edges so adjacent cells'
                // highlights don't butt up against each other into a
                // single continuous bar — keeps the "one cell is the
                // drop target" cue readable.
                RoundedRectangle(cornerRadius: 4, style: .continuous)
                    .fill(Color.accentColor.opacity(isTargeted ? 0.14 : 0))
                    .padding(.horizontal, 1)
                    .padding(.vertical, 1)
            )
            // Animate the accent fade only — nothing layout-affecting.
            // ConversationRowView (the list side's equivalent) explains
            // why layout animation interferes with drop hit-testing.
            .animation(.easeOut(duration: 0.12), value: isTargeted)
            .dropDestination(for: TagDragPayload.self) { payloads, _ in
                guard let first = payloads.first else { return false }
                onAttach(first.name)
                return true
            } isTargeted: { newValue in
                // Coalesce — SwiftUI fires this every cursor-tick with
                // the same value; each write re-runs body and retriggers
                // the animation watcher, which was a visible hitch on
                // tables with dozens of mounted rows.
                if isTargeted != newValue { isTargeted = newValue }
            }
    }
}

#endif
