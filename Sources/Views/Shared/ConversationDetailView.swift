import SwiftUI
#if os(macOS)
import AppKit
#endif

struct ConversationDetailView: View {
    private enum RenderSafety {
        static let maxRenderedConversationLength = 12_000
    }

    enum DetailDisplayMode: String, CaseIterable, Identifiable {
        case rendered = "Rendered"
        case plain = "Plain"

        var id: String { rawValue }
    }

    @State private var viewModel: ConversationDetailViewModel
    @State private var localDisplayMode: DetailDisplayMode = .rendered
    private let externalDisplayMode: Binding<DetailDisplayMode>?
    private let externalSelectedPromptID: Binding<String?>?
    private let showsSystemChrome: Bool
    private let onDetailChanged: ((ConversationDetail?) -> Void)?
    private let onPromptOutlineChanged: (([ConversationPromptOutlineItem]) -> Void)?

    init(
        conversationId: String,
        repository: any ConversationRepository,
        displayMode: Binding<DetailDisplayMode>? = nil,
        selectedPromptID: Binding<String?>? = nil,
        showsSystemChrome: Bool = true,
        onDetailChanged: ((ConversationDetail?) -> Void)? = nil,
        onPromptOutlineChanged: (([ConversationPromptOutlineItem]) -> Void)? = nil
    ) {
        _viewModel = State(
            initialValue: ConversationDetailViewModel(
                conversationId: conversationId,
                repository: repository
            )
        )
        externalDisplayMode = displayMode
        externalSelectedPromptID = selectedPromptID
        self.showsSystemChrome = showsSystemChrome
        self.onDetailChanged = onDetailChanged
        self.onPromptOutlineChanged = onPromptOutlineChanged
    }

    var body: some View {
        contentView
            .task(id: viewModel.conversationId) {
                await viewModel.load()
                onDetailChanged?(viewModel.detail)
                if let detail = viewModel.detail {
                    if Self.shouldPreferPlainDisplay(for: detail) {
                        resolvedDisplayMode.wrappedValue = .plain
                    }

                    let outline = Self.promptOutline(for: detail)
                    onPromptOutlineChanged?(outline)
                    // Intentionally do NOT seed `resolvedSelectedPromptID` here:
                    // doing so caused the viewer to open scrolled partway down
                    // (ScrollViewReader.onChange jumped to the first user
                    // prompt, hiding system/preface messages). The selection
                    // is now only set when the user taps an outline entry.
                }
            }
    }

    @ViewBuilder
    private var contentView: some View {
        if viewModel.isLoading {
            ProgressView()
        } else if let detail = viewModel.detail {
            LoadedConversationDetailView(
                displayMode: resolvedDisplayMode,
                selectedPromptID: resolvedSelectedPromptID,
                detail: detail,
                supportsRenderedDisplay: Self.supportsRenderedDisplay(for: detail),
                showsSystemChrome: showsSystemChrome
            )
        } else if let errorText = viewModel.errorText {
            ContentUnavailableView(
                "Couldn’t Load Conversation",
                systemImage: "exclamationmark.triangle",
                description: Text(errorText)
            )
        } else {
            ContentUnavailableView(
                "Not Found",
                systemImage: "questionmark.circle",
                description: Text("The selected conversation no longer exists.")
            )
        }
    }

    private var resolvedDisplayMode: Binding<DetailDisplayMode> {
        externalDisplayMode ?? $localDisplayMode
    }

    private var resolvedSelectedPromptID: Binding<String?> {
        externalSelectedPromptID ?? .constant(nil)
    }

    static func shouldPreferPlainDisplay(for detail: ConversationDetail) -> Bool {
        if detail.summary.source?.lowercased() == "markdown" {
            return true
        }

        return detail.messages.contains { $0.content.count > 20_000 }
    }

    static func supportsRenderedDisplay(for detail: ConversationDetail) -> Bool {
        let totalLength = detail.messages.reduce(into: 0) { partialResult, message in
            partialResult += message.content.count
        }
        return totalLength <= RenderSafety.maxRenderedConversationLength
    }

    static func promptOutline(for detail: ConversationDetail) -> [ConversationPromptOutlineItem] {
        detail.messages.enumerated().compactMap { index, message in
            guard message.isUser else {
                return nil
            }

            return ConversationPromptOutlineItem(
                id: message.id,
                index: index + 1,
                label: promptLabel(from: message.content)
            )
        }
    }

