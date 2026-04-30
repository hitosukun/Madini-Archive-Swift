import XCTest
@testable import MadiniArchive

/// Covers the per-provider transcript extractors. Each fixture is a realistic
/// subset of the shapes the real ChatGPT / Claude exports produce — enough to
/// exercise the decision branches (role mapping, content_type dispatch,
/// multimodal splitting, tool_use / attachments) without shipping full
/// export payloads.
final class ConversationTranscriptExtractorTests: XCTestCase {
    // MARK: - Helpers

    private func rawJSON(
        _ object: [String: Any],
        provider: RawExportProvider,
        conversationID: String = "conv-test",
        snapshotID: Int64 = 1,
        relativePath: String = "conversations.json",
        index: Int = 0
    ) throws -> RawConversationJSON {
        let data = try JSONSerialization.data(withJSONObject: object, options: [.sortedKeys])
        return RawConversationJSON(
            conversationID: conversationID,
            provider: provider,
            snapshotID: snapshotID,
            relativePath: relativePath,
            jsonIndex: index,
            data: data
        )
    }

    // MARK: - ChatGPT

    func testChatGPTExtractorYieldsOrderedUserAssistantTextPair() throws {
        let userNode: [String: Any] = [
            "id": "u1",
            "parent": "root",
            "children": ["a1"],
            "message": [
                "id": "u1",
                "author": ["role": "user"],
                "create_time": 1_700_000_000.0,
                "content": [
                    "content_type": "text",
                    "parts": ["Hello there"]
                ]
            ]
        ]
        let assistantNode: [String: Any] = [
            "id": "a1",
            "parent": "u1",
            "children": [],
            "message": [
                "id": "a1",
                "author": ["role": "assistant"],
                "create_time": 1_700_000_060.0,
                "metadata": ["model_slug": "gpt-4o"],
                "content": [
                    "content_type": "text",
                    "parts": ["Hi, how can I help?"]
                ]
            ]
        ]
        let root: [String: Any] = [
            "id": "root",
            "parent": NSNull(),
            "children": ["u1"],
            "message": NSNull()
        ]
        let payload = try rawJSON([
            "title": "Greeting",
            "create_time": 1_700_000_000.0,
            "update_time": 1_700_000_060.0,
            "current_node": "a1",
            "mapping": [
                "root": root,
                "u1": userNode,
                "a1": assistantNode
            ]
        ], provider: .chatGPT)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        XCTAssertEqual(transcript.title, "Greeting")
        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertEqual(transcript.messages[0].role, .user)
        XCTAssertEqual(transcript.messages[0].blocks, [.text("Hello there")])
        XCTAssertEqual(transcript.messages[1].role, .assistant)
        XCTAssertEqual(transcript.messages[1].model, "gpt-4o")
        XCTAssertEqual(transcript.messages[1].blocks, [.text("Hi, how can I help?")])
    }

    func testChatGPTExtractorPreservesMultimodalImagePart() throws {
        let node: [String: Any] = [
            "id": "m1",
            "parent": "root",
            "children": [],
            "message": [
                "id": "m1",
                "author": ["role": "user"],
                "content": [
                    "content_type": "multimodal_text",
                    "parts": [
                        "Look at this:",
                        [
                            "content_type": "image_asset_pointer",
                            "asset_pointer": "file-service://file-abc123",
                            "metadata": ["mime_type": "image/png"]
                        ],
                        "Thoughts?"
                    ]
                ]
            ]
        ]
        let payload = try rawJSON([
            "mapping": [
                "root": ["id": "root", "parent": NSNull(), "children": ["m1"], "message": NSNull()],
                "m1": node
            ],
            "current_node": "m1"
        ], provider: .chatGPT)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        let blocks = try XCTUnwrap(transcript.messages.first?.blocks)
        XCTAssertEqual(blocks, [
            .text("Look at this:"),
            .image(AssetReference(reference: "file-service://file-abc123", mimeType: "image/png")),
            .text("Thoughts?")
        ])
    }

