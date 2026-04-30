import Foundation

/// Parse ChatGPT's `conversations-NNNN.json` element shape into a
/// provider-neutral `ConversationTranscript`.
///
/// ChatGPT stores each conversation as:
///   `{ title, create_time, update_time, current_node, mapping: {id: node}}`
/// where each node has `{id, parent, children, message: {author, content, ...}}`.
/// The rendered conversation is the chain from `current_node` back to the
/// root via `parent` pointers — this is what the user actually saw in the
/// ChatGPT UI, not the raw DAG which can contain retried/abandoned branches.
enum ChatGPTTranscriptExtractor {
    static func extract(
        from rawJSON: RawConversationJSON
    ) throws -> ConversationTranscript {
        guard let object = try JSONSerialization.jsonObject(with: rawJSON.data) as? [String: Any] else {
            throw ExtractionError.notAnObject
        }
        let title = object["title"] as? String
        let createdAt = Self.epoch(object["create_time"])
        let updatedAt = Self.epoch(object["update_time"])
        let messages = Self.extractMessages(from: object)

        return ConversationTranscript(
            conversationID: rawJSON.conversationID,
            provider: .chatGPT,
            snapshotID: rawJSON.snapshotID,
            sourceRelativePath: rawJSON.relativePath,
            title: title,
            createdAt: createdAt,
            updatedAt: updatedAt,
            messages: messages
        )
    }

    enum ExtractionError: Error, Sendable, Equatable {
        case notAnObject
    }

    // MARK: - Message traversal

    private static func extractMessages(
        from object: [String: Any]
    ) -> [ConversationTranscriptMessage] {
        guard let mapping = object["mapping"] as? [String: [String: Any]] else {
            return []
        }
        let currentNode = object["current_node"] as? String
        let orderedIDs = orderedNodeIDs(mapping: mapping, currentNode: currentNode)

        var messages: [ConversationTranscriptMessage] = []
        messages.reserveCapacity(orderedIDs.count)
        for nodeID in orderedIDs {
            guard let node = mapping[nodeID],
                  let messageObj = node["message"] as? [String: Any] else {
                continue
            }
            if let msg = Self.decodeMessage(id: nodeID, message: messageObj) {
                messages.append(msg)
            }
        }
        return messages
    }

    /// Walk from `current_node` upwards via `parent` pointers. When
    /// `current_node` is absent (older exports), fall back to the node with no
    /// parent whose descendants form the longest chain. Nodes are collected
    /// in root-first order so the UI renders oldest-to-newest.
    private static func orderedNodeIDs(
        mapping: [String: [String: Any]],
        currentNode: String?
    ) -> [String] {
        if let start = currentNode, mapping[start] != nil {
            return walkUp(from: start, mapping: mapping)
        }
        // Fallback: find longest chain from any leaf. Deterministic across
        // runs (sorted ID order) so tests don't flap.
        let leaves = mapping.keys
            .filter { ((mapping[$0]?["children"] as? [Any]) ?? []).isEmpty }
            .sorted()
        var best: [String] = []
        for leaf in leaves {
            let chain = walkUp(from: leaf, mapping: mapping)
            if chain.count > best.count {
                best = chain
            }
        }
        return best
    }

    private static func walkUp(
        from nodeID: String,
        mapping: [String: [String: Any]]
    ) -> [String] {
        var chain: [String] = []
        var current: String? = nodeID
        var guardCounter = 0
        while let id = current, guardCounter < mapping.count + 1 {
            chain.append(id)
            current = mapping[id]?["parent"] as? String
            guardCounter += 1
        }
        return Array(chain.reversed())
    }

    // MARK: - Message decoding

    private static func decodeMessage(
        id: String,
        message: [String: Any]
    ) -> ConversationTranscriptMessage? {
        let role = Self.role(from: message["author"])
        // Skip the implicit system boot prompt that ChatGPT stuffs at the top
        // of every conversation — it's role=system with empty parts.
        if role == .system, Self.blocksAreEmpty(content: message["content"]) {
            return nil
        }

        let model = (message["metadata"] as? [String: Any])?["model_slug"] as? String
        let createdAt = Self.epoch(message["create_time"])
        let blocks = Self.blocks(from: message["content"], metadata: message["metadata"])

        // Drop messages that carry no renderable content at all — tool-call
        // plumbing nodes, etc. We keep `.unsupported` when at least that was
        // emitted, since showing a placeholder is better than silently eating
        // turns the user might expect to see.
        guard !blocks.isEmpty else { return nil }

        return ConversationTranscriptMessage(
            id: id,
            role: role,
            createdAt: createdAt,
            model: model,
            blocks: blocks
        )
    }

    private static func role(from author: Any?) -> ConversationTranscriptMessage.Role {
        guard let dict = author as? [String: Any],
              let raw = dict["role"] as? String else {
            return .unknown
        }
        switch raw.lowercased() {
        case "user": return .user
        case "assistant": return .assistant
        case "system": return .system
        case "tool": return .tool
        default: return .unknown
        }
    }

