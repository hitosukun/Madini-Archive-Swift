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
        HStack(spacing: 6) {
            Button(action: onSelect) {
                HStack(spacing: 6) {
                    Image(systemName: iconName)
                        .font(.caption2)
                        .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
                    Text(entry.name)
                        .font(.caption)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)

            // Pin toggle: always visible when pinned; hover-only when not.
            if entry.pinned || isHovering {
                Button(action: onTogglePin) {
                    Image(systemName: entry.pinned ? "pin.fill" : "pin")
                        .font(.caption2)
                        .foregroundStyle(entry.pinned ? Color.accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .help(entry.pinned ? "Unpin" : "Pin to top")
            }
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
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
