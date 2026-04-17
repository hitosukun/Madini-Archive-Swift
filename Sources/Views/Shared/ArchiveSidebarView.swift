import SwiftUI

enum ArchiveSidebarSelection: Hashable {
    case all
    case bookmarks
    case source(String)
    case model(source: String, model: String)
}

struct ArchiveSidebarView: View {
    @Binding var selection: ArchiveSidebarSelection?
    @Bindable var browseViewModel: BrowseViewModel
    let bookmarkCount: Int

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                sidebarRow(
                    title: "All",
                    count: browseViewModel.overallCount,
                    systemImage: "tray.full",
                    tint: .secondary
                )
                .tag(ArchiveSidebarSelection.all)

                sidebarRow(
                    title: "Bookmarks",
                    count: bookmarkCount,
                    systemImage: "bookmark.fill",
                    tint: .yellow
                )
                .tag(ArchiveSidebarSelection.bookmarks)
            }

            Section("Sources") {
                ForEach(browseViewModel.sidebarSources) { source in
                    DisclosureGroup {
                        ForEach(source.models) { model in
                            sidebarRow(
                                title: model.value,
                                count: model.count,
                                systemImage: "cube.transparent",
                                tint: .secondary
                            )
                            .tag(ArchiveSidebarSelection.model(source: source.value, model: model.value))
                        }
                    } label: {
                        sidebarRow(
                            title: source.value,
                            count: source.count,
                            systemImage: sourceIcon(source.value),
                            tint: sourceColor(source.value)
                        )
                    }
                    .tag(ArchiveSidebarSelection.source(source.value))
                }
            }
        }
        .listStyle(.sidebar)
    }

    @ViewBuilder
    private func sidebarRow(
        title: String,
        count: Int,
        systemImage: String,
        tint: Color
    ) -> some View {
        Label {
            HStack {
                Text(title)
                Spacer()
                Text("\(count)")
                    .font(.caption)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        } icon: {
            Image(systemName: systemImage)
                .foregroundStyle(tint)
        }
    }

    private func sourceIcon(_ source: String) -> String {
        switch source.lowercased() {
        case "chatgpt":
            "bubble.left.and.bubble.right"
        case "claude":
            "text.bubble"
        case "gemini":
            "sparkles"
        case "markdown":
            "folder"
        default:
            "folder"
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source.lowercased() {
        case "chatgpt":
            .green
        case "claude":
            .orange
        case "gemini":
            .blue
        default:
            .gray
        }
    }
}