    private static func blocksAreEmpty(content: Any?) -> Bool {
        guard let dict = content as? [String: Any] else { return true }
        if let parts = dict["parts"] as? [Any] {
            return parts.allSatisfy { ($0 as? String)?.isEmpty ?? false }
        }
        return (dict["text"] as? String)?.isEmpty ?? true
    }

    /// Flatten `message.content` into a flat block array. Split out by
    /// content_type so each case is easy to extend as we see new shapes in
    /// real exports.
    private static func blocks(
        from content: Any?,
        metadata: Any?
    ) -> [ConversationTranscriptBlock] {
        guard let dict = content as? [String: Any] else { return [] }
        let type = (dict["content_type"] as? String)?.lowercased() ?? ""
        switch type {
        case "text":
            return textBlocks(from: dict)
        case "multimodal_text":
            return multimodalBlocks(from: dict)
        case "code":
            return codeBlocks(from: dict)
        case "execution_output":
            if let text = dict["text"] as? String, !text.isEmpty {
                return [.toolResult(text)]
            }
            return []
        case "tether_browsing_display", "tether_quote":
            return [tetherBlock(from: dict)]
        case "system_error":
            if let text = dict["text"] as? String, !text.isEmpty {
                return [.toolResult("Error: \(text)")]
            }
            return [.unsupported(summary: "system error")]
        case "user_editable_context", "model_editable_context":
            // Boilerplate system-side context; safe to omit from the reader.
            return []
        case "":
            return []
        default:
            return [.unsupported(summary: "content_type: \(type)")]
        }
    }

    private static func textBlocks(from content: [String: Any]) -> [ConversationTranscriptBlock] {
        guard let parts = content["parts"] as? [Any] else { return [] }
        let text = parts
            .compactMap { $0 as? String }
            .filter { !$0.isEmpty }
            .joined(separator: "\n\n")
        return text.isEmpty ? [] : [.text(text)]
    }

    private static func codeBlocks(from content: [String: Any]) -> [ConversationTranscriptBlock] {
        let language = content["language"] as? String
        let source = content["text"] as? String ?? ""
        return source.isEmpty ? [] : [.code(language: language, source: source)]
    }

    private static func multimodalBlocks(
        from content: [String: Any]
    ) -> [ConversationTranscriptBlock] {
        guard let parts = content["parts"] as? [Any] else { return [] }
        var result: [ConversationTranscriptBlock] = []
        var textBuffer: [String] = []

        func flushText() {
            if !textBuffer.isEmpty {
                result.append(.text(textBuffer.joined(separator: "\n\n")))
                textBuffer.removeAll(keepingCapacity: true)
            }
        }

        for part in parts {
            if let text = part as? String {
                if !text.isEmpty { textBuffer.append(text) }
                continue
            }
            guard let dict = part as? [String: Any] else { continue }
            flushText()
            let partType = (dict["content_type"] as? String)?.lowercased() ?? ""
            switch partType {
            case "image_asset_pointer":
                if let pointer = dict["asset_pointer"] as? String, !pointer.isEmpty {
                    let mime = (dict["metadata"] as? [String: Any])?["mime_type"] as? String
                    result.append(.image(AssetReference(reference: pointer, mimeType: mime)))
                } else {
                    result.append(.unsupported(summary: "image_asset_pointer without asset_pointer"))
                }
            case "audio_asset_pointer", "video_container_asset_pointer":
                if let pointer = dict["asset_pointer"] as? String {
                    result.append(.attachment(
                        AssetReference(reference: pointer, mimeType: nil),
                        name: nil,
                        sizeBytes: (dict["size_bytes"] as? NSNumber)?.int64Value
                    ))
                } else {
                    result.append(.unsupported(summary: partType))
                }
            case "":
                // Empty dict in parts — just skip, don't pollute the reader
                // with an "unsupported: " placeholder.
                continue
            default:
                result.append(.unsupported(summary: "multimodal part: \(partType)"))
            }
        }
        flushText()
        return result
    }

    private static func tetherBlock(from content: [String: Any]) -> ConversationTranscriptBlock {
        let title = content["title"] as? String
        let url = content["url"] as? String
        let text = content["text"] as? String
        var lines: [String] = []
        if let title, !title.isEmpty { lines.append(title) }
        if let url, !url.isEmpty { lines.append(url) }
        if let text, !text.isEmpty { lines.append(text) }
        if lines.isEmpty {
            return .unsupported(summary: "browse snippet (empty)")
        }
        return .toolResult(lines.joined(separator: "\n"))
    }

    // MARK: - Utilities

    /// ChatGPT timestamps come in as `Double` unix epochs (seconds).
    /// Occasionally they ship as integer seconds — accept both.
    private static func epoch(_ any: Any?) -> Date? {
        if let number = any as? NSNumber {
            return Date(timeIntervalSince1970: number.doubleValue)
        }
        if let double = any as? Double {
            return Date(timeIntervalSince1970: double)
        }
        return nil
    }
}
