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
        if !entries.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Filters")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)

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
    }
}

private struct SavedFilterRow: View {
    let entry: SavedFilterEntry
    let onSelect: () -> Void
    let onTogglePin: () -> Void
    let onDelete: () -> Void

    @State private var isHovering = false

    var body: some View {
        HStack(spacing: 8) {
            Button(action: onSelect) {
                HStack(spacing: 8) {
                    Image(systemName: iconName)
                        .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)

                    SavedFilterSummaryView(entry: entry)

                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Pin toggle: always reserves layout space so hovering does
            // not shift the row's width. Invisible when the row is
            // neither pinned nor hovered.
            Button(action: onTogglePin) {
                Image(systemName: entry.pinned ? "pin.fill" : "pin")
                    .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .help(entry.pinned ? "Unpin" : "Pin to top")
            .opacity(entry.pinned || isHovering ? 1 : 0)
            .allowsHitTesting(entry.pinned || isHovering)
        }
        .font(.body)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 5, style: .continuous)
                .fill(isHovering ? Color.secondary.opacity(0.08) : Color.clear)
        )
        .onHover { isHovering = $0 }
        .contextMenu {
            Button(entry.pinned ? "Unpin" : "Pin", action: onTogglePin)
            Button("Delete", role: .destructive, action: onDelete)
        }
    }

    private var iconName: String {
        entry.pinned ? "star.fill" : "clock"
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

        if filter.hasMeaningfulFilters {
            HStack(spacing: 6) {
                if !filter.normalizedKeyword.isEmpty {
                    Text("“\(filter.normalizedKeyword)”")
                        .lineLimit(1)
                }

                ForEach(filter.sources.sorted(), id: \.self) { source in
                    Image(systemName: sourceIcon(source))
                        .font(.callout.weight(.semibold))
                        .foregroundStyle(sourceColor(source))
                        .help(source)
                }

                ForEach(filter.models.sorted(), id: \.self) { model in
                    Text(model)
                        .font(.callout)
                        .lineLimit(1)
                        .foregroundStyle(.primary)
                }

                ForEach(filter.bookmarkTags, id: \.self) { tag in
                    Text("#\(tag)")
                        .font(.callout)
                        .foregroundStyle(Color.teal)
                        .lineLimit(1)
                }

                if let dateFrom = filter.dateFrom, !dateFrom.isEmpty {
                    Label(dateFrom, systemImage: "calendar")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                if let dateTo = filter.dateTo, !dateTo.isEmpty {
                    Label(dateTo, systemImage: "calendar.badge.clock")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .foregroundStyle(.secondary)
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

    private func sourceIcon(_ source: String) -> String {
        switch source.lowercased() {
        case "chatgpt":
            "bubble.left.and.bubble.right.fill"
        case "claude":
            "text.bubble.fill"
        case "gemini":
            "sparkles"
        default:
            "doc.text.fill"
        }
    }

    private func sourceColor(_ source: String) -> Color {
        switch source.lowercased() {
        case "chatgpt":
            .green
        case "claude":
            .orange
        case "gemini":
            .blue
        default:
            .gray
        }
    }
}
