import SwiftUI

/// Phase 4: render a structural-thinking run (Python-annotated
/// `.thinking` blocks lifted out of `messages.content_json`) as a
/// single de-emphasized fold above the response. Visual idiom mirrors
/// `ForeignLanguageBlockView` so users who learned the chevron-fold
/// gesture from the language-detection version recognize the new
/// surface immediately.
///
/// Translation isn't wired up in Phase 4 — the language-fold version
/// uses Apple's Translation framework, but the value of translating
/// thinking is unclear (it's the model's internal monologue, often
/// English even in Japanese conversations, and users typically only
/// glance at it). Adding the TranslationSession affordance here is a
/// later refinement; for now expanding the fold reveals the raw
/// thinking text and that's enough.
struct ThinkingGroupView: View {
    /// "claude" / "chatgpt" / future. Used to label the fold's
    /// header so the user can tell whose internal monologue this is
    /// (the `provider` string travels straight from
    /// `MessageBlock.thinking(provider:_:_:)` and ultimately from
    /// the Python writer side).
    let provider: String
    /// The thinking blocks themselves. Each carries its own text and
    /// metadata; the body builder iterates and renders one Text per
    /// block.
    let blocks: [MessageBlock]

    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            header

            if expanded {
                VStack(alignment: .leading, spacing: 10) {
                    ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                        if case .thinking(_, let text, _) = block {
                            // Plain Text rather than a markdown
                            // parse — thinking content isn't usually
                            // markdown-formatted, and rendering it as
                            // verbatim avoids spurious bold / italic
                            // / heading interpretation of the
                            // model's internal scratch notes.
                            Text(text)
                                .font(.system(size: 14))
                                .foregroundStyle(.secondary)
                                .textSelection(.enabled)
                                .multilineTextAlignment(.leading)
                                .frame(maxWidth: .infinity, alignment: .leading)
                                .fixedSize(horizontal: false, vertical: true)
                        }
                    }
                }
                .padding(.top, 2)
            }
        }
        .padding(10)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(Color.secondary.opacity(0.06))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .strokeBorder(Color.secondary.opacity(0.18), lineWidth: 0.5)
        )
        .opacity(expanded ? 1.0 : 0.55)
        .animation(.easeInOut(duration: 0.18), value: expanded)
    }

    private var header: some View {
        Button {
            expanded.toggle()
        } label: {
            HStack(spacing: 6) {
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold))
                    .rotationEffect(.degrees(expanded ? 90 : 0))
                Image(systemName: "brain")
                    .font(.system(size: 11, weight: .medium))
                Text(headerLabel)
                    .font(.caption)
                    .fontWeight(.medium)
                if !expanded {
                    Text("·")
                        .foregroundStyle(.tertiary)
                    Text(previewSnippet)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
                Spacer(minLength: 0)
            }
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// "Thinking" prefixed with the provider name when known, so the
    /// user can tell whether they're looking at Claude internal
    /// monologue or ChatGPT o3 reasoning. Capitalizes the provider
    /// for display because the wire value is lowercase ("claude",
    /// "chatgpt").
    private var headerLabel: String {
        switch provider.lowercased() {
        case "claude": return "Claude · Thinking"
        case "chatgpt": return "ChatGPT · Thinking"
        case "": return "Thinking"
        default: return "\(provider.capitalized) · Thinking"
        }
    }

    /// Short tail of the first thinking block's text, shown next to
    /// the chevron when collapsed so the user can pattern-match
    /// "this thinking is about X" without expanding. Pulls from the
    /// first block only; multi-block thinking groups still get a
    /// single preview snippet (the group is a fold, not a feed).
    private var previewSnippet: String {
        for block in blocks {
            if case .thinking(_, let text, _) = block {
                let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
                if trimmed.count <= 60 { return trimmed }
                let idx = trimmed.index(trimmed.startIndex, offsetBy: 60)
                return String(trimmed[..<idx]) + "…"
            }
        }
        return ""
    }
}
