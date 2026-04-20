import SwiftUI

/// Middle-pane sort-order pull-down. Mounted inside the left sidebar's
/// narrow-the-results row (under the search field) — sort and date
/// filters both live with the sidebar because they operate on the
/// middle-pane-driving `LibraryViewModel`.
///
/// Flat menu (no enclosing Picker) — using `Picker` inside `Menu`
/// produces a nested "Sort ▸" submenu item, which adds a useless
/// extra level. Plain buttons render the four options directly at
/// the top level; the chosen option is marked with a checkmark via
/// `Label(systemImage:)` swap below.
struct LibraryListSortMenu: View {
    @Bindable var viewModel: LibraryViewModel
    /// When mounted in a narrow container (e.g. the window toolbar's
    /// `.principal` slot, which competes with the breadcrumb and the
    /// right-side action cluster for available width), callers set
    /// this to let the chip truncate its label — and in the worst case
    /// collapse to icon-only — rather than refusing to shrink. The
    /// default (sidebar / search-row usage) keeps the chip at its
    /// comfortable natural size via `.fixedSize()`.
    var compressible: Bool = false

    var body: some View {
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
                    // Never compress the icon itself — it's the fallback
                    // when the text truncates down to nothing.
                    .layoutPriority(1)
                Text(sortLabel)
                    .font(.caption)
                    .lineLimit(1)
                    .truncationMode(.tail)
                    // Lower priority than the icon so the text is the
                    // first casualty when the container narrows. Only
                    // relevant in `compressible` mode (see `.fixedSize()`
                    // below, which locks the whole HStack otherwise).
                    .layoutPriority(compressible ? 0 : 1)
            }
            .headerChipStyle()
        }
        .menuStyle(.button)
        .buttonStyle(.plain)
        .menuIndicator(.hidden)
        // `.fixedSize()` locks the label to its natural width. Keep it
        // on for the default (sidebar) mount, drop it for the toolbar
        // mount so the label can truncate under window-width pressure.
        .modifier(ConditionalFixedSize(active: !compressible))
        .help("Change sort order")
    }

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
}

/// Toggle `.fixedSize()` without breaking the `some View` type of the
/// parent's body. A plain `if` branch over `.fixedSize()` changes the
/// returned view type, which ripples into unhelpful generics
/// diagnostics; a `ViewModifier` keeps the outer type stable.
private struct ConditionalFixedSize: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        if active {
            content.fixedSize()
        } else {
            content
        }
    }
}

/// Horizontal flow of deletable active-filter pills. Rendered by the
/// sidebar's `SidebarSearchBar` active-filter strip. Kept as its own
/// `struct` so future sites can reuse the visual treatment without
/// copy-pasting the `FilterChipView` + color table.
struct ActiveFilterChipsView: View {
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

struct FilterChipView: View {
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
