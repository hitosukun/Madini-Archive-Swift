import SwiftUI

/// Unified recent + pinned filters list (replaces the old
/// `SearchSavedFiltersSection` which split them under separate headers).
///
/// The ordering is always "pinned first, then most-recent." Hovering a row
/// reveals a pin icon (or, for pinned rows, an always-lit one) — clicking
/// it toggles the pinned state without applying the filter.
struct SavedFiltersSection: View {
    let entries: [SavedFilterEntry]
    let onSelect: (SavedFilterEntry) -> Void
    let onTogglePin: (SavedFilterEntry) -> Void
    let onDelete: (SavedFilterEntry) -> Void

    var body: some View {
        // No internal "FILTERS" header here — the parent sidebar wraps
        // this view in its shared `section(title:)` helper so Filters
        // can collapse alongside Library / Sources / Tags.
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 2) {
                ForEach(entries) { entry in
                    SavedFilterRow(
                        entry: entry,
                        onSelect: { onSelect(entry) },
                        onTogglePin: { onTogglePin(entry) },
                        onDelete: { onDelete(entry) }
                    )
                }
            }
        }
    }

    /// Exposed so callers wrapping this view in their own `section(title:)`
    /// helper can skip rendering the section entirely when there's nothing
    /// to show (otherwise the parent would draw an empty collapsible
    /// "FILTERS" header with no content under it).
    var hasEntries: Bool { !entries.isEmpty }
}

