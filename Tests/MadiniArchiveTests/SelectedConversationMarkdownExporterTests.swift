import XCTest
@testable import MadiniArchive

final class SelectedConversationMarkdownExporterTests: XCTestCase {
    // MARK: - Fixtures

    private func summary(
        title: String? = "Sample title",
        source: String? = "claude",
        model: String? = "claude-sonnet-4-5",
        primaryTime: String? = "2026-04-28 10:28:20"
    ) -> ConversationSummary {
        ConversationSummary(
            id: "conv-1",
            headline: ConversationHeadlineSummary(
                primaryText: title ?? "fallback",
                secondaryText: nil,
                source: .title
            ),
            source: source,
            title: title,
            model: model,
            messageCount: 0,
            primaryTime: primaryTime,
            isBookmarked: false
        )
    }

    private func userMsg(_ id: String, _ content: String) -> Message {
        Message(id: id, role: .user, content: content)
    }

    private func assistantMsg(
        _ id: String,
        content: String,
        contentBlocks: [MessageBlock]? = nil
    ) -> Message {
        Message(
            id: id,
            role: .assistant,
            content: content,
            contentBlocks: contentBlocks
        )
    }

    private func toolMsg(_ id: String, _ content: String) -> Message {
        Message(id: id, role: .tool, content: content)
    }

    private func systemMsg(_ id: String, _ content: String) -> Message {
        Message(id: id, role: .system, content: content)
    }

    private func detail(
        title: String? = "Sample title",
        source: String? = "claude",
        primaryTime: String? = "2026-04-28 10:28:20",
        messages: [Message]
    ) -> ConversationDetail {
        ConversationDetail(
            summary: summary(title: title, source: source, primaryTime: primaryTime),
            messages: messages
        )
    }

    // MARK: - 1. Empty selection

