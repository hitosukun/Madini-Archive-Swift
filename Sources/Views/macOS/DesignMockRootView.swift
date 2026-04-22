#if os(macOS)
import AppKit
import SwiftUI

struct DesignMockRootView: View {
    @Environment(\.isSearching) private var isSearching
    @State private var selectedSidebarItemID: DesignMockSidebarItem.ID? = DesignMockSidebarItem.allThreads.id
    @State private var selectedConversationID: DesignMockConversation.ID? = DesignMockData.conversations.first?.id
    @State private var selectedLayoutMode: DesignMockLayoutMode = .default
    @State private var selectedCenterDisplayMode: DesignMockCenterDisplayMode = .cards
    @State private var searchText = ""
    @State private var selectedPromptIndex = 0
    @State private var expandedPromptConversationID: DesignMockConversation.ID?

    var body: some View {
        rootSplitView
        .searchable(text: $searchText, prompt: "検索")
        .navigationTitle("")
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                DesignMockLayoutModePicker(selection: $selectedLayoutMode, isCompact: isSearching || !searchText.isEmpty)
            }

            ToolbarItem(placement: .primaryAction) {
                DesignMockToolbarIconButton(systemImage: "square.and.arrow.up", help: "Share")
            }
        }
        .background(
            WindowConfigurator { window in
                window.titleVisibility = .hidden
                window.subtitle = ""
                window.title = ""
                window.representedURL = nil
                window.minSize = NSSize(width: 980, height: 640)
            }
        )
    }

    @ViewBuilder
    private var rootSplitView: some View {
        switch selectedLayoutMode {
        case .table:
            NavigationSplitView {
                DesignMockSidebar(selection: $selectedSidebarItemID)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
            } detail: {
                DesignMockThreadTablePane(
                    conversations: filteredConversations,
                    selection: $selectedConversationID
                )
            }
        case .default:
            NavigationSplitView {
                DesignMockSidebar(selection: $selectedSidebarItemID)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
            } content: {
                DesignMockDefaultContentPane(
                    displayMode: $selectedCenterDisplayMode,
                    conversations: filteredConversations,
                    conversationSelection: $selectedConversationID,
                    selectedPromptIndex: $selectedPromptIndex,
                    expandedPromptConversationID: $expandedPromptConversationID
                )
                .navigationSplitViewColumnWidth(min: 360, ideal: 460, max: 760)
            } detail: {
                DesignMockReaderPane(
                    conversation: selectedConversation,
                    selectedPromptIndex: $selectedPromptIndex,
                    prompts: DesignMockData.promptSnippets
                )
            }
        case .viewer:
            NavigationSplitView {
                DesignMockSidebar(selection: $selectedSidebarItemID)
                    .navigationSplitViewColumnWidth(min: 240, ideal: 270, max: 320)
            } detail: {
                DesignMockReaderPane(
                    conversation: selectedConversation,
                    selectedPromptIndex: $selectedPromptIndex,
                    prompts: DesignMockData.promptSnippets
                )
            }
        }
    }

    private var selectedConversation: DesignMockConversation? {
        guard let selectedConversationID else { return filteredConversations.first }
        return DesignMockData.conversations.first { $0.id == selectedConversationID } ?? filteredConversations.first
    }

    private var filteredConversations: [DesignMockConversation] {
        let query = searchText.trimmingCharacters(in: .whitespacesAndNewlines)
        return DesignMockData.conversations.filter { item in
            matchesSidebarFilter(item) && matchesSearch(item, query: query)
        }
    }

    private func matchesSidebarFilter(_ item: DesignMockConversation) -> Bool {
        guard let selectedSidebarItemID else { return true }
        switch DesignMockSidebarItem.kind(for: selectedSidebarItemID) {
        case .all:
            return true
        case .project(let id):
            return item.projectID == id
        case .suggested:
            if case .suggested = item.projectState { return true }
            return false
        case .unassigned:
            if case .none = item.projectState { return true }
            return false
        case .source(let source):
            return item.source.lowercased() == source.lowercased()
        }
    }

    private func matchesSearch(_ item: DesignMockConversation, query: String) -> Bool {
        guard !query.isEmpty else { return true }
        return item.title.localizedCaseInsensitiveContains(query)
            || item.projectLabel.localizedCaseInsensitiveContains(query)
            || item.source.localizedCaseInsensitiveContains(query)
    }
}

private struct DesignMockSidebar: View {
    @Binding var selection: DesignMockSidebarItem.ID?

