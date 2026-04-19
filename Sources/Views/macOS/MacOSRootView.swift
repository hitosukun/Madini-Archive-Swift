#if os(macOS)
import SwiftUI
import UniformTypeIdentifiers

struct MacOSRootView: View {
    let services: AppServices
    @State private var libraryViewModel: LibraryViewModel
    @State private var tabManager = ReaderTabManager()
    /// State for the JSON drag-and-drop import flow. `isDropTargeted`
    /// drives the blue highlight overlay rendered during an active hover;
    /// `importToast` drives the short banner that appears at the bottom of
    /// the window summarizing the importer's outcome. Kept here at the root
    /// level (rather than owned by the window-level drop handler) because
    /// the `.task(id: archiveEvents.importRevision)` refresh observer also
    /// wants to touch the toast when a reload completes.
    @State private var isJSONDropTargeted: Bool = false
    @State private var importToast: ImportToast? = nil
    /// Tracks NavigationSplitView column state so children (the middle-pane
    /// header bar in particular) can adjust layout when the sidebar is
    /// collapsed — otherwise the macOS traffic-light buttons overlap the
    /// content column's leading toolbar.
    @State private var columnVisibility: NavigationSplitViewVisibility = .all
    /// Measured height of the single window-spanning top bar. Drives the
    /// top `.safeAreaInset` on every pane underneath so rows can scroll
    /// under the bar and get blurred by its vibrancy material. Variable
    /// because the bar grows a footer row when source-file filter chips
    /// are present.
    @State private var unifiedHeaderBarHeight: CGFloat = WorkspaceLayoutMetrics.headerBarContentRowHeight
    /// Measured height of the sidebar's chrome strip overlay (search +
    /// sort/date + chip flow). Variable because the search field's
    /// glass container expands when active-filter chips wrap. Drives
    /// the sidebar's `safeAreaInset` so the first scrolling row always
    /// sits flush below the strip.
    @State private var sidebarHeaderHeight: CGFloat = WorkspaceLayoutMetrics.headerBarContentRowHeight
        + WorkspaceLayoutMetrics.sidebarControlsRowHeight
    /// Single source of truth for the workspace layout. Replaces the
    /// three mutually-exclusive `is*Active: Bool` flags this view used
    /// to carry separately (`isViewerModeActive` / `isFocusViewerActive`
    /// / `isTableMiddlePaneModeActive`). Having them as one enum prevents
    /// contradictory combinations at the type level and collapses what
    /// used to be three cascading `onChange` hooks into a single
    /// transition handler keyed on `viewMode`. See `MiddlePaneMode` for the
    /// cascade ordering the toolbar picker and horizontal swipe both
    /// walk. Deliberately volatile (no persistence) — focus-mode is
    /// not a preference.
    @State private var viewMode: MiddlePaneMode = .default
    // `selectedPromptID` used to live here as `@State`, but writing to it
    // from the reader's scroll-position observer forced `MacOSRootView` to
    // re-render every scroll tick, which cascaded into content-margin
    // recalculations and flagged SwiftUI's "preference updated multiple
    // times per frame" warning. It now lives on `ReaderTabManager` as an
    // `@Observable` property so only the views that actually read it
    // participate in the re-render. See the property's doc comment there.
    @Environment(ArchiveEvents.self) private var archiveEvents

    init(services: AppServices) {
        self.services = services
        _libraryViewModel = State(
            initialValue: LibraryViewModel(
                conversationRepository: services.conversations,
                searchRepository: services.search,
                bookmarkRepository: services.bookmarks,
                viewService: services.views,
                tagRepository: services.tags
            )
        )
    }