    private static func promptLabel(from text: String) -> String {
        let collapsed = text
            .replacingOccurrences(of: "\\s+", with: " ", options: .regularExpression)
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else {
            return "Untitled Prompt"
        }

        if collapsed.count <= 72 {
            return collapsed
        }

        let endIndex = collapsed.index(collapsed.startIndex, offsetBy: 72)
        return String(collapsed[..<endIndex]).trimmingCharacters(in: .whitespaces) + "…"
    }
}

struct ConversationPromptOutlineItem: Identifiable, Hashable {
    let id: String
    let index: Int
    let label: String
}

private struct LoadedConversationDetailView: View {
    @EnvironmentObject private var services: AppServices
    @Environment(ArchiveEvents.self) private var archiveEvents
    @Binding var displayMode: ConversationDetailView.DetailDisplayMode
    @Binding var selectedPromptID: String?
    let detail: ConversationDetail
    let supportsRenderedDisplay: Bool
    let showsSystemChrome: Bool
    @State private var bookmarkOverride: Bool?

    var body: some View {
        let detailBody = Group {
            if shouldUseDocumentViewer {
                DocumentConversationView(detail: detail, isBookmarked: effectiveBookmarked, onToggleBookmark: toggleBookmark)
            } else {
                ScrollViewReader { proxy in
                    ScrollView {
                        LazyVStack(alignment: .leading, spacing: 0) {
                            ConversationHeaderView(
                                summary: detail.summary,
                                isBookmarked: effectiveBookmarked,
                                onToggleBookmark: toggleBookmark
                            )
                                .padding(.bottom, 16)

                            ForEach(Array(detail.messages.enumerated()), id: \.element.id) { index, message in
                                MessageBubbleView(
                                    message: message,
                                    displayMode: messageDisplayMode,
                                    identityContext: MessageIdentityContext(
                                        source: detail.summary.source,
                                        model: detail.summary.model
                                    )
                                )
                                .id(message.id)
                                .contentShape(Rectangle())
                                .onTapGesture {
                                    guard message.isUser else {
                                        return
                                    }

                                    selectedPromptID = message.id
                                }

                                if index < detail.messages.count - 1 {
                                    Divider()
                                        .padding(.vertical, 12)
                                }
                            }
                        }
                        .padding()
                    }
                    .onAppear {
                        scrollToSelectedPrompt(using: proxy, animated: false)
                    }
                    .onChange(of: selectedPromptID) { _, _ in
                        scrollToSelectedPrompt(using: proxy, animated: true)
                    }
                }
            }
        }
        if showsSystemChrome {
            detailBody
                .navigationTitle(detail.summary.title ?? "Untitled")
                .toolbar {
                    if shouldPreferPlainDisplay {
                        ToolbarItem {
                            Menu(effectiveDisplayMode.rawValue) {
                                Button("Rendered") {
                                    displayMode = .rendered
                                }
                                .disabled(!supportsRenderedDisplay)
                                Button("Plain") {
                                    displayMode = .plain
                                }
                            }
                        }
                    }

                    DetailExportToolbar(detail: detail)
                }
        } else {
            detailBody
        }
    }

    private var effectiveBookmarked: Bool {
        bookmarkOverride ?? detail.summary.isBookmarked
    }

    private var shouldPreferPlainDisplay: Bool {
        ConversationDetailView.shouldPreferPlainDisplay(for: detail)
    }

    private var shouldUseDocumentViewer: Bool {
        effectiveDisplayMode == .plain
            && detail.messages.count == 1
            && shouldPreferPlainDisplay
    }

    private var messageDisplayMode: MessageBubbleView.DisplayMode {
        switch effectiveDisplayMode {
        case .rendered:
            return .rendered
        case .plain:
            return .plain
        }
    }

    private var effectiveDisplayMode: ConversationDetailView.DetailDisplayMode {
        supportsRenderedDisplay ? displayMode : .plain
    }

    private func toggleBookmark() {
        let target = BookmarkTarget(
            targetType: .thread,
            targetID: detail.summary.id,
            payload: bookmarkPayload
        )
        let nextState = !effectiveBookmarked

        Task {
            do {
                _ = try await services.bookmarks.setBookmark(target: target, bookmarked: nextState)
                bookmarkOverride = nextState
                archiveEvents.didChangeBookmarks()
            } catch {
                print("Failed to toggle bookmark: \(error)")
            }
        }
    }

    private var bookmarkPayload: [String: String] {
        var payload: [String: String] = ["title": detail.summary.displayTitle]
        if let source = detail.summary.source {
            payload["source"] = source
        }
        if let model = detail.summary.model {
            payload["model"] = model
        }
        return payload
    }

