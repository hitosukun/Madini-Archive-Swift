import SwiftUI

/// Renders the vault's `.md` files as a collapsible tree, Obsidian-style.
/// The view model holds the flat page list; this view groups them into
/// folders for display only.
struct WikiFileTreeView: View {
    let viewModel: WikiBrowserViewModel

    private var rootNode: TreeNode {
        TreeBuilder.build(from: viewModel.pages)
    }

    var body: some View {
        if viewModel.pages.isEmpty {
            ContentUnavailableView(
                "No pages",
                systemImage: "doc.text",
                description: Text("This vault has no markdown files yet, or it hasn't been indexed.")
            )
        } else {
            List(selection: Binding(
                get: { viewModel.selectedPagePath },
                set: { newValue in
                    Task { await viewModel.selectPage(path: newValue) }
                }
            )) {
                OutlineGroup(rootNode.children ?? [], children: \.children) { node in
                    NodeRow(node: node)
                }
            }
            .listStyle(.sidebar)
        }
    }
}

private struct NodeRow: View {
    let node: TreeNode

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: node.isFolder ? "folder" : "doc.text")
                .foregroundStyle(node.isFolder ? .secondary : .primary)
            Text(node.displayName)
        }
        .tag(node.pagePath as String?)
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
