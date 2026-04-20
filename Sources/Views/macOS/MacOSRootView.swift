#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

struct MacOSRootView: View {
    private static let collapsedSplitColumnWidth: CGFloat = 1

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
        // Window chrome: intentionally left at SwiftUI defaults.
        //
        // We previously configured `toolbarStyle = .unifiedCompact`
        // and `titlebarAppearsTransparent = true` here, but the
        // resulting window pushed the toolbar up over the sidebar
        // column boundary (sidebar toggle floated above the sidebar,
        // content clipped by translucent chrome). The root cause
        // wasn't narrowed down to a single flag — either of the two
        // interacts oddly with `NavigationSplitView`'s own layout
        // assumptions on the current SDK.
        //
        // Minimal-config baseline: no style tweaks. If a scroll-
        // driven material / separator effect is wanted later, add it
        // via an explicit scroll observer rather than the AppKit-
        // automatic path (which depends on `.fullSizeContentView`,
        // shown to break `NavigationSplitView` here).
        //
        // `WindowConfigurator` itself is kept for future AppKit
        // tweaks that don't disturb the split view (traffic-light
        // behavior, window appearance, etc.).
        //
        // `titleVisibility = .hidden` suppresses the "MadiniArchive"
        // title string that macOS otherwise renders between the
        // traffic-light cluster and the toolbar items. The breadcrumb
        // (`ReaderHeaderActivityPill`) already communicates "what
        // you're looking at" at a finer granularity, so the global app
        // title is redundant and competes with the centered toolbar
        // cluster for chrome real estate. This is the minimally
        // invasive NSWindow setting — unlike `titlebarAppearsTransparent`
        // or `toolbarStyle = .unifiedCompact` (both tried previously,
        // both broke `NavigationSplitView`'s sidebar layout on the
        // current SDK), `.titleVisibility` only hides the label and
        // leaves AppKit's titlebar / toolbar geometry untouched.
        .background(WindowConfigurator(configure: Self.applyWindowChrome))
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
        // Trash-drop undo toast. Distinct overlay from `importToast`
        // above so each has its own transition / z-order — stacking
        // them in a single overlay branch would cause one to abort the
        // other's transition when both change at the same time. The
        // toast sits slightly above the import-toast anchor so a rare
        // race (import finishes while undo window is still open) keeps
        // both visible instead of the later one clipping the earlier.
        .overlay(alignment: .bottom) {
            if let snapshot = libraryViewModel.pendingTrashUndo {
                TrashUndoToast(
                    snapshot: snapshot,
                    onUndo: {
                        Task { await libraryViewModel.undoTrashPurge() }
                    },
                    onDismiss: {
                        libraryViewModel.dismissTrashUndo()
                    }
                )
                .transition(.move(edge: .bottom).combined(with: .opacity))
                .padding(.bottom, 72)
            }
        }
        .animation(.easeInOut(duration: 0.18), value: isJSONDropTargeted)
        .animation(.easeInOut(duration: 0.2), value: importToast?.id)
        .animation(.easeInOut(duration: 0.2), value: libraryViewModel.pendingTrashUndo)
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
            let wasReading = old == .viewer || old == .focus
            let isReading = new == .viewer || new == .focus
            if !wasReading && isReading {
                if let id = tabManager.activeTab?.conversationID {
                    Task { await libraryViewModel.loadViewerConversation(id: id) }
                }
            } else if wasReading && !isReading {
                libraryViewModel.clearViewerData()
            }
            // Switching into any list-bearing middle-pane mode should
            // land the user on the currently-active conversation with
            // its card already highlighted and scrolled into view. All
            // three list modes (`.default`, `.table`, `.viewer`) read
            // `pendingListScrollConversationID` off the view model, so
            // `revealConversation(id:)` routes to whichever list just
            // mounted — and pages in the target row if it had fallen
            // off the currently-loaded window. `.focus` is skipped
            // because there's no list to scroll. For `.viewer` the
            // active id lives on the reader tab; for the other two it
            // lives on `selectedConversationId`, so we pick whichever
            // is non-nil (both should usually be set).
            if old != new && new != .focus {
                let activeID = libraryViewModel.selectedConversationId
                    ?? tabManager.activeTab?.conversationID
                if let id = activeID {
                    Task { await libraryViewModel.revealConversation(id: id) }
                }
            }
        }
        // While in a reading mode, keep the middle-pane outline in sync
        // with whichever tab is active in the reader. (Outside reading
        // modes this is a no-op — the list doesn't read `viewer*` state.)
        .onChange(of: tabManager.activeTab?.conversationID) { _, newID in
            guard viewMode == .viewer || viewMode == .focus,
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
                // In focus sub-mode the middle column collapses to a
                // near-zero sliver so only the detail pane remains
                // visible. We intentionally use `1pt`, not `0pt`:
                // asking AppKit to animate a split item between
                // "collapsed to zero" and a normal width can leave the
                // old `NSSplitViewItem.MaxSize == 0` constraint alive
                // for one pass while the new minimum-width constraint is
                // already installed, producing the red unsatisfiable-
                // constraint logs seen during swipe transitions.
                //
                // Table mode: the content column hosts the full-width
                // spreadsheet and the detail column is collapsed to the
                // same near-zero sliver —
                // but without lifting the default `contentMaxWidth` cap
                // (560pt) the middle pane refuses to expand beyond that,
                // leaving a huge dead strip between the table and the
                // right window edge. Lift min/ideal/max to generous
                // values in this mode so the table absorbs all available
                // horizontal space.
                .navigationSplitViewColumnWidth(
                    min: Self.collapsedSplitColumnWidth,
                    ideal: viewMode == .focus ? Self.collapsedSplitColumnWidth
                        : viewMode == .table ? 1200
                        : WorkspaceLayoutMetrics.contentIdealWidth,
                    max: viewMode == .focus ? Self.collapsedSplitColumnWidth
                        : viewMode == .table ? .infinity
                        : WorkspaceLayoutMetrics.contentMaxWidth
                )
        } detail: {
            rightPane
                // Table mode: collapse the reader pane to the same
                // near-zero sliver so
                // the middle (table) pane absorbs the full remaining
                // space. Same column-width trick used for focus mode on
                // the content column above — macOS 3-column
                // `NavigationSplitView` is unreliable at hiding a
                // column via `columnVisibility`, but a 1pt width avoids
                // the transient `MaxSize == 0` conflicts AppKit emits on
                // swipe-driven transitions. Non-table values fall back
                // to generous bounds that mirror the system default.
                .navigationSplitViewColumnWidth(
                    min: Self.collapsedSplitColumnWidth,
                    ideal: viewMode == .table ? Self.collapsedSplitColumnWidth : 720,
                    max: viewMode == .table ? Self.collapsedSplitColumnWidth : .infinity
                )
        }
        // Window toolbar — the single home for window-chrome controls.
        //
        // Responsibility split:
        //   * `.navigation`: navigation bar (sort chip + title +
        //     prompt pulldown). Placed on the leading edge so it
        //     flows rightward from the sidebar toggle without the
        //     symmetric-reservation cost that `.principal` (center)
        //     imposes on the trailing cluster.
        //   * `.primaryAction`: share button (standalone) + mode
        //     picker (a real `NSSegmentedControl` wrapped as one
        //     `NSToolbarItem`). See `MiddlePaneModePicker`.
        //
        // `.toolbarBackground(.automatic, for: .windowToolbar)` is
        // set explicitly (rather than left implicit) so the chrome
        // behavior is pinned to the SwiftUI-default unified-toolbar
        // rendering for this window. We do NOT touch `NSWindow`
        // (`toolbarStyle`, `titlebarAppearsTransparent`, style mask)
        // — that path broke `NavigationSplitView`'s sidebar layout
        // on the current SDK. Any scroll-driven material / separator
        // work will go in a separate pane-internal observer, not via
        // the AppKit-automatic titlebar path.
        .toolbar(id: "workspace") {
            // Sort pulldown + cascade breadcrumb, grouped in the same
            // `.principal` slot so they read as one centered navigation
            // cluster (sort chip on the left, breadcrumb on the right).
            //
            // The sort pulldown used to live in the sidebar's
            // search-row area; the user wanted it promoted into window
            // chrome. First pass put it in a separate
            // `.navigation`-placed ToolbarItem, which planted it at the
            // far-leading edge — past the window title / sidebar toggle
            // — far away from the breadcrumb it semantically belongs
            // next to. Folding both into the same principal item lets
            // macOS center the whole cluster and keeps sort adjacent
            // to the breadcrumb regardless of window width.
            // Navigation cluster (sort + breadcrumb). Placed in
            // `.navigation` rather than `.principal` on purpose:
            // `.principal` centers the item, which makes AppKit reserve
            // symmetric toolbar space on both sides — so even when the
            // cluster is narrow, the mirror space on the right pushes
            // the primary-action buttons off. `.navigation` anchors it
            // to the leading side, just after the sidebar toggle, and
            // lets it flow naturally from there. The right-hand
            // primary-action cluster (share, mode picker) stays pinned
            // to the trailing edge and never competes with an
            // imaginary centered reservation.
            ToolbarItem(id: "navigation-bar", placement: .navigation) {
                HStack(spacing: 10) {
                    // `compressible: true` — the toolbar competes with
                    // the breadcrumb and the right-side action cluster
                    // for width, so the sort chip must be willing to
                    // truncate its label (worst case: icon-only).
                    LibraryListSortMenu(viewModel: libraryViewModel, compressible: true)
                    ReaderHeaderActivityPill(
                        activeDetail: tabManager.activeDetail,
                        promptOutline: tabManager.promptOutline,
                        selectedPromptID: tabManager.selectedPromptID,
                        onSelectPrompt: { id in
                            tabManager.requestPromptSelection(id)
                        },
                        conversations: libraryViewModel.conversations,
                        onSelectConversation: { id in
                            libraryViewModel.selectedConversationId = id
                        },
                        onTitlePulldownOpen: revealActiveConversationInMiddlePane
                    )
                }
                // No frame hint: in the leading (`.navigation`) slot
                // the toolbar lays items out left-to-right from the
                // sidebar toggle, so the content's natural ideal size
                // (= the first tier of `ViewThatFits`, ~560pt) is
                // exactly what we want AppKit to grant when there's
                // room. When the window narrows, AppKit proposes less
                // width and `ViewThatFits` walks the tier ladder down.
                // The outer frame is intentionally absent —
                // `minWidth: …` is unnecessary because `ViewThatFits`
                // already provides a well-defined minimum (the
                // tightest tier), and `maxWidth: .infinity` would
                // make the principal eat whatever slack was meant for
                // the primary-action cluster.
            }
            ToolbarItem(id: "share", placement: .primaryAction) {
                WorkspaceFloatingExportButton(detail: tabManager.activeDetail)
            }
            ToolbarItem(id: "mode-picker", placement: .primaryAction) {
                MiddlePaneModePicker(selection: $viewMode)
            }
        }
        // Pin to SwiftUI's default unified-toolbar rendering. Dropping
        // this call did not change the dark strip at the sidebar's
        // top edge (diagnostic confirmed), so the strip is the
        // standard titlebar / toolbar chrome — not something we're
        // painting. Keeping `.automatic` here makes the rendering
        // explicit so the chrome doesn't drift under SDK updates.
        // Visual integration with the strip is handled on the
        // sidebar side (see `UnifiedLibrarySidebar.body`), not by
        // trying to hide the chrome or modify NSWindow.
        .toolbarBackground(.automatic, for: .windowToolbar)
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
            canEnterViewer: tabManager.activeTab != nil,
            isEnabled: viewMode != .table
        )
    }

    /// Reveal the currently-open conversation in the middle pane right
    /// as the title popover opens so the popover's current row and the
    /// underlying list/table stay visually aligned.
    private func revealActiveConversationInMiddlePane() {
        guard let id = tabManager.activeTab?.conversationID else { return }
        Task { await libraryViewModel.revealConversation(id: id) }
    }

    /// Apply all window-chrome tweaks that must survive SwiftUI re-
    /// writing them. Called by `WindowConfigurator` once on attach and
    /// again on every `updateNSView` pass, plus from the KVO observer
    /// whenever SwiftUI writes `window.title`.
    ///
    /// Kept as a static helper (rather than inline inside
    /// `.background(WindowConfigurator { ... })`) because embedding
    /// the toolbar-item loop directly in `body` tipped the Swift type
    /// checker over the "unable to type-check in reasonable time"
    /// threshold. Static methods type-check independently, so pulling
    /// this out keeps the body lean.
    private static func applyWindowChrome(_ window: NSWindow) {
        // Hide the system window title label. Blanking the string too
        // guarantees no glyphs render even if the visibility bit gets
        // flipped back by a later SwiftUI pass.
        window.titleVisibility = .hidden
        window.title = ""

        // Toolbar overflow priorities. Keep all three of our custom
        // items (navigation-bar, share, mode-picker) pinned at the
        // same `.high` priority so AppKit's overflow algorithm
        // treats them as equally important — no single one gets
        // sacrificed before the others. Compressibility itself is
        // driven from the SwiftUI side: the principal HStack uses
        // a `.frame(minWidth: …)` that lets it measure small, and
        // its children (`LibraryListSortMenu(compressible: true)`,
        // `ReaderHeaderActivityPill`) truncate internally. With a
        // flexible minimum, NSToolbar reads the principal as
        // "happy at a narrow width," so it stays visible alongside
        // primary-action items even when the window is narrow.
        //
        // `NSToolbarItem.minSize` / `.maxSize` are deprecated in
        // macOS 12+ — Apple's guidance is to let the system measure
        // from the hosted view's constraints, which for us means
        // the SwiftUI intrinsic size. So we don't touch those and
        // rely on the SwiftUI content alone.
        if let toolbar = window.toolbar {
            for item in toolbar.items {
                switch item.itemIdentifier.rawValue {
                case "navigation-bar", "share", "mode-picker":
                    item.visibilityPriority = .high
                default:
                    break
                }
            }
        }
    }

    private var libraryContentPane: some View {
        // Window chrome (title pill, share, mode picker) lives in the
        // real window toolbar (`.toolbar { }` on `workspaceSplitView`),
        // so this pane no longer needs to reserve room for a floating
        // overlay. Each sub-view starts flush below the system toolbar
        // via standard safe-area insets.
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
                    onExitTableMode: { viewMode = .default }
                )
            } else if viewMode == .focus {
                // Focus sub-mode: middle column is collapsed via
                // `columnVisibility = .detailOnly`, but macOS's 3-column
                // NavigationSplitView can still fleetingly render this
                // pane during the transition. `Color.clear` guarantees
                // the user never sees a flash of stale content.
                Color.clear
            } else if viewMode == .viewer {
                // Viewer mode: middle pane swaps the card list for a
                // flat prompt-directory index of the active reader
                // tab's conversation. Clicking a row asks the reader
                // (right pane) to jump to that prompt.
                ViewerModePane(
                    viewModel: libraryViewModel,
                    tabManager: tabManager,
                    conversationID: tabManager.activeTab?.conversationID
                )
            } else {
                // Default mode: standard card list. Active filter
                // chips no longer render here — they live inside the
                // sidebar's expanded search container.
                UnifiedConversationListView(
                    viewModel: libraryViewModel,
                    onTapTag: { tag in
                        libraryViewModel.toggleBookmarkTag(tag.name)
                    }
                )
            }
        }
        // Bottom fade only — the previous top fade existed so rows
        // dissolving into the floating overlay bar read as soft-
        // landing rather than clipped. With the standard window
        // toolbar in charge, the system draws its own material backing
        // and a top fade would just dim content that the toolbar
        // already separates visually.
        .edgeFadeMask(
            top: 0,
            bottom: viewMode == .table ? 0 : WorkspaceLayoutMetrics.bottomFadeHeight
        )
    }

    private var rightPane: some View {
        ReaderWorkspaceView(
            tabManager: tabManager,
            repository: services.conversations
        )
    }

    private var librarySidebar: some View {
        UnifiedLibrarySidebar(
            viewModel: libraryViewModel,
            dataSource: services.dataSource
        )
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
                // Intentional breathing strip below the window
                // toolbar's bottom edge. The toolbar paints its own
                // background layer (a darker band on maximize,
                // confirmed via a diagnostic toggle of
                // `.toolbarBackground`) — we can't remove it without
                // touching NSWindow, which is off-limits. So we lean
                // into it: this spacer gives the sidebar a visual
                // header lane that reads as continuous with the
                // toolbar chrome, so the first real row (search bar)
                // doesn't crash into the band. 12pt here + the 12pt
                // outer top padding below = ~24pt of clearance total,
                // roughly matching Finder's sidebar-to-toolbar gap.
                Color.clear
                    .frame(height: 12)
                // Sidebar chrome — search field (which also hosts the
                // active-filter chip flow) + narrow-the-results row
                // (sort + date). Renders as the first children of the
                // ScrollView so the whole strip scrolls with the list
                // instead of pinning as an overlay. An earlier iteration
                // floated it as an `.overlay(alignment: .top)` over the
                // sidebar, but that fought AppKit for titlebar real
                // estate and produced a "black band covering the
                // search field" regression when combined with the
                // window-spanning unified top bar.
                VStack(alignment: .leading, spacing: 0) {
                    SidebarSearchBar(
                        viewModel: viewModel,
                        activeFilterChips: viewModel.activeFilterChips,
                        onClearChip: viewModel.clearFilterChip
                    )

                    // Sort pulldown moved to the window toolbar's leading
                    // edge (`ToolbarItem(placement: .navigation)` in
                    // `workspaceSplitView`), so this row now carries only
                    // the date-range picker. The HStack + trailing
                    // `Spacer` is kept so the date chip stays
                    // left-aligned and the row's height matches the
                    // other sidebar rows above/below it — dropping the
                    // HStack would pull the chip flush against the
                    // section-header padding.
                    HStack(spacing: WorkspaceLayoutMetrics.headerBarInteriorSpacing) {
                        HeaderDateRangePicker(viewModel: viewModel)
                        Spacer(minLength: 0)
                    }
                    .frame(height: WorkspaceLayoutMetrics.sidebarControlsRowHeight)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

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
        // Brown matches the per-source-file rows nested directly under
        // this row (see `SidebarCheckboxRow(tint: .brown)` below) so the
        // storage drive and the JSON files inside it read as one
        // colour-coded import family.
        case .database: .brown
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
                conversationList
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private var conversationList: some View {
        ScrollViewReader { proxy in
            List(viewModel.conversations, selection: $viewModel.selectedConversationIDs) { conversation in
                conversationRow(for: conversation)
            }
            .scrollContentBackground(.hidden)
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
            .onChange(of: viewModel.pendingListScrollConversationID) { _, newValue in
                guard let id = newValue else { return }
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .top)
                }
                Task { @MainActor in
                    viewModel.pendingListScrollConversationID = nil
                }
            }
            .task {
                let id = viewModel.pendingListScrollConversationID
                    ?? viewModel.selectedConversationId
                guard let id else { return }
                try? await Task.sleep(nanoseconds: 40_000_000)
                withAnimation(.easeInOut(duration: 0.2)) {
                    proxy.scrollTo(id, anchor: .top)
                }
                if viewModel.pendingListScrollConversationID == id {
                    viewModel.pendingListScrollConversationID = nil
                }
            }
        }
    }

    private func conversationRow(for conversation: ConversationSummary) -> some View {
        ConversationRowView(
            conversation: conversation,
            tags: viewModel.conversationTags[conversation.id] ?? [],
            onTapTag: onTapTag,
            draggedConversationIDs: viewModel.draggedConversationIDs(for: conversation.id),
            onAttachTag: { tagName in
                Task {
                    await viewModel.attachTag(
                        named: tagName,
                        toConversation: conversation.id
                    )
                }
            }
        )
        .tag(conversation.id)
        .id(conversation.id)
        .onAppear {
            Task {
                await viewModel.loadMoreIfNeeded(currentItem: conversation)
            }
        }
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

/// Native `NSSegmentedControl` hosting the middle-pane mode cascade,
/// mounted as a single `NSToolbarItem` in the window title bar
/// (`MacOSRootView.workspaceSplitView`'s `.toolbar`). Four glyph
/// segments — テーブル / デフォルト / ビューアー / フォーカス — matching
/// the ordering of `MiddlePaneMode`'s cascade left-to-right so the
/// control reads the same way the trackpad swipe feels.
///
/// **Why `NSSegmentedControl` directly, not `Picker(.segmented)` nor
/// a custom HStack of `Button`s.** The goal of this rewrite is to let
/// AppKit own the chrome — Finder's toolbar view picker is literally
/// an `NSSegmentedControl` in a unified toolbar, and matching that
/// requires the control to *be* the AppKit widget, not a SwiftUI
/// approximation. The previous custom-`Button` version painted its
/// own capsule fill and stroke on each segment, which caused macOS 26
/// to group all five toolbar chips (share + four modes) into one pill
/// bubble. Handing the four modes to AppKit as a single
/// `NSSegmentedControl` means the toolbar sees ONE control with four
/// internal segments — so the share button reads as its own item
/// sitting next to the group, not a fifth segment absorbed into it.
///
/// A thin `Coordinator` routes `action:` callbacks back into the
/// SwiftUI binding. The control fires on `mouseUp`, which lands on
/// the same runloop turn the click happens — so click latency matches
/// the trackpad-swipe path that writes the binding from an `NSEvent`
/// monitor.
///
/// Always visible across all four modes; no disabled states — the
/// cascade accepts any target, and writing a mode with no active
/// conversation just lands the user in an empty reader pane, same as
/// the swipe path.
struct MiddlePaneModePicker: NSViewRepresentable {
    @Binding var selection: MiddlePaneMode

    func makeCoordinator() -> Coordinator {
        Coordinator(binding: $selection)
    }

    func makeNSView(context: Context) -> NSSegmentedControl {
        let modes = MiddlePaneMode.allCases
        let images: [NSImage] = modes.map { mode in
            NSImage(
                systemSymbolName: mode.systemImage,
                accessibilityDescription: mode.displayName
            ) ?? NSImage()
        }

        let control = NSSegmentedControl(
            images: images,
            trackingMode: .selectOne,
            target: context.coordinator,
            action: #selector(Coordinator.segmentChanged(_:))
        )
        // `.automatic` picks whichever style the current window style
        // mask / toolbar style implies — in a unified toolbar that
        // resolves to the "separated" pill look Finder uses.
        control.segmentStyle = .automatic
        control.controlSize = .regular

        for (index, mode) in modes.enumerated() {
            control.setToolTip(mode.displayName, forSegment: index)
        }
        if let index = modes.firstIndex(of: selection) {
            control.selectedSegment = index
        }
        return control
    }

    func updateNSView(_ nsView: NSSegmentedControl, context: Context) {
        context.coordinator.binding = $selection
        let modes = MiddlePaneMode.allCases
        if let index = modes.firstIndex(of: selection),
           nsView.selectedSegment != index {
            nsView.selectedSegment = index
        }
    }

    final class Coordinator {
        var binding: Binding<MiddlePaneMode>

        init(binding: Binding<MiddlePaneMode>) {
            self.binding = binding
        }

        @objc func segmentChanged(_ sender: NSSegmentedControl) {
            let modes = MiddlePaneMode.allCases
            let idx = sender.selectedSegment
            guard idx >= 0 && idx < modes.count else { return }
            let next = modes[idx]
            guard next != binding.wrappedValue else { return }
            // Match the swipe path: write the binding synchronously
            // with animation disabled so the view-tree swap lands on
            // the click's own runloop turn.
            var transaction = Transaction()
            transaction.disablesAnimations = true
            withTransaction(transaction) {
                binding.wrappedValue = next
            }
        }
    }
}

// MARK: - Window configuration

/// Walks up to the hosting `NSWindow` on first layout and applies the
/// window-level chrome settings SwiftUI doesn't expose: toolbar style
/// (`.unified` — merges title bar + toolbar into one Finder-style
/// region), full-size content view toggle, and any future AppKit-only
/// tweaks. Attached via `.background(WindowConfigurator { … })` at the
/// root of `MacOSRootView.body`.
///
/// **Why `viewDidMoveToWindow` rather than a `DispatchQueue.main.async`
/// poke from `makeNSView`.** The representable is built before the
/// view has been added to a window, so `view.window` is `nil` in
/// `makeNSView`. Hooking the AppKit lifecycle callback fires exactly
/// once when the view actually joins the window hierarchy, which is
/// also when the window is ready to accept chrome changes.
struct WindowConfigurator: NSViewRepresentable {
    let configure: (NSWindow) -> Void

    func makeNSView(context: Context) -> WindowAccessorView {
        let view = WindowAccessorView()
        view.onAttach = configure
        return view
    }

    // Re-apply `configure` on every SwiftUI update pass. Belt-and-
    // suspenders on top of the KVO observer installed in
    // `viewDidMoveToWindow` — some state (toolbar item priorities)
    // gets rebuilt by SwiftUI on toolbar refresh, so catching the
    // view-update pass covers the gap while KVO covers the title.
    func updateNSView(_ nsView: WindowAccessorView, context: Context) {
        if let window = nsView.window {
            configure(window)
        }
    }

    final class WindowAccessorView: NSView {
        var onAttach: ((NSWindow) -> Void)?
        /// KVO token for `window.title`. SwiftUI's NavigationSplitView
        /// re-writes `NSWindow.title` from the app bundle name on its
        /// own schedule (not tied to our `updateNSView` calls), so we
        /// need an observer that fires whenever the title is written
        /// and forces it back to empty. Without this, setting
        /// `.titleVisibility = .hidden` + `title = ""` from
        /// `updateNSView` is insufficient — by the time AppKit renders
        /// the titlebar, SwiftUI has already put "MadiniArchive" back.
        private var titleObservation: NSKeyValueObservation?

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            titleObservation?.invalidate()
            guard let window = self.window else { return }
            onAttach?(window)

            titleObservation = window.observe(\.title, options: [.new]) { [weak self] window, _ in
                guard let self = self else { return }
                // Only re-run `onAttach` when SwiftUI has put a non-
                // empty string back — otherwise our own `title = ""`
                // call inside `onAttach` would recurse here. Setting
                // an already-empty title is a no-op for KVO so this
                // terminates cleanly on the first intercept.
                if window.title != "" {
                    self.onAttach?(window)
                }
            }
        }

        deinit {
            titleObservation?.invalidate()
        }
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

/// Bottom-of-window banner shown right after a Trash drop bulk-detached
/// tags from one or more conversations. Gives the user an explicit Undo
/// affordance for the brief window between action and commit — without
/// this, a single stray drop could silently clear tag state the user
/// spent time curating, which is the "foolproof" property asked for.
///
/// Separate from `ImportToastView` because the content shape differs
/// (this one has interactive buttons and must accept hit-testing; the
/// import toast is passive). Sharing a "Toast" chrome helper would be
/// premature while there are only two; revisit if a third toast lands.
private struct TrashUndoToast: View {
    let snapshot: TrashTagsUndoSnapshot
    let onUndo: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "trash")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 1) {
                Text(primaryMessage)
                    .font(.callout.weight(.medium))
                    .foregroundStyle(.primary)
                if snapshot.detachedTagCount > 0 {
                    Text(secondaryMessage)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }

            // The Undo affordance is the whole point of the toast —
            // rendered as a bordered prominent button so it reads as
            // the primary action even while the user is still looking
            // at the drop origin (sidebar) rather than the toast.
            Button("Undo", action: onUndo)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .keyboardShortcut("z", modifiers: [.command])

            // Dismiss without restoring — the user accepts the purge
            // mid-window. `onDismiss` just clears `pendingTrashUndo`
            // (no DB work), so this is cheap and non-destructive.
            Button {
                onDismiss()
            } label: {
                Image(systemName: "xmark")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.plain)
            .help("Dismiss")
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
    }

    private var primaryMessage: String {
        let count = snapshot.conversationCount
        if count == 1 {
            return "Cleared tags from 1 conversation"
        }
        return "Cleared tags from \(count) conversations"
    }

    private var secondaryMessage: String {
        let count = snapshot.detachedTagCount
        if count == 1 {
            return "1 tag removed — Undo to restore"
        }
        return "\(count) tags removed — Undo to restore"
    }
}

#endif