    var body: some View {
        List(selection: $selection) {
            Section("Library") {
                sidebarRow(DesignMockSidebarItem.allThreads)
                sidebarRow(.init(id: "archive-db", title: "archive.db", subtitle: "Local SQLite archive", systemImage: "externaldrive", kind: .all))
            }

            Section("Projects") {
                ForEach(DesignMockData.projects.map(DesignMockSidebarItem.project)) { item in
                    sidebarRow(item)
                }
            }

            Section("Triage") {
                sidebarRow(.init(id: "suggested", title: "Needs review", subtitle: "Suggested project links", systemImage: "tray.and.arrow.down", kind: .suggested))
                sidebarRow(.init(id: "unassigned", title: "Unassigned", subtitle: "No project yet", systemImage: "circle.dashed", kind: .unassigned))
            }

            Section("Sources") {
                ForEach(DesignMockData.sources, id: \.name) { source in
                    sidebarRow(.init(
                        id: "source-\(source.name)",
                        title: source.name,
                        subtitle: "\(source.count) threads",
                        systemImage: "circle.fill",
                        kind: .source(source.name)
                    ))
                }
            }
        }
        .listStyle(.sidebar)
    }

    private func sidebarRow(_ item: DesignMockSidebarItem) -> some View {
        Label {
            VStack(alignment: .leading, spacing: 2) {
                Text(item.title)
                    .lineLimit(1)
                if let subtitle = item.subtitle {
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        } icon: {
            Image(systemName: item.systemImage)
                .foregroundStyle(item.iconStyle)
                .frame(width: 17)
        }
        .tag(item.id)
    }
}

private struct DesignMockThreadListPane: View {
    let conversations: [DesignMockConversation]
    @Binding var selection: DesignMockConversation.ID?
    @Binding var selectedPromptIndex: Int
    @Binding var expandedPromptConversationID: DesignMockConversation.ID?

    var body: some View {
        if let expandedConversation {
            pinnedPromptView(for: expandedConversation)
        } else {
            cardList
        }
    }

    private var cardList: some View {
        List {
            ForEach(conversations) { conversation in
                DesignMockConversationListRow(conversation: conversation)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        withAnimation(.easeOut(duration: 0.16)) {
                            selectOrToggle(conversation)
                        }
                    }
                .padding(.vertical, 6)
                .listRowBackground(rowBackground(for: conversation))
            }
        }
        .listStyle(.inset)
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
    }

    private func pinnedPromptView(for conversation: DesignMockConversation) -> some View {
        VStack(spacing: 0) {
            Button {
                withAnimation(.easeOut(duration: 0.16)) {
                    expandedPromptConversationID = nil
                }
            } label: {
                DesignMockConversationListRow(conversation: conversation)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.accentColor.opacity(0.14))
            }
            .buttonStyle(.plain)

            Divider()

            ScrollView {
                DesignMockExpandedPromptList(selectedPromptIndex: $selectedPromptIndex)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            .scrollContentBackground(.hidden)
        }
        .background(.regularMaterial)
    }

    private func selectOrToggle(_ conversation: DesignMockConversation) {
        if selection == conversation.id {
            expandedPromptConversationID = expandedPromptConversationID == conversation.id ? nil : conversation.id
        } else {
            selection = conversation.id
            expandedPromptConversationID = nil
            selectedPromptIndex = 0
        }
    }

    private func rowBackground(for conversation: DesignMockConversation) -> Color {
        conversation.id == selection ? Color.accentColor.opacity(0.14) : Color.clear
    }

    private var expandedConversation: DesignMockConversation? {
        guard let expandedPromptConversationID else { return nil }
        return conversations.first { $0.id == expandedPromptConversationID }
    }
}

private struct DesignMockDefaultContentPane: View {
    @Binding var displayMode: DesignMockCenterDisplayMode
    let conversations: [DesignMockConversation]
    @Binding var conversationSelection: DesignMockConversation.ID?
    @Binding var selectedPromptIndex: Int
    @Binding var expandedPromptConversationID: DesignMockConversation.ID?

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Picker("Center View", selection: $displayMode) {
                    ForEach(DesignMockCenterDisplayMode.allCases) { mode in
                        Image(systemName: mode.symbol)
                            .accessibilityLabel(Text(mode.title))
                            .tag(mode)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .controlSize(.small)
                .frame(width: 92)

                Spacer()
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)

            Divider()

            contentView
        }
    }

