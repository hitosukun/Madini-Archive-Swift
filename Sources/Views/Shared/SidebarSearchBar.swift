import SwiftUI

/// Left-sidebar search field with `#tag` prefix parsing.
///
/// Plain tokens are forwarded to `LibraryViewModel.searchText` (full-text
/// search). Tokens starting with `#` are promoted into
/// `filter.bookmarkTags` and cleared from the visible draft. The active
/// tag set is surfaced elsewhere (the highlighted rows in the Tags
/// section and the chip strip in the middle-pane header), so we do NOT
/// render chips inside the search field itself — they previously made
/// the field cramped and pushed the input caret around as tags were
/// added/removed.
struct SidebarSearchBar: View {
    @Bindable var viewModel: LibraryViewModel
    @State private var draft: String = ""

    var body: some View {
        HStack(alignment: .center, spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)

            TextField("Search archive  (use #tag)", text: $draft)
                .textFieldStyle(.plain)
                .onChange(of: draft) { _, newValue in
                    commitParsed(newValue)
                }
                .onAppear {
                    draft = viewModel.filter.keyword
                }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        // Glass-chip treatment that matches the toolbar chip family
        // (`HeaderChipBackground` in `WorkspaceLayoutMetrics.swift`).
        // Previously we painted a flat 8% secondary tint, which read as
        // a plain filled box — fine in isolation but out of step with
        // the other panes' glass-capsule controls. `.thinMaterial` +
        // a near-invisible stroke unifies the chip family so the
        // sidebar search and the middle-pane sort pill look like the
        // same kind of control.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
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

