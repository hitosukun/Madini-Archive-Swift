import XCTest
@testable import MadiniArchive

final class PromptListExporterTests: XCTestCase {
    // MARK: - Fixtures

    private func summary(
        title: String? = "Sample title",
        source: String? = "chatgpt",
        model: String? = "gpt-5",
        primaryTime: String? = "2026-04-28"
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

    private func msg(
        _ role: MessageRole,
        _ content: String,
        id: String? = nil
    ) -> Message {
        Message(
            id: id ?? UUID().uuidString,
            role: role,
            content: content
        )
    }

    private func detail(
        title: String? = "Sample title",
        source: String? = "chatgpt",
        model: String? = "gpt-5",
        primaryTime: String? = "2026-04-28",
        messages: [Message]
    ) -> ConversationDetail {
        ConversationDetail(
            summary: summary(
                title: title, source: source,
                model: model, primaryTime: primaryTime
            ),
            messages: messages
        )
    }

    // MARK: - Header

    func testHeaderWithAllFields() {
        let d = detail(messages: [msg(.user, "First prompt")])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.hasPrefix("## Sample title\n2026-04-28 / chatgpt / gpt-5\n\n"))
    }

    func testHeaderWithMissingTitle() {
        let d = detail(title: nil, messages: [msg(.user, "p")])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.hasPrefix("## (無題)\n"))
    }

    func testHeaderWithEmptyTitle() {
        let d = detail(title: "   ", messages: [msg(.user, "p")])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.hasPrefix("## (無題)\n"))
    }

    func testHeaderDropsMissingSource() {
        let d = detail(source: nil, messages: [msg(.user, "p")])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("\n2026-04-28 / gpt-5\n"))
    }

    func testHeaderDropsAllMetadataLine() {
        let d = detail(
            source: nil, model: nil, primaryTime: nil,
            messages: [msg(.user, "p")]
        )
        let out = PromptListExporter.export(d)
        // No metadata line at all → blank line follows the title.
        XCTAssertTrue(out.hasPrefix("## Sample title\n\n"))
    }

    // MARK: - Numbered prompts

    func testSingleUserPrompt() {
        let d = detail(messages: [msg(.user, "Hello world")])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("1. Hello world"))
    }

    func testMultipleUserPromptsNumbered() {
        let d = detail(messages: [
            msg(.user, "First"),
            msg(.user, "Second"),
            msg(.user, "Third"),
        ])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("1. First"))
        XCTAssertTrue(out.contains("2. Second"))
        XCTAssertTrue(out.contains("3. Third"))
    }

    func testAssistantMessagesSkipped() {
        let d = detail(messages: [
            msg(.user, "Q1"),
            msg(.assistant, "A1"),
            msg(.user, "Q2"),
            msg(.assistant, "A2"),
        ])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("1. Q1"))
        XCTAssertTrue(out.contains("2. Q2"))
        XCTAssertFalse(out.contains("A1"))
        XCTAssertFalse(out.contains("A2"))
    }

    func testSystemAndToolMessagesSkipped() {
        let d = detail(messages: [
            msg(.system, "system prompt"),
            msg(.user, "real prompt"),
            msg(.tool, "tool result"),
        ])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("1. real prompt"))
        XCTAssertFalse(out.contains("system prompt"))
        XCTAssertFalse(out.contains("tool result"))
    }

    // MARK: - Full-content preservation

    func testMultilinePromptPreservedInFull() {
        let d = detail(messages: [
            msg(.user, "first line\nsecond line\nthird line"),
        ])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("1. first line\nsecond line\nthird line"))
    }

    func testLongSingleLinePromptPreservedInFull() {
        let long = String(repeating: "a", count: 200)
        let d = detail(messages: [msg(.user, long)])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("1. " + long))
        XCTAssertFalse(out.contains("…"))
    }

    func testLeadingTrailingWhitespaceTrimmed() {
        let d = detail(messages: [
            msg(.user, "  spaced prompt  "),
        ])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("1. spaced prompt\n"))
    }

    func testEmptyUserMessagesSkipped() {
        let d = detail(messages: [
            msg(.user, ""),
            msg(.user, "   "),
            msg(.user, "real"),
        ])
        let out = PromptListExporter.export(d)
        // Only one numbered entry survives, and it gets index 1 — the
        // counter only advances when a row is emitted.
        XCTAssertTrue(out.contains("1. real"))
        XCTAssertFalse(out.contains("2."))
    }

    // MARK: - Spacing between prompts

    /// Adjacent prompts get a blank line between them so multi-line
    /// content from one prompt doesn't visually merge into the next.
    func testBlankLineSeparatesAdjacentPrompts() {
        let d = detail(messages: [
            msg(.user, "First"),
            msg(.user, "Second"),
        ])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.contains("1. First\n\n2. Second"))
    }

    /// The output ends with exactly one trailing newline (not a blank
    /// line followed by a newline) so paste targets don't show
    /// dangling whitespace at the end.
    func testNoDanglingBlankLineAtEnd() {
        let d = detail(messages: [msg(.user, "Only")])
        let out = PromptListExporter.export(d)
        XCTAssertTrue(out.hasSuffix("1. Only\n"))
        XCTAssertFalse(out.hasSuffix("\n\n"))
    }

    // MARK: - End-to-end shape

    func testFullExampleMatchesHandoffShape() {
        let d = detail(
            title: "動物の頭と人間の胴体の神が世界中に存在する理由",
            source: "chatgpt",
            model: "gpt-5",
            primaryTime: "2026-04-28",
            messages: [
                msg(.user, "世界各地に、動物の頭と人間の胴体というパターンの神とか精霊がいるのはなぜ"),
                msg(.assistant, "（応答が入る）"),
                msg(.user, "言語や文字の発達との関係は?"),
                msg(.user, "音が人間で意味が動物に対応する傾向があるということ?"),
                msg(.user, "人間の体が OS で動物の頭がアプリみたいな対応?"),
            ]
        )
        let out = PromptListExporter.export(d)
        let expected = """
        ## 動物の頭と人間の胴体の神が世界中に存在する理由
        2026-04-28 / chatgpt / gpt-5

        1. 世界各地に、動物の頭と人間の胴体というパターンの神とか精霊がいるのはなぜ

        2. 言語や文字の発達との関係は?

        3. 音が人間で意味が動物に対応する傾向があるということ?

        4. 人間の体が OS で動物の頭がアプリみたいな対応?

        """
        XCTAssertEqual(out, expected)
    }
}
