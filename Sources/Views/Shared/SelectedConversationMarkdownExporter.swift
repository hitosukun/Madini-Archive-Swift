import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Renders a *partial* conversation transcript as markdown: a chosen
/// subset of user prompts plus the assistant / tool / system responses
/// that follow each prompt up to (but not including) the next prompt.
///
/// The intended use is "abstract a slice of a thread to paste as
/// context into another Claude session". Single-thread oriented:
/// the function takes one `ConversationDetail` and a set of prompt
/// ids the user picked from the middle pane. Out-of-thread ids are
/// silently ignored — the caller is the UI's selection state and
/// should never carry foreign ids, but the defensive filter avoids
/// crashing on stale state mid-tab-switch.
///
/// Sibling exporter pattern (cf. `MarkdownExporter`, `PlainTextExporter`,
/// `PromptListExporter`): a pure-value enum that takes a
/// `ConversationDetail` and returns a `String`. No `@MainActor`, no
/// repository access, no GRDB. The pasteboard write lives separately
/// in `SelectedConversationClipboard` for the same reason
/// `LLMPromptClipboard` is split off from `PlainTextExporter` — the
/// platform pasteboard APIs differ between macOS and iOS and we don't
/// want pure string work to carry an AppKit/UIKit dependency.
///
/// ## Output shape
///
///     # <thread title>
///
///     - Date: <YYYY-MM-DD>
///     - Model: <Claude / ChatGPT / Gemini>
///     - Source: Madini Archive
///
///     ---
///
///     ## <user-only prompt index>. <prompt label>
///
///     **User:**
///     <prompt content, full text>
///
///     **Claude:**
///
///     > [thinking]
///     > <thinking text, line by line>
///
///     <response text>
///
///     ---
///
///     ## <next selected index>. ...
///
/// ## Rules
///
/// - **Indexing**: user prompts are numbered 1-based across the *whole*
///   thread, not the selection. Picking prompts 1, 3, 7 produces
///   `## 1.` / `## 3.` / `## 7.` — the gap is the signal that other
///   prompts exist between them.
/// - **Title fallback**: empty / nil title renders as `# Untitled`.
/// - **Date format**: prefix-10 of `summary.primaryTime` so a stored
///   `"2026-04-28 10:28:20"` becomes `Date: 2026-04-28`. Strings shorter
///   than 10 chars are emitted in full.
/// - **Model label**: `claude / chatgpt / gemini` map to
///   `Claude / ChatGPT / Gemini`. Unknown sources go through Swift's
///   default `.capitalized` (so `"openai" → "Openai"`); we don't try
///   to invent canonical names for sources we haven't seen yet.
/// - **Speaker label**: user is always `**User:**`. Assistant uses the
///   model label (so the conversation reads as "Claude:", not the
///   generic "Assistant:"). System / tool messages get `**System:**` /
///   `**Tool:**`. Tool + system messages that fall *between* the
///   selected prompt and the next prompt are included — they're part
///   of that prompt's response context.
/// - **Response body**:
///   - If `Message.contentBlocks == nil` → emit `Message.content`
///     verbatim. (Legacy rows or threads where no thinking was ever
///     captured.)
///   - If `contentBlocks` contains *only* `.text` and `.thinking`
///     blocks → walk them in order. Text blocks emit verbatim;
///     thinking blocks emit as a markdown blockquote led by
///     `> [thinking]` then each line of the thinking text prefixed
///     with `> ` (blank lines become bare `> `). A blank line
///     follows each thinking block so the surrounding response
///     prose doesn't visually merge with the quote.
///   - If `contentBlocks` contains *any other* block type
///     (tool_use, tool_result, artifact, unsupported) → fall back to
///     `Message.content`. Phase 1 doesn't try to render those block
///     kinds; the flat content is the safest preservation path. Future
///     phases can extend the switch.
/// - **Empty selection / no matching ids**: returns `""`. Caller
///   typically uses this signal to skip the pasteboard write.
enum SelectedConversationMarkdownExporter {
    static func export(
        detail: ConversationDetail,
        selectedPromptIDs: Set<String>
    ) -> String {
        guard !selectedPromptIDs.isEmpty else { return "" }

        let segments = extractSegments(
            detail: detail,
            selectedPromptIDs: selectedPromptIDs
        )
        guard !segments.isEmpty else { return "" }

        let assistantLabel = modelLabel(for: detail.summary.source)

        var lines: [String] = []
        appendHeader(detail: detail, modelLabel: assistantLabel, into: &lines)
        for segment in segments {
            appendSegment(
                segment,
                assistantLabel: assistantLabel,
                into: &lines
            )
        }

        // Drop the trailing blank line emitted after the final `---`
        // so the output ends with exactly one newline (PromptListExporter
        // uses the same pattern).
        while lines.last == "" {
            lines.removeLast()
        }
        return lines.joined(separator: "\n") + "\n"
    }