    var body: some View {
        // The loaded/total counter and archive filename used to live in a
        // bottom status bar; both have moved into the left sidebar's Library
        // section (see `UnifiedLibrarySidebar`). Dropping the bar reclaims a
        // row of vertical space in the middle pane — a noticeable win on
        // 13-inch displays.
        workspaceSplitView
        // Window-level JSON drop handler. Sits ABOVE the in-app tag /
        // conversation drop destinations (which live on specific rows
        // further down the view tree) so an external file drag lands
        // here first. Accepting `UTType.fileURL` — not `UTType.json` —
        // because we want the drop handler to fire on any file; we
        // filter to JSONs ourselves inside `handleFileURLDrop(_:)` so
        // the user can see a "only .json files are supported" toast
        // rather than a silent rejection at the drop-zone layer.
        .onDrop(of: [.fileURL], isTargeted: $isJSONDropTargeted) { providers in
            handleFileURLDrop(providers: providers)
            return true
        }
        // Drop-target highlight + result toast live on the same overlay
        // anchor (bottom of the window) so the feedback geometry stays
        // stable as the user drags → drops → waits → sees result.
        .overlay(alignment: .top) {
            if isJSONDropTargeted {
                dropTargetBanner
                    .transition(.move(edge: .top).combined(with: .opacity))
            }
        }
        .overlay(alignment: .bottom) {
            if let toast = importToast {
                ImportToastView(toast: toast)
                    .transition(.move(edge: .bottom).combined(with: .opacity))
                    .padding(.bottom, 24)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isJSONDropTargeted)
        .animation(.easeInOut(duration: 0.2), value: importToast?.id)
        .focusedSceneValue(\.libraryViewModel, libraryViewModel)
        // Make the Library view-model and archive events visible to the
        // right-pane tag editor (`ConversationTagsEditor`) without
        // threading them through ConversationDetailView's API. The
        // detail view stays platform-shared and ignorant of the macOS
        // tag editor; the editor just reads from the env on appear.
        .environment(libraryViewModel)
        .environment(archiveEvents)
        .task {
            await libraryViewModel.loadIfNeeded()
        }
        .task(id: archiveEvents.bookmarkRevision) {
            await libraryViewModel.reload()
        }
        .task(id: archiveEvents.savedViewRevision) {
            await libraryViewModel.reloadSupportingState()
        }
        // Fires after a successful JSON import bumps
        // `archiveEvents.importRevision`. Reloads the main conversation
        // list AND the sidebar's `sourceFileFacets` so the just-imported
        // file appears under archive.db → "Sources" without the user
        // having to restart. The initial run (revision == 0) is a no-op
        // because SwiftUI fires `.task(id:)` on mount; the `guard` below
        // short-circuits that first invocation.
        .task(id: archiveEvents.importRevision) {
            guard archiveEvents.importRevision > 0 else { return }
            await libraryViewModel.reload()
        }
        .onChange(of: libraryViewModel.selectedConversationId) { _, conversationID in
            guard let summary = libraryViewModel.summary(for: conversationID) else {
                return
            }

            tabManager.openConversation(
                id: summary.id,
                title: summary.displayTitle
            )
        }
        // MiddlePaneMode transitions. The sidebar is freely user-
        // controllable in every mode now (per user request: "左サイド
        // バーはいつでも表示と非表示を切り替えていい"), so this handler
        // no longer touches `columnVisibility` — it just kicks off /
        // tears down the viewer-pane detail fetch and triggers the
        // reveal-active-card scroll on entry into Viewer Mode.
        .onChange(of: viewMode) { old, new in
            let wasReading = old == .viewer || old == .hidden
            let isReading = new == .viewer || new == .hidden
            if !wasReading && isReading {
                if let id = tabManager.activeTab?.conversationID {
                    Task { await libraryViewModel.loadViewerConversation(id: id) }
                }
            } else if wasReading && !isReading {
                libraryViewModel.clearViewerData()
            }
            // Entering `.viewer` — the middle pane is now the normal
            // card list (same control as default mode) but it should
            // auto-scroll to the currently-open conversation so the
            // user's active card sits at the top of the visible list.
            // Reveal handles paging in additional rows if the target
            // id has fallen off the currently-loaded window.
            if old != .viewer && new == .viewer,
               let id = tabManager.activeTab?.conversationID {
                Task { await libraryViewModel.revealConversation(id: id) }
            }
        }
        // While in a reading mode, keep the middle-pane outline in sync
        // with whichever tab is active in the reader. (Outside reading
        // modes this is a no-op — the list doesn't read `viewer*` state.)
        .onChange(of: tabManager.activeTab?.conversationID) { _, newID in
            guard viewMode == .viewer || viewMode == .hidden,
                  let newID else { return }
            Task { await libraryViewModel.loadViewerConversation(id: newID) }
            // Viewer mode: keep the middle-pane list pinned to whichever
            // tab the reader is currently showing, so switching tabs via
            // keyboard / prompt popover scrolls the card list along too.
            if viewMode == .viewer {
                Task { await libraryViewModel.revealConversation(id: newID) }
            }
        }
        // Tab-switch reset for `selectedPromptID` now lives inside
        // `ReaderTabManager.openConversation(…)` itself, so no onChange
        // is needed here — clearing is atomic with the tab change, which
        // also eliminates a brief window where the new tab would appear
        // with a highlight pointing at a prompt from the previous one.
    }

    // MARK: - JSON drag-and-drop import

    /// Banner shown over the top of the window while a drag is hovering.
    /// Keeps the visual contract simple — tell the user we'll import
    /// `.json` files and that anything else is ignored.
    private var dropTargetBanner: some View {
        Text("Drop .json files to import into archive.db")
            .font(.callout.weight(.medium))
            .foregroundStyle(.white)
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(
                Capsule(style: .continuous)
                    .fill(Color.accentColor.opacity(0.88))
            )
            .overlay(
                Capsule(style: .continuous)
                    .stroke(Color.white.opacity(0.25), lineWidth: 0.5)
            )
            .padding(.top, 48)
            .shadow(color: .black.opacity(0.15), radius: 8, y: 2)
            .allowsHitTesting(false)
    }

    /// Resolve each dragged provider into a URL, filter to .json, then hand
    /// the batch to `JSONImporter`. Runs entirely as a fire-and-forget
    /// `Task` so the `.onDrop` closure can return `true` immediately.
    private func handleFileURLDrop(providers: [NSItemProvider]) {
        // Per-provider URL loading is async (the system may have to
        // materialize the file or fetch promise metadata). Gather a
        // single array of URLs, dropping failures.
        Task { @MainActor in
            var urls: [URL] = []
            for provider in providers {
                if let url = await loadFileURL(from: provider) {
                    urls.append(url)
                }
            }

            // Filter to `.json` files by extension. Pathextension check is
            // enough — we rely on the Python importer to detect whether
            // the contents are ChatGPT/Claude/Gemini/etc. If the user
            // drops a `.txt` or `.md` alongside the jsons, reject only
            // the non-json entries and import the rest.
            let jsonURLs = urls.filter { $0.pathExtension.lowercased() == "json" }
            let rejectedCount = urls.count - jsonURLs.count

            guard !jsonURLs.isEmpty else {
                if rejectedCount > 0 {
                    showToast(.failure(
                        message: "Only .json files can be imported.",
                        detail: nil
                    ))
                }
                return
            }

            showToast(.progress(message: "Importing \(jsonURLs.count) file\(jsonURLs.count == 1 ? "" : "s")…"))

            do {
                // Actual shell-out runs on a detached background task so
                // the importer's blocking IO doesn't pin the main actor.
                let result = try await Task.detached(priority: .userInitiated) {
                    try await JSONImporter.importFiles(jsonURLs)
                }.value

                if result.exitCode == 0 {
                    archiveEvents.didImportConversations()
                    let summary = rejectedCount > 0
                        ? "Imported \(jsonURLs.count) file\(jsonURLs.count == 1 ? "" : "s"), skipped \(rejectedCount) non-JSON."
                        : "Imported \(jsonURLs.count) file\(jsonURLs.count == 1 ? "" : "s")."
                    showToast(.success(message: summary))
                } else {
                    // Non-zero exit: importer ran but the Python side
                    // reported an error. Surface a short tail of stderr
                    // so the user has a pointer to the cause (full
                    // output is still in Console.app as stderr lines).
                    let tail = result.stderr
                        .split(separator: "\n")
                        .suffix(2)
                        .joined(separator: " ")
                    showToast(.failure(
                        message: "Import failed (exit \(result.exitCode)).",
                        detail: tail.isEmpty ? nil : String(tail)
                    ))
                }
            } catch {
                showToast(.failure(
                    message: "Import couldn't start.",
                    detail: error.localizedDescription
                ))
            }
        }
    }

    /// Async wrapper around `NSItemProvider.loadItem(forTypeIdentifier:…)`
    /// for the `public.file-url` UTI. Returns nil when the provider
    /// doesn't carry a file URL (e.g. a text-only drag from a browser).
    private func loadFileURL(from provider: NSItemProvider) async -> URL? {
        guard provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) else {
            return nil
        }
        return await withCheckedContinuation { (cont: CheckedContinuation<URL?, Never>) in
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                // The system delivers the URL as either `URL`, `NSURL`,
                // or a serialized `Data` blob depending on where the
                // drag originated. Accept each form.
                if let url = item as? URL {
                    cont.resume(returning: url)
                } else if let nsurl = item as? NSURL {
                    cont.resume(returning: nsurl as URL)
                } else if let data = item as? Data,
                          let url = URL(dataRepresentation: data, relativeTo: nil) {
                    cont.resume(returning: url)
                } else {
                    cont.resume(returning: nil)
                }
            }
        }
    }

    /// Replace whatever toast is currently on screen and schedule a fade
    /// for success/failure toasts. Progress toasts have no timeout — they
    /// hang on screen until a subsequent `showToast(_:)` replaces them.
    private func showToast(_ toast: ImportToast) {
        importToast = toast
        let autoDismissSeconds: Double?
        switch toast.kind {
        case .progress: autoDismissSeconds = nil
        case .success: autoDismissSeconds = 3.2
        case .failure: autoDismissSeconds = 5.0
        }
        guard let delay = autoDismissSeconds else { return }
        let capturedID = toast.id
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: UInt64(delay * 1_000_000_000))
            // Only dismiss if the current toast is still the one we scheduled
            // for — otherwise a later toast's timer would kill it too early.
            if importToast?.id == capturedID {
                importToast = nil
            }
        }
    }

    private var workspaceSplitView: some View {
        NavigationSplitView(columnVisibility: $columnVisibility) {
            librarySidebar
        } content: {
            libraryContentPane
                .ignoresSafeArea(.container, edges: .top)
                // In focus sub-mode the middle column collapses to zero
                // width so only the detail pane remains visible. macOS's
                // `NavigationSplitViewVisibility.detailOnly` does NOT
                // reliably hide the middle column of a 3-column split
                // view (it fights back and the sidebar reappears), so
                // we drive the collapse via column width instead — the
                // column technically still exists, but occupies 0pt and
                // is therefore invisible.
                //
                // Table mode: the content column hosts the full-width
                // spreadsheet and the detail column is collapsed to 0 —
                // but without lifting the default `contentMaxWidth` cap
                // (560pt) the middle pane refuses to expand beyond that,
                // leaving a huge dead strip between the table and the
                // right window edge. Lift min/ideal/max to generous
                // values in this mode so the table absorbs all available
                // horizontal space.
                .navigationSplitViewColumnWidth(
                    min: viewMode == .hidden ? 0
                        : viewMode == .table ? WorkspaceLayoutMetrics.contentMinWidth
                        : WorkspaceLayoutMetrics.contentMinWidth,
                    ideal: viewMode == .hidden ? 0
                        : viewMode == .table ? 1200
                        : WorkspaceLayoutMetrics.contentIdealWidth,
                    max: viewMode == .hidden ? 0
                        : viewMode == .table ? .infinity
                        : WorkspaceLayoutMetrics.contentMaxWidth
                )
        } detail: {
            rightPane
                .ignoresSafeArea(.container, edges: .top)
                // Table mode: collapse the reader pane to zero width so
                // the middle (table) pane absorbs the full remaining
                // space. Same column-width trick used for focus mode on
                // the content column above — macOS 3-column
                // `NavigationSplitView` is unreliable at hiding a
                // column via `columnVisibility`, but 0-width works.
                // Non-table values fall back to generous bounds that
                // mirror the system default (no explicit constraint).
                .navigationSplitViewColumnWidth(
                    min: viewMode == .table ? 0 : 320,
                    ideal: viewMode == .table ? 0 : 720,
                    max: viewMode == .table ? 0 : .infinity
                )
        }
        // Single window-spanning top bar. Always mounted over all three
        // columns regardless of mode — the bar's outer shell (height,
        // padding, divider) never changes so swipe transitions no
        // longer produce toolbar-rebuild jitter. See
        // `UnifiedWorkspaceTopBar` for the slot-structure and mode-
        // specific content switch.
        .overlay(alignment: .top) {
            UnifiedWorkspaceTopBar(
                viewMode: $viewMode,
                tabManager: tabManager,
                sidebarIsCollapsed: columnVisibility != .all,
                conversations: libraryViewModel.conversations,
                onSelectConversation: { id in
                    // Same path as a click in the middle-pane list
                    // (and the table view's open-row handler):
                    // mutating `selectedConversationId` triggers
                    // `MacOSRootView.onChange` which resolves the
                    // summary and asks `tabManager` to open it. Keeps
                    // the reader-tab lifecycle in one place.
                    libraryViewModel.selectedConversationId = id
                },
                onDoubleTapBlankArea: scrollAllPanesToTop
            )
            // Same rationale as the pane contents: each column ignores
            // top safe area so content can extend under the titlebar,
            // and the NavigationSplitView itself does NOT, so the
            // overlay has to ignore top safe area explicitly to sit
            // flush at window y=0.
            .ignoresSafeArea(.container, edges: .top)
        }
        .onPreferenceChange(HeaderBarHeightPreferenceKey.self) { newHeight in
            unifiedHeaderBarHeight = newHeight
        }
        // Trackpad / mouse swipe → toggle Viewer Mode. Lives on the
        // workspace split view (not on a single pane) so the gesture
        // works regardless of which pane the user happens to be over,
        // matching the toolbar button — which is also reachable from
        // anywhere — as a parallel input path. See
        // `ViewerModeSwipeGesture` for the threshold/dominance
        // rationale and platform branches. `canEnter` mirrors the
        // toolbar button's gate so a swipe-to-enter without an active
        // tab is a no-op (same as clicking the disabled button); exits
        // are always allowed regardless.
        .viewerModeSwipeGesture(
            viewMode: $viewMode,
            canEnterViewer: tabManager.activeTab != nil
        )
    }

    /// Double-tap on the unified top bar's blank chrome → snap each
    /// pane back to the top. Window-chrome convention (matches macOS
    /// app titlebars / browser tab bars where double-clicking blank
    /// chrome jumps content to the top).
    ///
    /// Coverage today:
    ///   * Right pane (reader) — via `tabManager.scrollToTopToken`.
    ///   * Middle pane in Viewer Mode — same token (`ViewerModePane`
    ///     observes it for its prompt-directory scroll).
    ///   * Middle pane in default list mode — via
    ///     `pendingListScrollConversationID`, set to the first card.
    ///
    /// Not yet covered: Table mode (SwiftUI `Table` lacks a clean
    /// programmatic scroll API) and the left sidebar (already
    /// short enough that scrolling rarely matters). Both can be
    /// added later without changing this entry point.
    private func scrollAllPanesToTop() {
        tabManager.scrollToTopToken = UUID()
        if let firstID = libraryViewModel.conversations.first?.id {
            libraryViewModel.pendingListScrollConversationID = firstID
        }
    }

    private var libraryContentPane: some View {
        // The window-spanning `UnifiedWorkspaceTopBar` floats above
        // every pane via an overlay on `workspaceSplitView`, so this
        // pane has no local header bar anymore. Content still extends
        // under the bar (each column ignores the top safe area), and
        // the bar's measured height comes back via
        // `HeaderBarHeightPreferenceKey` to drive the top inset below.
        Group {
            if viewMode == .table {
                // Table mode: the middle pane becomes a full-width
                // spreadsheet of every conversation passing the
                // current sidebar filters. The right (reader) pane is
                // collapsed to zero width in the split-view config so
                // the table owns the full content area.
                ConversationTableView(
                    viewModel: libraryViewModel,
                    tabManager: tabManager,
                    topContentInset: unifiedHeaderBarHeight,
                    onExitTableMode: { viewMode = .default }
                )
            } else if viewMode == .hidden {
                // Focus sub-mode: middle column is collapsed via
                // `columnVisibility = .detailOnly`, but macOS's 3-column
                // NavigationSplitView can still fleetingly render this
                // pane during the transition (and, in some build
                // variants, keeps reserving a narrow strip for it even
                // after the visibility flip). Rendering `Color.clear`
                // here guarantees the user never sees a flash of the
                // old prompt-list content under the new toolbar.
                Color.clear
            } else if viewMode == .viewer {
                // Viewer mode: middle pane swaps the card list for a
                // flat prompt-directory index of the active reader
                // tab's conversation. Clicking a row asks the reader
                // (right pane) to jump to that prompt.
                ViewerModePane(
                    viewModel: libraryViewModel,
                    tabManager: tabManager,
                    conversationID: tabManager.activeTab?.conversationID,
                    topContentInset: unifiedHeaderBarHeight
                )
            } else {
                // Default mode: standard card list. Active filter
                // chips no longer render here — they live inside the
                // sidebar's expanded search container.
                UnifiedConversationListView(
                    viewModel: libraryViewModel,
                    topContentInset: unifiedHeaderBarHeight,
                    onTapTag: { tag in
                        libraryViewModel.toggleBookmarkTag(tag.name)
                    }
                )
            }
        }
        // Fade content passing under the floating toolbar strip AND off
        // the bottom edge so rows dissolve into the chrome instead of
        // hitting a hard edge. Skip the edge fades in table mode — the
        // table's column headers live at the top edge and must render
        // crisp; a top fade would wash them out. The table renders its
        // own bottom scroll-overshoot inset internally.
        .edgeFadeMask(
            top: viewMode == .table ? 0 : WorkspaceLayoutMetrics.topFadeHeight,
            bottom: viewMode == .table ? 0 : WorkspaceLayoutMetrics.bottomFadeHeight
        )
    }

    private var rightPane: some View {
        ReaderWorkspaceView(
            tabManager: tabManager,
            repository: services.conversations,
            topContentInset: unifiedHeaderBarHeight
        )
    }

    private var librarySidebar: some View {
        // Floating-search-bar layout. Previously the sidebar was a
        // VStack(search, scroll) which stacked opaque rows and left no
        // visible window material at the top. Now the ScrollView fills
        // the column and the search bar rides as a frosted overlay at
        // the top — same pattern as the middle pane's filter bar and
        // the right pane's reader toolbar. Rows scroll up under the
        // search band and blur, which gives the whole sidebar the same
        // "openness" the other two columns get.
        UnifiedLibrarySidebar(
            viewModel: libraryViewModel,
            dataSource: services.dataSource
        )
        // Reserve space for the sidebar chrome strip (search field
        // with embedded chip flow + sort/date row). Driven by the
        // overlay's measured height so the inset grows when active-
        // filter chips wrap into multiple rows inside the search
        // container.
        .safeAreaInset(edge: .top, spacing: 0) {
            Color.clear
                .frame(height: sidebarHeaderHeight)
                .allowsHitTesting(false)
        }
        .overlay(alignment: .top) {
            // Finder-pattern top strip: search field (which doubles as
            // the active-filter chip host) on the row that aligns with
            // the unified top bar, then the narrow-the-results
            // controls (sort + date) directly below. Both rows are
            // sidebar-local — they operate on the middle pane via
            // `LibraryViewModel`, so they belong with the sidebar's
            // other filtering chrome.
            VStack(spacing: 0) {
                SidebarSearchBar(
                    viewModel: libraryViewModel,
                    activeFilterChips: libraryViewModel.activeFilterChips,
                    onClearChip: libraryViewModel.clearFilterChip
                )
                .padding(.horizontal, WorkspaceLayoutMetrics.paneHorizontalPadding)
                .frame(minHeight: WorkspaceLayoutMetrics.headerBarContentRowHeight)

                HStack(spacing: WorkspaceLayoutMetrics.headerBarInteriorSpacing) {
                    LibraryListSortMenu(viewModel: libraryViewModel)
                    HeaderDateRangePicker(viewModel: libraryViewModel)
                    Spacer(minLength: 0)
                }
                .padding(.horizontal, WorkspaceLayoutMetrics.paneHorizontalPadding)
                .frame(height: WorkspaceLayoutMetrics.sidebarControlsRowHeight)
            }
            .frame(maxWidth: .infinity)
            .background(
                GeometryReader { proxy in
                    Color.clear.preference(
                        key: SidebarHeaderHeightPreferenceKey.self,
                        value: proxy.size.height
                    )
                }
            )
        }
        .onPreferenceChange(SidebarHeaderHeightPreferenceKey.self) { newValue in
            sidebarHeaderHeight = newValue
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(
            min: WorkspaceLayoutMetrics.sidebarMinWidth,
            ideal: WorkspaceLayoutMetrics.sidebarIdealWidth,
            max: WorkspaceLayoutMetrics.sidebarMaxWidth
        )
    }

}