    func testChatGPTExtractorEmitsCodeBlockWithLanguage() throws {
        let node: [String: Any] = [
            "id": "c1",
            "parent": "root",
            "children": [],
            "message": [
                "id": "c1",
                "author": ["role": "assistant"],
                "content": [
                    "content_type": "code",
                    "language": "swift",
                    "text": "print(\"hi\")"
                ]
            ]
        ]
        let payload = try rawJSON([
            "mapping": [
                "root": ["id": "root", "parent": NSNull(), "children": ["c1"], "message": NSNull()],
                "c1": node
            ],
            "current_node": "c1"
        ], provider: .chatGPT)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        XCTAssertEqual(transcript.messages.first?.blocks, [
            .code(language: "swift", source: "print(\"hi\")")
        ])
    }

    func testChatGPTExtractorEmitsUnsupportedForUnknownContentType() throws {
        let node: [String: Any] = [
            "id": "x1",
            "parent": "root",
            "children": [],
            "message": [
                "id": "x1",
                "author": ["role": "assistant"],
                "content": [
                    "content_type": "canvas_painter"
                ]
            ]
        ]
        let payload = try rawJSON([
            "mapping": [
                "root": ["id": "root", "parent": NSNull(), "children": ["x1"], "message": NSNull()],
                "x1": node
            ],
            "current_node": "x1"
        ], provider: .chatGPT)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        XCTAssertEqual(transcript.messages.first?.blocks, [
            .unsupported(summary: "content_type: canvas_painter")
        ])
    }

    func testChatGPTExtractorDropsEmptySystemBootMessage() throws {
        let systemNode: [String: Any] = [
            "id": "s1",
            "parent": "root",
            "children": ["u1"],
            "message": [
                "id": "s1",
                "author": ["role": "system"],
                "content": [
                    "content_type": "text",
                    "parts": [""]
                ]
            ]
        ]
        let userNode: [String: Any] = [
            "id": "u1",
            "parent": "s1",
            "children": [],
            "message": [
                "id": "u1",
                "author": ["role": "user"],
                "content": ["content_type": "text", "parts": ["hello"]]
            ]
        ]
        let payload = try rawJSON([
            "mapping": [
                "root": ["id": "root", "parent": NSNull(), "children": ["s1"], "message": NSNull()],
                "s1": systemNode,
                "u1": userNode
            ],
            "current_node": "u1"
        ], provider: .chatGPT)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        XCTAssertEqual(transcript.messages.count, 1)
        XCTAssertEqual(transcript.messages.first?.role, .user)
    }

    // MARK: - Claude

    func testClaudeExtractorFlattensChatMessagesInOrder() throws {
        let payload = try rawJSON([
            "uuid": "conv-1",
            "name": "Chat",
            "created_at": "2026-01-01T00:00:00Z",
            "chat_messages": [
                [
                    "uuid": "m1",
                    "sender": "human",
                    "created_at": "2026-01-01T00:00:01.123Z",
                    "content": [
                        ["type": "text", "text": "Hi Claude"]
                    ]
                ],
                [
                    "uuid": "m2",
                    "sender": "assistant",
                    "model": "claude-4-opus",
                    "content": [
                        ["type": "text", "text": "Hi back"]
                    ]
                ]
            ]
        ], provider: .claude)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        XCTAssertEqual(transcript.title, "Chat")
        XCTAssertEqual(transcript.messages.count, 2)
        XCTAssertEqual(transcript.messages[0].role, .user)
        XCTAssertEqual(transcript.messages[0].blocks, [.text("Hi Claude")])
        XCTAssertEqual(transcript.messages[1].role, .assistant)
        XCTAssertEqual(transcript.messages[1].model, "claude-4-opus")
    }

