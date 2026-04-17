import SwiftUI

struct ConversationRowView: View {
    let conversation: ConversationSummary
    var tags: [TagEntry] = []
    var onToggleBookmark: (() -> Void)? = nil
    var onTapTag: ((TagEntry) -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(conversation.displayTitle)
                .font(.headline)
                .foregroundStyle(.primary)
                .lineLimit(2)
                .multilineTextAlignment(.leading)

            HStack(spacing: 8) {
                // Bookmark glyph removed: the UI concept is now folded into
                // Tags. `onToggleBookmark` is retained on the signature for
                // now so existing call-sites (iOS/Browse/macOS) still compile,
                // but no affordance is rendered here.

                if let source = conversation.source {
                    SourceBadge(source: source)
                }

                if let model = conversation.model {
                    Text(model)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }

                Label("\(conversation.messageCount)", systemImage: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .labelStyle(.titleAndIcon)

                Spacer()

                if let time = conversation.primaryTime {
                    Text(String(time.prefix(10)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }

            if !tags.isEmpty {
                FlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                    ForEach(tags, id: \.id) { tag in
                        ConversationCardTagChip(tag: tag) {
                            onTapTag?(tag)
                        }
                        .transition(
                            .asymmetric(
                                insertion: .scale(scale: 0.2, anchor: .trailing).combined(with: .opacity),
                                removal: .opacity
                            )
                        )
                    }
                }
            }
        }
        .padding(.vertical, 2)
        .animation(.spring(response: 0.3, dampingFraction: 0.78), value: tags.map(\.id))
    }
}

private struct ConversationCardTagChip: View {
    let tag: TagEntry
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            Text("#\(tag.name)")
                .font(.caption2)
                .lineLimit(1)
                .padding(.horizontal, 6)
                .padding(.vertical, 2)
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.teal.opacity(0.16))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.teal.opacity(0.28), lineWidth: 0.5)
                )
                .foregroundStyle(Color.teal)
        }
        .buttonStyle(.plain)
    }
}

struct SourceBadge: View {
    let source: String

    var body: some View {
        Text(source)
            .font(.caption2)
            .fontWeight(.medium)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.15))
            .foregroundStyle(color)
            .clipShape(Capsule())
    }

    private var color: Color {
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

struct BookmarkStatusIcon: View {
    let isBookmarked: Bool

    var body: some View {
        Image(systemName: isBookmarked ? "bookmark.fill" : "bookmark")
            .font(.caption)
            .foregroundStyle(isBookmarked ? Color.yellow : Color.secondary.opacity(0.6))
            .accessibilityLabel(isBookmarked ? "Bookmarked" : "Not bookmarked")
    }
}

struct BookmarkToggleButton: View {
    let isBookmarked: Bool
    var action: (() -> Void)? = nil

    var body: some View {
        if let action {
            Button(action: action) {
                BookmarkStatusIcon(isBookmarked: isBookmarked)
            }
            .buttonStyle(.plain)
            .help(isBookmarked ? "Remove bookmark" : "Bookmark")
        } else {
            BookmarkStatusIcon(isBookmarked: isBookmarked)
        }
    }
}
