import SwiftUI

/// Left-sidebar search field with `#tag` prefix parsing.
///
/// Plain tokens are forwarded to `LibraryViewModel.searchText` (full-text
/// search). Tokens starting with `#` are split off into
/// `filter.bookmarkTags` and rendered as chips to the left of the field.
/// This makes `#madini chatgpt` read as "search for chatgpt within the
/// #madini tag."
struct SidebarSearchBar: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var draft: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            // Chips for tags already committed into filter.bookmarkTags.
            if !viewModel.filter.bookmarkTags.isEmpty {
                ForEach(viewModel.filter.bookmarkTags, id: \.self) { tag in
                    TagSearchChip(name: tag) {
                        viewModel.removeBookmarkTag(tag)
                    }
                }
            }

            TextField("Search archive  (use #tag)", text: $draft)
                .textFieldStyle(.plain)
                .onChange(of: draft) { _, newValue in
                    commitParsed(newValue)
                }
                .onAppear {
                    // Initial seed: mirror keyword + inline-display of tags.
                    draft = viewModel.filter.keyword
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color.secondary.opacity(0.08))
        .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
    }

    /// Extract `#tag` tokens from the raw text and sync them with the
    /// library filter. Only tokens terminated by whitespace are promoted —
    /// a trailing `#par` stays in the TextField until the user types a
    /// separator, matching the feel of Slack / Linear tag pickers.
    private func commitParsed(_ raw: String) {
        var remaining: [String] = []
        var promoted = false

        // Split preserving whether the last token is "in progress" (not yet
        // followed by whitespace).
        let endsWithSpace = raw.last?.isWhitespace ?? false
        let rawTokens = raw.split(whereSeparator: { $0.isWhitespace }).map(String.init)

        for (index, token) in rawTokens.enumerated() {
            let isLast = index == rawTokens.count - 1
            let isInProgress = isLast && !endsWithSpace

            if token.hasPrefix("#"), !isInProgress {
                let tagName = String(token.dropFirst()).trimmingCharacters(in: .whitespacesAndNewlines)
                if !tagName.isEmpty,
                   !viewModel.filter.bookmarkTags.contains(where: { $0.caseInsensitiveCompare(tagName) == .orderedSame }) {
                    viewModel.filter.bookmarkTags.append(tagName)
                    promoted = true
                }
            } else {
                remaining.append(token)
            }
        }

        let rebuiltKeyword = remaining.joined(separator: " ")
        // Update the filter keyword if it changed (drives debounced reload).
        if viewModel.filter.keyword != rebuiltKeyword {
            viewModel.updateSearchText(rebuiltKeyword)
        } else if promoted {
            // Reload anyway because bookmarkTags changed by direct mutation.
            Task { await viewModel.reload() }
        }

        if promoted {
            // Clear the promoted tokens from the visible draft, preserving
            // any in-progress trailing `#...` that wasn't committed.
            let preserved = rawTokens.enumerated().compactMap { index, token -> String? in
                let isLast = index == rawTokens.count - 1
                let isInProgress = isLast && !endsWithSpace
                if token.hasPrefix("#"), !isInProgress { return nil }
                return token
            }
            draft = preserved.joined(separator: " ") + (endsWithSpace ? " " : "")
        }
    }
}

private struct TagSearchChip: View {
    let name: String
    let onRemove: () -> Void

    var body: some View {
        HStack(spacing: 2) {
            Text("#\(name)")
                .font(.caption.weight(.medium))
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(Capsule().fill(Color.teal.opacity(0.18)))
        .foregroundStyle(Color.teal)
    }
}
