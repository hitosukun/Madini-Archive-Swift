import Foundation

/// Constructs the canonical "open in the original service" URL for an
/// imported conversation, mirroring the Python viewer's
/// `getSourceButtonMarkup(conv)` in `viewer.js`:
///
///   - `chatgpt` → `https://chatgpt.com/c/{id}` (id length > 20)
///   - `claude`  → `https://claude.ai/chat/{id}` (id length > 20)
///   - `gemini`  → `https://gemini.google.com/app` (no per-conversation
///     deep link is published, so we land on the app root)
///   - everything else (including `markdown`) → `nil`, meaning no pill /
///     no action is offered for that conversation.
///
/// The id-length gate on chatgpt/claude filters out synthetic ids (e.g.
/// markdown-import fallbacks) that aren't real service-side UUIDs — those
/// would 404 if we tried to open them. A real ChatGPT id is a 36-char
/// UUID and a real Claude id is a 36-char UUID, so the `> 20` cutoff is
/// a generous check that still rules out short synthetic ids.
enum ConversationOriginURL {
    /// Returns the URL to open for the given conversation, or `nil` when
    /// no canonical URL can be constructed (unknown source, synthetic id,
    /// markdown import, …). Callers typically hide the pill entirely when
    /// this returns nil.
    static func url(source: String?, id: String) -> URL? {
        guard let source = source?.lowercased() else { return nil }
        switch source {
        case "chatgpt":
            guard id.count > 20 else { return nil }
            return URL(string: "https://chatgpt.com/c/\(id)")
        case "claude":
            guard id.count > 20 else { return nil }
            return URL(string: "https://claude.ai/chat/\(id)")
        case "gemini":
            // No deep-link pattern — the Gemini web app doesn't expose a
            // public per-thread URL. Opening the app root is still useful
            // so the user can navigate to recent chats from there.
            return URL(string: "https://gemini.google.com/app")
        default:
            return nil
        }
    }

    /// Human-readable service label for the pill. Matches the Python
    /// viewer's capitalization (`"ChatGPT"`, `"Claude"`, `"Gemini"`)
    /// rather than the stored lowercase source key.
    static func displayName(for source: String) -> String {
        switch source.lowercased() {
        case "chatgpt": return "ChatGPT"
        case "claude": return "Claude"
        case "gemini": return "Gemini"
        default: return source
        }
    }

    /// Tooltip / accessibility label for the pill. "Open in ChatGPT" etc.
    static func openTooltip(for source: String) -> String {
        "Open in \(displayName(for: source))"
    }
}
