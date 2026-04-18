#if os(iOS)
import SwiftUI

struct IOSRootView: View {
    let services: AppServices
    @State private var browseViewModel: BrowseViewModel
    @State private var searchViewModel: SearchViewModel
    @State private var bookmarkViewModel: BookmarkListViewModel
    @Environment(ArchiveEvents.self) private var archiveEvents

    init(services: AppServices) {
        self.services = services
        _browseViewModel = State(initialValue: BrowseViewModel(repository: services.conversations))
        _searchViewModel = State(
            initialValue: SearchViewModel(
                searchRepository: services.search,
                conversationRepository: services.conversations,
                viewService: services.views
            )
        )
        _bookmarkViewModel = State(initialValue: BookmarkListViewModel(repository: services.bookmarks))
    }

    var body: some View {
        TabView {
            NavigationStack {
                IOSBrowseView(
                    viewModel: browseViewModel,
                    repository: services.conversations,
                    bookmarkRepository: services.bookmarks
                )
            }
            .tabItem {
                Label("Browse", systemImage: "sidebar.left")
            }

            NavigationStack {
                IOSSearchView(
                    viewModel: searchViewModel,
                    repository: services.conversations,
                    bookmarkRepository: services.bookmarks
                )
            }
            .tabItem {
                Label("Search", systemImage: "magnifyingglass")
            }

            NavigationStack {
                IOSBookmarksView(viewModel: bookmarkViewModel, repository: services.conversations)
            }
            .tabItem {
                Label("Bookmarks", systemImage: "bookmark")
            }
        }
        .task(id: archiveEvents.bookmarkRevision) {
            await bookmarkViewModel.load()
            await browseViewModel.reload()
            if searchViewModel.hasSearched || !searchViewModel.results.isEmpty {
                searchViewModel.performSearchNow()
            }
        }
        .task(id: archiveEvents.savedViewRevision) {
            await searchViewModel.reloadSupportingState()
        }
    }
}

private struct IOSBrowseView: View {
    @Bindable var viewModel: BrowseViewModel
    let repository: any ConversationRepository
    let bookmarkRepository: any BookmarkRepository
    @Environment(ArchiveEvents.self) private var archiveEvents

    var body: some View {
        Group {
            if viewModel.isLoading {
                ProgressView()
            } else if let errorText = viewModel.errorText {
                ContentUnavailableView(
                    "Couldn’t Load Conversations",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
            } else if viewModel.conversations.isEmpty {
                ContentUnavailableView(
                    viewModel.hasActiveFilters ? "No Results" : "No Conversations",
                    systemImage: viewModel.hasActiveFilters ? "line.3.horizontal.decrease.circle" : "tray",
                    description: Text(viewModel.hasActiveFilters ? "Try clearing the current filters." : "No conversations found.")
                )
            } else {
                List(viewModel.conversations) { conversation in
                    NavigationLink {
                        ConversationDetailView(conversationId: conversation.id, repository: repository)
                    } label: {
                        ConversationRowView(conversation: conversation)
                    }
                    .onAppear {
                        Task {
                            await viewModel.loadMoreIfNeeded(currentItem: conversation)
                        }
                    }
                }
            }
        }
        .navigationTitle("Browse")
        .toolbar {
            ToolbarItemGroup(placement: .topBarTrailing) {
                Menu {
                    Picker("Source", selection: viewModel.sourceSelectionBinding()) {
                        Text("All Sources").tag(nil as String?)
                        ForEach(viewModel.sourceOptions) { option in
                            Text("\(option.value) (\(option.count))")
                                .tag(option.value as String?)
                        }
                    }

                    Picker("Model", selection: viewModel.modelSelectionBinding()) {
                        Text("All Models").tag(nil as String?)
                        ForEach(viewModel.modelOptions) { option in
                            Text("\(option.value) (\(option.count))")
                                .tag(option.value as String?)
                        }
                    }

                    if viewModel.hasActiveFilters {
                        Button("Clear Filters") {
                            viewModel.clearFilters()
                        }
                    }
                } label: {
                    Image(systemName: "line.3.horizontal.decrease.circle")
                }

                Button {
                    viewModel.toggleSortOrder()
                } label: {
                    Image(systemName: viewModel.sortKey == .dateDesc ? "arrow.down" : "arrow.up")
                }
            }
        }
        .task {
            await viewModel.loadIfNeeded()
        }
    }

}

private struct IOSSearchView: View {
    @Bindable var viewModel: SearchViewModel
    let repository: any ConversationRepository
    let bookmarkRepository: any BookmarkRepository
    @Environment(ArchiveEvents.self) private var archiveEvents

    var body: some View {
        VStack(spacing: 0) {
            SearchControlsView(viewModel: viewModel)
                .padding()

            Group {
                if let errorText = viewModel.errorText {
                    ContentUnavailableView(
                        "Search Failed",
                        systemImage: "exclamationmark.triangle",
                        description: Text(errorText)
                    )
                } else if !viewModel.hasSearched {
                    ContentUnavailableView(
                        "Start a search",
                        systemImage: "magnifyingglass",
                        description: Text("Enter a query to search across all conversations.")
                    )
                } else if viewModel.results.isEmpty {
                    ContentUnavailableView(
                        "No Results",
                        systemImage: "text.magnifyingglass",
                        description: Text("Try a different keyword or loosen the filters.")
                    )
                } else {
                    List(viewModel.results) { result in
                        NavigationLink {
                            ConversationDetailView(conversationId: result.conversationID, repository: repository)
                        } label: {
                            SearchResultRowView(
                                result: result,
                                onToggleBookmark: {
                                    toggleBookmark(result)
                                }
                            )
                        }
                        .onAppear {
                            Task {
                                await viewModel.loadMoreIfNeeded(currentItem: result)
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
        }
        .navigationTitle("Search")
        .task {
            await viewModel.loadFiltersIfNeeded()
        }
    }

    private func toggleBookmark(_ result: SearchResult) {
        let nextState = !result.isBookmarked
        let target = BookmarkTarget(
            targetType: .thread,
            targetID: result.conversationID,
            payload: ["title": result.displayTitle]
        )

        Task {
            do {
                _ = try await bookmarkRepository.setBookmark(target: target, bookmarked: nextState)
                viewModel.setBookmarkState(for: result.conversationID, isBookmarked: nextState)
                archiveEvents.didChangeBookmarks()
            } catch {
                print("Failed to toggle bookmark: \(error)")
            }
        }
    }
}

private struct IOSBookmarksView: View {
    @Bindable var viewModel: BookmarkListViewModel
    let repository: any ConversationRepository

    var body: some View {
        BookmarkListView(viewModel: viewModel)
            .task {
                await viewModel.load()
            }
            .navigationTitle("Bookmarks")
    }
}
#endif
