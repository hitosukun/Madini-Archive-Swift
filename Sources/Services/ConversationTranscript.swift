import Foundation

/// Provider-neutral transcript built from a `RawConversationJSON`. The reader
/// UI consumes `ConversationTranscript` directly; the per-provider JSON
/// shape only exists inside the extractors (`ChatGPTTranscriptExtractor` /
/// `ClaudeTranscriptExtractor`).
///
/// `sourceRelativePath` is preserved so image / attachment resolution can
/// scope asset lookups to the same snapshot file the transcript was parsed
/// from — a single snapshot can contain multiple conversation chunks, and
/// assets referenced by one chunk may not be visible to another.
struct ConversationTranscript: Sendable, Hashable {
    let conversationID: String
    let provider: RawExportProvider
    let snapshotID: Int64
    let sourceRelativePath: String
    let title: String?
    let createdAt: Date?
    let updatedAt: Date?
    let messages: [ConversationTranscriptMessage]
}

/// One logical message in the transcript. `blocks` preserves author order
/// (ChatGPT: walk from current_node up to root, reversed; Claude: iterate
/// `chat_messages` in array order).
struct ConversationTranscriptMessage: Identifiable, Sendable, Hashable {
    /// Provider-native message ID. For ChatGPT this is the mapping-node ID;
    /// for Claude it's the per-message UUID.
    let id: String
    let role: Role
    let createdAt: Date?
    /// Provider-reported model name when available (ChatGPT
    /// `message.metadata.model_slug` / Claude `message.model`). The reader
    /// uses this to label assistant turns across different models.
    let model: String?
    let blocks: [ConversationTranscriptBlock]

    enum Role: String, Sendable, Hashable {
        case user
        case assistant
        case system
        case tool
        case unknown
    }
}

/// The atomic renderable unit in a transcript. `unsupported` is deliberately
/// left in the surface so the reader can show a placeholder ("tool call
/// omitted") instead of silently dropping unknown content_types — easier to
/// spot missing parsers in real exports.
enum ConversationTranscriptBlock: Sendable, Hashable {
    case text(String)
    case code(language: String?, source: String)
    case image(AssetReference)
    case attachment(AssetReference, name: String?, sizeBytes: Int64?)
    case toolUse(name: String, inputJSON: String)
    case toolResult(String)
    case artifact(identifier: String, title: String?, kind: String?, content: String)
    case unsupported(summary: String)
}

/// A reference to an asset blob that lives in the Raw Export Vault. The
/// reader hands this off to `RawAssetResolver.resolveAsset(snapshotID:reference:)`
/// and renders whatever blob comes back. We keep the reference string in its
/// provider-native form (e.g. `"file-service://file-abc123"`) because the
/// resolver already handles URL / path / basename matching.
struct AssetReference: Sendable, Hashable {
    let reference: String
    let mimeType: String?
}
