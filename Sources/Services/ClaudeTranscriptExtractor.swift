import Foundation

/// Parse Claude's `conversations.json` element shape into a provider-neutral
/// `ConversationTranscript`.
///
/// Shape overview (Claude web export):
///   `{ uuid, name, created_at, updated_at, chat_messages: [...] }`
///   Each `chat_message` has:
///     `{ uuid, sender ("human"|"assistant"), created_at, text,
///        content: [{type: "text"|"tool_use"|"tool_result"|"image", ...}],
///        attachments: [{file_name, file_size, ...}],
///        files: [{file_name, file_size, file_kind, ...}] }`
///
/// `text` is the legacy flat transcript string; `content` is the richer
/// structured view. We prefer `content` when present, and fall back to
/// `text` otherwise.
enum ClaudeTranscriptExtractor {
    static func extract(
        from rawJSON: RawConversationJSON
    ) throws -> ConversationTranscript {
        guard let object = try JSONSerialization.jsonObject(with: rawJSON.data) as? [String: Any] else {
            throw ExtractionError.notAnObject
        }
        let title = object["name"] as? String
        let createdAt = Self.isoDate(object["created_at"])
        let updatedAt = Self.isoDate(object["updated_at"])
        let messages = Self.decodeMessages(from: object["chat_messages"])

        return ConversationTranscript(
            conversationID: rawJSON.conversationID,
            provider: .claude,
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

    // MARK: - Message decoding

    private static func decodeMessages(
        from any: Any?
    ) -> [ConversationTranscriptMessage] {
        guard let array = any as? [[String: Any]] else { return [] }
        return array.compactMap(Self.decodeMessage(_:))
    }

    private static func decodeMessage(
        _ raw: [String: Any]
    ) -> ConversationTranscriptMessage? {
        let id = (raw["uuid"] as? String) ?? (raw["id"] as? String) ?? UUID().uuidString
        let role = Self.role(from: raw["sender"])
        let createdAt = Self.isoDate(raw["created_at"])
        let model = raw["model"] as? String

        var blocks: [ConversationTranscriptBlock] = []
        if let content = raw["content"] as? [[String: Any]], !content.isEmpty {
            blocks.append(contentsOf: Self.contentBlocks(from: content))
        } else if let text = raw["text"] as? String, !text.isEmpty {
            blocks.append(.text(text))
        }

        blocks.append(contentsOf: Self.attachmentBlocks(from: raw["attachments"]))
        blocks.append(contentsOf: Self.fileBlocks(from: raw["files"]))

        guard !blocks.isEmpty else { return nil }

        return ConversationTranscriptMessage(
            id: id,
            role: role,
            createdAt: createdAt,
            model: model,
            blocks: blocks
        )
    }

    private static func role(from any: Any?) -> ConversationTranscriptMessage.Role {
        guard let value = any as? String else { return .unknown }
        switch value.lowercased() {
        case "human", "user": return .user
        case "assistant": return .assistant
        case "system": return .system
        case "tool": return .tool
        default: return .unknown
        }
    }

    private static func contentBlocks(
        from parts: [[String: Any]]
    ) -> [ConversationTranscriptBlock] {
        var result: [ConversationTranscriptBlock] = []
        for part in parts {
            let type = (part["type"] as? String)?.lowercased() ?? ""
            switch type {
            case "text":
                if let text = part["text"] as? String, !text.isEmpty {
                    result.append(.text(text))
                }
            case "image":
                result.append(contentsOf: Self.imageBlocks(from: part))
            case "tool_use":
                let name = (part["name"] as? String) ?? "tool"
                let input = part["input"] ?? [:]
                let inputJSON = Self.compactJSON(input)
                result.append(.toolUse(name: name, inputJSON: inputJSON))
            case "tool_result":
                result.append(contentsOf: Self.toolResultBlocks(from: part["content"]))
            case "artifact":
                result.append(Self.artifactBlock(from: part))
            case "thinking", "redacted_thinking":
                // Hidden reasoning traces — the provider UI doesn't surface
                // these to the user, so we don't either. A flag in the UI
                // can toggle them on later.
                continue
            case "":
                continue
            default:
                result.append(.unsupported(summary: "content type: \(type)"))
            }
        }
        return result
    }

    /// Claude images arrive in one of two shapes:
    ///   `source: {type:"base64", media_type:"image/png", data:"..."}` (inline)
    ///   `source: {type:"url", url:"..."}` (newer exports, content is stored
    ///   separately in the vault as a file-* or att-* asset).
    /// The reader wants a vault-resolvable reference, so we prefer the
    /// URL-shaped source; inline base64 isn't asset-backed and falls through
    /// as unsupported for now (the UI can add a data-URL rendering path later
    /// if inline images show up frequently).
    private static func imageBlocks(
        from part: [String: Any]
    ) -> [ConversationTranscriptBlock] {
        guard let source = part["source"] as? [String: Any] else {
            return [.unsupported(summary: "image without source")]
        }
        let mime = source["media_type"] as? String
        if let url = source["url"] as? String, !url.isEmpty {
            return [.image(AssetReference(reference: url, mimeType: mime))]
        }
        if let filePath = source["file_path"] as? String, !filePath.isEmpty {
            return [.image(AssetReference(reference: filePath, mimeType: mime))]
        }
        return [.unsupported(summary: "inline base64 image")]
    }

    private static func toolResultBlocks(from any: Any?) -> [ConversationTranscriptBlock] {
        if let text = any as? String, !text.isEmpty {
            return [.toolResult(text)]
        }
        if let parts = any as? [[String: Any]] {
            var joined: [String] = []
            var images: [ConversationTranscriptBlock] = []
            for part in parts {
                let type = (part["type"] as? String)?.lowercased() ?? ""
                if type == "text", let t = part["text"] as? String, !t.isEmpty {
                    joined.append(t)
                } else if type == "image" {
                    images.append(contentsOf: Self.imageBlocks(from: part))
                }
            }
            var result: [ConversationTranscriptBlock] = []
            if !joined.isEmpty {
                result.append(.toolResult(joined.joined(separator: "\n\n")))
            }
            result.append(contentsOf: images)
            return result
        }
        return []
    }

    private static func artifactBlock(from part: [String: Any]) -> ConversationTranscriptBlock {
        let identifier = (part["identifier"] as? String) ?? (part["id"] as? String) ?? ""
        let title = part["title"] as? String
        // `type` on the outer part is always "artifact" (dispatcher key).
        // `artifact_type` holds the actual kind ("image/svg+xml",
        // "application/vnd.ant.code", etc.), so prefer that.
        let kind = (part["artifact_type"] as? String) ?? (part["mime_type"] as? String)
        let content = (part["content"] as? String) ?? (part["text"] as? String) ?? ""
        return .artifact(
            identifier: identifier,
            title: title,
            kind: kind,
            content: content
        )
    }

    private static func attachmentBlocks(from any: Any?) -> [ConversationTranscriptBlock] {
        guard let array = any as? [[String: Any]] else { return [] }
        return array.map { raw in
            let name = raw["file_name"] as? String
            let size = (raw["file_size"] as? NSNumber)?.int64Value
                ?? (raw["file_size_bytes"] as? NSNumber)?.int64Value
            // Attachments reference the file by name; the resolver matches by
            // basename / suffix so this resolves even when the asset was
            // stashed under a nested vault path.
            let reference = name ?? ""
            return .attachment(
                AssetReference(reference: reference, mimeType: raw["file_type"] as? String),
                name: name,
                sizeBytes: size
            )
        }
    }

    private static func fileBlocks(from any: Any?) -> [ConversationTranscriptBlock] {
        guard let array = any as? [[String: Any]] else { return [] }
        return array.compactMap { raw in
            let name = raw["file_name"] as? String
            let size = (raw["file_size"] as? NSNumber)?.int64Value
            let kind = raw["file_kind"] as? String
            let mime = (kind == "image") ? (raw["file_type"] as? String) : nil
            let reference = name ?? ""
            if kind == "image" {
                return .image(AssetReference(reference: reference, mimeType: mime))
            }
            return .attachment(
                AssetReference(reference: reference, mimeType: raw["file_type"] as? String),
                name: name,
                sizeBytes: size
            )
        }
    }

    // MARK: - Utilities

    private static func compactJSON(_ any: Any) -> String {
        // `fragmentsAllowed` keeps this robust against scalar inputs — Claude
        // tool_use inputs are usually objects, but nothing stops a tool from
        // receiving a single string.
        guard let data = try? JSONSerialization.data(
            withJSONObject: any,
            options: [.fragmentsAllowed, .sortedKeys]
        ), let string = String(data: data, encoding: .utf8) else {
            return ""
        }
        return string
    }

    private static func isoDate(_ any: Any?) -> Date? {
        guard let string = any as? String else { return nil }
        let isoFractional = ISO8601DateFormatter()
        isoFractional.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        if let date = isoFractional.date(from: string) { return date }
        let iso = ISO8601DateFormatter()
        iso.formatOptions = [.withInternetDateTime]
        return iso.date(from: string)
    }
}