    @ViewBuilder
    private var contentView: some View {
        switch displayMode {
        case .table:
            DesignMockThreadTablePane(
                conversations: conversations,
                selection: $conversationSelection
            )
        case .cards:
            DesignMockThreadListPane(
                conversations: conversations,
                selection: $conversationSelection,
                selectedPromptIndex: $selectedPromptIndex,
                expandedPromptConversationID: $expandedPromptConversationID
            )
        }
    }
}

private struct DesignMockThreadTablePane: View {
    let conversations: [DesignMockConversation]
    @Binding var selection: DesignMockConversation.ID?

    var body: some View {
        Table(conversations, selection: $selection) {
            TableColumn("Title") { conversation in
                Text(conversation.title)
                    .lineLimit(1)
            }
            TableColumn("Project") { conversation in
                Text(conversation.projectLabel)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            TableColumn("Updated") { conversation in
                Text(conversation.updated)
                    .foregroundStyle(.secondary)
            }
            .width(82)
            TableColumn("Prompts") { conversation in
                Text("\(conversation.prompts)")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
            }
            .width(70)
            TableColumn("Source") { conversation in
                Text(conversation.source)
                    .foregroundStyle(conversation.sourceColor)
            }
            .width(82)
        }
    }
}

private struct DesignMockExpandedPromptList: View {
    @Binding var selectedPromptIndex: Int

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            ForEach(DesignMockData.promptSnippets.indices, id: \.self) { index in
                Button {
                    selectedPromptIndex = index
                } label: {
                    HStack(alignment: .firstTextBaseline, spacing: 8) {
                        Image(systemName: "text.bubble")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .frame(width: 16)

                        Text(DesignMockData.promptSnippets[index])
                            .font(.caption)
                            .lineLimit(1)

                        Spacer(minLength: 8)

                        Text("\(index + 1)")
                            .font(.caption2.monospacedDigit())
                            .foregroundStyle(.secondary)
                }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 8)
                    .background(
                        selectedPromptIndex == index ? Color.accentColor.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6, style: .continuous)
                    )
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.leading, 22)
        .padding(.trailing, 2)
    }
}

private struct DesignMockReaderPane: View {
    let conversation: DesignMockConversation?
    @Binding var selectedPromptIndex: Int
    let prompts: [String]

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                DesignMockReaderTitle(
                    conversation: conversation,
                    selectedPromptIndex: $selectedPromptIndex,
                    prompts: prompts
                )

                VStack(alignment: .leading, spacing: 14) {
                    Text("Original-preserving reader mock")
                        .font(.title3.weight(.semibold))

                    Text("This area stands in for the eventual conversation renderer. The chrome is intentionally native: the sidebar keeps source-list behavior, the window toolbar owns global actions, and prompt navigation lives with the reader context.")
                        .lineSpacing(5)

                    Text("Project hints, source metadata, and prompt position are shown as reading context rather than written back into canonical message bodies.")
                        .foregroundStyle(.secondary)
                        .lineSpacing(5)
                }
                .padding(18)
                .frame(maxWidth: 760, alignment: .leading)
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 12, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 12, style: .continuous)
                        .strokeBorder(.quaternary, lineWidth: 0.7)
                }
            }
            .padding(.horizontal, 28)
            .padding(.vertical, 26)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(.background)
    }
}

private struct DesignMockReaderTitle: View {
    let conversation: DesignMockConversation?
    @Binding var selectedPromptIndex: Int
    let prompts: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(conversation?.title ?? "Select a conversation")
                .font(.largeTitle.weight(.semibold))
                .lineLimit(2)
                .textSelection(.enabled)

