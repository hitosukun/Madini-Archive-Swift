import SwiftUI

/// Single source of truth for the SF Symbol + tint color used to represent
/// a conversation source (ChatGPT, Claude, Gemini, Markdown, …).
///
/// Prior to this helper every pane had its own `sourceIcon(_:)` local
/// function. They drifted: the left-pane sidebar showed Markdown as
/// `folder`, the middle-pane card badge used `doc.text.fill`, and the
/// right-pane detail view used `doc.text`. Users saw "different icon for
/// the same source" depending on which pane they looked at. Centralizing
/// here so every call site renders the same glyph for the same source.
enum SourceAppearance {
    /// Returns the SF Symbol name for a given source. Pass `filled: true`
    /// at badge-style call sites where a solid glyph reads better next
    /// to text (e.g. card titles). Sidebar-row uses should pass `false`
    /// so the icon matches Apple's "secondary list icon" weight.
    static func icon(for source: String, filled: Bool = false) -> String {
        let base = baseIcon(for: source)
        // Not every symbol we use has a `.fill` variant — `sparkles`
        // doesn't, for example. Return the base when filled doesn't apply.
        guard filled, hasFillVariant(base) else { return base }
        return "\(base).fill"
    }

    /// Returns the accent color associated with a source, matching the
    /// brand where a real accent exists. Falls back to `.gray` for
    /// unknown sources.
    static func color(for source: String) -> Color {
        switch source.lowercased() {
        case "chatgpt":
            .green
        case "claude":
            .orange
        case "gemini":
            .blue
        case "markdown":
            .secondary
        default:
            .gray
        }
    }

    /// Infer the parent service from a model name's prefix. Case-insensitive.
    /// Returns `nil` for unknown models so call sites can fall back to a
    /// neutral color. The returned source string is lowercase to match the
    /// keys used by `color(for:)`.
    ///
    /// Model naming is messy in the wild — OpenAI ships `gpt-4o`, `o1-mini`,
    /// `o3-mini`, sometimes just `chatgpt-…`; Anthropic uses `claude-…`;
    /// Google uses `gemini-…`. Cover each family's known prefixes so that
    /// model pills/rows inherit their parent service's brand color without
    /// requiring the ArchiveSearchFilter schema to track a model→source
    /// relationship.
    static func inferredSource(forModel model: String) -> String? {
        let key = model.lowercased()
        if key.hasPrefix("gpt")
            || key.hasPrefix("o1")
            || key.hasPrefix("o3")
            || key.hasPrefix("chatgpt")
        {
            return "chatgpt"
        }
        if key.hasPrefix("claude") {
            return "claude"
        }
        if key.hasPrefix("gemini") {
            return "gemini"
        }
        return nil
    }

    /// Convenience that returns the display color for a model name by
    /// inheriting its parent service's brand color. Unknown model families
    /// fall back to `.gray`.
    static func color(forModel model: String) -> Color {
        guard let source = inferredSource(forModel: model) else { return .gray }
        return color(for: source)
    }

    private static func baseIcon(for source: String) -> String {
        switch source.lowercased() {
        case "chatgpt":
            "bubble.left.and.bubble.right"
        case "claude":
            "text.bubble"
        case "gemini":
            "sparkles"
        case "markdown":
            // Markdown (imported `.md` files) reads better as a text
            // document than as a generic folder — "folder" leaves the
            // user wondering whether they're looking at a directory
            // group or a source type.
            "doc.text"
        default:
            "doc.text"
        }
    }

    private static func hasFillVariant(_ base: String) -> Bool {
        switch base {
        case "sparkles":
            false
        default:
            true
        }
    }
}
