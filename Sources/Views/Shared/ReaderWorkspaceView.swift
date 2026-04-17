import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ReaderWorkspaceView: View {
    @Bindable var tabManager: ReaderTabManager
    let repository: any ConversationRepository

    @State private var activeDetail: ConversationDetail?
    @State private var displayModes: [ReaderTab.ID: ConversationDetailView.DetailDisplayMode] = [:]
    @State private var promptOutline: [ConversationPromptOutlineItem] = []
    @State private var selectedPromptID: String?
    @FocusState private var workspaceFocused: Bool

    var body: some View {
        Group {
            if let activeTab = tabManager.activeTab {
                switch activeTab.content {
                case .conversation(let conversationID):
                    ConversationDetailView(
                        conversationId: conversationID,
                        repository: repository,
                        displayMode: displayModeBinding(for: activeTab),
                        selectedPromptID: $selectedPromptID,
                        showsSystemChrome: false,
                        onDetailChanged: { detail in
                            activeDetail = detail
                        },
                        onPromptOutlineChanged: { outline in
                            promptOutline = outline
                            if !outline.contains(where: { $0.id == selectedPromptID }) {
                                selectedPromptID = outline.first?.id
                            }
                        }
                    )
                    .id(activeTab.id)
                case .search, .bookmarks:
                    ContentUnavailableView(
                        "Not Implemented Yet",
                        systemImage: "hammer",
                        description: Text("This tab kind will be added in a later step.")
                    )
                }
            } else {
                ContentUnavailableView(
                    "Open a conversation",
                    systemImage: "rectangle.on.rectangle",
                    description: Text("Select a conversation or open one in a new tab.")
                )
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .focusable()
        .focusEffectDisabled()
        .focused($workspaceFocused)
        .onMoveCommand(perform: handleMoveCommand(_:))
        .simultaneousGesture(
            TapGesture().onEnded {
                workspaceFocused = true
            }
        )
        .onAppear {
            workspaceFocused = true
        }
        .onChange(of: tabManager.activeTabID) { _, _ in
            activeDetail = nil
            promptOutline = []
            selectedPromptID = nil
            workspaceFocused = true
        }
        .safeAreaInset(edge: .top, spacing: 0) {
            ReaderWorkspaceHeaderBar(
                activeDetail: activeDetail,
                promptOutline: promptOutline,
                selectedPromptID: selectedPromptID,
                onSelectPrompt: selectPrompt,
                onSelectPreviousPrompt: { selectAdjacentPrompt(step: -1) },
                onSelectNextPrompt: { selectAdjacentPrompt(step: 1) }
            ) {
                WorkspaceFloatingExportButton(detail: activeDetail)
            }
        }
    }

    private var activeDisplayModeBinding: Binding<ConversationDetailView.DetailDisplayMode>? {
        guard let activeTab = tabManager.activeTab,
              case .conversation = activeTab.content else {
            return nil
        }

        return displayModeBinding(for: activeTab)
    }

    private func displayModeBinding(for tab: ReaderTab) -> Binding<ConversationDetailView.DetailDisplayMode> {
        Binding(
            get: { displayModes[tab.id] ?? .rendered },
            set: { displayModes[tab.id] = $0 }
        )
    }

    private func selectPrompt(_ promptID: String) {
        selectedPromptID = promptID
        workspaceFocused = true
    }

    private func selectAdjacentPrompt(step: Int) {
        guard !promptOutline.isEmpty else {
            return
        }

        let currentIndex = promptOutline.firstIndex(where: { $0.id == selectedPromptID }) ?? 0
        let nextIndex = min(max(currentIndex + step, 0), promptOutline.count - 1)
        guard nextIndex != currentIndex || selectedPromptID == nil else {
            return
        }

        selectedPromptID = promptOutline[nextIndex].id
        workspaceFocused = true
    }

    private func handleMoveCommand(_ direction: MoveCommandDirection) {
        switch direction {
        case .up:
            selectAdjacentPrompt(step: -1)
        case .down:
            selectAdjacentPrompt(step: 1)
        default:
            break
        }
    }

}

private struct ReaderWorkspaceHeaderBar<Accessory: View>: View {
    let activeDetail: ConversationDetail?
    let promptOutline: [ConversationPromptOutlineItem]
    let selectedPromptID: String?
    let onSelectPrompt: (String) -> Void
    let onSelectPreviousPrompt: () -> Void
    let onSelectNextPrompt: () -> Void
    @ViewBuilder let accessory: () -> Accessory

    var body: some View {
        WorkspaceHeaderBar {
            ReaderWorkspaceOutlineControl(
                activeDetail: activeDetail,
                promptOutline: promptOutline,
                selectedPromptID: selectedPromptID,
                onSelectPrompt: onSelectPrompt,
                onSelectPreviousPrompt: onSelectPreviousPrompt,
                onSelectNextPrompt: onSelectNextPrompt
            )

            Spacer(minLength: 0)

            accessory()
        }
    }
}

private struct ReaderWorkspaceOutlineControl: View {
    let activeDetail: ConversationDetail?
    let promptOutline: [ConversationPromptOutlineItem]
    let selectedPromptID: String?
    let onSelectPrompt: (String) -> Void
    let onSelectPreviousPrompt: () -> Void
    let onSelectNextPrompt: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Menu {
                if !promptOutline.isEmpty {
                    Section("Prompts") {
                        ForEach(promptOutline) { prompt in
                            Button {
                                onSelectPrompt(prompt.id)
                            } label: {
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        if selectedPromptID == prompt.id {
                                            Image(systemName: "checkmark")
                                        }

                                        Text(prompt.label)
                                            .lineLimit(2)
                                    }

                                    Text("Prompt \(prompt.index)")
                                        .font(.caption)
                                        .foregroundStyle(.secondary)
                                }
                            }
                        }
                    }
                }
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: "text.bubble")
                        .font(.caption)

                    VStack(alignment: .leading, spacing: 1) {
                        if let activeDetail {
                            Text(activeDetail.summary.displayTitle)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }

                        Text(currentPromptTitle)
                            .font(.subheadline.weight(.semibold))
                            .foregroundStyle(.primary)
                            .lineLimit(1)
                    }

                    Image(systemName: "chevron.down")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.secondary)
                }
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
            }
            .menuStyle(.borderlessButton)

            if activeDetail != nil {
                Divider()
                    .frame(height: 18)
                    .padding(.horizontal, 2)

                PromptStepButton(
                    systemName: "chevron.up",
                    helpText: "Previous Prompt",
                    action: onSelectPreviousPrompt
                )
                .padding(.leading, 4)

                PromptStepButton(
                    systemName: "chevron.down",
                    helpText: "Next Prompt",
                    action: onSelectNextPrompt
                )
                .padding(.trailing, 6)
            }
        }
        .background(.regularMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 13, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 13, style: .continuous)
                .stroke(Color.primary.opacity(0.08), lineWidth: 1)
        )
    }

    private var currentPromptTitle: String {
        guard let selectedPromptID,
              let selectedPrompt = promptOutline.first(where: { $0.id == selectedPromptID }) else {
            return activeDetail?.summary.displayTitle ?? "Reader"
        }

        return selectedPrompt.label
    }

}

