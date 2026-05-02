import SwiftUI

/// Renders the vault's `.md` files as a collapsible tree, Obsidian-style.
/// The view model holds the flat page list; this view groups them into
/// folders for display.
///
/// Folder rows behave the way Obsidian does — clicking anywhere on the
/// row (the chevron, the folder icon, or the label) toggles the folder
/// open/closed. macOS Finder's sidebar uses a stricter rule
/// (chevron-only) but feels foreign in a wiki reader.
struct WikiFileTreeView: View {
    let viewModel: WikiBrowserViewModel
    @State private var expandedFolders: Set<String> = []

    private var rootNode: TreeNode {
        TreeBuilder.build(from: viewModel.pages)
    }

    /// Flattens the tree into a sequence of (node, depth) pairs for the
    /// rows that are currently visible (parents expanded). Recomputed
    /// on every render — fast enough for a few thousand pages.
    private var visibleRows: [(node: TreeNode, depth: Int)] {
        var rows: [(TreeNode, Int)] = []
        func walk(_ node: TreeNode, depth: Int) {
            rows.append((node, depth))
            guard node.isFolder, expandedFolders.contains(node.id),
                  let kids = node.children else { return }
            for child in kids { walk(child, depth: depth + 1) }
        }
        for child in rootNode.children ?? [] {
            walk(child, depth: 0)
        }
        return rows
    }

    var body: some View {
        VStack(spacing: 0) {
            searchBar
                .padding(.horizontal, 8)
                .padding(.top, 8)
                .padding(.bottom, 4)
            Divider()
            if viewModel.searchIsActive {
                searchResultsList
            } else if viewModel.pages.isEmpty {
                ContentUnavailableView(
                    "No pages",
                    systemImage: "doc.text",
                    description: Text("This vault has no markdown files yet, or it hasn't been indexed.")
                )
            } else {
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(visibleRows, id: \.node.id) { row in
                            rowButton(row.node, depth: row.depth)
                        }
                    }
                    .padding(.vertical, 4)
                    .padding(.horizontal, 4)
                }
            }
        }
    }

    @ViewBuilder
    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundStyle(.secondary)
            TextField(
                "Search this vault…",
                text: Binding(
                    get: { viewModel.searchQuery },
                    set: { newValue in
                        viewModel.searchQuery = newValue
                        Task { await viewModel.runSearch() }
                    }
                )
            )
            .textFieldStyle(.plain)
            .help("Search vault content. Use `key:value` to filter by frontmatter (e.g. `type:chr`).")
            if !viewModel.searchQuery.isEmpty {
                Button {
                    viewModel.clearSearch()
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 5)
        .background(Color.secondary.opacity(0.1))
        .cornerRadius(6)
    }

    @ViewBuilder
    private var searchResultsList: some View {
        if viewModel.searchResults.isEmpty {
            ContentUnavailableView(
                "No matches",
                systemImage: "magnifyingglass",
                description: Text("Try a different query or filter (e.g. `type:chr`).")
            )
        } else {
            ScrollView {
                LazyVStack(alignment: .leading, spacing: 0) {
                    Text("\(viewModel.searchResults.count) result(s)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal, 10)
                        .padding(.top, 6)
                    ForEach(viewModel.searchResults) { result in
                        searchResultRow(result)
                    }
                }
                .padding(.vertical, 4)
            }
        }
    }

    @ViewBuilder
    private func searchResultRow(_ result: WikiPageSearchResult) -> some View {
        Button {
            Task { await viewModel.selectPage(path: result.path) }
        } label: {
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 6) {
                    Image(systemName: "doc.text")
                        .foregroundStyle(.primary)
                    Text(result.title ?? result.path)
                        .font(.callout.weight(.medium))
                        .lineLimit(1)
                }
                Text(strippedSnippet(result.snippet))
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Text(result.path)
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(
                viewModel.selectedPagePath == result.path
                    ? Color.accentColor.opacity(0.25)
                    : Color.clear
            )
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
        .padding(.horizontal, 4)
    }

    /// Strip the FTS5 `<b>...</b>` markers — MarkdownUI is overkill for
    /// a 2-line snippet and we don't render highlights yet.
    private func strippedSnippet(_ snippet: String) -> String {
        snippet
            .replacingOccurrences(of: "<b>", with: "")
            .replacingOccurrences(of: "</b>", with: "")
    }

    @ViewBuilder
    private func rowButton(_ node: TreeNode, depth: Int) -> some View {
        Button {
            if node.isFolder {
                if expandedFolders.contains(node.id) {
                    expandedFolders.remove(node.id)
                } else {
                    expandedFolders.insert(node.id)
                }
            } else if let path = node.pagePath {
                Task { await viewModel.selectPage(path: path) }
            }
        } label: {
            HStack(spacing: 4) {
                // Disclosure chevron only on folder rows; leaves get a
                // matching-width spacer so the icons line up.
                if node.isFolder {
                    Image(systemName: expandedFolders.contains(node.id)
                          ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.secondary)
                        .frame(width: 12)
                } else {
                    Color.clear.frame(width: 12)
                }
                Image(systemName: node.isFolder ? "folder" : "doc.text")
                    .foregroundStyle(node.isFolder ? .secondary : .primary)
                    .frame(width: 16)
                Text(node.displayName)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Spacer(minLength: 0)
            }
            .padding(.leading, CGFloat(depth) * 14)
            .padding(.vertical, 4)
            .padding(.horizontal, 6)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
            .background(rowBackground(for: node))
            .cornerRadius(4)
        }
        .buttonStyle(.plain)
    }

    private func rowBackground(for node: TreeNode) -> Color {
        if let path = node.pagePath, viewModel.selectedPagePath == path {
            return Color.accentColor.opacity(0.25)
        }
        return Color.clear
    }
}