private struct UnifiedLibrarySidebar: View {
    @Bindable var viewModel: LibraryViewModel
    let dataSource: AppServices.DataSource
    @State private var expandedSources: Set<String> = []
    /// Separate expanded state for the archive.db entry so it doesn't collide
    /// with source-facet ids (they share the `expandedSources` key space
    /// otherwise via string overlap).
    @State private var archiveFileListExpanded: Bool = false
    /// Top-level section headers the user has collapsed. Stored as a Set
    /// (rather than the inverse "expanded" set) so sections default to
    /// expanded on first launch — a new user isn't greeted by a sidebar
    /// full of collapsed headers.
    @State private var collapsedSections: Set<String> = []

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                section(title: "Library") {
                    SidebarSelectionRow(
                        title: "All",
                        count: viewModel.overallCount,
                        systemImage: "tray.full",
                        tint: .secondary,
                        isSelected: true
                    ) {
                        // No-op: the All/Bookmarks split was removed when the
                        // bookmark concept folded into Tags. Kept as a header
                        // affordance so the sidebar still has a "Library" entry.
                    }

                    // Replaces the old bottom status bar. Tapping the disclosure
                    // arrow reveals one checkbox per imported JSON file so the
                    // user can narrow the library to a specific import batch.
                    archiveDataSourceRow
                }

