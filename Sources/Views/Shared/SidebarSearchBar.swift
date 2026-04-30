import SwiftUI

/// Left-sidebar search field with `#tag` prefix parsing, doubling as
/// the host for the active-filter chip set.
///
/// Plain tokens are forwarded to `LibraryViewModel.searchText` (full-text
/// search). Tokens starting with `#` are promoted into
/// `filter.bookmarkTags` and cleared from the visible draft.
///
/// **In-progress `#` tokens are NOT searched.** While the user is still
/// typing a tag — i.e. the trailing whitespace-separated token starts
/// with `#` and hasn't been followed by whitespace yet — the partial
/// query is held out of the keyword filter and a popover of matching
/// tag suggestions opens next to the field. Previously `#foo` mid-typing
/// was forwarded to the keyword search as literal text, which meant the
/// library reloaded to zero matches on every keystroke of a tag token.
/// Selecting a suggestion (click) promotes it to the bookmark-tag filter
/// and strips the `#...` from the draft. Typing a space still commits
/// whatever was typed as a new tag filter, matching Slack / Linear tag
/// pickers.
///
/// **Chips inside the field.** When `activeFilterChips` is non-empty the
/// glass container expands vertically and renders the chip flow under
/// the text field — same surface, same chrome. The user spec was that
/// the search box "ぐいっと広がって" with chips inside, so the field and
/// its filter state read as one control rather than two stacked rows.
struct SidebarSearchBar: View {
    @Bindable var viewModel: LibraryViewModel
    /// Currently-active filter chips supplied by the parent (driven by
    /// `LibraryViewModel.activeFilterChips`). Empty array hides the
    /// chip section and keeps the container at single-row height.
    var activeFilterChips: [LibraryActiveFilterChip] = []
    /// Per-chip dismissal handler — `LibraryViewModel.clearFilterChip`
    /// in production. Optional so callers that don't need filter chips
    /// (preview / iOS) can omit it.
    var onClearChip: (LibraryActiveFilterChip) -> Void = { _ in }

    @EnvironmentObject private var services: AppServices
    @Environment(ArchiveEvents.self) private var archiveEvents

    @State private var draft: String = ""
    /// Known tag names sourced from `tagRepository.listTags()`. Refreshed
    /// on appear and whenever `archiveEvents.bookmarkRevision` changes,
    /// so tags added via the right-pane tag editor / sidebar tag list
    /// show up in autocomplete without an app relaunch.
    @State private var availableTags: [TagEntry] = []

