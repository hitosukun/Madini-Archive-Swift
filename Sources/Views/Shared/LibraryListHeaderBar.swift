import SwiftUI

/// Top bar rendered above the middle (content) pane's conversation list.
///
/// Shares the `WorkspaceHeaderBar` wrapper with the right pane's
/// `ReaderWorkspaceHeaderBar` so the two panes' top bars line up pixel-for-
/// pixel (same padding, same minHeight, same material, same bottom divider).
/// Houses:
///   - Traffic-light breathing room when the sidebar is collapsed (macOS
///     slides the traffic-light cluster onto the content column in that
///     state).
///   - A sort menu covering both date and prompt-count dimensions.
///   - A date-range popover control.
///   - A wrap-capable active-filter chip row (rendered as a footer so it
///     shares the bar's material + divider rather than forming a second
///     visually disconnected strip).
///   - A loaded/total count indicator.
///
/// The sidebar open/close button is intentionally NOT drawn here — macOS
/// already supplies one in the NavigationSplitView's titlebar (the leftmost
/// "sidebar.left" icon just above this bar). Mirroring it inside the header
/// bar produced a visible duplicate.
struct LibraryListHeaderBar: View {
    @Bindable var viewModel: LibraryViewModel
    /// When the NavigationSplitView sidebar is hidden, macOS traffic-light
    /// buttons slide onto the content column. Reserve leading space so our
    /// sort/date controls don't end up underneath them.
    var sidebarIsCollapsed: Bool = false

    var body: some View {
        WorkspaceHeaderBar {
            // Nested HStack with tighter spacing than the shared
            // `WorkspaceHeaderBar` default (12pt). When the sidebar is
            // collapsed we need every horizontal point — the 140pt
            // traffic-light spacer eats a big chunk up front, and loose
            // 12pt gaps between sort/date/count push the counter off the
            // trailing edge. 6pt keeps the controls visually grouped
            // without feeling crammed.
            HStack(spacing: 6) {
                if sidebarIsCollapsed {
                    // When the sidebar is collapsed, the window's leading
                    // edge accumulates macOS chrome from three sources:
                    // traffic-light cluster (~70pt), NavigationSplitView's
                    // titlebar sidebar-toggle button (~40pt), plus inter-
                    // item padding. 140pt clears all of that so the sort
                    // menu doesn't end up under the toolbar.
                    Color.clear.frame(width: 140, height: 1)
                }
                sortMenu
                HeaderDateRangePicker(viewModel: viewModel)
                Spacer(minLength: 0)
                countLabel
            }
        } footer: {
            if !viewModel.activeFilterChips.isEmpty {
                ActiveFilterChipsView(
                    chips: viewModel.activeFilterChips,
                    onClear: viewModel.clearFilterChip
                )
                .padding(.horizontal, WorkspaceLayoutMetrics.headerBarHorizontalPadding)
                .padding(.bottom, 8)
            }
        }
    }

    // MARK: - Sort menu

    private var sortMenu: some View {
        // Flat menu (no enclosing Picker) — using `Picker` inside `Menu`
        // produces a nested "Sort ▸" submenu item, which adds a useless
        // extra level. Plain buttons render the four options directly at
        // the top level; the chosen option is marked with a checkmark via
        // `Label(systemImage:)` swap below.
        Menu {
            sortButton(.dateDesc, title: "Newest first", systemImage: "arrow.down")
            sortButton(.dateAsc, title: "Oldest first", systemImage: "arrow.up")
            Divider()
            sortButton(.promptCountDesc, title: "Most prompts", systemImage: "text.bubble.fill")
            sortButton(.promptCountAsc, title: "Fewest prompts", systemImage: "text.bubble")
        } label: {
            HStack(spacing: 4) {
                Image(systemName: sortGlyph)
                    .font(.subheadline.weight(.semibold))
                Text(sortLabel)
                    .font(.caption)
            }
            // Shared chip treatment — height, padding, corner radius, and
            // fill come from `HeaderChipBackground` so this pill, the
            // sibling date-range picker, and the right pane's outline
            // capsule all render as one family.
            .headerChipStyle()
        }
        // `.menuStyle(.button)` + `.buttonStyle(.plain)` — the prior
        // `.menuStyle(.borderlessButton)` on macOS silently strips the
        // label's `.background(...)`, so the capsule chip treatment
        // applied inside the label never reached the screen and the
        // sort control rendered as bare text next to the neighboring
        // capsule chips. `.button` preserves the label verbatim, and
        // `.plain` on top drops the default macOS button bezel so only
        // our chip shows.
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Change sort order")
    }

    /// Individual menu item. Shows a checkmark glyph next to the option
    /// that matches the current `sortKey`; other options keep their
    /// dimension glyph so the user can still tell which is which.
    private func sortButton(
        _ key: ConversationSortKey,
        title: String,
        systemImage: String
    ) -> some View {
        Button {
            viewModel.setSortKey(key)
        } label: {
            Label(
                title,
                systemImage: viewModel.sortKey == key ? "checkmark" : systemImage
            )
        }
    }