/// Single history-filter row. Exposed (non-private) so callers that
/// want to interleave filter rows with non-filter history items in a
/// single chronological list can render each row individually, instead
/// of handing a whole batch to `SavedFiltersSection` as one group.
struct SavedFilterRow: View {
    let entry: SavedFilterEntry
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            // Leading icon doubles as the pin toggle. Morphs between
            // states so one glyph-slot carries both meanings:
            //   - resting unpinned: clock (recent)
            //   - hovered unpinned: outline star (affordance hint)
            //   - pinned: filled accent star
            // Merging the old clock-on-the-left + pin-on-the-right
            // layout into a single icon removes the "two nearly-
            // identical icons per row" visual clutter.
            Button(action: onTogglePin) {
                Image(systemName: pinIconName)
                    .foregroundStyle(pinIconColor)
                    // Fixed width keeps the summary text column from
                    // sliding horizontally as the glyph morphs between
                    // clock (narrow) and star (wider).
                    .frame(width: 14, alignment: .center)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(entry.pinned ? "Unpin" : "Pin to top")

            Button(action: onSelect) {
                HStack(spacing: 8) {
                    SavedFilterSummaryView(entry: entry)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
        .font(.body)
        .padding(.horizontal, 6)
        // 4pt vertical — previously 7pt, which read as too airy once
        // the History section started interleaving filter rows with
        // thread rows (the user asked to "行間を詰めて"). Keep in sync
        // with `RecentThreadRow`'s vertical padding so the two row
        // kinds share identical row heights.
        .padding(.vertical, 4)
        // Apply contentShape BEFORE `.onHover` so the whole padded
        // rectangle counts as hoverable, not just the visible glyph /
        // text. Without this the user has to land directly on a child
        // view for hover to fire.
        .contentShape(Rectangle())
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovering ? Color.secondary.opacity(0.08) : Color.clear)
        )
        // Explicitly disable the implicit animation SwiftUI would
        // otherwise run on the background fill and icon swap when
        // `isHovering` flips. During a scroll with the cursor parked
        // over the sidebar, rows slide under the pointer rapidly —
        // each transition would otherwise kick off a fresh fade
        // animation, and the cascade of overlapping animations across
        // every visible row is the scroll-jitter the user was feeling.
        // Hover feedback is now an instant toggle, which reads fine
        // visually and lets the scroll run smooth.
        .animation(nil, value: isHovering)
        .onHover { hovering in
            // Wrap the state write in a zero-animation transaction so
            // any ambient `withAnimation` at the parent level can't
            // retroactively animate the hover transition either.
            var tx = Transaction()
            tx.disablesAnimations = true
            withTransaction(tx) {
                isHovering = hovering
            }
        }
        .contextMenu {
            Button(entry.pinned ? "Unpin" : "Pin", action: onTogglePin)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var pinIconName: String {
        if entry.pinned { return "star.fill" }
        return isHovering ? "star" : "clock"
    }

    private var pinIconColor: Color {
        if entry.pinned { return Color.accentColor }
        return isHovering ? Color.accentColor.opacity(0.85) : .secondary
    }
}

/// Render a saved-filter entry as a composition of its filter criteria
/// (source icon, model text, #tag chips, …) rather than a single opaque
/// label. The stored `entry.name` ("Filtered View", "source: chatgpt" etc.)
/// collided for many distinct filters, which made the history list
/// unusable — two rows labeled "Filtered View" could select completely
/// different views.
///
/// Display rules:
/// - Sources with a known icon collapse to just the colored glyph
///   (no redundant "chatgpt" text), matching the card's SourceBadge.
/// - Models render as compact text (no per-model icons exist).
/// - Tags render as `#name` chips in teal.
/// - Keywords render as `"text"`.
/// - Dates render with a calendar icon.
/// - If the filter is empty (purely a user-named saved view), fall
///   back to `entry.name`.
private struct SavedFilterSummaryView: View {
    let entry: SavedFilterEntry

    var body: some View {
        let filter = entry.filters

        // A filter can be "meaningful" (hasMeaningfulFilters == true) without
        // any of the renderable dimensions below matching — e.g. a saved
        // filter that only sets `roles` or `sourceFiles`. In that case the
        // HStack would render nothing but the leading icon, producing a
        // mysteriously blank row in the sidebar. Compute whether we'll have
        // anything visible; if not, fall through to the name-based label.
        if filter.hasMeaningfulFilters, hasRenderableContent(filter) {
            // Per-kind hue lives on the LEADING icon only. Label text
            // stays `.primary` so saved-filter rows read as a uniform
            // neutral list of items — the colored glyphs give you the
            // dimension (search vs source vs model vs date …) at a
            // glance without the text needing to compete. Palette
            // mirrors `FilterChipView.tint` in the middle-pane active-
            // filter pills so the sidebar entry and the chip it'll
            // produce when clicked are visually linked.
            //
            // Container is `FlowLayout`, NOT `HStack`: the sidebar
            // column is narrow, and an HStack here collapses each
            // child's text into a 1pt-wide column (rendering as one
            // glyph per line — `2`/`0`/`2`/`5`/`-`/`0`/`4`/`-`/`1`/`7`).
            // FlowLayout keeps each labeled item together and wraps to
            // the next row when the next item won't fit, so a filter
            // with many dimensions reads as "Icon Label / Icon Label /
            // ↵ Icon Label" — the readable multi-line shape.
            FlowLayout(horizontalSpacing: 6, verticalSpacing: 4) {
                if !filter.normalizedKeyword.isEmpty {
                    Label {
                        Text("“\(filter.normalizedKeyword)”")
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "magnifyingglass")
                            .foregroundStyle(.blue)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                }

                // Source entries render as plain colored text — no leading
                // icon. The service's brand color on the label itself
                // (green = chatgpt, orange = claude, blue = gemini)
                // replaces the prior per-service SF Symbol glyph, which
                // made the sidebar feel crowded and set the model row
                // apart from its parent service.
                //
                // Suppression: when a model is included in the same saved
                // filter, its inferred service equals one of `filter.sources`.
                // The model's own colored text already communicates the
                // service, so rendering the matching source as a second
                // entry would be redundant. Skip those.
                let suppressedSources: Set<String> = Set(
                    filter.models.compactMap { SourceAppearance.inferredSource(forModel: $0) }
                )
                ForEach(
                    filter.sources.sorted().filter { !suppressedSources.contains($0.lowercased()) },
                    id: \.self
                ) { source in
                    Text(source)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(SourceAppearance.color(for: source))
                        .help(source)
                }

                // Model rows inherit the parent service's brand color via
                // `color(forModel:)`, so `gpt-4o` reads green, `claude-3-5-…`
                // orange, `gemini-2.0-…` blue — visually linking the model
                // to its (now-suppressed) service entry. Unknown prefixes
                // fall back to `.gray`.
                ForEach(filter.models.sorted(), id: \.self) { model in
                    Text(model)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(SourceAppearance.color(forModel: model))
                }

                // Source-file filter entries. `doc.text` in `.brown`
                // mirrors the `.sourceFile` active-filter chip tint.
                // Brown was chosen to stay distinct from the three LLM
                // brand colors (green/orange/blue) — the prior `.mint`
                // was close enough to gemini blue to cause confusion.
                ForEach(filter.sourceFiles.sorted(), id: \.self) { path in
                    Label {
                        Text(lastPathComponent(path))
                            .lineLimit(1)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "doc.text")
                            .foregroundStyle(.brown)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                    .help(path)
                }

                // Tags are deliberately colorless (`#` prefix alone carries
                // the "this is a tag" signal). Matches `.bookmarkTag`
                // chip tint of `.secondary`.
                ForEach(filter.bookmarkTags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                // Role. Pink `person.fill` glyph + primary text, matching
                // the `.role` active-filter chip tint.
                ForEach(Array(filter.roles).sorted(by: { $0.rawValue < $1.rawValue }), id: \.self) { role in
                    Label {
                        Text(role.rawValue)
                            .font(.callout)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "person.fill")
                            .foregroundStyle(.pink)
                    }
                    .labelStyle(.titleAndIcon)
                }

                // Date range. Calendar glyph in `.purple` matches the
                // `.dateFrom` / `.dateTo` chip tint. Purple sits clearly
                // apart from the three LLM brand colors (green/orange/
                // blue), so a date-only filter never reads as a service
                // — the prior `.orange` collided with Claude's brand.
                if let dateFrom = filter.dateFrom, !dateFrom.isEmpty {
                    Label {
                        Text(dateFrom)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "calendar")
                            .foregroundStyle(.purple)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                }

                if let dateTo = filter.dateTo, !dateTo.isEmpty {
                    Label {
                        Text(dateTo)
                            .foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "calendar.badge.clock")
                            .foregroundStyle(.purple)
                    }
                    .labelStyle(.titleAndIcon)
                    .font(.callout)
                }

                if filter.bookmarkedOnly {
                    Image(systemName: "bookmark.fill")
                        .font(.callout)
                        .foregroundStyle(.yellow)
                        .help("Bookmarked only")
                }
            }
        } else {
            Text(entry.name)
                .lineLimit(1)
        }
    }

    /// Returns true iff at least one renderable dimension is present.
    /// Keep this mirror of the `body` conditionals in sync when adding
    /// new filter dimensions — otherwise silent blank rows return.
    private func hasRenderableContent(_ filter: ArchiveSearchFilter) -> Bool {
        if !filter.normalizedKeyword.isEmpty { return true }
        // Mirror the body's source suppression: a saved filter that only
        // sets `chatgpt` + `gpt-4o` has zero "visible" source entries
        // after suppression, but still has a renderable model — don't
        // bail to the name-based fallback just because `sources` is
        // non-empty pre-suppression.
        let suppressed: Set<String> = Set(
            filter.models.compactMap { SourceAppearance.inferredSource(forModel: $0) }
        )
        let visibleSources = filter.sources.filter { !suppressed.contains($0.lowercased()) }
        if !visibleSources.isEmpty { return true }
        if !filter.models.isEmpty { return true }
        if !filter.sourceFiles.isEmpty { return true }
        if !filter.bookmarkTags.isEmpty { return true }
        if !filter.roles.isEmpty { return true }
        if let f = filter.dateFrom, !f.isEmpty { return true }
        if let t = filter.dateTo, !t.isEmpty { return true }
        if filter.bookmarkedOnly { return true }
        return false
    }

    private func lastPathComponent(_ path: String) -> String {
        let component = (path as NSString).lastPathComponent
        return component.isEmpty ? path : component
    }
}
