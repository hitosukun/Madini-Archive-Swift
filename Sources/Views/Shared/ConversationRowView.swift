import SwiftUI

struct ConversationRowView: View {
    let conversation: ConversationSummary
    var tags: [TagEntry] = []
    var onTapTag: ((TagEntry) -> Void)? = nil
    /// Shared multi-select drag source. When this row is part of the
    /// current selection, dragging it should carry the whole selected set.
    var draggedConversationIDs: [String]? = nil
    /// Called when a `TagDragPayload` is dropped onto this row. When nil,
    /// the row does not install a drop destination (iOS / Browse where
    /// sidebar-tag drops don't apply).
    var onAttachTag: ((String) -> Void)? = nil

    @State private var isDropTargeted = false

    var body: some View {
        // Two-column layout: main content (title, meta, tag chips) on the
        // left, a narrow trailing rail carrying just the date on the right.
        // The rail used to also host a per-card pin toggle; that was
        // replaced by the right-pane Viewer Mode button (see
        // `ReaderWorkspaceView.ViewerModeToggleButton`), so there's nothing
        // else competing for the trailing column now.
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

                // Tag chips. The previous `.spring` reveal animation + `.transition`
                // on each chip fought with `.draggable`/`.dropDestination` on the
                // row — during a drop the row view was animating while the drop
                // target hit-testing was still active, causing the drop to be
                // cancelled or swallowed. Static rendering now; DnD feedback
                // comes from the row-level highlight overlay below.
                if !tags.isEmpty {
                    FlowLayout(horizontalSpacing: 4, verticalSpacing: 4) {
                        ForEach(tags, id: \.id) { tag in
                            ConversationCardTagChip(tag: tag) {
                                onTapTag?(tag)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            VStack(alignment: .trailing, spacing: 6) {
                ConversationDragHandle(
                    conversationIDs: effectiveDraggedConversationIDs,
                    title: conversation.displayTitle
                )

                if let time = conversation.primaryTime {
                    Text(String(time.prefix(10)))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .monospacedDigit()
                }
            }
        }
        .padding(.vertical, 2)
        .padding(.horizontal, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(isDropTargeted ? 0.14 : 0))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(
                    Color.accentColor.opacity(isDropTargeted ? 0.7 : 0),
                    lineWidth: 1.5
                )
        )
        // Animate ONLY the highlight color/opacity, not anything that
        // could change layout — the chip-row note above explains why
        // layout-affecting animation interferes with DnD hit testing.
        // `value: isDropTargeted` scopes the animation so it doesn't fire
        // for unrelated body re-evals (tag updates, selection changes).
        .animation(.easeOut(duration: 0.12), value: isDropTargeted)
        .contentShape(Rectangle())
        .modifier(
            ConversationRowTagDropModifier(
                isTargeted: $isDropTargeted,
                onAttachTag: onAttachTag
            )
        )
    }

    private var effectiveDraggedConversationIDs: [String] {
        let ids = draggedConversationIDs ?? [conversation.id]
        return ids.isEmpty ? [conversation.id] : ids
    }
}

private struct ConversationDragHandle: View {
    let conversationIDs: [String]
    let title: String

    var body: some View {
        Image(systemName: "line.3.horizontal")
            .font(.caption.weight(.semibold))
            .foregroundStyle(.secondary)
            .frame(width: 24, height: 20)
            .background(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .fill(Color.secondary.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 5, style: .continuous)
                    .stroke(Color.secondary.opacity(0.12), lineWidth: 0.5)
            )
            .contentShape(Rectangle())
            .help(conversationIDs.count > 1 ? "\(conversationIDs.count) conversations" : "Drag conversation")
            .conversationDragSource(ids: conversationIDs, previewTitle: title)
    }
}

/// Gates the tag-drop destination on whether a handler was supplied and
/// provides the `isTargeted` highlight signal. Kept as a ViewModifier so
/// the drop modifier only exists when `onAttachTag` is non-nil — applying
/// `.dropDestination` unconditionally can interfere with surrounding
/// gesture recognizers even when it does no work.
private struct ConversationRowTagDropModifier: ViewModifier {
    @Binding var isTargeted: Bool
    let onAttachTag: ((String) -> Void)?

    func body(content: Content) -> some View {
        if let onAttachTag {
            content.dropDestination(for: TagDragPayload.self) { payloads, _ in
                guard let first = payloads.first else { return false }
                onAttachTag(first.name)
                return true
            } isTargeted: { newValue in
                // Guard redundant writes — SwiftUI fires this callback on
                // every cursor-move tick during the drag, often with the
                // same value as the prior call. Each write re-runs body
                // and any `.animation(value:)` watchers. With dozens of
                // visible rows each owning their own `isTargeted` state,
                // the redundant churn was the bulk of the perceived lag.
                if isTargeted != newValue { isTargeted = newValue }
            }
        } else {
            content
        }
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
                // Monochrome chip — color was called out as too loud and
                // colliding visually with other colored UI (JSON glyph
                // green, filter-chip palette). The capsule shape + `#`
                // prefix already reads unambiguously as "tag", so the
                // chrome doesn't need to carry hue too. Neutral secondary
                // fill + primary text = a quiet pill that defers to the
                // card's title as the focal point.
                .background(
                    Capsule(style: .continuous)
                        .fill(Color.secondary.opacity(0.14))
                )
                .overlay(
                    Capsule(style: .continuous)
                        .stroke(Color.secondary.opacity(0.22), lineWidth: 0.5)
                )
                .foregroundStyle(.secondary)
        }
        .buttonStyle(.plain)
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
