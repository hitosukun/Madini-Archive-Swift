import SwiftUI

/// Shared drag source wiring for "conversation surface → sidebar tag".
/// Keeps the payload + preview identical across list and table
/// representations so the sidebar can treat them as the same source.
private struct ConversationDragSourceModifier: ViewModifier {
    let conversationIDs: [String]
    let previewTitle: String

    func body(content: Content) -> some View {
        content.draggable(ConversationDragPayload(ids: conversationIDs)) {
            ConversationDragPreview(
                title: previewTitle,
                count: conversationIDs.count
            )
        }
    }
}

private struct ConversationDragPreview: View {
    let title: String
    let count: Int

    var body: some View {
        HStack(spacing: 6) {
            Text(title)
                .font(.caption)
                .lineLimit(1)
            if count > 1 {
                Text("\(count)")
                    .font(.caption2.weight(.semibold))
                    .padding(.horizontal, 6)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(Color.accentColor.opacity(0.18)))
            }
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 4)
        .background(
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .fill(Color.accentColor.opacity(0.15))
        )
    }
}

extension View {
    func conversationDragSource(ids: [String], previewTitle: String) -> some View {
        modifier(
            ConversationDragSourceModifier(
                conversationIDs: ids,
                previewTitle: previewTitle
            )
        )
    }
}