// MARK: - Tree model

struct TreeNode: Identifiable, Hashable {
    let id: String       // Path-like identifier; unique per node
    let displayName: String
    let pagePath: String? // Set on leaf nodes (files); nil on folders
    var children: [TreeNode]?

    var isFolder: Bool { pagePath == nil }
}

enum TreeBuilder {
    /// Build a folder tree from a flat list of pages. Folders sort
    /// before files within each level; both alphabetised case-insensitively.
    static func build(from pages: [WikiPage]) -> TreeNode {
        var root = MutableNode(name: "", path: "")
        for page in pages {
            let parts = page.path.split(separator: "/").map(String.init)
            insert(parts: parts, fullPath: page.path, into: &root)
        }
        return finalize(root)
    }

    private final class MutableNode {
        let name: String
        let path: String
        var pagePath: String?
        var children: [String: MutableNode] = [:]

        init(name: String, path: String) {
            self.name = name
            self.path = path
        }
    }

    private static func insert(
        parts: [String], fullPath: String, into node: inout MutableNode
    ) {
        var current: MutableNode = node
        for (i, part) in parts.enumerated() {
            let isLast = (i == parts.count - 1)
            let childPath = current.path.isEmpty ? part : "\(current.path)/\(part)"
            if let existing = current.children[part] {
                current = existing
            } else {
                let new = MutableNode(name: part, path: childPath)
                current.children[part] = new
                current = new
            }
            if isLast {
                current.pagePath = fullPath
            }
        }
    }

    private static func finalize(_ node: MutableNode) -> TreeNode {
        let kids = node.children.values
            .map(finalize)
            .sorted { lhs, rhs in
                if lhs.isFolder != rhs.isFolder { return lhs.isFolder }
                return lhs.displayName.localizedCaseInsensitiveCompare(
                    rhs.displayName
                ) == .orderedAscending
            }
        let displayName = node.name.hasSuffix(".md")
            ? String(node.name.dropLast(3))
            : node.name
        return TreeNode(
            id: node.path.isEmpty ? "__root__" : node.path,
            displayName: displayName,
            pagePath: node.pagePath,
            children: kids.isEmpty ? nil : kids
        )
    }
}