    func testEmptySelectionReturnsEmptyString() {
        let d = detail(messages: [
            userMsg("u1", "Hello"),
            assistantMsg("a1", content: "Hi"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: []
        )
        XCTAssertEqual(out, "")
    }

    // MARK: - 2. Single contiguous prompt

    func testSinglePromptSelected() {
        let d = detail(messages: [
            userMsg("u1", "Hello"),
            assistantMsg("a1", content: "Hi there"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        let expected = """
        # Sample title

        - Date: 2026-04-28
        - Model: Claude
        - Source: Madini Archive

        ---

        ## 1. Hello

        **User:**
        Hello

        **Claude:**

        Hi there

        ---

        """
        XCTAssertEqual(out, expected)
    }

    // MARK: - 3. Two consecutive prompts

    func testTwoConsecutivePromptsSelected() {
        let d = detail(messages: [
            userMsg("u1", "Q1"),
            assistantMsg("a1", content: "A1"),
            userMsg("u2", "Q2"),
            assistantMsg("a2", content: "A2"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1", "u2"]
        )
        XCTAssertTrue(out.contains("## 1. Q1"))
        XCTAssertTrue(out.contains("## 2. Q2"))
        XCTAssertTrue(out.contains("A1"))
        XCTAssertTrue(out.contains("A2"))
        // Both segments produce a trailing `---`
        let dashCount = out.components(separatedBy: "\n").filter { $0 == "---" }.count
        XCTAssertEqual(dashCount, 3) // header + 2 segments
    }

    // MARK: - 4. Non-contiguous selection

    func testNonContiguousSelection() {
        let d = detail(messages: [
            userMsg("u1", "Q1"), assistantMsg("a1", content: "A1"),
            userMsg("u2", "Q2"), assistantMsg("a2", content: "A2"),
            userMsg("u3", "Q3"), assistantMsg("a3", content: "A3"),
            userMsg("u4", "Q4"), assistantMsg("a4", content: "A4"),
            userMsg("u5", "Q5"), assistantMsg("a5", content: "A5"),
            userMsg("u6", "Q6"), assistantMsg("a6", content: "A6"),
            userMsg("u7", "Q7"), assistantMsg("a7", content: "A7"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1", "u3", "u7"]
        )
        // Headings are 1, 3, 7 — gaps are intentional, no `## 2.` etc.
        XCTAssertTrue(out.contains("## 1. Q1"))
        XCTAssertTrue(out.contains("## 3. Q3"))
        XCTAssertTrue(out.contains("## 7. Q7"))
        XCTAssertFalse(out.contains("## 2."))
        XCTAssertFalse(out.contains("## 4."))
        XCTAssertFalse(out.contains("## 5."))
        XCTAssertFalse(out.contains("## 6."))
        // Only the responses paired with selected prompts are included.
        XCTAssertTrue(out.contains("A1"))
        XCTAssertTrue(out.contains("A3"))
        XCTAssertTrue(out.contains("A7"))
        XCTAssertFalse(out.contains("A2"))
        XCTAssertFalse(out.contains("A4"))
    }

    // MARK: - 5. Last prompt in thread

    func testLastPromptInThreadSelectedIncludesAllTrailingResponses() {
        let d = detail(messages: [
            userMsg("u1", "Q1"), assistantMsg("a1", content: "A1"),
            userMsg("u2", "Q2"),
            assistantMsg("a2", content: "Part one"),
            assistantMsg("a3", content: "Part two"),
            assistantMsg("a4", content: "Part three"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u2"]
        )
        XCTAssertTrue(out.contains("## 2. Q2"))
        XCTAssertTrue(out.contains("Part one"))
        XCTAssertTrue(out.contains("Part two"))
        XCTAssertTrue(out.contains("Part three"))
        XCTAssertFalse(out.contains("A1")) // u1 not selected
    }

    // MARK: - 6. Thinking + text block

    func testThinkingBlockBeforeTextBlock() {
        let blocks: [MessageBlock] = [
            .thinking(provider: "anthropic", text: "considering options", metadata: [:]),
            .text("Here is my response."),
        ]
        let d = detail(messages: [
            userMsg("u1", "What should I do?"),
            assistantMsg("a1", content: "fallback flat", contentBlocks: blocks),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("> [thinking]\n> considering options\n"))
        XCTAssertTrue(out.contains("Here is my response."))
        // Fallback flat content NOT used because all blocks are
        // .text/.thinking — only the structured form should appear.
        XCTAssertFalse(out.contains("fallback flat"))
    }

    // MARK: - 7. Interleaved thinking and text

    func testInterleavedThinkingAndText() {
        let blocks: [MessageBlock] = [
            .thinking(provider: "anthropic", text: "first thought", metadata: [:]),
            .text("First spoken part."),
            .thinking(provider: "anthropic", text: "second thought", metadata: [:]),
            .text("Final answer."),
        ]
        let d = detail(messages: [
            userMsg("u1", "Question"),
            assistantMsg("a1", content: "ignored", contentBlocks: blocks),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        // Order is preserved.
        let firstThoughtRange = out.range(of: "first thought")
        let firstSpokenRange = out.range(of: "First spoken part.")
        let secondThoughtRange = out.range(of: "second thought")
        let finalAnswerRange = out.range(of: "Final answer.")
        XCTAssertNotNil(firstThoughtRange)
        XCTAssertNotNil(firstSpokenRange)
        XCTAssertNotNil(secondThoughtRange)
        XCTAssertNotNil(finalAnswerRange)
        XCTAssertLessThan(firstThoughtRange!.lowerBound, firstSpokenRange!.lowerBound)
        XCTAssertLessThan(firstSpokenRange!.lowerBound, secondThoughtRange!.lowerBound)
        XCTAssertLessThan(secondThoughtRange!.lowerBound, finalAnswerRange!.lowerBound)
    }

    // MARK: - 8. Multi-line thinking with blank line

    func testMultilineThinkingPreservesEachLineIncludingBlanks() {
        let blocks: [MessageBlock] = [
            .thinking(
                provider: "anthropic",
                text: "line 1\nline 2\n\nline 4",
                metadata: [:]
            ),
            .text("body"),
        ]
        let d = detail(messages: [
            userMsg("u1", "q"),
            assistantMsg("a1", content: "x", contentBlocks: blocks),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        // Each thinking line is `> ` prefixed; the blank line becomes
        // a bare `>` with no trailing content.
        XCTAssertTrue(out.contains("> [thinking]\n> line 1\n> line 2\n>\n> line 4\n"))
    }

    // MARK: - 9. No content blocks → fallback to flat content

    func testMessageWithoutContentBlocksFallsBackToContent() {
        let d = detail(messages: [
            userMsg("u1", "q"),
            assistantMsg("a1", content: "plain response", contentBlocks: nil),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("plain response"))
        XCTAssertFalse(out.contains("[thinking]"))
    }

    func testMessageWithEmptyContentBlocksFallsBackToContent() {
        // contentBlocks == [] should behave like nil — the Python
        // importer shouldn't emit empty arrays, but if a hand-edited
        // row ever lands one, emit Message.content instead of an
        // empty rendered section.
        let d = detail(messages: [
            userMsg("u1", "q"),
            assistantMsg("a1", content: "the flat content", contentBlocks: []),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("the flat content"))
        XCTAssertFalse(out.contains("[thinking]"))
    }

    func testMessageWithOnlyTextBlockEmitsThatTextNotFlatContent() {
        let blocks: [MessageBlock] = [.text("structured text")]
        let d = detail(messages: [
            userMsg("u1", "q"),
            assistantMsg("a1", content: "flat text", contentBlocks: blocks),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("structured text"))
        XCTAssertFalse(out.contains("flat text"))
    }

    // MARK: - 10. Unsupported block kind → fallback to flat content

    func testMessageWithToolUseBlockFallsBackToFlatContent() {
        let blocks: [MessageBlock] = [
            .text("partial structured"),
            .toolUse(name: "search", inputSummary: "{...}"),
            .text("more structured"),
        ]
        let d = detail(messages: [
            userMsg("u1", "q"),
            assistantMsg("a1", content: "the flat fallback", contentBlocks: blocks),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        // Phase 1 falls back when any non-text/thinking block appears.
        XCTAssertTrue(out.contains("the flat fallback"))
        XCTAssertFalse(out.contains("partial structured"))
        XCTAssertFalse(out.contains("more structured"))
    }

    func testMessageWithArtifactBlockFallsBack() {
        let blocks: [MessageBlock] = [
            .artifact(identifier: "a1", title: nil, kind: "code", content: "x = 1"),
        ]
        let d = detail(messages: [
            userMsg("u1", "q"),
            assistantMsg("a1", content: "fallback content", contentBlocks: blocks),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("fallback content"))
    }

    // MARK: - 11. Date format

    func testDateFormatTrimsToTenChars() {
        let d = detail(
            primaryTime: "2026-04-28 10:28:20",
            messages: [
                userMsg("u1", "q"),
                assistantMsg("a1", content: "a"),
            ]
        )
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("- Date: 2026-04-28\n"))
        XCTAssertFalse(out.contains("- Date: 2026-04-28 10:28:20"))
    }

    func testDateShorterThanTenCharsPassesThrough() {
        let d = detail(
            primaryTime: "2026",
            messages: [userMsg("u1", "q"), assistantMsg("a1", content: "a")]
        )
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("- Date: 2026\n"))
    }

    func testNilDateOmitsLine() {
        let d = detail(
            primaryTime: nil,
            messages: [userMsg("u1", "q"), assistantMsg("a1", content: "a")]
        )
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertFalse(out.contains("- Date:"))
    }

    // MARK: - 12. Model label mapping

    func testModelLabelKnownSources() {
        let cases: [(String, String)] = [
            ("claude", "Claude"),
            ("CLAUDE", "Claude"),
            ("chatgpt", "ChatGPT"),
            ("gemini", "Gemini"),
        ]
        for (source, expected) in cases {
            let d = detail(
                source: source,
                messages: [userMsg("u1", "q"), assistantMsg("a1", content: "a")]
            )
            let out = SelectedConversationMarkdownExporter.export(
                detail: d, selectedPromptIDs: ["u1"]
            )
            XCTAssertTrue(
                out.contains("- Model: \(expected)\n"),
                "Source \"\(source)\" should produce model label \"\(expected)\""
            )
            // Speaker label for assistant should also use it.
            XCTAssertTrue(
                out.contains("**\(expected):**"),
                "Speaker label should be \"\(expected)\" for source \"\(source)\""
            )
        }
    }

    func testModelLabelUnknownSourceCapitalized() {
        let d = detail(
            source: "openai",
            messages: [userMsg("u1", "q"), assistantMsg("a1", content: "a")]
        )
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("- Model: Openai\n"))
    }

    func testNilSourceOmitsModelLine() {
        let d = detail(
            source: nil,
            messages: [userMsg("u1", "q"), assistantMsg("a1", content: "a")]
        )
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertFalse(out.contains("- Model:"))
        // Assistant speaker falls back to "Assistant".
        XCTAssertTrue(out.contains("**Assistant:**"))
    }

    // MARK: - 13. Empty title

    func testEmptyTitleFallsBackToUntitled() {
        let d = detail(
            title: "",
            messages: [userMsg("u1", "q"), assistantMsg("a1", content: "a")]
        )
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.hasPrefix("# Untitled\n"))
    }

    func testWhitespaceTitleFallsBackToUntitled() {
        let d = detail(
            title: "   \n\t  ",
            messages: [userMsg("u1", "q"), assistantMsg("a1", content: "a")]
        )
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.hasPrefix("# Untitled\n"))
    }

    // MARK: - 14. Unknown prompt ID

    func testUnknownPromptIDIgnoredButOthersStillProduceOutput() {
        let d = detail(messages: [
            userMsg("u1", "Q1"), assistantMsg("a1", content: "A1"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1", "ghost-id"]
        )
        XCTAssertTrue(out.contains("## 1. Q1"))
    }

    func testAllUnknownPromptIDsReturnsEmptyString() {
        let d = detail(messages: [
            userMsg("u1", "Q1"), assistantMsg("a1", content: "A1"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["ghost-1", "ghost-2"]
        )
        XCTAssertEqual(out, "")
    }

    // MARK: - 15. Tool / system role responses

    func testToolAndSystemRolesGetTheirOwnSpeakerLabels() {
        let d = detail(messages: [
            userMsg("u1", "Q"),
            systemMsg("s1", "system note"),
            assistantMsg("a1", content: "considering"),
            toolMsg("t1", "tool output payload"),
            assistantMsg("a2", content: "final answer"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.contains("**System:**"))
        XCTAssertTrue(out.contains("system note"))
        XCTAssertTrue(out.contains("**Tool:**"))
        XCTAssertTrue(out.contains("tool output payload"))
        XCTAssertTrue(out.contains("**Claude:**"))
        XCTAssertTrue(out.contains("considering"))
        XCTAssertTrue(out.contains("final answer"))
    }

    // MARK: - Trailing newline invariant

    func testOutputEndsWithExactlyOneNewline() {
        let d = detail(messages: [
            userMsg("u1", "q"), assistantMsg("a1", content: "a"),
        ])
        let out = SelectedConversationMarkdownExporter.export(
            detail: d, selectedPromptIDs: ["u1"]
        )
        XCTAssertTrue(out.hasSuffix("\n"))
        XCTAssertFalse(out.hasSuffix("\n\n"))
    }
}
