import SwiftUI

/// "Open the original thread" pill for the right-pane conversation header.
///
/// Ports the Python viewer's `source-action-btn` from `viewer.js`
/// (`getSourceButtonMarkup`). When the conversation came from ChatGPT /
/// Claude / Gemini AND its stored id looks like a real service UUID, the
/// label renders as a clickable pill that jumps to the original thread
/// in the default browser. For unknown sources (markdown imports, custom
/// tooling) or synthetic ids, the pill falls back to plain non-clickable
/// text — same visual weight as before so the header layout doesn't
/// shift on a per-conversation basis.
///
/// Display rules (match `ConversationRowView` / `ConversationHeaderView`):
///   - Model present → show model text in that model's inferred brand
///     color. The pill opens the parent-service URL.
///   - Model absent  → show the service name in its brand color. The
///     pill opens the service URL.
///   - No URL        → plain text, no hover/click affordance.
///
/// A tiny `arrow.up.right.square` glyph trails the label when the pill
/// is clickable, so the control reads unambiguously as "this opens
/// something external" even without hovering for the tooltip.
struct SourceOriginPill: View {
    /// Conversation id — used as the path component when constructing
    /// the ChatGPT / Claude URL.
    let conversationID: String
    /// Raw service key from the database (`"chatgpt"` / `"claude"` /
    /// `"gemini"` / `"markdown"` / …). Nil-safe so callers can pass
    /// `summary.source` directly.
    let source: String?
    /// Model name if known. Takes display priority over `source`, because
    /// the model name implicitly identifies the parent service via its
    /// prefix (`gpt-4o` → chatgpt, etc.) and is the more specific pill
    /// label when both are available.
    let model: String?

    @Environment(\.openURL) private var openURL

    var body: some View {
        // Compute the target URL once. When nil we render a plain Text —
        // matches the pre-pill layout so markdown imports / unknown
        // sources don't suddenly gain a button-shaped background.
        let targetURL = ConversationOriginURL.url(source: source, id: conversationID)

        if let targetURL {
            Button {
                openURL(targetURL)
            } label: {
                pillLabel(isClickable: true)
            }
            .buttonStyle(.plain)
            .help(source.map(ConversationOriginURL.openTooltip(for:)) ?? "Open")
            .accessibilityLabel(
                Text(source.map(ConversationOriginURL.openTooltip(for:)) ?? "Open")
            )
        } else {
            // Non-clickable fallback. Preserve the same text + color so the
            // right-pane header looks consistent whether or not an origin
            // URL exists for the current conversation.
            plainLabel
        }
    }

    // MARK: - Label variants

    /// The clickable pill: tinted text + trailing `arrow.up.right.square`
    /// glyph + faint tinted capsule background + a darker tinted stroke.
    /// Layered deliberately — the material-free tint fill alone blended
    /// too much with the surrounding window background in Dark Mode and
    /// made the pill hard to spot; the thin stroke ensures the shape
    /// reads even against a heavy background.
    @ViewBuilder
    private func pillLabel(isClickable: Bool) -> some View {
        HStack(spacing: 4) {
            Text(labelText)
                .font(.callout.weight(.medium))
                .foregroundStyle(tint)
                .lineLimit(1)

            if isClickable {
                Image(systemName: "arrow.up.right.square")
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(tint.opacity(0.85))
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 3)
        .background(
            Capsule(style: .continuous)
                .fill(tint.opacity(0.12))
        )
        .overlay(
            Capsule(style: .continuous)
                .stroke(tint.opacity(0.32), lineWidth: 0.5)
        )
        .contentShape(Capsule(style: .continuous))
    }

    /// Non-pill fallback rendering. Mirrors the pre-pill header layout
    /// exactly so adding `SourceOriginPill` to the header doesn't shift
    /// content for conversations without a canonical URL.
    @ViewBuilder
    private var plainLabel: some View {
        Text(labelText)
            .font(.callout)
            .foregroundStyle(tint)
            .lineLimit(1)
    }

    // MARK: - Display values

    /// Pill text: prefer the explicit model name (more specific), fall
    /// back to the raw service key.
    private var labelText: String {
        if let model, !model.isEmpty { return model }
        if let source, !source.isEmpty {
            return ConversationOriginURL.displayName(for: source)
        }
        return ""
    }

    /// Brand color for the label + capsule tint. Model color wins when a
    /// model is set (so `gpt-4o` reads green, matching card rows), else
    /// the service brand color, else neutral secondary.
    private var tint: Color {
        if let model, !model.isEmpty {
            return SourceAppearance.color(forModel: model)
        }
        if let source, !source.isEmpty {
            return SourceAppearance.color(for: source)
        }
        return .secondary
    }
}
