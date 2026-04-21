#if os(macOS)
import SwiftUI

struct DesignMockRootView: View {
    @State private var selectedMode: DesignMockMode = .default
    @State private var selectedProjectID: String?
    @State private var selectedConversationID = DesignMockData.conversations.first?.id
    @State private var sortKey: DesignMockSortKey = .newest
    @State private var hoveredBreadcrumbSegment: DesignMockBreadcrumbSegment?

    private let sidebarWidth: CGFloat = 260
    private let toolbarHeight: CGFloat = 52

    var body: some View {
        GeometryReader { geometry in
            ZStack {
                DesignMockLiquidBackground()

                HStack(spacing: 0) {
                    sidebar
                        .frame(width: sidebarWidth)

                    VStack(spacing: 0) {
                        toolbar(width: max(0, geometry.size.width - sidebarWidth))

                        HStack(spacing: 0) {
                            middlePane
                                .frame(width: middleWidth(totalWidth: geometry.size.width - sidebarWidth))

                            if selectedMode != .table {
                                readerPane
                                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                            }
                        }
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .foregroundStyle(DesignMockColors.primaryText)
        }
        .background(
            WindowConfigurator { window in
                window.titleVisibility = .hidden
                window.isMovableByWindowBackground = true
            }
        )
    }

    private func toolbar(width: CGFloat) -> some View {
        HStack(spacing: 12) {
            sortChip
                .layoutPriority(4)

            Spacer(minLength: 8)

            breadcrumb
                .frame(maxWidth: min(760, max(80, width - 260)), alignment: .center)
                .layoutPriority(2)

            Spacer(minLength: 8)

            HStack(spacing: 6) {
                toolbarIconButton("square.and.arrow.up")
                modePicker
            }
                .layoutPriority(5)
        }
        .padding(.horizontal, 12)
        .frame(height: toolbarHeight)
        .background(.ultraThinMaterial)
        .background(DesignMockColors.toolbarTint)
        .overlay(alignment: .bottom) {
            Rectangle()
                .fill(DesignMockColors.border)
                .frame(height: 1)
        }
    }

    private var sortChip: some View {
        Menu {
            ForEach(DesignMockSortKey.allCases) { key in
                Button {
                    sortKey = key
                } label: {
                    Label(key.menuTitle, systemImage: sortKey == key ? "checkmark" : key.symbol)
                }
            }
        } label: {
            ViewThatFits(in: .horizontal) {
                HStack(spacing: 4) {
                    Image(systemName: sortKey.symbol)
                        .font(.system(size: 12, weight: .semibold))
                    Text(sortKey.shortTitle)
                        .font(.caption2)
                        .lineLimit(1)
                }

                Image(systemName: sortKey.symbol)
                    .font(.system(size: 12, weight: .semibold))
            }
            .padding(.horizontal, 10)
            .frame(minWidth: 30)
            .frame(height: 24)
            .clipShape(Capsule())
            .background(.thinMaterial, in: Capsule())
            .background(DesignMockColors.glassWash, in: Capsule())
            .overlay {
                Capsule()
                    .stroke(DesignMockColors.glassStroke, lineWidth: 0.7)
            }
            .shadow(color: DesignMockColors.glassShadow, radius: 8, y: 3)
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize(horizontal: true, vertical: false)
    }

    private var breadcrumb: some View {
        ViewThatFits(in: .horizontal) {
            breadcrumbCapsule(titleWidth: 260, promptWidth: 260, promptStyle: .full, showsCounter: true)
            breadcrumbCapsule(titleWidth: 190, promptWidth: 170, promptStyle: .full, showsCounter: true)
            breadcrumbCapsule(titleWidth: 130, promptWidth: 92, promptStyle: .full, showsCounter: true)
            breadcrumbCapsule(titleWidth: 130, promptWidth: 24, promptStyle: .ellipsis, showsCounter: true)
            breadcrumbCapsule(titleWidth: 96, promptWidth: 0, promptStyle: .hidden, showsCounter: false)
        }
        .frame(minWidth: 0, alignment: .center)
    }

    private func breadcrumbCapsule(
        titleWidth: CGFloat,
        promptWidth: CGFloat,
        promptStyle: DesignMockPromptBreadcrumbStyle,
        showsCounter: Bool
    ) -> some View {
        HStack(spacing: 0) {
            breadcrumbSegment("自作小説アルラウネの執筆支援", weight: .semibold, segment: .title, width: titleWidth)

            if promptStyle != .hidden {
                Image(systemName: "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(hoveredBreadcrumbSegment == .title ? DesignMockColors.tertiaryText.opacity(0.35) : DesignMockColors.tertiaryText)
                    .padding(.horizontal, 2)

                switch promptStyle {
                case .full:
                    breadcrumbPromptSegment(width: promptWidth, showsCounter: showsCounter)
                case .ellipsis:
                    breadcrumbPromptSegment(width: promptWidth, promptStyle: .ellipsis, showsCounter: showsCounter)
                case .hidden:
                    EmptyView()
                }
            }
        }
        .padding(.horizontal, 4)
        .frame(height: 24)
        .fixedSize(horizontal: true, vertical: false)
        .clipShape(Capsule())
        .background(.thinMaterial, in: Capsule())
        .background(DesignMockColors.glassWash.opacity(0.8), in: Capsule())
        .overlay {
            Capsule()
                .stroke(DesignMockColors.glassStroke.opacity(0.75), lineWidth: 0.6)
        }
        .shadow(color: DesignMockColors.glassShadow, radius: 10, y: 4)
    }

    private var promptCounter: some View {
        Text("1 / 42")
            .font(.caption2)
            .monospacedDigit()
            .foregroundStyle(DesignMockColors.secondaryText)
            .padding(.trailing, 4)
    }

    private func breadcrumbPromptSegment(
        width: CGFloat,
        promptStyle: DesignMockPromptBreadcrumbStyle = .full,
        showsCounter: Bool
    ) -> some View {
        Menu {
            ForEach(DesignMockData.promptSnippets.indices, id: \.self) { index in
                Button("プロンプト \(index + 1)") {}
            }
        } label: {
            HStack(spacing: 6) {
                switch promptStyle {
                case .full:
                    Text("自作小説アルラウネを執筆支援")
                        .font(.system(size: 13))
                        .lineLimit(1)
                        .truncationMode(.tail)
                        .foregroundStyle(DesignMockColors.secondaryText)
                        .frame(width: width, alignment: .leading)
                case .ellipsis:
                    Text("…")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(DesignMockColors.secondaryText)
                        .frame(width: width, alignment: .center)
                case .hidden:
                    EmptyView()
                }

                if showsCounter {
                    promptCounter
                }
            }
            .padding(.horizontal, 6)
            .frame(height: 22)
            .background(
                hoveredBreadcrumbSegment == .prompt ? DesignMockColors.segmentHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovering in
            hoveredBreadcrumbSegment = isHovering ? .prompt : (hoveredBreadcrumbSegment == .prompt ? nil : hoveredBreadcrumbSegment)
        }
    }

    private func breadcrumbSegment(_ title: String, weight: Font.Weight, segment: DesignMockBreadcrumbSegment, width: CGFloat? = nil) -> some View {
        Menu {
            ForEach(DesignMockData.conversations.prefix(8)) { item in
                Button(item.title) {
                    selectedConversationID = item.id
                }
            }
        } label: {
            HStack(spacing: 6) {
                Text(title)
                    .font(.system(size: 13, weight: weight))
                    .lineLimit(1)
                    .truncationMode(.tail)
                Image(systemName: "chevron.down")
                    .font(.system(size: 8, weight: .bold))
                    .foregroundStyle(DesignMockColors.secondaryText)
                    .opacity(hoveredBreadcrumbSegment == segment ? 1 : 0)
            }
            .padding(.horizontal, 6)
            .frame(width: width, height: 22, alignment: .leading)
            .background(
                hoveredBreadcrumbSegment == segment ? DesignMockColors.segmentHover : Color.clear,
                in: RoundedRectangle(cornerRadius: 9, style: .continuous)
            )
            .contentShape(Rectangle())
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .onHover { isHovering in
            hoveredBreadcrumbSegment = isHovering ? segment : (hoveredBreadcrumbSegment == segment ? nil : hoveredBreadcrumbSegment)
        }
    }

    private var modePicker: some View {
        HStack(spacing: 0) {
            ForEach(DesignMockMode.allCases) { mode in
                Button {
                    withAnimation(.easeOut(duration: 0.12)) {
                        selectedMode = mode
                    }
                } label: {
                    Image(systemName: mode.symbol)
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(selectedMode == mode ? DesignMockColors.primaryText : DesignMockColors.secondaryText)
                        .frame(width: 30, height: 24)
                        .background(selectedMode == mode ? DesignMockColors.segmentSelected : Color.clear, in: Capsule())
                }
                .buttonStyle(.plain)
                .help(mode.title)
            }
        }
        .padding(2)
        .clipShape(Capsule())
        .background(.thinMaterial, in: Capsule())
        .background(DesignMockColors.glassWash, in: Capsule())
        .overlay {
            Capsule()
                .stroke(DesignMockColors.glassStroke, lineWidth: 0.7)
        }
        .shadow(color: DesignMockColors.glassShadow, radius: 8, y: 3)
    }

    private func toolbarIconButton(_ systemName: String) -> some View {
        Button {
        } label: {
            Image(systemName: systemName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(DesignMockColors.secondaryText)
                .frame(width: 30, height: 28)
        }
        .buttonStyle(.plain)
        .clipShape(Capsule())
        .background(.thinMaterial, in: Capsule())
        .background(DesignMockColors.glassWash, in: Capsule())
        .overlay {
            Capsule()
                .stroke(DesignMockColors.glassStroke, lineWidth: 0.7)
        }
        .shadow(color: DesignMockColors.glassShadow, radius: 8, y: 3)
    }

    private var sidebar: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                    .frame(height: 14)

                sidebarSection("LIBRARY") {
                    sidebarRow(id: "__all", glyph: "circle.grid.2x2.fill", title: "All threads", count: 629)
                    sidebarSubtleRow(glyph: "externaldrive", title: "archive.db")
                }

                sidebarSection("PROJECTS") {
                    ForEach(DesignMockData.projects) { project in
                        sidebarRow(id: project.id, glyph: "folder.fill", title: project.title, count: project.count)
                    }
                }

                sidebarSection("TRIAGE") {
                    sidebarRow(id: "__inbox", glyph: "tray.and.arrow.down.fill", title: "Inbox", count: 12)
                    sidebarRow(id: "__orphans", glyph: "circle", title: "Orphans", count: 517)
                }

                sidebarSection("SOURCES") {
                    sidebarSubtleRow(glyph: "circle.fill", title: "chatgpt", count: "547")
                    sidebarSubtleRow(glyph: "circle.fill", title: "gemini", count: "55")
                    sidebarSubtleRow(glyph: "circle.fill", title: "claude", count: "27")
                }
            }
            .padding(.horizontal, 12)
            .padding(.bottom, 20)
        }
        .scrollContentBackground(.hidden)
        .background(.ultraThinMaterial)
        .background(DesignMockColors.sidebarTint)
        .overlay(alignment: .trailing) {
            Rectangle()
                .fill(DesignMockColors.border)
                .frame(width: 1)
        }
    }

    private func sidebarSection<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title)
                .font(.caption2.weight(.semibold))
                .foregroundStyle(DesignMockColors.tertiaryText)
                .tracking(0.6)
            VStack(alignment: .leading, spacing: 3) {
                content()
            }
        }
    }

    private func sidebarRow(id: String, glyph: String, title: String, count: Int) -> some View {
        Button {
            selectedProjectID = selectedProjectID == id ? nil : id
        } label: {
            HStack(spacing: 8) {
                Image(systemName: glyph)
                    .font(.system(size: 12, weight: .medium))
                    .frame(width: 18)
                    .foregroundStyle(isProjectSelected(id) ? DesignMockColors.primaryText : DesignMockColors.secondaryText)
                Text(title)
                    .lineLimit(1)
                Spacer()
                Text("\(count)")
                    .font(.caption2)
                    .monospacedDigit()
                    .foregroundStyle(isProjectSelected(id) ? DesignMockColors.primaryText.opacity(0.65) : DesignMockColors.tertiaryText)
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 28)
            .background(isProjectSelected(id) ? DesignMockColors.sidebarSelection : Color.clear, in: RoundedRectangle(cornerRadius: 8, style: .continuous))
            .overlay {
                if isProjectSelected(id) {
                    RoundedRectangle(cornerRadius: 8, style: .continuous)
                        .stroke(DesignMockColors.glassStroke.opacity(0.6), lineWidth: 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func sidebarSubtleRow(glyph: String, title: String, count: String? = nil) -> some View {
        HStack(spacing: 8) {
            Image(systemName: glyph)
                .font(.system(size: 11, weight: .medium))
                .frame(width: 18)
                .foregroundStyle(DesignMockColors.tertiaryText)
            Text(title)
                .lineLimit(1)
            Spacer()
            if let count {
                Text(count)
                    .font(.caption2)
                    .foregroundStyle(DesignMockColors.tertiaryText)
            }
        }
        .font(.callout)
        .foregroundStyle(DesignMockColors.secondaryText)
        .padding(.horizontal, 8)
        .frame(height: 26)
    }

    private var middlePane: some View {
        Group {
            switch selectedMode {
            case .viewer:
                viewerIndex
            case .focus:
                EmptyView()
            case .table, .default:
                conversationTable
            }
        }
        .background(.regularMaterial)
        .background(DesignMockColors.middleTint)
        .overlay(alignment: .trailing) {
            if selectedMode != .table {
                Rectangle()
                    .fill(DesignMockColors.border)
                    .frame(width: 1)
            }
        }
    }

    private var conversationTable: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 14)

            HStack(spacing: 0) {
                tableHeader("Title", width: nil, alignment: .leading)
                tableHeader("Project", width: 210, alignment: .leading)
                if selectedMode == .table {
                    tableHeader("Updated", width: 92, alignment: .leading)
                }
                tableHeader("Prompts", width: 72, alignment: .trailing)
                if selectedMode == .table {
                    tableHeader("Source", width: 86, alignment: .leading)
                }
            }
            .padding(.horizontal, 12)
            .frame(height: 28)
            .background(.thinMaterial)
            .background(DesignMockColors.headerTint)
            .overlay(alignment: .bottom) {
                Rectangle()
                    .fill(DesignMockColors.border)
                    .frame(height: 1)
            }

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(filteredConversations) { item in
                        tableRow(item)
                    }
                }
                .padding(.horizontal, 12)
                .padding(.vertical, 4)
            }
            .scrollContentBackground(.hidden)
        }
    }

    @ViewBuilder
    private func tableHeader(_ text: String, width: CGFloat?, alignment: Alignment) -> some View {
        let label = Text(text)
            .font(.caption.weight(.semibold))
            .foregroundStyle(DesignMockColors.secondaryText)
        if let width {
            label.frame(width: width, alignment: alignment)
        } else {
            label.frame(maxWidth: .infinity, alignment: alignment)
        }
    }

    private func tableRow(_ item: DesignMockConversation) -> some View {
        Button {
            selectedConversationID = item.id
        } label: {
            HStack(spacing: 0) {
                Text(item.title)
                    .font(.callout.weight(item.id == selectedConversationID ? .semibold : .regular))
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)

                projectCell(item)
                    .frame(width: 210, alignment: .leading)

                if selectedMode == .table {
                    Text(item.updated)
                        .foregroundStyle(DesignMockColors.secondaryText)
                        .frame(width: 92, alignment: .leading)
                }

                Text("\(item.prompts)")
                    .monospacedDigit()
                    .foregroundStyle(DesignMockColors.secondaryText)
                    .frame(width: 72, alignment: .trailing)

                if selectedMode == .table {
                    Text(item.source)
                        .foregroundStyle(sourceColor(item.source))
                        .frame(width: 86, alignment: .leading)
                }
            }
            .font(.callout)
            .padding(.horizontal, 8)
            .frame(height: 32)
            .background(
                item.id == selectedConversationID ? DesignMockColors.tableSelection : rowStripe(for: item),
                in: RoundedRectangle(cornerRadius: 7, style: .continuous)
            )
            .overlay {
                if item.id == selectedConversationID {
                    RoundedRectangle(cornerRadius: 7, style: .continuous)
                        .stroke(DesignMockColors.glassStroke.opacity(0.55), lineWidth: 0.5)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: 7, style: .continuous))
        }
        .buttonStyle(.plain)
    }

    private func projectCell(_ item: DesignMockConversation) -> some View {
        HStack(spacing: 5) {
            switch item.projectState {
            case .assigned(let title, let kind):
                Image(systemName: "folder.fill")
                    .font(.system(size: 11, weight: .medium))
                    .foregroundStyle(DesignMockColors.tertiaryText)
                Text(title)
                    .lineLimit(1)
                if kind == .manual {
                    Image(systemName: "pencil")
                        .font(.system(size: 9, weight: .medium))
                        .foregroundStyle(DesignMockColors.tertiaryText)
                }
            case .suggested(let title, let score, _):
                Image(systemName: "arrow.right")
                    .font(.system(size: 10, weight: .bold))
                    .foregroundStyle(DesignMockColors.tertiaryText)
                Text(title)
                    .lineLimit(1)
                Text(String(format: "%.2f", score))
                    .font(.caption2)
                    .foregroundStyle(DesignMockColors.tertiaryText)
            case .none:
                Text("—")
                    .foregroundStyle(DesignMockColors.tertiaryText)
            }
        }
        .font(.caption)
        .foregroundStyle(DesignMockColors.secondaryText)
    }

    private var viewerIndex: some View {
        VStack(spacing: 0) {
            Spacer()
                .frame(height: 14)

            viewerCard
                .padding(12)

            ScrollView {
                LazyVStack(spacing: 0) {
                    ForEach(0..<18, id: \.self) { index in
                        HStack(alignment: .firstTextBaseline, spacing: 10) {
                            Text("\(index + 1)")
                                .font(.caption2)
                                .monospacedDigit()
                                .foregroundStyle(DesignMockColors.tertiaryText)
                                .frame(width: 28, alignment: .trailing)
                            Text(DesignMockData.promptSnippets[index % DesignMockData.promptSnippets.count])
                                .font(.callout)
                                .lineLimit(1)
                            Spacer()
                        }
                        .padding(.horizontal, 14)
                        .frame(height: 34)
                        .background(index == 0 ? DesignMockColors.tableSelection.opacity(0.22) : Color.clear)
                        .overlay(alignment: .leading) {
                            if index == 0 {
                                Rectangle()
                                    .fill(DesignMockColors.selection)
                                    .frame(width: 2)
                            }
                        }
                    }
                }
            }
            .scrollContentBackground(.hidden)
        }
    }

    private var viewerCard: some View {
        HStack(alignment: .top, spacing: 14) {
            VStack(alignment: .leading, spacing: 7) {
                Text(selectedConversation?.title ?? "自作小説アルラウネの執筆支援")
                    .font(.headline)
                    .lineLimit(2)
                HStack(spacing: 5) {
                    Text(selectedConversation?.source ?? "chatgpt")
                        .foregroundStyle(sourceColor(selectedConversation?.source ?? "chatgpt"))
                    Text("·")
                        .foregroundStyle(DesignMockColors.tertiaryText)
                    Image(systemName: "bubble.left")
                    Text("\(selectedConversation?.prompts ?? 42)")
                    Text("·")
                        .foregroundStyle(DesignMockColors.tertiaryText)
                    Text(selectedConversation?.updated ?? "Apr 18")
                }
                .font(.caption)
                .foregroundStyle(DesignMockColors.secondaryText)
            }

            Spacer()

            VStack(alignment: .trailing, spacing: 4) {
                projectCell(selectedConversation ?? DesignMockData.conversations[0])
                Text("真夜・錫花・アビエニア")
                    .font(.caption2)
                    .foregroundStyle(DesignMockColors.tertiaryText)
            }
        }
        .padding(14)
        .clipShape(RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .background(DesignMockColors.glassWash, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .stroke(DesignMockColors.glassStroke, lineWidth: 0.7)
        }
        .shadow(color: DesignMockColors.glassShadow, radius: 12, y: 5)
    }

    private var readerPane: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                Spacer()
                    .frame(height: 22)

                Text("Reader pane")
                    .font(.title3.weight(.semibold))

                Text("Resize and switch modes to exercise the new shell. This pane is intentionally static for now; later we can connect the real reader and repositories into this surface.")
                    .foregroundStyle(DesignMockColors.secondaryText)
                    .lineSpacing(4)

                VStack(alignment: .leading, spacing: 12) {
                    Text("自作小説アルラウネの執筆支援")
                        .font(.title2.weight(.semibold))
                    Text("ここはあとで実データの会話本文を流し込む場所。今は見た目のリズム、余白、プロジェクト表示、toolbar の優先度だけを見るための静的プロトタイプにしているよ。")
                        .lineSpacing(6)
                    Text("プロジェクトはタグではなく、取り込み元フォルダとユーザー判断から生まれる読み返し用の軸として扱う想定。")
                        .foregroundStyle(DesignMockColors.secondaryText)
                        .lineSpacing(6)
                }
                .padding(20)
                .clipShape(RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background(.thinMaterial, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .background(DesignMockColors.glassWash, in: RoundedRectangle(cornerRadius: 18, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: 18, style: .continuous)
                        .stroke(DesignMockColors.glassStroke, lineWidth: 0.7)
                }
                .shadow(color: DesignMockColors.glassShadow, radius: 16, y: 7)
            }
            .padding(.horizontal, 26)
            .padding(.bottom, 32)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .scrollContentBackground(.hidden)
        .background(.regularMaterial)
        .background(DesignMockColors.readerTint)
    }

    private var filteredConversations: [DesignMockConversation] {
        let selected = selectedProjectID
        return DesignMockData.conversations.filter { item in
            guard let selected else { return true }
            if selected == "__all" { return true }
            if selected == "__inbox" {
                if case .suggested = item.projectState { return true }
                return false
            }
            if selected == "__orphans" {
                if case .none = item.projectState { return true }
                return false
            }
            return item.projectID == selected
        }
    }

    private var selectedConversation: DesignMockConversation? {
        DesignMockData.conversations.first { $0.id == selectedConversationID }
    }

    private func middleWidth(totalWidth: CGFloat) -> CGFloat? {
        guard selectedMode != .focus else { return 0 }
        if selectedMode == .table { return nil }
        return max(380, min(560, totalWidth * 0.38))
    }

    private func isProjectSelected(_ id: String) -> Bool {
        if id == "__all" {
            return selectedProjectID == "__all"
        }
        return selectedProjectID == id
    }

    private func sourceColor(_ source: String) -> Color {
        switch source.lowercased() {
        case "chatgpt": return .green
        case "claude": return .orange
        case "gemini": return .blue
        default: return DesignMockColors.secondaryText
        }
    }

    private func rowStripe(for item: DesignMockConversation) -> Color {
        guard let index = DesignMockData.conversations.firstIndex(where: { $0.id == item.id }) else {
            return Color.clear
        }
        return index.isMultiple(of: 2) ? Color.white.opacity(0.035) : Color.clear
    }
}

private enum DesignMockColors {
    static let toolbarTint = Color.white.opacity(0.16)
    static let sidebarTint = Color.white.opacity(0.10)
    static let middleTint = Color.white.opacity(0.28)
    static let readerTint = Color.white.opacity(0.34)
    static let headerTint = Color.white.opacity(0.20)
    static let glassWash = Color.white.opacity(0.18)
    static let glassStroke = Color.white.opacity(0.34)
    static let glassShadow = Color.black.opacity(0.10)
    static let segmentHover = Color.primary.opacity(0.08)
    static let segmentSelected = Color.white.opacity(0.38)
    static let selection = Color.accentColor
    static let sidebarSelection = Color.white.opacity(0.30)
    static let tableSelection = Color.accentColor.opacity(0.82)
    static let border = Color.primary.opacity(0.10)
    static let primaryText = Color.primary.opacity(0.92)
    static let secondaryText = Color.secondary.opacity(0.82)
    static let tertiaryText = Color.secondary.opacity(0.50)
}

private enum DesignMockBreadcrumbSegment {
    case title
    case prompt
}

private enum DesignMockPromptBreadcrumbStyle {
    case full
    case ellipsis
    case hidden
}

private struct DesignMockLiquidBackground: View {
    var body: some View {
        ZStack {
            LinearGradient(
                colors: [
                    Color(nsColor: .windowBackgroundColor),
                    Color.accentColor.opacity(0.10),
                    Color(nsColor: .textBackgroundColor)
                ],
                startPoint: .topLeading,
                endPoint: .bottomTrailing
            )

            Circle()
                .fill(Color.blue.opacity(0.13))
                .frame(width: 520, height: 520)
                .blur(radius: 80)
                .offset(x: -360, y: -260)

            Circle()
                .fill(Color.cyan.opacity(0.10))
                .frame(width: 460, height: 460)
                .blur(radius: 90)
                .offset(x: 420, y: -190)

            Circle()
                .fill(Color.orange.opacity(0.08))
                .frame(width: 420, height: 420)
                .blur(radius: 110)
                .offset(x: 360, y: 360)
        }
        .ignoresSafeArea()
    }
}

private enum DesignMockMode: String, CaseIterable, Identifiable {
    case table
    case `default`
    case viewer
    case focus

    var id: String { rawValue }

    var title: String {
        switch self {
        case .table: return "テーブル"
        case .default: return "デフォルト"
        case .viewer: return "ビューアー"
        case .focus: return "フォーカス"
        }
    }

    var symbol: String {
        switch self {
        case .table: return "tablecells"
        case .default: return "rectangle.split.3x1"
        case .viewer: return "book.pages"
        case .focus: return "doc.plaintext"
        }
    }
}

private enum DesignMockSortKey: String, CaseIterable, Identifiable {
    case newest
    case oldest
    case mostPrompts
    case fewestPrompts

    var id: String { rawValue }

    var shortTitle: String {
        switch self {
        case .newest: return "Newest"
        case .oldest: return "Oldest"
        case .mostPrompts: return "Most"
        case .fewestPrompts: return "Fewest"
        }
    }

    var menuTitle: String {
        switch self {
        case .newest: return "Newest first"
        case .oldest: return "Oldest first"
        case .mostPrompts: return "Most prompts"
        case .fewestPrompts: return "Fewest prompts"
        }
    }

    var symbol: String {
        switch self {
        case .newest: return "arrow.down"
        case .oldest: return "arrow.up"
        case .mostPrompts: return "text.bubble.fill"
        case .fewestPrompts: return "text.bubble"
        }
    }
}

private struct DesignMockProject: Identifiable {
    let id: String
    let title: String
    let count: Int
}

private struct DesignMockConversation: Identifiable {
    let id: String
    let title: String
    let projectID: String?
    let projectState: DesignMockProjectState
    let updated: String
    let prompts: Int
    let source: String
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

    static let conversations: [DesignMockConversation] = [
        .init(id: "c1", title: "自作小説アルラウネの執筆支援", projectID: "alraune", projectState: .assigned(title: "アルラウネ執筆", kind: .imported), updated: "Apr 18", prompts: 42, source: "chatgpt"),
        .init(id: "c2", title: "アルラウネ 設定まとめ", projectID: "alraune", projectState: .assigned(title: "アルラウネ執筆", kind: .imported), updated: "Apr 12", prompts: 23, source: "chatgpt"),
        .init(id: "c3", title: "続きの話を聞く", projectID: "alraune", projectState: .assigned(title: "アルラウネ執筆", kind: .suggested), updated: "Apr 08", prompts: 15, source: "chatgpt"),
        .init(id: "c4", title: "Opusの意味とモデル名の由来", projectID: nil, projectState: .suggested(title: "Madini Archive", score: 0.62, reason: "SwiftUI・モデル名・アプリ命名"), updated: "Apr 02", prompts: 7, source: "claude"),
        .init(id: "c5", title: "ファンタジー百合小説の設定と脚本管理", projectID: "yuri", projectState: .assigned(title: "ファンタジー百合小説", kind: .imported), updated: "Mar 28", prompts: 31, source: "chatgpt"),
        .init(id: "c6", title: "輪行で運動習慣", projectID: nil, projectState: .suggested(title: "読書メモ", score: 0.48, reason: "運動・習慣・記録"), updated: "Mar 22", prompts: 11, source: "gemini"),
        .init(id: "c7", title: "README 改善提案", projectID: "madini", projectState: .assigned(title: "Madini Archive", kind: .manual), updated: "Mar 15", prompts: 6, source: "claude"),
        .init(id: "c8", title: "複利の仕組み", projectID: nil, projectState: .none, updated: "Mar 09", prompts: 4, source: "gemini"),
        .init(id: "c9", title: "会話統計と傾向分析", projectID: "madini", projectState: .assigned(title: "Madini Archive", kind: .imported), updated: "Mar 01", prompts: 18, source: "chatgpt"),
        .init(id: "c10", title: "転校生の逆の表現", projectID: nil, projectState: .none, updated: "Feb 26", prompts: 5, source: "claude")
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
