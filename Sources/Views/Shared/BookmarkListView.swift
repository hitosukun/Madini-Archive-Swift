import SwiftUI

struct BookmarkListView: View {
    @Bindable var viewModel: BookmarkListViewModel
    var showsNavigationChrome: Bool = true

    var body: some View {
        let content = Group {
            if viewModel.isLoading {
                ProgressView()
            } else if let errorText = viewModel.errorText {
                ContentUnavailableView(
                    "Couldn’t Load Bookmarks",
                    systemImage: "exclamationmark.triangle",
                    description: Text(errorText)
                )
            } else if viewModel.items.isEmpty {
                ContentUnavailableView(
                    "No Bookmarks",
                    systemImage: "bookmark",
                    description: Text("Bookmark a conversation to keep it close at hand.")
                )
            } else {
                List(viewModel.items, selection: $viewModel.selectedTargetID) { item in
                    BookmarkListRowView(entry: item)
                        .tag(item.targetID)
                }
            }
        }
        if showsNavigationChrome {
            content
                .navigationTitle("Bookmarks")
        } else {
            content
        }
    }
}

private struct BookmarkListRowView: View {
    let entry: BookmarkListEntry

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(entry.title?.isEmpty == false ? (entry.title ?? entry.label) : entry.label)
                .font(.headline)
                .lineLimit(2)

            HStack(spacing: 8) {
                BookmarkStatusIcon(isBookmarked: true)

                // Model preferred, source fallback — model text is painted
                // in the service's brand color so a separate source label
                // becomes redundant (see `ConversationRowView`).
                if let model = entry.model, !model.isEmpty {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(SourceAppearance.color(forModel: model))
                        .lineLimit(1)
                } else if let source = entry.source {
                    SourceText(source: source)
                }

                Spacer()

                if let primaryTime = entry.primaryTime {
                    Text(String(primaryTime.prefix(10)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
    }
}