    /// Glyph reflecting the current sort dimension + direction. Date sorts
    /// keep their arrow-up/arrow-down (the pre-prompt-count UI); prompt-
    /// count sorts use the chat-bubble glyph to signal a different axis.
    private var sortGlyph: String {
        switch viewModel.sortKey {
        case .dateDesc: return "arrow.down"
        case .dateAsc: return "arrow.up"
        case .promptCountDesc: return "text.bubble.fill"
        case .promptCountAsc: return "text.bubble"
        }
    }

    private var sortLabel: String {
        switch viewModel.sortKey {
        case .dateDesc: return "Newest"
        case .dateAsc: return "Oldest"
        case .promptCountDesc: return "Most"
        case .promptCountAsc: return "Fewest"
        }
    }

    // MARK: - Count indicator

    /// Card count shown at the trailing edge of the main row.
    ///
    /// Earlier this rendered as "loaded / total" (e.g. "100 / 619") to
    /// surface how much of the library was paginated in so far. That
    /// split carried more weight than most users needed — the numerator
    /// flickers during infinite-scroll loads and the fraction reads as
    /// visual noise. We now show only the total count so the header
    /// stays quiet.
    ///
    /// A `tray` glyph prefixes the number as a visual anchor that says
    /// "cards in this view." It's suppressed while the sidebar is
    /// collapsed — in that state the main row is already giving up
    /// ~140pt to macOS chrome (traffic-light cluster + the sidebar-
    /// reveal button), and dropping the leading glyph hands those last
    /// few points back to the sort / date controls. The sidebar-open
    /// state has plenty of room for the glyph and benefits from it
    /// being there (the tray matches the `archivebox` glyph used on
    /// the sidebar's "All" / archive rows, so the count visibly reads
    /// as "library total").
    private var countLabel: some View {
        HStack(spacing: 4) {
            if !sidebarIsCollapsed {
                Image(systemName: "tray")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text("\(viewModel.totalCount)")
                .monospacedDigit()
                .foregroundStyle(.secondary)
        }
        .font(.caption)
        // Keep the number string on one line even when the pane is
        // narrow — without `.lineLimit(1)` + `.fixedSize()`, a 3-digit
        // count under a tight header bar breaks between digits ("619"
        // becoming "61" + "9" on a second line).
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help("\(viewModel.totalCount) conversations in this view")
    }
}

private struct ActiveFilterChipsView: View {
    let chips: [LibraryActiveFilterChip]
    let onClear: (LibraryActiveFilterChip) -> Void

    var body: some View {
        FlowLayout(horizontalSpacing: 6, verticalSpacing: 6) {
            ForEach(chips) { chip in
                FilterChipView(chip: chip, onClear: onClear)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct FilterChipView: View {
    let chip: LibraryActiveFilterChip
    let onClear: (LibraryActiveFilterChip) -> Void

    var body: some View {
        HStack(spacing: 4) {
            Text(chip.label)
                .font(.caption)
                .lineLimit(1)

            Button {
                onClear(chip)
            } label: {
                Image(systemName: "xmark")
                    .font(.caption2.weight(.bold))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.secondary)
        }
        .padding(.leading, 8)
        .padding(.trailing, 6)
        .padding(.vertical, 4)
        // Opaque chip. Previous recipe (`tint.opacity(0.16)` only) let the
        // window / scroll content bleed through, dropping contrast so far
        // that the chip's own text — also painted in `tint` — became hard
        // to read. Stack a `.regularMaterial` solid layer under a faint
        // tint wash: material blocks the backdrop, tint wash keeps the
        // color cue, text stays in the stronger `tint`.
        .background(
            ZStack {
                Capsule(style: .continuous)
                    .fill(.regularMaterial)
                Capsule(style: .continuous)
                    .fill(tint.opacity(0.22))
            }
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.45), lineWidth: 0.5)
        )
        .foregroundStyle(tint)
    }

    private var tint: Color {
        switch chip.kind {
        case .keyword: return .blue
        // Source / model chips inherit the brand color of the service they
        // belong to (chatgpt=green, claude=orange, gemini=blue). Models
        // infer their service from their name prefix so a `gpt-4o` pill
        // reads as "an OpenAI model" at a glance, visually linking to the
        // matching (now-suppressed) chatgpt source chip.
        case .source(let name): return SourceAppearance.color(for: name)
        case .model(let name): return SourceAppearance.color(forModel: name)
        // `.brown` / `.purple` chosen to stay off the three LLM brand
        // colors (green/orange/blue). Previous `.mint` for source files
        // sat close to Gemini blue, and `.orange` for dates collided
        // directly with Claude — both could mislead the eye into
        // treating a file-path / date pill as a service filter.
        case .sourceFile: return .brown
        case .dateFrom, .dateTo: return .purple
        case .role: return .pink
        case .bookmarkedOnly: return .yellow
        // Tag active-filter chips stay monochrome — the label carries the
        // `#name` text which already identifies it as a tag. Using
        // `.secondary` makes it read as a neutral pill among the colored
        // keyword/source/model chips rather than competing for attention.
        case .bookmarkTag: return .secondary
        }
    }
}