            HStack(spacing: 8) {
                Label(conversation?.source ?? "source", systemImage: "tray.full")
                    .foregroundStyle(conversation?.sourceColor ?? .secondary)
                Text("·")
                    .foregroundStyle(.tertiary)
                promptMenu
                Text("·")
                    .foregroundStyle(.tertiary)
                Text(conversation?.projectLabel ?? "No project")
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            .font(.callout)
        }
    }

    private var promptMenu: some View {
        Menu {
            ForEach(prompts.indices, id: \.self) { index in
                Button {
                    selectedPromptIndex = index
                } label: {
                    Label(
                        "Prompt \(index + 1): \(prompts[index])",
                        systemImage: index == selectedPromptIndex ? "checkmark" : "text.bubble"
                    )
                }
            }
        } label: {
            HStack(spacing: 5) {
                Label(currentPromptTitle, systemImage: "text.bubble")
                    .lineLimit(1)
                Text("\(min(selectedPromptIndex + 1, max(prompts.count, 1))) / \(max(prompts.count, 1))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
    }

    private var currentPromptTitle: String {
        guard prompts.indices.contains(selectedPromptIndex) else {
            return "Prompt"
        }
        return prompts[selectedPromptIndex]
    }
}

private struct DesignMockConversationListRow: View {
    let conversation: DesignMockConversation

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(conversation.title)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)

                Spacer(minLength: 8)

                Text(conversation.updated)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }

            HStack(spacing: 8) {
                Label(conversation.projectLabel, systemImage: conversation.projectSymbol)
                    .lineLimit(1)
                Text("\(conversation.prompts) prompts")
                    .monospacedDigit()
                Text(conversation.source)
                    .foregroundStyle(conversation.sourceColor)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 6)
    }
}

private struct DesignMockLayoutModePicker: View {
    @Binding var selection: DesignMockLayoutMode
    let isCompact: Bool

    var body: some View {
        Picker("Layout", selection: $selection) {
            ForEach(DesignMockLayoutMode.allCases) { mode in
                Image(systemName: mode.symbol)
                    .accessibilityLabel(Text(mode.title))
                    .tag(mode)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .controlSize(isCompact ? .small : .regular)
        .help("Layout mode")
    }
}

private struct DesignMockToolbarIconButton: View {
    let systemImage: String
    let help: String
    var action: () -> Void = {}

    init(systemImage: String, help: String, action: @escaping () -> Void = {}) {
        self.systemImage = systemImage
        self.help = help
        self.action = action
    }

    var body: some View {
        Button {
            action()
        } label: {
            Image(systemName: systemImage)
                .font(DesignMockToolbarMetrics.iconFont)
                .foregroundStyle(.primary)
        }
        .help(help)
    }
}

private enum DesignMockToolbarMetrics {
    static let iconFont: Font = .system(size: 14, weight: .semibold)
}

private struct DesignMockSidebarItem: Identifiable {
    enum Kind: Equatable {
        case all
        case project(String)
        case suggested
        case unassigned
        case source(String)
    }

    let id: String
    let title: String
    let subtitle: String?
    let systemImage: String
    let kind: Kind

    static let allThreads = DesignMockSidebarItem(
        id: "all",
        title: "All Threads",
        subtitle: "629 threads",
        systemImage: "rectangle.stack",
        kind: .all
    )

    static func project(_ project: DesignMockProject) -> DesignMockSidebarItem {
        DesignMockSidebarItem(
            id: "project-\(project.id)",
            title: project.title,
            subtitle: "\(project.count) threads",
            systemImage: "folder",
            kind: .project(project.id)
        )
    }

    static func kind(for id: String) -> Kind {
        if id == allThreads.id || id == "archive-db" { return .all }
        if id == "suggested" { return .suggested }
        if id == "unassigned" { return .unassigned }
        if let project = DesignMockData.projects.first(where: { "project-\($0.id)" == id }) {
            return .project(project.id)
        }
        if let source = DesignMockData.sources.first(where: { "source-\($0.name)" == id }) {
            return .source(source.name)
        }
        return .all
    }

    var iconStyle: AnyShapeStyle {
        switch kind {
        case .source(let source):
            AnyShapeStyle(DesignMockSource(name: source, count: 0).color)
        default:
            AnyShapeStyle(.secondary)
        }
    }
}

private enum DesignMockLayoutMode: String, CaseIterable, Identifiable {
    case table
    case `default`
    case viewer

    var id: String { rawValue }

    var title: String {
        switch self {
        case .table: return "Table"
        case .default: return "Default"
        case .viewer: return "Viewer"
        }
    }

    var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .default: return "rectangle.split.3x1"
        case .viewer: return "doc.plaintext"
        }
    }
}

private enum DesignMockCenterDisplayMode: String, CaseIterable, Identifiable {
    case table
    case cards

    var id: String { rawValue }

    var title: String {
        switch self {
        case .cards: return "Cards"
        case .table: return "Table"
        }
    }

    var symbol: String {
        switch self {
        case .cards: return "rectangle.stack"
        case .table: return "tablecells"
        }
    }
}

private struct DesignMockProject: Identifiable {
    let id: String
    let title: String
    let count: Int
}

private struct DesignMockSource {
    let name: String
    let count: Int

