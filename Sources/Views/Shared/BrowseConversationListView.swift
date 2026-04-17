import SwiftUI

struct BrowseConversationListView: View {
    @Bindable var viewModel: BrowseViewModel
    var onToggleBookmark: (ConversationSummary) -> Void = { _ in }
    var showsNavigationChrome: Bool = true

    var body: some View {
        let content = Group {
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
                List(viewModel.conversations, selection: $viewModel.selectedConversationId) { conversation in
                    ConversationRowView(
                        conversation: conversation,
                        onToggleBookmark: { onToggleBookmark(conversation) }
                    )
                        .tag(conversation.id)
                        .onAppear {
                            Task {
                                await viewModel.loadMoreIfNeeded(currentItem: conversation)
                            }
                        }
                }
            }
        }
        if showsNavigationChrome {
            content
                .navigationTitle(viewModel.browseTitle)
                .toolbar {
                    ToolbarItemGroup {
                        Button {
                            viewModel.toggleSortOrder()
                        } label: {
                            Image(systemName: viewModel.sortKey == .dateDesc ? "arrow.down" : "arrow.up")
                        }
                        .help(viewModel.sortKey == .dateDesc ? "Newest first" : "Oldest first")

                        if viewModel.hasActiveFilters {
                            Button {
                                viewModel.clearFilters()
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                            }
                            .help("Clear filters")
                        }
                    }
                }
        } else {
            content
        }
    }
}