    private func scrollToSelectedPrompt(
        using proxy: ScrollViewProxy,
        animated: Bool
    ) {
        guard let selectedPromptID else {
            return
        }

        let action = {
            proxy.scrollTo(selectedPromptID, anchor: .top)
        }

        if animated {
            withAnimation(.easeInOut(duration: 0.2), action)
        } else {
            action()
        }
    }
}

private struct DocumentConversationView: View {
    private enum Layout {
        static let avatarSize: CGFloat = 30
        static let avatarColumnWidth: CGFloat = 38
    }

    let detail: ConversationDetail
    let isBookmarked: Bool
    let onToggleBookmark: () -> Void
    @Environment(IdentityPreferencesStore.self) private var identityPreferences

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            ConversationHeaderView(
                summary: detail.summary,
                isBookmarked: isBookmarked,
                onToggleBookmark: onToggleBookmark
            )
                .padding(.horizontal)
                .padding(.top)

            if let message = detail.messages.first {
                HStack(alignment: .top, spacing: 10) {
                    if message.isUser {
                        Spacer()

                        Text(identityPresentation(for: message).displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(identityPresentation(for: message).accentColor)

                        IdentityAvatarView(
                            presentation: identityPresentation(for: message),
                            size: Layout.avatarSize
                        )
                        .frame(width: Layout.avatarColumnWidth, alignment: .topTrailing)
                    } else {
                        IdentityAvatarView(
                            presentation: identityPresentation(for: message),
                            size: Layout.avatarSize
                        )
                        .frame(width: Layout.avatarColumnWidth, alignment: .topLeading)

                        Text(identityPresentation(for: message).displayName)
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundStyle(identityPresentation(for: message).accentColor)

                        Spacer()
                    }
                }
                .padding(.horizontal)

                ReadOnlyTextDocumentView(text: message.content)
                    .padding(.leading, message.isUser ? 16 : Layout.avatarColumnWidth + 10)
                    .padding(.trailing, message.isUser ? Layout.avatarColumnWidth + 10 : 16)
                    .padding(.bottom)
            }
        }
    }

    private func identityPresentation(for message: Message) -> MessageIdentityPresentation {
        identityPreferences.presentation(
            for: message.role,
            context: MessageIdentityContext(
                source: detail.summary.source,
                model: detail.summary.model
            )
        )
    }
}

private struct ConversationHeaderView: View {
    let summary: ConversationSummary
    let isBookmarked: Bool
    let onToggleBookmark: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            BookmarkToggleButton(
                isBookmarked: isBookmarked,
                action: onToggleBookmark
            )

            if let source = summary.source {
                Label(source, systemImage: sourceIcon(source))
                    .font(.callout)
                    .foregroundStyle(.secondary)
            }

            if let model = summary.model {
                Text(model)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }

            if let time = summary.primaryTime {
                Spacer()
                Text(time)
                    .font(.callout)
                    .foregroundStyle(.tertiary)
            }
        }
        .padding(.horizontal, 4)
    }

    private func sourceIcon(_ source: String) -> String {
        switch source.lowercased() {
        case "chatgpt":
            "bubble.left.and.bubble.right"
        case "claude":
            "text.bubble"
        case "gemini":
            "sparkles"
        default:
            "doc.text"
        }
    }
}

private struct DetailExportToolbar: ToolbarContent {
    let detail: ConversationDetail

    var body: some ToolbarContent {
        #if os(macOS)
        ToolbarItem {
            Button {
                export(detail)
            } label: {
                Image(systemName: "square.and.arrow.up")
            }
            .help("Export as Markdown")
        }
        #else
        ToolbarItem {
            ShareLink(item: MarkdownExporter.export(detail)) {
                Image(systemName: "square.and.arrow.up")
            }
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

enum MarkdownExporter {
    static func export(_ detail: ConversationDetail) -> String {
        var lines: [String] = []

        lines.append("# \(detail.summary.title ?? "Untitled")")
        lines.append("")

        var metadata: [String] = []
        if let source = detail.summary.source {
            metadata.append("Source: \(source)")
        }
        if let model = detail.summary.model {
            metadata.append("Model: \(model)")
        }
        if let time = detail.summary.primaryTime {
            metadata.append("Date: \(time)")
        }

        if !metadata.isEmpty {
            lines.append(metadata.joined(separator: " | "))
            lines.append("")
            lines.append("---")
            lines.append("")
        }

        for message in detail.messages {
            lines.append("### \(message.isUser ? "**User**" : "**\(message.role.rawValue.capitalized)**")")
            lines.append("")
            lines.append(message.content)
            lines.append("")
        }

        return lines.joined(separator: "\n")
    }
}