                section(title: "Sources") {
                    ForEach(viewModel.sourceFacets) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                SidebarCheckboxRow(
                                    title: source.value,
                                    count: source.count,
                                    // Icon retired: the service's brand
                                    // color lives on the title text itself
                                    // now (green/orange/blue). Row reads
                                    // as colored type instead of colored
                                    // glyph + neutral type.
                                    systemImage: nil,
                                    tint: SourceAppearance.color(for: source.value),
                                    isSelected: source.isSelected,
                                    action: {
                                        viewModel.toggleSource(source.value)
                                        expandedSources.insert(source.value)
                                    }
                                )

                                Button {
                                    toggleSourceExpansion(source.value)
                                } label: {
                                    Image(systemName: expandedSources.contains(source.value) ? "chevron.down" : "chevron.right")
                                        .font(.caption2.weight(.bold))
                                        .foregroundStyle(.secondary)
                                        .frame(width: 16, height: 16)
                                }
                                .buttonStyle(.plain)
                            }

                            if expandedSources.contains(source.value) {
                                VStack(alignment: .leading, spacing: 4) {
                                    ForEach(source.models) { model in
                                        SidebarCheckboxRow(
                                            title: model.value,
                                            count: model.count,
                                            // Model rows inherit their
                                            // parent service's brand color
                                            // via the title text (no glyph).
                                            // Visually links the model back
                                            // to its parent source row
                                            // above — "claude-3-5-sonnet"
                                            // reads orange under a "claude"
                                            // row painted orange, the
                                            // relationship is obvious.
                                            systemImage: nil,
                                            tint: SourceAppearance.color(for: source.value),
                                            isSelected: model.isSelected,
                                            compact: true,
                                            action: {
                                                viewModel.toggleModel(model.value)
                                            }
                                        )
                                        .padding(.leading, 24)
                                    }
                                }
                            }
                        }
                    }
                }

                // Filters section (dates + roles + Clear) removed: the roles
                // filter is retired; the date range was relocated into the
                // middle-pane header popover for proximity to the sort bar.

                // Tags + Filters wrapped in `section(title:)` so they get
                // the same collapse/expand behavior as Library and
                // Sources. Each section's view intentionally no longer
                // draws its own "TAGS" / "FILTERS" header — the wrapper
                // owns the title now so the stack reads as one family of
                // collapsibles down the sidebar.
                section(title: "Tags") {
                    SidebarTagsSection(libraryViewModel: viewModel)
                }

                // "Saved View" name input removed. Pinning is now the way to
                // promote a recent filter into a persistent view.
                if !viewModel.unifiedFilters.isEmpty {
                    // Suppress the whole section when there are no saved
                    // entries — otherwise the user would be greeted by an
                    // empty collapsible "FILTERS" header with nothing
                    // under it.
                    section(title: "Filters") {
                        SavedFiltersSection(
                            entries: viewModel.unifiedFilters,
                            onSelect: { entry in viewModel.applySavedFilter(entry) },
                            onTogglePin: { entry in
                                viewModel.togglePinned(entry)
                                archiveEvents.didChangeSavedViews()
                            },
                            onDelete: { entry in
                                viewModel.deleteFilterEntry(entry)
                                archiveEvents.didChangeSavedViews()
                            }
                        )
                    }
                }
            }
            .padding(12)
        }
        // Drop the ScrollView's own opaque backdrop so the translucent
        // window material we install via `TranslucentWindowBackground`
        // shows through the sidebar. Without this the ScrollView paints
        // a solid fill and the column stays opaque despite the window
        // being clear.
        .scrollContentBackground(.hidden)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            expandedSources = Set(viewModel.sourceFacets.map(\.value))
        }
    }

    @Environment(ArchiveEvents.self) private var archiveEvents

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        let isCollapsed = collapsedSections.contains(title)
        VStack(alignment: .leading, spacing: 8) {
            // Tappable header row — disclosure chevron + title act as a
            // single hit target. `contentShape(Rectangle())` makes the
            // trailing `Spacer` also clickable so the user can hit
            // anywhere along the header band, not just on the text.
            Button {
                if isCollapsed {
                    collapsedSections.remove(title)
                } else {
                    collapsedSections.insert(title)
                }
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: isCollapsed ? "chevron.right" : "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .frame(width: 10)
                    Text(title)
                        .font(.caption)
                        .textCase(.uppercase)
                    Spacer()
                }
                .foregroundStyle(.secondary)
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            if !isCollapsed {
                content()
            }
        }
    }

    @ViewBuilder
    private func compactField<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(title)
                .font(.caption2)
                .foregroundStyle(.secondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private func toggleSourceExpansion(_ source: String) {
        if expandedSources.contains(source) {
            expandedSources.remove(source)
        } else {
            expandedSources.insert(source)
        }
    }

    @ViewBuilder
    private var archiveDataSourceRow: some View {
        // The data source row is expandable only when there are enumerable
        // files (i.e. `.database`). For `.mock` the pill still renders but
        // tapping it is a no-op and no chevron is drawn.
        let isExpandable = !viewModel.sourceFileFacets.isEmpty

        VStack(alignment: .leading, spacing: 6) {
            // Entire pill row acts as the expansion hit target — previously
            // only the small trailing chevron was tappable, which was an
            // unforgiving target. Wrapping everything in a single Button
            // means clicking anywhere on the "archive.db  5 / 619" band
            // toggles the file list below.
            Button {
                guard isExpandable else { return }
                archiveFileListExpanded.toggle()
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: archiveIconName)
                        .foregroundStyle(archiveTint)
                    Text(archiveDisplayName)
                        .font(.body)
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer(minLength: 4)
                    Text("\(viewModel.conversations.count) / \(viewModel.totalCount)")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()

                    // Disclosure chevron lives inside the same Button so it
                    // stays visually aligned with the row label. It's now
                    // an indicator rather than the only hit target.
                    if isExpandable {
                        Image(systemName: archiveFileListExpanded ? "chevron.down" : "chevron.right")
                            .font(.caption2.weight(.bold))
                            .foregroundStyle(.secondary)
                            .frame(width: 12)
                    }
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(archiveHelpText)

            if archiveFileListExpanded, !viewModel.sourceFileFacets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(viewModel.sourceFileFacets) { file in
                        SidebarCheckboxRow(
                            title: file.displayName,
                            count: file.count,
                            systemImage: "doc.text",
                            // Brown matches the `.sourceFile` active-
                            // filter chip + saved-filter icon, and stays
                            // distinct from the three LLM brand colors
                            // (green/orange/blue) so import files never
                            // read as a service.
                            tint: .brown,
                            isSelected: file.isSelected,
                            compact: true,
                            action: {
                                viewModel.toggleSourceFile(file.path)
                            }
                        )
                        .padding(.leading, 24)
                        .help(file.path)
                    }
                }
            }
        }
    }

    private var archiveIconName: String {
        switch dataSource {
        case .database: "externaldrive.fill"
        case .mock: "shippingbox"
        }
    }

    private var archiveTint: Color {
        switch dataSource {
        case .database: .green
        case .mock: .orange
        }
    }

    private var archiveDisplayName: String {
        switch dataSource {
        case .database(let path):
            let component = (path as NSString).lastPathComponent
            return component.isEmpty ? path : component
        case .mock:
            return "Mock Data"
        }
    }

    private var archiveHelpText: String {
        switch dataSource {
        case .database(let path):
            return path
        case .mock:
            return "In-memory preview fixtures"
        }
    }

}