    func testClaudeExtractorEmitsInlineImageWhenSourceHasURL() throws {
        let payload = try rawJSON([
            "uuid": "conv-1",
            "chat_messages": [
                [
                    "uuid": "m1",
                    "sender": "human",
                    "content": [
                        ["type": "text", "text": "Check this"],
                        [
                            "type": "image",
                            "source": [
                                "type": "url",
                                "media_type": "image/png",
                                "url": "att-abc123.png"
                            ]
                        ]
                    ]
                ]
            ]
        ], provider: .claude)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        XCTAssertEqual(transcript.messages.first?.blocks, [
            .text("Check this"),
            .image(AssetReference(reference: "att-abc123.png", mimeType: "image/png"))
        ])
    }

    func testClaudeExtractorCapturesToolUseAndArtifact() throws {
        let payload = try rawJSON([
            "uuid": "conv-1",
            "chat_messages": [
                [
                    "uuid": "m1",
                    "sender": "assistant",
                    "content": [
                        [
                            "type": "tool_use",
                            "name": "compute",
                            "input": ["expr": "1+1"]
                        ],
                        [
                            "type": "tool_result",
                            "content": "2"
                        ],
                        [
                            "type": "artifact",
                            "identifier": "plot-svg-1",
                            "title": "Sine wave",
                            "artifact_type": "image/svg+xml",
                            "content": "<svg/>"
                        ]
                    ]
                ]
            ]
        ], provider: .claude)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        let blocks = try XCTUnwrap(transcript.messages.first?.blocks)
        XCTAssertEqual(blocks.count, 3)
        guard case let .toolUse(name, inputJSON) = blocks[0] else {
            return XCTFail("expected toolUse, got \(blocks[0])")
        }
        XCTAssertEqual(name, "compute")
        XCTAssertEqual(inputJSON, #"{"expr":"1+1"}"#)
        XCTAssertEqual(blocks[1], .toolResult("2"))
        XCTAssertEqual(blocks[2], .artifact(
            identifier: "plot-svg-1",
            title: "Sine wave",
            kind: "image/svg+xml",
            content: "<svg/>"
        ))
    }

    func testClaudeExtractorPromotesAttachmentsAndFiles() throws {
        let payload = try rawJSON([
            "uuid": "conv-1",
            "chat_messages": [
                [
                    "uuid": "m1",
                    "sender": "human",
                    "text": "see attached",
                    "attachments": [
                        ["file_name": "spec.pdf", "file_size": 12_345, "file_type": "application/pdf"]
                    ],
                    "files": [
                        ["file_name": "preview.png", "file_kind": "image", "file_type": "image/png", "file_size": 6_789]
                    ]
                ]
            ]
        ], provider: .claude)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        let blocks = try XCTUnwrap(transcript.messages.first?.blocks)
        XCTAssertEqual(blocks.count, 3)
        XCTAssertEqual(blocks[0], .text("see attached"))
        XCTAssertEqual(blocks[1], .attachment(
            AssetReference(reference: "spec.pdf", mimeType: "application/pdf"),
            name: "spec.pdf",
            sizeBytes: 12_345
        ))
        XCTAssertEqual(blocks[2], .image(
            AssetReference(reference: "preview.png", mimeType: "image/png")
        ))
    }

    func testClaudeExtractorSkipsHiddenThinkingBlocks() throws {
        let payload = try rawJSON([
            "uuid": "conv-1",
            "chat_messages": [
                [
                    "uuid": "m1",
                    "sender": "assistant",
                    "content": [
                        ["type": "thinking", "thinking": "let me plan..."],
                        ["type": "text", "text": "Here's the answer."]
                    ]
                ]
            ]
        ], provider: .claude)

        let transcript = try ConversationTranscriptExtractor.extract(from: payload)
        XCTAssertEqual(transcript.messages.first?.blocks, [
            .text("Here's the answer.")
        ])
    }

    // MARK: - Dispatcher

    func testExtractorThrowsForGeminiProvider() throws {
        let payload = try rawJSON([:], provider: .gemini)
        XCTAssertThrowsError(try ConversationTranscriptExtractor.extract(from: payload)) { error in
            guard case ConversationTranscriptExtractor.Error.unsupportedProvider(let provider) = error else {
                return XCTFail("unexpected error \(error)")
            }
            XCTAssertEqual(provider, .gemini)
        }
    }
}
