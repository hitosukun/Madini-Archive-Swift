import Foundation

/// Thin dispatcher that picks the right per-provider extractor for a
/// `RawConversationJSON` payload. Keeps call sites provider-agnostic: the
/// reader just asks for a transcript and gets back a flat `ConversationTranscript`.
enum ConversationTranscriptExtractor {
    enum Error: Swift.Error, Sendable {
        /// The provider has no extractor (Gemini, `.unknown`).
        case unsupportedProvider(RawExportProvider)
    }

    static func extract(
        from rawJSON: RawConversationJSON
    ) throws -> ConversationTranscript {
        switch rawJSON.provider {
        case .chatGPT:
            return try ChatGPTTranscriptExtractor.extract(from: rawJSON)
        case .claude:
            return try ClaudeTranscriptExtractor.extract(from: rawJSON)
        case .gemini, .unknown:
            throw Error.unsupportedProvider(rawJSON.provider)
        }
    }
}