    var color: Color {
        switch name.lowercased() {
        case "chatgpt": return .green
        case "claude": return .orange
        case "gemini": return .blue
        default: return .secondary
        }
    }
}

private struct DesignMockConversation: Identifiable {
    let id: String
    let title: String
    let projectID: String?
    let projectState: DesignMockProjectState
    let updated: String
    let sortRank: Int
    let prompts: Int
    let source: String

    var projectLabel: String {
        switch projectState {
        case .assigned(let title, _):
            return title
        case .suggested(let title, _, _):
            return "Suggested: \(title)"
        case .none:
            return "Unassigned"
        }
    }

    var projectSymbol: String {
        switch projectState {
        case .assigned(_, let kind):
            return kind == .manual ? "folder.badge.gearshape" : "folder"
        case .suggested:
            return "wand.and.stars"
        case .none:
            return "circle.dashed"
        }
    }

    var sourceColor: Color {
        DesignMockSource(name: source, count: 0).color
    }
}

private enum DesignMockProjectState {
    case assigned(title: String, kind: DesignMockProjectMembership)
    case suggested(title: String, score: Double, reason: String)
    case none
}

private enum DesignMockProjectMembership {
    case imported
    case manual
    case suggested
}

private enum DesignMockData {
    static let projects: [DesignMockProject] = [
        .init(id: "alraune", title: "アルラウネ執筆", count: 42),
        .init(id: "yuri", title: "ファンタジー百合小説", count: 31),
        .init(id: "madini", title: "Madini Archive", count: 18),
        .init(id: "reading", title: "読書メモ", count: 9)
    ]

    static let sources: [DesignMockSource] = [
        .init(name: "chatgpt", count: 547),
        .init(name: "gemini", count: 55),
        .init(name: "claude", count: 27)
    ]

    static let conversations: [DesignMockConversation] = [
        .init(id: "c1", title: "自作小説アルラウネの執筆支援", projectID: "alraune", projectState: .assigned(title: "アルラウネ執筆", kind: .imported), updated: "Apr 18", sortRank: 1, prompts: 42, source: "chatgpt"),
        .init(id: "c2", title: "アルラウネ 設定まとめ", projectID: "alraune", projectState: .assigned(title: "アルラウネ執筆", kind: .imported), updated: "Apr 12", sortRank: 2, prompts: 23, source: "chatgpt"),
        .init(id: "c3", title: "続きの話を聞く", projectID: "alraune", projectState: .assigned(title: "アルラウネ執筆", kind: .suggested), updated: "Apr 08", sortRank: 3, prompts: 15, source: "chatgpt"),
        .init(id: "c4", title: "Opusの意味とモデル名の由来", projectID: nil, projectState: .suggested(title: "Madini Archive", score: 0.62, reason: "SwiftUI・モデル名・アプリ命名"), updated: "Apr 02", sortRank: 4, prompts: 7, source: "claude"),
        .init(id: "c5", title: "ファンタジー百合小説の設定と脚本管理", projectID: "yuri", projectState: .assigned(title: "ファンタジー百合小説", kind: .imported), updated: "Mar 28", sortRank: 5, prompts: 31, source: "chatgpt"),
        .init(id: "c6", title: "輪行で運動習慣", projectID: nil, projectState: .suggested(title: "読書メモ", score: 0.48, reason: "運動・習慣・記録"), updated: "Mar 22", sortRank: 6, prompts: 11, source: "gemini"),
        .init(id: "c7", title: "README 改善提案", projectID: "madini", projectState: .assigned(title: "Madini Archive", kind: .manual), updated: "Mar 15", sortRank: 7, prompts: 6, source: "claude"),
        .init(id: "c8", title: "複利の仕組み", projectID: nil, projectState: .none, updated: "Mar 09", sortRank: 8, prompts: 4, source: "gemini"),
        .init(id: "c9", title: "会話統計と傾向分析", projectID: "madini", projectState: .assigned(title: "Madini Archive", kind: .imported), updated: "Mar 01", sortRank: 9, prompts: 18, source: "chatgpt"),
        .init(id: "c10", title: "転校生の逆の表現", projectID: nil, projectState: .none, updated: "Feb 26", sortRank: 10, prompts: 5, source: "claude")
    ]

    static let promptSnippets = [
        "自作小説アルラウネを執筆支援",
        "キャラクター設定の深掘り",
        "世界観の補足設定を追加",
        "第一章の推敲",
        "アルラウネの過去エピソード",
        "対話シーンの調整"
    ]
}
#endif
