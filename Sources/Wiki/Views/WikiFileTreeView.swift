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
        if viewModel.pages.isEmpty {
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
