import SwiftUI

struct SourceSidebarView: View {
    @Bindable var viewModel: BrowseViewModel

    var body: some View {
        List(selection: sidebarSelectionBinding) {
            sidebarRow(
                title: "All",
                count: viewModel.overallCount,
                systemImage: "tray.full",
                tint: .secondary
            )
            .tag(BrowseSidebarSelection.all)

            Section("Sources") {
                ForEach(viewModel.sidebarSources) { source in
                    DisclosureGroup {
                        ForEach(source.models) { model in
                            sidebarRow(
                                title: model.value,
                                count: model.count,
                                systemImage: "cube.transparent",
                                tint: .secondary
                            )
                            .tag(BrowseSidebarSelection.model(source: source.value, model: model.value))
                        }
                    } label: {
                        sidebarRow(
                            title: source.value,
                            count: source.count,
                            systemImage: sourceIcon(source.value),
                            tint: sourceColor(source.value)
                        )
                    }
                    .tag(BrowseSidebarSelection.source(source.value))
                }
            }
        }
        .navigationTitle("Madini Archive")
        .listStyle(.sidebar)
    }

    private var sidebarSelectionBinding: Binding<BrowseSidebarSelection?> {
        Binding(
            get: { viewModel.sidebarSelection },
            set: { viewModel.applySidebarSelection($0) }
        )
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
