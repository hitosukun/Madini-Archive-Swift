import Foundation
#if os(macOS)
import AppKit
#endif
#if canImport(UIKit)
import UIKit
#endif

/// Renders a conversation as a numbered list of every user prompt's
/// full text — one entry per prompt, multi-line content preserved so
/// the user keeps the whole intent rather than just the opening
/// sentence.
///
/// Sibling to `MarkdownExporter` / `PlainTextExporter` (both defined in
/// `ConversationDetailView.swift`). Lives in its own file because the
/// share menu's two copy options have different audiences (full
/// thread for LLMs ingesting, prompts-only for humans skimming what
/// a thread "asked"), and the implementations don't share enough to
/// live in the same enum.
///
/// Output shape:
///
///     ## <title>
///     <date> / <source> / <model>
///
///     1. <first user prompt, full text including any line breaks>
///
///     2. <next prompt, full text>
///
///     ...
///
/// Each numbered entry is followed by a blank line so adjacent
/// multi-line prompts don't visually run into each other when pasted
/// into a chat box or a markdown editor.
///
/// Rules:
/// - Title falls back to "(無題)" when `summary.title` is nil/empty.
/// - The metadata line drops missing fields and adjusts separators —
///   so a row with only a date renders as `<date>` (no leading slash).
/// - System / assistant / tool messages are skipped; only `role == .user`
///   contributes a numbered entry.
/// - Each user message contributes its **full content**, trimmed only
///   of surrounding whitespace. Internal line breaks are preserved.
///   Earlier revisions kept just the first line and (briefly) also
///   truncated to 80 characters; both behaviors discarded too much
///   prompt content.
/// - Empty user messages (post-trim) are dropped — they'd otherwise
///   produce numbered rows with no content.
enum PromptListExporter {
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

        // Numbered user prompts (full content, blank-line separated)
        var index = 1
        for message in detail.messages where message.isUser {
            let content = message.content
                .trimmingCharacters(in: .whitespacesAndNewlines)
            guard !content.isEmpty else { continue }
            lines.append("\(index). \(content)")
            lines.append("") // blank line between adjacent prompts
            index += 1
        }

        // Drop the trailing blank line so the output ends with one
        // newline, not two.
        while lines.last == "" {
            lines.removeLast()
        }

        return lines.joined(separator: "\n") + "\n"
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