    /// True while the suggestion popover is anchored open. Driven off
    /// `inProgressTagQuery` — the computed returns `nil` for any draft
    /// state that isn't "the last token starts with #", which closes
    /// the popover automatically.
    @State private var isPopoverOpen: Bool = false

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .center, spacing: 6) {
                Image(systemName: "magnifyingglass")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)

                TextField("Search  (\"phrase\", title:foo, -word, #tag)", text: $draft)
                    .textFieldStyle(.plain)
                    .onChange(of: draft) { _, newValue in
                        commitParsed(newValue)
                    }
                    .onAppear {
                        draft = viewModel.filter.keyword
                    }
                    .onSubmit {
                        // Enter while a `#...` suggestion is active:
                        // promote the first match (or the raw query if
                        // no matches — lets the user file under a tag
                        // name that doesn't exist yet, same as the
                        // space-committed path).
                        commitTopSuggestion()
                    }
            }
            .popover(
                isPresented: $isPopoverOpen,
                attachmentAnchor: .rect(.bounds),
                arrowEdge: .bottom
            ) {
                tagSuggestionsPopover
            }

            if !activeFilterChips.isEmpty {
                ActiveFilterChipsView(
                    chips: activeFilterChips,
                    onClear: onClearChip
                )
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        // Glass-chip treatment that matches the toolbar chip family
        // (`HeaderChipBackground` in `WorkspaceLayoutMetrics.swift`).
        // `.thinMaterial` + a near-invisible stroke unifies the chip
        // family so the sidebar search and the middle-pane sort pill
        // look like the same kind of control.
        .background(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(.thinMaterial)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .strokeBorder(Color.primary.opacity(0.08), lineWidth: 0.5)
        )
        .task {
            await refreshTags()
        }
        // Same trigger the sidebar tags section listens on — tag creates
        // / renames / deletes anywhere in the app re-fire this revision,
        // so the popover's list stays current.
        .task(id: archiveEvents.bookmarkRevision) {
            await refreshTags()
        }
    }

    // MARK: - Suggestion popover

    private var tagSuggestionsPopover: some View {
        let matches = matchingTags
        return VStack(alignment: .leading, spacing: 0) {
            if matches.isEmpty {
                Text("No matching tags")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 8)
            } else {
                ForEach(matches) { tag in
                    Button {
                        commitTag(named: tag.name)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "number")
                                .foregroundStyle(.secondary)
                                .font(.caption)
                            Text(tag.name)
                                .font(.callout)
                                .foregroundStyle(.primary)
                            Spacer(minLength: 0)
                            if tag.usageCount > 0 {
                                Text("\(tag.usageCount)")
                                    .font(.caption2)
                                    .foregroundStyle(.secondary)
                            }
                        }
                        .contentShape(Rectangle())
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .frame(minWidth: 220, maxWidth: 300)
        .padding(.vertical, 4)
    }

    /// The partial tag query the user is currently typing — everything
    /// after the trailing `#`, as long as the last token is still
    /// "in progress" (no trailing whitespace yet). `nil` when the draft
    /// doesn't end in an in-progress `#...`.
    private var inProgressTagQuery: String? {
        let endsWithSpace = draft.last?.isWhitespace ?? false
        if endsWithSpace { return nil }
        guard let lastToken = draft.split(whereSeparator: { $0.isWhitespace }).last else {
            return nil
        }
        guard lastToken.hasPrefix("#") else { return nil }
        return String(lastToken.dropFirst())
    }

    /// Tags matching the current in-progress query by case-insensitive
    /// prefix match, excluding tags already pinned as active filters
    /// (no point suggesting a tag the user already filtered on). An
    /// empty query matches everything — typing just `#` opens the full
    /// list. Sorted by the tag repository's own ordering.
    private var matchingTags: [TagEntry] {
        guard let query = inProgressTagQuery else { return [] }
        let alreadyActive = Set(
            viewModel.filter.bookmarkTags.map { $0.lowercased() }
        )
        return availableTags.filter { tag in
            if alreadyActive.contains(tag.name.lowercased()) { return false }
            guard !query.isEmpty else { return true }
            return tag.name.range(
                of: query,
                options: [.caseInsensitive, .anchored]
            ) != nil
        }
    }

    private func refreshTags() async {
        do {
            availableTags = try await services.tags.listTags()
        } catch {
            // Non-fatal — autocomplete just stays empty if the fetch
            // fails, and the space-commit path still works.
            availableTags = []
        }
    }

    // MARK: - Suggestion commit

    private func commitTopSuggestion() {
        guard let query = inProgressTagQuery else { return }
        let pick = matchingTags.first?.name ?? query
        guard !pick.isEmpty else { return }
        commitTag(named: pick)
    }

    /// Replace the trailing in-progress `#...` in `draft` with nothing
    /// (so the user sees a clean field), and push the tag onto the
    /// filter. Mirrors the state change the space-commit path does, so
    /// downstream observers (chips, reload) react identically.
    private func commitTag(named rawName: String) {
        let name = rawName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }

        if !viewModel.filter.bookmarkTags.contains(where: {
            $0.caseInsensitiveCompare(name) == .orderedSame
        }) {
            viewModel.filter.bookmarkTags.append(name)
            Task { await viewModel.reload() }
        }

        // Strip the trailing `#...` token, preserve everything before it.
        let tokens = draft.split(whereSeparator: { $0.isWhitespace }).map(String.init)
        let withoutLast = tokens.dropLast()
        draft = withoutLast.joined(separator: " ")
        if !draft.isEmpty { draft += " " }

        isPopoverOpen = false
    }

    /// Extract `#tag` tokens from the raw text and sync them with the
    /// library filter. Only tokens terminated by whitespace are promoted —
    /// a trailing `#par` stays in the TextField until the user types a
    /// separator, matching the feel of Slack / Linear tag pickers.
    /// The in-progress `#...` token is **not** forwarded to the keyword
    /// filter, preventing a zero-result literal search while the user
    /// is mid-typing a tag.
    private func commitParsed(_ raw: String) {
        var remaining: [String] = []
        var promoted = false

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
            } else if token.hasPrefix("#"), isInProgress {
                // In-progress tag token — hold out of both `remaining`
                // (keyword search) AND `promoted` filters. The popover
                // below picks it up for autocomplete.
                continue
            } else {
                remaining.append(token)
            }
        }

        let rebuiltKeyword = remaining.joined(separator: " ")
        if viewModel.filter.keyword != rebuiltKeyword {
            viewModel.updateSearchText(rebuiltKeyword)
        } else if promoted {
            Task { await viewModel.reload() }
        }

        if promoted {
            let preserved = rawTokens.enumerated().compactMap { index, token -> String? in
                let isLast = index == rawTokens.count - 1
                let isInProgress = isLast && !endsWithSpace
                if token.hasPrefix("#"), !isInProgress { return nil }
                return token
            }
            draft = preserved.joined(separator: " ") + (endsWithSpace ? " " : "")
        }

        // Open / close the popover based on whether the draft ends in
        // an in-progress `#...`. Doing this at the end of `commitParsed`
        // (rather than in a `.onChange` on `inProgressTagQuery`) keeps
        // the popover state in lockstep with the parse — no flicker on
        // keystrokes that promote a tag via trailing whitespace.
        isPopoverOpen = inProgressTagQuery != nil
    }
}
