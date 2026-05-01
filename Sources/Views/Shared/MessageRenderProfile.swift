import Foundation

/// Per-source rendering policy for `MessageBubbleView`. The resolver
/// maps a conversation's `source` (and optionally `model`) to a
/// profile; the bubble consults the profile instead of branching on
/// the source string directly.
///
/// Why a profile struct, not `if source == "claude"` scattered through
/// the view: Madini ingests from ChatGPT, Claude, Gemini, and generic
/// Markdown exports today, and more sources are likely. Each one has
/// its own quirks — Claude emits English "thinking aloud" preambles
/// that read better folded into a faded box, ChatGPT almost never
/// does and its fenced code blocks get misdetected as monologue if we
/// force the same treatment. Per-source policy belongs in one place,
/// so when a new source lands we add a profile constant and a case to
/// `resolve(source:model:)` rather than hunting for every `if`.
///
/// Intentionally flat: a profile is a set of Bool / enum toggles, not
/// a closure bag. Rendering logic stays in the view; the profile just
/// says which branches to take.
struct MessageRenderProfile: Hashable, Sendable {
    /// Fold consecutive foreign-language (relative to system language)
    /// blocks into a single de-emphasized group. See
    /// `ForeignLanguageGrouping`. Useful for Claude, which routinely
    /// produces multi-paragraph English preambles in Japanese-primary
    /// conversations; harmful for ChatGPT, where English code-block
    /// payloads get misdetected as prose.
    ///
    /// Phase 4 leaves this on for `.claude` because legacy archive
    /// rows (content_json IS NULL) still need the language-detection
    /// fallback. Phase 6 cleanup will flip it off once Phase 5
    /// backfill has populated content_json for every Claude message
    /// that ever had thinking — at that point the structural path
    /// (`collapsesThinking`) will catch every case the heuristic
    /// path used to guess at.
    var collapsesForeignLanguageRuns: Bool

    /// Phase 4 structural-thinking fold. When true and the message
    /// has a populated `Message.contentBlocks`, the bubble lifts
    /// every `.thinking` block out of the flat-content render and
    /// shows them grouped above the response in a `ThinkingGroupView`
    /// — the same de-emphasized, opt-in-to-expand affordance the
    /// `ForeignLanguageBlockView` provides, but driven by Python's
    /// explicit thinking annotation (`messages.content_json` written
    /// by Phase 2 / 2b) instead of NLLanguageRecognizer guesses.
    ///
    /// Doesn't fire when `contentBlocks` is nil (legacy rows, plain-
    /// text messages without structured data) — the bubble falls
    /// through to the language-heuristic path in that case so today's
    /// behavior is preserved for un-backfilled archive.db files.
    var collapsesThinking: Bool

    /// Catch-all profile. Renders blocks as-is, no language grouping
    /// and no thinking fold. The default for Gemini, Markdown
    /// imports, and any source we haven't classified yet. "Do nothing
    /// surprising" is the right fallback when we don't know the
    /// source's habits.
    static let passthrough = MessageRenderProfile(
        collapsesForeignLanguageRuns: false,
        collapsesThinking: false
    )

    /// Claude. Collapses English monologue runs (legacy heuristic for
    /// un-backfilled rows) AND structural thinking blocks (Phase 4
    /// path for content_json-populated rows). Both paths run in
    /// parallel so reading experience improves immediately for newly-
    /// imported messages while older rows keep their pre-Phase-4
    /// behavior until Phase 5 backfill.
    static let claude = MessageRenderProfile(
        collapsesForeignLanguageRuns: true,
        collapsesThinking: true
    )

    /// ChatGPT. Doesn't suffer from the language-detection false
    /// positive that motivated the Claude language fold (its export
    /// keeps response and reasoning in separate `mapping` nodes, so
    /// the flat content column never mixes English thinking with
    /// Japanese response inside one Text). But the o3 / research
    /// models do emit `thoughts` / `reasoning_recap` in
    /// content_json (Phase 2b), and those are worth folding away by
    /// default — they're routinely thousands of words of internal
    /// monologue that aren't part of the user-facing answer.
    static let chatgpt = MessageRenderProfile(
        collapsesForeignLanguageRuns: false,
        collapsesThinking: true
    )

    /// Resolve a profile from the conversation's source string.
    /// Case-insensitive; matches the `source` values written by
    /// the parsers (`"claude"`, `"chatgpt"`, `"gemini"`,
    /// `"markdown"`). Unknown / nil sources fall through to
    /// `.passthrough`.
    ///
    /// `model` is accepted for future use (e.g. different Claude
    /// model families may warrant different defaults) but currently
    /// only `source` drives the dispatch.
    static func resolve(source: String?, model: String? = nil) -> MessageRenderProfile {
        guard let normalized = source?.lowercased(), !normalized.isEmpty else {
            return .passthrough
        }
        switch normalized {
        case "claude":
            return .claude
        case "chatgpt":
            return .chatgpt
        default:
            return .passthrough
        }
    }
}
