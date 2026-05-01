import Foundation

/// Phase 4: turns the structured `[MessageBlock]` Python writes into
/// `messages.content_json` into a render stream the bubble view can
/// consume.
///
/// Strategy is deliberately minimal: every `.thinking` block in the
/// message gets lifted into a single `.thinkingGroup` that sits at
/// the top of the rendered list, and the rest of the message is
/// rendered through the existing markdown pipeline (parse the flat
/// `content` column → `ContentBlock` array → `.block(_)` items).
/// We don't try to interleave thinking with response text at the
/// position it occupies in the original `content[]` array — Claude
/// often emits two or three thinking blocks scattered between tool
/// calls, and showing them where they appeared (rather than lumped
/// at the top) would force tool-use markdown rendering off the flat
/// content path. For Phase 4 the simplification is acceptable; a
/// later phase can fully switch tool / artifact rendering to the
/// structured form and restore positional fidelity.
///
/// Why a separate type rather than another method on
/// `ForeignLanguageGrouping`: the language-detection grouper works
/// on `[ContentBlock]` (markdown parse output), the structural one
/// works on `[MessageBlock]` (JSON-decoded blocks). They share the
/// same output type (`[MessageRenderItem]`) but the input types and
/// semantics are different enough that bundling them under one
/// namespace would require explaining "this method ignores the
/// other input" everywhere. Keeping them separate keeps each
/// caller's code path linear.
enum StructuredBlockGrouper {
    /// Build the render stream for a message that has populated
    /// `Message.contentBlocks`. The flat `ContentBlock` list comes
    /// from the existing markdown parse of `Message.content` — we
    /// take it as input rather than re-parsing, so the caller
    /// (`MessageBubbleView.renderItems`) controls the cache.
    ///
    /// When `profile.collapsesThinking` is false or there are no
    /// thinking blocks, the structured input is effectively a no-op
    /// and we return the flat-content blocks wrapped as
    /// `.block(_)` items — same shape the legacy grouper produces
    /// when language collapse is disabled.
    static func group(
        structured: [MessageBlock],
        flatContent: [ContentBlock],
        profile: MessageRenderProfile
    ) -> [MessageRenderItem] {
        guard profile.collapsesThinking else {
            return flatContent.map { .block($0) }
        }

        let thinkingBlocks = structured.filter { block in
            if case .thinking = block { return true }
            return false
        }
        guard !thinkingBlocks.isEmpty else {
            return flatContent.map { .block($0) }
        }

        // Provider is taken from the first thinking block. When a
        // single message mixes providers (extremely unlikely — would
        // require a tool that re-injected another model's reasoning)
        // the header tag will read as the dominant one; the expanded
        // content shows each block's provider individually if the
        // group view ever wants to surface that.
        let provider: String = {
            if case .thinking(let p, _, _) = thinkingBlocks[0] {
                return p
            }
            return "unknown"
        }()

        var result: [MessageRenderItem] = [
            .thinkingGroup(provider: provider, blocks: thinkingBlocks)
        ]
        for block in flatContent {
            result.append(.block(block))
        }
        return result
    }
}
