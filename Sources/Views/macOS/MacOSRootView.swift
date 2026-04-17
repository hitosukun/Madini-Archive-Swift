#if os(macOS)
import SwiftUI

struct MacOSRootView: View {
    let services: AppServices
    @State private var libraryViewModel: LibraryViewModel
    @State private var tabManager = ReaderTabManager()
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
        VStack(spacing: 0) {
            workspaceSplitView
            DataSourceStatusView(
                dataSource: services.dataSource,
                loadedCount: libraryViewModel.conversations.count,
                totalCount: libraryViewModel.totalCount,
                itemLabel: "conversations"
            )
        }
        .focusedSceneValue(\.libraryViewModel, libraryViewModel)
        .task {
            await libraryViewModel.loadIfNeeded()
        }
        .task(id: archiveEvents.bookmarkRevision) {
            await libraryViewModel.reload()
        }
        .task(id: archiveEvents.savedViewRevision) {
            await libraryViewModel.reloadSupportingState()
        }
        .onChange(of: libraryViewModel.selectedConversationId) { _, conversationID in
            guard let summary = libraryViewModel.summary(for: conversationID) else {
                return
            }

            tabManager.openConversation(
                id: summary.id,
                title: summary.displayTitle,
                mode: .replaceCurrent
            )
        }
    }

    private var workspaceSplitView: some View {
        NavigationSplitView {
            librarySidebar
        } content: {
            libraryContentPane
                .ignoresSafeArea(.container, edges: .top)
                .navigationSplitViewColumnWidth(
                    min: WorkspaceLayoutMetrics.contentMinWidth,
                    ideal: WorkspaceLayoutMetrics.contentIdealWidth,
                    max: WorkspaceLayoutMetrics.contentMaxWidth
                )
        } detail: {
            rightPane
                .ignoresSafeArea(.container, edges: .top)
        }
    }

    private var libraryContentPane: some View {
        VStack(spacing: 0) {
            UnifiedConversationListView(
                viewModel: libraryViewModel,
                onToggleBookmark: toggleBookmark(_:),
                onTapTag: { tag in
                    libraryViewModel.toggleBookmarkTag(tag.name)
                }
            )
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            LibraryListHeaderBar(viewModel: libraryViewModel)
        }
    }

    private var rightPane: some View {
        ReaderWorkspaceView(tabManager: tabManager, repository: services.conversations)
    }

    private var librarySidebar: some View {
        VStack(spacing: 0) {
            SidebarSearchBar(viewModel: libraryViewModel)
                .padding(.horizontal, WorkspaceLayoutMetrics.paneHorizontalPadding)
                .padding(.top, WorkspaceLayoutMetrics.paneTopPadding)
                .padding(.bottom, WorkspaceLayoutMetrics.paneBottomPadding)

            Divider()

            UnifiedLibrarySidebar(
                viewModel: libraryViewModel
            )
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationSplitViewColumnWidth(
            min: WorkspaceLayoutMetrics.sidebarMinWidth,
            ideal: WorkspaceLayoutMetrics.sidebarIdealWidth,
            max: WorkspaceLayoutMetrics.sidebarMaxWidth
        )
    }

    private func toggleBookmark(_ summary: ConversationSummary) {
        let nextState = !summary.isBookmarked
        let target = BookmarkTarget(
            targetType: .thread,
            targetID: summary.id,
            payload: bookmarkPayload(title: summary.displayTitle, source: summary.source, model: summary.model)
        )

        Task {
            do {
                _ = try await services.bookmarks.setBookmark(target: target, bookmarked: nextState)
                libraryViewModel.setBookmarkState(for: summary.id, isBookmarked: nextState)
                archiveEvents.didChangeBookmarks()
            } catch {
                print("Failed to toggle bookmark: \(error)")
            }
        }
    }

    private func bookmarkPayload(title: String, source: String?, model: String?) -> [String: String] {
        var payload = ["title": title]
        if let source {
            payload["source"] = source
        }
        if let model {
            payload["model"] = model
        }
        return payload
    }
}

private struct UnifiedLibrarySidebar: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var expandedSources: Set<String> = []

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
                }

                section(title: "Sources") {
                    ForEach(viewModel.sourceFacets) { source in
                        VStack(alignment: .leading, spacing: 6) {
                            HStack(spacing: 8) {
                                SidebarCheckboxRow(
                                    title: source.value,
                                    count: source.count,
                                    systemImage: sourceIcon(source.value),
                                    tint: sourceColor(source.value),
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
                                            systemImage: "cube.transparent",
                                            tint: .secondary,
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

                SidebarTagsSection(libraryViewModel: viewModel)

                // "Saved View" name input removed. Pinning is now the way to
                // promote a recent filter into a persistent view.
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
            .padding(12)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .onAppear {
            expandedSources = Set(viewModel.sourceFacets.map(\.value))
        }
    }

    @Environment(ArchiveEvents.self) private var archiveEvents

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption)
                .foregroundStyle(.secondary)
                .textCase(.uppercase)

            content()
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

    private func sourceIcon(_ source: String) -> String {
        switch source.lowercased() {
        case "chatgpt":
            return "bubble.left.and.bubble.right"
        case "claude":
            return "text.bubble"
        case "gemini":
            return "sparkles"
        case "markdown":
            return "folder"
        default:
            return "folder"
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source.lowercased() {
        case "chatgpt":
            return .green
        case "claude":
            return .orange
        case "gemini":
            return .blue
        default:
            return .gray
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
    let systemImage: String
    let tint: Color
    let isSelected: Bool
    var compact: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                Image(systemName: isSelected ? "checkmark.square.fill" : "square")
                    .foregroundStyle(isSelected ? Color.accentColor : .secondary)

                Image(systemName: systemImage)
                    .foregroundStyle(tint)
                    .font(compact ? .caption : .body)

                Text(title)
                    .font(compact ? .subheadline : .body)
                    .foregroundStyle(.primary)
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
    let onToggleBookmark: (ConversationSummary) -> Void
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
                List(viewModel.conversations, selection: $viewModel.selectedConversationId) { conversation in
                    ConversationRowView(
                        conversation: conversation,
                        tags: viewModel.conversationTags[conversation.id] ?? [],
                        onToggleBookmark: { onToggleBookmark(conversation) },
                        onTapTag: onTapTag
                    )
                    .tag(conversation.id)
                    .dropDestination(for: TagDragPayload.self) { payloads, _ in
                        guard let first = payloads.first else { return false }
                        Task {
                            await viewModel.attachTag(
                                named: first.name,
                                toConversation: conversation.id
                            )
                        }
                        return true
                    }
                    .onAppear {
                        Task {
                            await viewModel.loadMoreIfNeeded(currentItem: conversation)
                        }
                    }
                }
                .overlay(alignment: .bottom) {
                    if viewModel.isLoadingMore {
                        ProgressView()
                            .padding()
                    }
                }
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
#endif
