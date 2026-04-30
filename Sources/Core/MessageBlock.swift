import Foundation

/// Structured representation of a single message block as stored in
/// `messages.content_json` by the Python core. Phase 3 wires read-only
/// access on the Swift side; Phase 4 will use these blocks to drive
/// the structural folding of `thinking` runs in `MessageBubbleView`,
/// replacing the language-detection heuristic that the temporary
/// hotfixes in `ForeignLanguageGrouping` lean on.
///
/// The schema is provider-agnostic: the same `thinking` case carries
/// Claude's internal monologue and ChatGPT o3 / research-model
/// reasoning, distinguished by the `provider` payload. Unknown `type`
/// values from future provider additions decode into `.unsupported`
/// so the reader can still walk the block list and show a placeholder
/// instead of dropping the message entirely.
///
/// See `docs/plans/thinking-preservation-2026-04-30.md` §2.2 for the
/// full schema and `Madini_Dev/split_chatlog.py` for the writer side
/// (`_build_claude_message_blocks`, `_build_chatgpt_message_blocks`).
enum MessageBlock: Hashable, Sendable, Codable {
    case text(String)
    case thinking(provider: String, text: String, metadata: [String: JSONValue])
    case toolUse(name: String, inputSummary: String)
    case toolResult(name: String, isError: Bool, summary: String)
    case artifact(identifier: String, title: String?, kind: String?, content: String)
    /// Forward-compat catch-all for `type` values the current build
    /// doesn't recognize. Carries the raw type string so a future
    /// debug surface (or just a console log) can tell us what
    /// providers have started emitting.
    case unsupported(rawType: String)

    private enum CodingKeys: String, CodingKey {
        case type
        case text
        case provider
        case metadata
        case name
        case inputSummary = "input_summary"
        case isError = "is_error"
        case summary
        case identifier
        case title
        case kind
        case content
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "text":
            let text = try container.decode(String.self, forKey: .text)
            self = .text(text)
        case "thinking":
            // `provider` is required so the reader can dispatch
            // provider-specific styling (Claude folds, ChatGPT recap
            // header, etc.). Older Python emit cycles before Phase
            // 2b shouldn't lack it, but if a hand-edited blob does,
            // default to "unknown" rather than failing the whole
            // message decode.
            let provider = (try? container.decode(String.self, forKey: .provider)) ?? "unknown"
            let text = try container.decode(String.self, forKey: .text)
            let metadata = (try? container.decode([String: JSONValue].self, forKey: .metadata)) ?? [:]
            self = .thinking(provider: provider, text: text, metadata: metadata)
        case "tool_use":
            let name = try container.decode(String.self, forKey: .name)
            let inputSummary = (try? container.decode(String.self, forKey: .inputSummary)) ?? ""
            self = .toolUse(name: name, inputSummary: inputSummary)
        case "tool_result":
            let name = try container.decode(String.self, forKey: .name)
            let isError = (try? container.decode(Bool.self, forKey: .isError)) ?? false
            let summary = (try? container.decode(String.self, forKey: .summary)) ?? ""
            self = .toolResult(name: name, isError: isError, summary: summary)
        case "artifact":
            let identifier = (try? container.decode(String.self, forKey: .identifier)) ?? ""
            let title = try? container.decodeIfPresent(String.self, forKey: .title)
            let kind = try? container.decodeIfPresent(String.self, forKey: .kind)
            let content = (try? container.decode(String.self, forKey: .content)) ?? ""
            self = .artifact(identifier: identifier, title: title ?? nil, kind: kind ?? nil, content: content)
        default:
            self = .unsupported(rawType: type)
        }
    }

    func encode(to encoder: Encoder) throws {
        // Provided for Codable completeness only. Phase 3 is read-
        // only on the Swift side — the Python core owns the
        // `messages.content_json` schema; round-tripping through
        // Swift is not a supported workflow today.
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .thinking(let provider, let text, let metadata):
            try container.encode("thinking", forKey: .type)
            try container.encode(provider, forKey: .provider)
            try container.encode(text, forKey: .text)
            try container.encode(metadata, forKey: .metadata)
        case .toolUse(let name, let inputSummary):
            try container.encode("tool_use", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(inputSummary, forKey: .inputSummary)
        case .toolResult(let name, let isError, let summary):
            try container.encode("tool_result", forKey: .type)
            try container.encode(name, forKey: .name)
            try container.encode(isError, forKey: .isError)
            try container.encode(summary, forKey: .summary)
        case .artifact(let identifier, let title, let kind, let content):
            try container.encode("artifact", forKey: .type)
            try container.encode(identifier, forKey: .identifier)
            try container.encodeIfPresent(title, forKey: .title)
            try container.encodeIfPresent(kind, forKey: .kind)
            try container.encode(content, forKey: .content)
        case .unsupported(let rawType):
            try container.encode(rawType, forKey: .type)
        }
    }
}

/// Minimal value type for the heterogeneous `metadata` dict on
/// `thinking` blocks. The Python writer emits a mix of strings
/// (timestamps, signature, source_analysis_msg_id), bools (cut_off,
/// truncated, recap), and occasionally numbers — `JSONValue` lets
/// Swift decode the dict without committing to a strict schema, and
/// the reader can call `.stringValue` for display when the underlying
/// type doesn't matter.
enum JSONValue: Hashable, Sendable, Codable {
    case string(String)
    case bool(Bool)
    case int(Int)
    case double(Double)
    case null

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if container.decodeNil() {
            self = .null
        } else if let value = try? container.decode(Bool.self) {
            self = .bool(value)
        } else if let value = try? container.decode(Int.self) {
            self = .int(value)
        } else if let value = try? container.decode(Double.self) {
            self = .double(value)
        } else if let value = try? container.decode(String.self) {
            self = .string(value)
        } else {
            throw DecodingError.dataCorruptedError(
                in: container,
                debugDescription: "JSONValue: unsupported scalar type"
            )
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .null:
            try container.encodeNil()
        case .bool(let value):
            try container.encode(value)
        case .int(let value):
            try container.encode(value)
        case .double(let value):
            try container.encode(value)
        case .string(let value):
            try container.encode(value)
        }
    }

    /// Best-effort string projection for display surfaces. Lossy by
    /// design — `bool`s become `"true"` / `"false"`, numbers become
    /// their decimal representation. The intent is "show me what's
    /// there", not "preserve the original JSON shape".
    var stringValue: String {
        switch self {
        case .string(let value): return value
        case .bool(let value): return value ? "true" : "false"
        case .int(let value): return String(value)
        case .double(let value): return String(value)
        case .null: return ""
        }
    }
}