private struct PromptStepButton: View {
    let systemName: String
    let helpText: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemName)
                .font(.caption.weight(.semibold))
                .frame(width: 18, height: 18)
        }
        .buttonStyle(.borderless)
        .help(helpText)
    }
}

private struct WorkspaceFloatingExportButton: View {
    let detail: ConversationDetail?

    var body: some View {
        #if os(macOS)
        Button {
            guard let detail else {
                return
            }

            export(detail)
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 16, weight: .medium))
                .frame(width: 30, height: 30)
                .background(
                    Circle()
                        .fill(Color(nsColor: .controlBackgroundColor))
                )
                .overlay(
                    Circle()
                        .stroke(Color.primary.opacity(0.08), lineWidth: 1)
                )
        }
        .buttonStyle(.borderless)
        .help("Export as Markdown")
        .disabled(detail == nil)
        .opacity(detail == nil ? 0.4 : 1)
        #else
        if let detail {
            ShareLink(item: MarkdownExporter.export(detail)) {
                Image(systemName: "square.and.arrow.up")
            }
        } else {
            Image(systemName: "square.and.arrow.up")
                .foregroundStyle(.tertiary)
        }
        #endif
    }

    #if os(macOS)
    private func export(_ detail: ConversationDetail) {
        let markdown = MarkdownExporter.export(detail)
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.plainText]
        panel.nameFieldStringValue = sanitizeFilename(detail.summary.title ?? "conversation") + ".md"

        panel.begin { response in
            guard response == .OK, let url = panel.url else {
                return
            }

            try? markdown.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    private func sanitizeFilename(_ name: String) -> String {
        let illegal = CharacterSet(charactersIn: "/:\\")
        return name.components(separatedBy: illegal).joined(separator: "_")
    }
    #endif
}