    // MARK: - Segment extraction

    /// One emitted prompt + the responses that follow it. `responses`
    /// is the slice of `detail.messages` from just after the prompt
    /// up to (but not including) the next user message — or to the
    /// thread end when the selected prompt is the final user message.
    private struct PromptSegment {
        let promptIndex: Int
        let prompt: Message
        var responses: [Message]
    }

    private static func extractSegments(
        detail: ConversationDetail,
        selectedPromptIDs: Set<String>
    ) -> [PromptSegment] {
        var segments: [PromptSegment] = []
        var pending: PromptSegment?
        var userIndex = 0

        for message in detail.messages {
            if message.isUser {
                if let p = pending {
                    segments.append(p)
                    pending = nil
                }
                userIndex += 1
                if selectedPromptIDs.contains(message.id) {
                    pending = PromptSegment(
                        promptIndex: userIndex,
                        prompt: message,
                        responses: []
                    )
                }
            } else if var p = pending {
                p.responses.append(message)
                pending = p
            }
        }
        if let p = pending {
            segments.append(p)
        }
        return segments
    }

    // MARK: - Header

    private static func appendHeader(
        detail: ConversationDetail,
        modelLabel: String,
        into lines: inout [String]
    ) {
        let trimmedTitle = detail.summary.title?
            .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let title = trimmedTitle.isEmpty ? "Untitled" : trimmedTitle
        lines.append("# \(title)")
        lines.append("")

        if let date = formatDate(detail.summary.primaryTime), !date.isEmpty {
            lines.append("- Date: \(date)")
        }
        if !modelLabel.isEmpty {
            lines.append("- Model: \(modelLabel)")
        }
        lines.append("- Source: Madini Archive")
        lines.append("")
        lines.append("---")
        lines.append("")
    }

    /// `"2026-04-28 10:28:20"` → `"2026-04-28"`. Inputs shorter than
    /// 10 chars (rare but possible — manual edits, malformed import)
    /// pass through verbatim.
    private static func formatDate(_ primaryTime: String?) -> String? {
        guard let primaryTime, !primaryTime.isEmpty else { return nil }
        if primaryTime.count >= 10 {
            return String(primaryTime.prefix(10))
        }
        return primaryTime
    }

    /// Source-string → human-readable model name. Known mappings
    /// preserve the canonical product casing (ChatGPT, not Chatgpt);
    /// unknown sources fall through to Swift's default `.capitalized`.
    private static func modelLabel(for source: String?) -> String {
        guard let source, !source.isEmpty else { return "" }
        switch source.lowercased() {
        case "claude":  return "Claude"
        case "chatgpt": return "ChatGPT"
        case "gemini":  return "Gemini"
        default:        return source.capitalized
        }
    }

    // MARK: - Segment rendering

    private static func appendSegment(
        _ segment: PromptSegment,
        assistantLabel: String,
        into lines: inout [String]
    ) {
        let label = promptLabel(from: segment.prompt.content)
        lines.append("## \(segment.promptIndex). \(label)")
        lines.append("")
        lines.append("**User:**")
        lines.append(segment.prompt.content)
        lines.append("")

        for response in segment.responses {
            let speaker = speakerLabel(
                for: response.role,
                assistantLabel: assistantLabel
            )
            lines.append("**\(speaker):**")
            lines.append("")
            appendResponseBody(response, into: &lines)
            lines.append("")
        }

        lines.append("---")
        lines.append("")
    }

    private static func speakerLabel(
        for role: MessageRole,
        assistantLabel: String
    ) -> String {
        switch role {
        case .user:      return "User"
        case .assistant: return assistantLabel.isEmpty ? "Assistant" : assistantLabel
        case .system:    return "System"
        case .tool:      return "Tool"
        }
    }

