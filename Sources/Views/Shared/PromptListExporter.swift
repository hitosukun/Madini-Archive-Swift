import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Renders a conversation as a numbered list of just its user prompts —
/// one line per prompt, truncated to a single line so the user can scan
/// what a thread is "about" without rereading the whole exchange.
///
/// Sibling to `MarkdownExporter` / `PlainTextExporter` (both defined in
/// `ConversationDetailView.swift`). Lives in its own file because the
/// share menu's two new exports — full thread vs prompts-only — have
/// different audiences (humans skimming vs LLMs ingesting), and the
/// implementations don't share enough to live in the same enum.
///
/// Output shape:
///
///     ## <title>
///     <date> / <source> / <model>
///
///     1. <first user prompt's first line, ≤80 chars>
///     2. <next prompt's first line>
///     ...
///
/// Rules:
/// - Title falls back to "(無題)" when `summary.title` is nil/empty.
/// - The metadata line drops missing fields and adjusts separators —
///   so a row with only a date renders as `<date>` (no leading slash).
/// - System / assistant / tool messages are skipped; only `role == .user`
///   contributes a numbered entry.
/// - Each user message contributes its **first line** (anything before
///   the first `\n`), trimmed of surrounding whitespace.
/// - Lines longer than `lineLimit` (80) are truncated with `…`.
/// - Empty user messages (post-trim) are dropped — they'd otherwise
///   produce numbered rows with no content.
enum PromptListExporter {
    /// Maximum length of each numbered line before truncation. Counted
    /// in Swift Character units (grapheme clusters), so emoji and
    /// combining marks consume one slot regardless of UTF-16 length.
    static let lineLimit = 80

    static func export(_ detail: ConversationDetail) -> String {
        var lines: [String] = []

        // Header — title + metadata
        let titleLine = detail.summary.title?.trimmingCharacters(in: .whitespaces)
        let title = (titleLine?.isEmpty == false ? titleLine : nil) ?? "(無題)"
        lines.append("## \(title)")

        var meta: [String] = []
        if let time = detail.summary.primaryTime, !time.isEmpty {
            meta.append(time)
        }
        if let source = detail.summary.source, !source.isEmpty {
            meta.append(source)
        }
        if let model = detail.summary.model, !model.isEmpty {
            meta.append(model)
        }
        if !meta.isEmpty {
            lines.append(meta.joined(separator: " / "))
        }

        lines.append("") // blank line between header and prompt list

        // Numbered user prompts
        var index = 1
        for message in detail.messages where message.isUser {
            let line = firstLineSummary(of: message.content)
            guard !line.isEmpty else { continue }
            lines.append("\(index). \(line)")
            index += 1
        }

        return lines.joined(separator: "\n") + "\n"
    }

    /// Take the first line of a multi-line message, trim whitespace,
    /// and truncate to `lineLimit` characters with a trailing `…` if
    /// shortened. Returns the empty string for content that's all
    /// whitespace.
    static func firstLineSummary(of content: String) -> String {
        let firstLine = content
            .split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
            .first.map(String.init) ?? ""
        let trimmed = firstLine.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.count > lineLimit else { return trimmed }
        return String(trimmed.prefix(lineLimit)) + "…"
    }
}

/// Puts `PromptListExporter.export(detail)` on the system clipboard.
/// Mirror of `LLMPromptClipboard` but for the prompts-only summary
/// rather than the full LLM-ready transcript.
enum PromptListClipboard {
    @MainActor
    static func copy(_ detail: ConversationDetail) {
        let text = PromptListExporter.export(detail)
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(text, forType: .string)
        #elseif canImport(UIKit)
        UIPasteboard.general.string = text
        #endif
    }
}
