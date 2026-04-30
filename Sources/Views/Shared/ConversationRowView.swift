import SwiftUI

struct ConversationRowView: View {
    let conversation: ConversationSummary

    var body: some View {
        // Single-column card body. The previous version also rendered
        // per-tag chips and hosted a `TagDragPayload` drop destination;
        // both were dropped when tags were retired in favor of the
        // search-history surface.
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 6) {
                Text(conversation.displayTitle)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                HStack(spacing: 8) {
                    // Model-preferred display: when the conversation carries
                    // a model name, it already communicates the parent
                    // service via `color(forModel:)` (gpt-4o → green,
                    // claude-3-5-sonnet → orange, gemini → blue), so the
                    // separate source label ("chatgpt" / "claude") becomes
                    // redundant. Fall back to the source text only when the
                    // model is unknown.
                    if let model = conversation.model {
                        Text(model)
                            .font(.caption2)
                            .foregroundStyle(SourceAppearance.color(forModel: model))
                            .lineLimit(1)
                    } else if let source = conversation.source {
                        SourceText(source: source)
                    }

                    Label("\(conversation.messageCount)", systemImage: "text.bubble")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .labelStyle(.titleAndIcon)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if let time = conversation.primaryTime {
                Text(String(time.prefix(10)))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .contentShape(Rectangle())
    }
}

/// Service indicator rendered next to the conversation title. Was an
/// SF Symbol glyph (`SourceBadge`) in the service's brand color. The
/// glyph was retired in favor of painting the service name text itself
/// — "chatgpt" in green, "claude" in orange, "gemini" in blue — so the
/// row reads as colored type instead of `colored glyph + neutral text`.
/// Matches the sidebar Sources section and the saved-filter list, where
/// the same text-only treatment now applies.
struct SourceText: View {
    let source: String

    var body: some View {
        Text(source)
            .font(.caption2.weight(.medium))
            .foregroundStyle(SourceAppearance.color(for: source))
            .lineLimit(1)
            .help(source)
            .accessibilityLabel(Text(source))
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