private struct SidebarSelectionRow: View {
    let title: String
    let count: Int
    let systemImage: String
    let tint: Color
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            rowBody
                .padding(.horizontal, 10)
                .padding(.vertical, 7)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(isSelected ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.06))
                .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private var rowBody: some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }
}

private struct SidebarCheckboxRow: View {
    let title: String
    let count: Int
    /// Optional leading glyph. Pass `nil` for "text-only" rows where the
    /// title itself carries the visual hook via `tint` (e.g. the source
    /// rows after the per-service SF Symbol was retired — the word
    /// "chatgpt" is painted green directly instead of sitting next to a
    /// green bubble glyph). When non-nil the row behaves as before: glyph
    /// in `tint`, title in `.primary`.
    let systemImage: String?
    let tint: Color
    let isSelected: Bool
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                if let systemImage {
                    Image(systemName: systemImage)
                        .foregroundStyle(tint)
                        .font(compact ? .caption : .body)
                }

                Text(title)
                    .font(compact ? .subheadline : .body)
                    // When no leading glyph exists, the tint migrates onto
                    // the title text itself so the row still conveys its
                    // service/kind at a glance.
                    .foregroundStyle(systemImage == nil ? tint : .primary)
                    .lineLimit(1)

                Spacer()

                Text("\(count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            .padding(.vertical, compact ? 3 : 5)
        }
        .buttonStyle(.plain)
    }
}

