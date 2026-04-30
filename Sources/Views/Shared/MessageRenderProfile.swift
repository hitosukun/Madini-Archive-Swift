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
    var collapsesForeignLanguageRuns: Bool

    /// Catch-all profile. Renders blocks as-is, no language grouping.
    /// The default for ChatGPT, Gemini, Markdown imports, and any
    /// source we haven't classified yet. "Do nothing surprising" is
    /// the right fallback when we don't know the source's habits.
    static let passthrough = MessageRenderProfile(
        collapsesForeignLanguageRuns: false
    )

    /// Claude. Collapses English monologue runs so Japanese-primary
    /// users can skim past the "thinking aloud" preamble and get to
    /// the substantive answer.
    static let claude = MessageRenderProfile(
        collapsesForeignLanguageRuns: true
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
        default:
            return .passthrough
        }
    }
}