    /// Walk an assistant / tool / system message's contentBlocks,
    /// rendering text blocks verbatim and thinking blocks as
    /// `> [thinking]` blockquotes. Falls back to `Message.content` when:
    /// - `contentBlocks` is nil (legacy / no-thinking messages),
    /// - `contentBlocks` is the empty array (the importer should not
    ///   write this, but if it ever does, an empty rendered section
    ///   is the worst possible default — emit the flat content
    ///   instead so the user still sees the message), or
    /// - `contentBlocks` contains any block kind we don't render in
    ///   Phase 1 (tool_use, tool_result, artifact, unsupported).
    /// The fallback is conservative — losing the structured form is
    /// preferable to silently dropping content the user expects to see.
    private static func appendResponseBody(
        _ message: Message,
        into lines: inout [String]
    ) {
        guard let blocks = message.contentBlocks, !blocks.isEmpty else {
            lines.append(message.content)
            return
        }

        // Any block kind beyond .text / .thinking forces the fallback.
        let hasUnsupportedBlock = blocks.contains { block in
            switch block {
            case .text, .thinking:
                return false
            case .toolUse, .toolResult, .artifact, .unsupported:
                return true
            }
        }
        if hasUnsupportedBlock {
            lines.append(message.content)
            return
        }

        for block in blocks {
            switch block {
            case .text(let text):
                lines.append(text)
            case .thinking(_, let text, _):
                appendThinkingBlock(text: text, into: &lines)
            case .toolUse, .toolResult, .artifact, .unsupported:
                // Already filtered above.
                break
            }
        }
    }

    /// Emit a thinking text block as a markdown blockquote:
    ///
    ///     > [thinking]
    ///     > line one
    ///     > line two
    ///     > <— blank line within thinking, still quoted
    ///     > line four
    ///
    /// Followed by a single blank line so the quote doesn't visually
    /// merge with the following non-thinking content.
    private static func appendThinkingBlock(
        text: String,
        into lines: inout [String]
    ) {
        lines.append("> [thinking]")
        // Use components(separatedBy:) so empty trailing lines are
        // preserved — split() with default options would drop them.
        for thinkingLine in text.components(separatedBy: "\n") {
            if thinkingLine.isEmpty {
                lines.append(">")
            } else {
                lines.append("> \(thinkingLine)")
            }
        }
        lines.append("")
    }

    // MARK: - Prompt label

    /// Whitespace-collapsed, length-capped prompt label for the
    /// `## N. <label>` heading. Same algorithm as
    /// `ConversationDetailView.promptLabel(from:)` in
    /// `Sources/Views/Shared/ConversationDetailView.swift:224` —
    /// reimplemented as `private static` here rather than reaching into
    /// that file's `private` access level. Two reasons:
    ///   1. Promoting the original to `internal` couples this
    ///      exporter to that view file's surface area, making future
    ///      refactors there harder.
    ///   2. Reimplementing keeps Sub-A self-contained as the spec
    ///      requested, with the duplication acknowledged here.
    /// If both copies need to evolve in lock-step they can be hoisted
    /// into a shared utility in a follow-up; for Sub-A the duplication
    /// is the cleaner trade.
    private static let whitespaceRegex: NSRegularExpression = {
        // swiftlint:disable:next force_try
        try! NSRegularExpression(pattern: "\\s+")
    }()

    private static let promptLabelMaxLength = 72

    private static func promptLabel(from text: String) -> String {
        let range = NSRange(text.startIndex..., in: text)
        let collapsed = whitespaceRegex
            .stringByReplacingMatches(in: text, range: range, withTemplate: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)

        guard !collapsed.isEmpty else {
            return "Untitled Prompt"
        }
        if collapsed.count <= promptLabelMaxLength {
            return collapsed
        }
        let endIndex = collapsed.index(
            collapsed.startIndex,
            offsetBy: promptLabelMaxLength
        )
        return String(collapsed[..<endIndex])
            .trimmingCharacters(in: .whitespaces) + "…"
    }
}

// MARK: - Clipboard

/// Writes the result of `SelectedConversationMarkdownExporter.export`
/// to the system pasteboard. Mirrors `LLMPromptClipboard` /
/// `PromptListClipboard` — the export work is platform-agnostic, the
/// pasteboard write splits on `os(macOS)` / `canImport(UIKit)`.
enum SelectedConversationClipboard {
    @MainActor
    static func copy(
        detail: ConversationDetail,
        selectedPromptIDs: Set<String>
    ) {
        let text = SelectedConversationMarkdownExporter.export(
            detail: detail,
            selectedPromptIDs: selectedPromptIDs
        )
        guard !text.isEmpty else { return }

        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