private struct RoleGrid: View {
    let selectedRoles: Set<MessageRole>
    let onToggle: (MessageRole) -> Void

    private let columns = [
        GridItem(.flexible(minimum: 80), spacing: 8),
        GridItem(.flexible(minimum: 80), spacing: 8),
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 8) {
            ForEach([MessageRole.user, .assistant, .tool, .system], id: \.rawValue) { role in
                Button {
                    onToggle(role)
                } label: {
                    Text(role.displayName)
                        .font(.caption)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .frame(maxWidth: .infinity)
                        .background(selectedRoles.contains(role) ? Color.accentColor.opacity(0.18) : Color.secondary.opacity(0.08))
                        .foregroundStyle(selectedRoles.contains(role) ? Color.accentColor : .secondary)
                        .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
                }
                .buttonStyle(.plain)
            }
        }
    }
}

private struct UnifiedConversationListView: View {
    @Bindable var viewModel: LibraryViewModel
    /// Top content inset — reserves vertical room above the first row so it
    /// isn't permanently hidden under the floating header bar overlay.
    /// Passed in from the parent which measures the bar's height at runtime.
    var topContentInset: CGFloat = WorkspaceLayoutMetrics.headerBarContentRowHeight
    let onTapTag: (TagEntry) -> Void

    var body: some View {
        Group {
            if viewModel.isLoading && viewModel.conversations.isEmpty {
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if let errorText = viewModel.errorText {
                ContentUnavailableView(
                    "Couldn’t Load Conversations",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else if viewModel.conversations.isEmpty {
                ContentUnavailableView(
                    viewModel.hasActiveFilters ? "No Results" : "No Conversations",
                    systemImage: viewModel.hasActiveFilters ? "line.3.horizontal.decrease.circle" : "tray",
                    description: Text(viewModel.hasActiveFilters ? "Try clearing the current filters." : "No conversations found.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // Multi-select: using `selectedConversationIDs` (Set) drives
                // the native Cmd/Shift-click multi-select for the card list.
                // The detail pane / keyboard nav still peek at the scalar
                // `selectedConversationId` (which returns `.first`), which
                // is good enough when the user is picking one card; when
                // they've selected many, none of the scalar consumers fire
                // anything noisy — the primary purpose of multi-select is
                // dragging a batch to a sidebar tag (see SidebarTagRow's
                // drop destination, which now loops over payloads).
                // Wrap in ScrollViewReader so external requests (the
                // right-pane header's conversation-title button) can
                // scroll the list back to the currently-open card. The
                // proxy drives `proxy.scrollTo(id, anchor: .top)` keyed
                // on the `.tag(conversation.id)` assigned per row.
                ScrollViewReader { proxy in
                List(viewModel.conversations, selection: $viewModel.selectedConversationIDs) { conversation in
                    ConversationRowView(
                        conversation: conversation,
                        tags: viewModel.conversationTags[conversation.id] ?? [],
                        onTapTag: onTapTag,
                        onAttachTag: { tagName in
                            Task {
                                await viewModel.attachTag(
                                    named: tagName,
                                    toConversation: conversation.id
                                )
                            }
                        }
                    )
                    // NOTE: `.equatable()` was tried here for tag-drop perf,
                    // but it caused intermittent "card click doesn't open"
                    // — `List` with a `selection:` binding does not play
                    // well with `EquatableView` wrapping its rows. The
                    // optimization isn't worth the broken primary action.
                    .tag(conversation.id)
                    .id(conversation.id)
                    .onAppear {
                        Task {
                            await viewModel.loadMoreIfNeeded(currentItem: conversation)
                        }
                    }
                }
                // Hide the List's built-in opaque backdrop so the top header
                // bar's vibrancy material has something to blur against
                // (whatever shows through from the pane/window behind it).
                .scrollContentBackground(.hidden)
                // `.contentMargins(.top, X, for: .scrollContent)` is the
                // "correct" API for this on ScrollView, but macOS List
                // reliably IGNORES it and places its first row at the
                // pane's top edge — exactly behind the overlay header bar,
                // which is how the user sees cards disappearing under the
                // bar. `.safeAreaInset(edge: .top)` reserves space through
                // a path List *does* honor: it shrinks the scroll region
                // from above and draws the inset content (an invisible
                // Color.clear) in that reserved band. The header-bar
                // overlay sits in front of that band, so the List's first
                // row is flush with the bar's bottom edge and never
                // occluded.
                .safeAreaInset(edge: .top, spacing: 0) {
                    // Reserve room for the unified top bar so the
                    // List's first row sits flush with the bar's
                    // bottom edge instead of being hidden behind it.
                    Color.clear
                        .frame(height: topContentInset)
                        .allowsHitTesting(false)
                }
                // Mirror the top inset at the bottom so the last row can
                // scroll UP past the bottom-fade zone and be read at
                // full opacity. Without this the final card's title
                // sits permanently under the fade mask.
                .safeAreaInset(edge: .bottom, spacing: 0) {
                    Color.clear
                        .frame(height: WorkspaceLayoutMetrics.bottomFadeHeight)
                        .allowsHitTesting(false)
                }
                .overlay(alignment: .bottom) {
                    if viewModel.isLoadingMore {
                        ProgressView()
                            .padding()
                    }
                }
                // External scroll requests (e.g. tapping the reader
                // header's title pill). Clears the request after
                // applying so setting the same id twice still fires
                // both times.
                .onChange(of: viewModel.pendingListScrollConversationID) { _, newValue in
                    guard let id = newValue else { return }
                    withAnimation(.easeInOut(duration: 0.2)) {
                        proxy.scrollTo(id, anchor: .top)
                    }
                    Task { @MainActor in
                        viewModel.pendingListScrollConversationID = nil
                    }
                }
                } // ScrollViewReader
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct SearchSavedFiltersSection: View {
    let recentFilters: [SavedFilterEntry]
    let savedViews: [SavedViewEntry]
    let onSelect: (SavedFilterEntry) -> Void
    let onDeleteSavedView: (SavedViewEntry) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if !recentFilters.isEmpty {
                filterGroup(title: "Recent Filters", entries: recentFilters, allowDelete: false)
            }

            if !savedViews.isEmpty {
                filterGroup(title: "Saved Views", entries: savedViews, allowDelete: true)
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    @ViewBuilder
    private func filterGroup(title: String, entries: [SavedFilterEntry], allowDelete: Bool) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.headline)

            ForEach(entries) { entry in
                ZStack(alignment: .topTrailing) {
                    Button {
                        onSelect(entry)
                    } label: {
                        VStack(alignment: .leading, spacing: 2) {
                            Text(entry.name)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)
                            Text(summaryText(for: entry.filters))
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(10)
                    }
                    .buttonStyle(.plain)
                    .contentShape(RoundedRectangle(cornerRadius: 10))

                    if allowDelete {
                        Button {
                            onDeleteSavedView(entry)
                        } label: {
                            Image(systemName: "trash")
                        }
                        .buttonStyle(.plain)
                        .foregroundStyle(.secondary)
                        .padding(10)
                    }
                }
                .background(Color.secondary.opacity(0.08))
                .clipShape(RoundedRectangle(cornerRadius: 10))
            }
        }
    }

    private func summaryText(for filters: ArchiveSearchFilter) -> String {
        filters.summaryText
    }
}

/// Finder-style segmented picker mounted as an `NSToolbarItem` in the
/// window title bar (`MacOSRootView.workspaceSplitView`'s `.toolbar`).
/// Four glyph segments — テーブル / デフォルト / ビューアー / フォーカス —
/// matching the ordering of `MiddlePaneMode`'s cascade left-to-right so the
/// control reads the same way the trackpad swipe feels. Always visible
/// across all four modes; no disabled states — the cascade accepts any
/// target, and writing a mode with no active conversation just lands
/// the user in an empty reader pane, same as the swipe path.
///
/// Rendered with `.pickerStyle(.segmented)` so macOS paints the
/// standard segment chrome + selection highlight — this is the whole
/// point of the "use Finder's familiar design" user ask, we just lean
/// on the built-in segmented control rather than rolling our own.
/// Not private: mounted by `UnifiedWorkspaceTopBar` at the trailing
/// edge of the window-spanning top bar. The picker occupies a fixed
/// slot in every view mode so its x-coordinate stays stable as the
/// user cascades through table → default → viewer → focus.
struct MiddlePaneModePicker: View {
    @Binding var selection: MiddlePaneMode

    var body: some View {
        Picker("View Mode", selection: $selection) {
            ForEach(MiddlePaneMode.allCases) { mode in
                Image(systemName: mode.systemImage)
                    .help(mode.displayName)
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .help("ビュー切替")
    }
}

// MARK: - Import toast

/// One-shot banner model for the JSON DnD import flow.
///
/// `id` is a fresh `UUID` per instance so replacing an earlier toast with
/// a later one (even of the same kind/message) still retriggers the
/// `.transition` animation — without it, `.animation(value:)` on the
/// parent doesn't see a change and the re-run would pop in without a
/// fade. The auto-dismiss scheduler also uses `id` to verify it's
/// dismissing the toast it originally targeted (vs. a newer one the
/// user triggered before the timer fired).
struct ImportToast: Identifiable, Equatable {
    enum Kind: Equatable {
        case progress
        case success
        case failure(detail: String?)
    }

    let id: UUID = UUID()
    let kind: Kind
    let message: String

    static func progress(message: String) -> ImportToast {
        ImportToast(kind: .progress, message: message)
    }

    static func success(message: String) -> ImportToast {
        ImportToast(kind: .success, message: message)
    }

    static func failure(message: String, detail: String?) -> ImportToast {
        ImportToast(kind: .failure(detail: detail), message: message)
    }
}

private struct ImportToastView: View {
    let toast: ImportToast

    var body: some View {
        HStack(spacing: 10) {
            leadingGlyph
            VStack(alignment: .leading, spacing: 2) {
                Text(toast.message)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                if case .failure(let detail) = toast.kind, let detail, !detail.isEmpty {
                    // Show the last line or two of Python stderr so the
                    // user has a pointer to the cause. Clipped to a
                    // single line + truncated — full output remains in
                    // Console.app.
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(.regularMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .shadow(color: .black.opacity(0.18), radius: 10, y: 4)
        .allowsHitTesting(false)
    }

    @ViewBuilder
    private var leadingGlyph: some View {
        switch toast.kind {
        case .progress:
            // ProgressView renders as a tiny indeterminate spinner — the
            // ideal "working on it" cue for a short-lived shell-out.
            ProgressView()
                .controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(.green)
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
        }
    }
}

#endif
