// ViewModels/ConversationDetailViewModel.swift
//
// 個別会話の詳細表示に関する UI 状態を管理する。

import Observation

@MainActor
@Observable
final class ConversationDetailViewModel {
    var detail: ConversationDetail?
    var isLoading: Bool = false
    var errorText: String?
    /// Images / attachments pulled from the raw export transcript,
    /// keyed by DB `Message.id`. `nil` until the second-stage raw
    /// transcript load completes — or forever when the host has no
    /// `RawConversationLoader` wired (mock mode, Gemini conversations
    /// whose provider-native IDs aren't stable, or any conversation
    /// whose raw JSON isn't vaulted). The reader treats `nil` as the
    /// text-only fast path, so there's no degradation for the
    /// majority of conversations.
    var assetContext: MessageAssetContext?

    private let repository: any ConversationRepository
    let conversationId: String

    init(conversationId: String, repository: any ConversationRepository) {
        self.conversationId = conversationId
        self.repository = repository
    }

    func load() async {
        isLoading = true
        errorText = nil
        // Clear stale attachments as we swap conversations. Without
        // this, a fresh load briefly renders the previous
        // conversation's images on top of the new text until the new
        // extraction resolves.
        assetContext = nil
        defer { isLoading = false }

        do {
            detail = try await repository.fetchDetail(id: conversationId)
        } catch {
            detail = nil
            errorText = error.localizedDescription
            print("Failed to load detail: \(error)")
        }
    }

    /// Best-effort second-stage load: pull the raw export JSON for
    /// this conversation, extract it into provider-neutral blocks,
    /// and build a per-message attachment map so
    /// `MessageBubbleView` can render the user-uploaded images that
    /// never made it into the DB's flat text column.
    ///
    /// Every failure mode (no loader wired, no vaulted JSON for this
    /// conversation, provider without a text-extractor, JSON parse
    /// error) leaves `assetContext` `nil` — the reader falls back to
    /// text-only rendering, which is the right degradation. We
    /// deliberately don't surface an error to the UI because "this
    /// conversation had no vaulted images" is indistinguishable from
    /// "we couldn't find the raw JSON", and both should read as
    /// "reader works, no pictures to show."
    func attachRawServices(
        loader: (any RawConversationLoader)?,
        vault: any RawExportVault,
        resolver: any RawAssetResolver
    ) async {
        guard let loader, let detail else { return }
        do {
            guard let raw = try await loader.loadRawJSON(conversationID: conversationId) else {
                return
            }
            let transcript = try Self.extract(rawJSON: raw)
            let attachments = Self.alignAttachments(
                dbMessages: detail.messages,
                transcript: transcript
            )
            // If nothing aligned, don't bother publishing an empty
            // context — `nil` is the sentinel the bubble fast-path
            // uses to skip asset rendering entirely.
            guard attachments.values.contains(where: { !$0.isEmpty }) else {
                return
            }
            // Drop the result if the user navigated away mid-flight.
            // The `.task(id:)` on the view normally cancels us, but an
            // explicit guard avoids racing a stale context into a view
            // that's already showing a different conversation.
            guard self.detail?.summary.id == conversationId else { return }
            // Flatten attachments into reading-order so the preview
            // window can navigate across the whole conversation with
            // arrow keys. Walking `detail.messages` (not
            // `attachments.keys`) is what gives us the user-visible
            // order — dictionaries aren't ordered, but message lists
            // are.
            var ordered: [AssetReference] = []
            var offsets: [String: Int] = [:]
            for msg in detail.messages {
                guard let refs = attachments[msg.id], !refs.isEmpty else { continue }
                offsets[msg.id] = ordered.count
                ordered.append(contentsOf: refs)
            }
            assetContext = MessageAssetContext(
                vault: vault,
                resolver: resolver,
                snapshotID: raw.snapshotID,
                attachmentsByMessageID: attachments,
                orderedReferences: ordered,
                startOffsetByMessageID: offsets
            )
        } catch {
            print("Raw transcript attach failed for \(conversationId): \(error)")
        }
    }

    private static func extract(rawJSON: RawConversationJSON) throws -> ConversationTranscript {
        switch rawJSON.provider {
        case .chatGPT:
            return try ChatGPTTranscriptExtractor.extract(from: rawJSON)
        case .claude:
            return try ClaudeTranscriptExtractor.extract(from: rawJSON)
        case .gemini, .unknown:
            // `RawConversationLoader` already refuses Gemini, and
            // `.unknown` shouldn't make it into a cache row — guard
            // anyway so this switch stays exhaustive and we fail
            // loudly in logs instead of rendering empty attachments.
            throw AttachError.unsupportedProvider
        }
    }

    private enum AttachError: Error { case unsupportedProvider }

    /// Attach asset references to DB messages by splitting both streams
    /// into "turns" (ranges delimited by user messages) and matching
    /// them by the user message's text content rather than by
    /// positional index.
    ///
    /// ## Why content-matched turns, not positional turns
    ///
    /// The earlier positional turn-pairing (dbTurns[i] ↔ tTurns[i])
    /// drifted on conversations where the DB and the transcript
    /// disagree on turn boundaries. Cases observed in real exports:
    ///
    ///   - ChatGPT occasionally records two consecutive user nodes
    ///     (user pressed the retry button; both live in the canonical
    ///     branch). The DB's importer may collapse, keep, or split
    ///     these differently than the transcript extractor.
    ///   - A user-editable-context / memory-update node sometimes
    ///     lands between two user messages. The transcript extractor
    ///     returns `[]` for those (`user_editable_context` short-
    ///     circuits in `ChatGPTTranscriptExtractor.blocks`), so the
    ///     transcript turn lacks a row that the DB still has as an
    ///     assistant message.
    ///   - Back-to-back assistant messages from retried tool calls
    ///     (refusal followed by orphan code-prompt, no intervening
    ///     user) tilt turn boundaries slightly.
    ///
    /// Any of those shaves or adds one transcript turn relative to the
    /// DB. A positional pairing then mis-binds every downstream turn,
    /// which is what the user saw as "late-conversation narratives
    /// have no image" — the drifted tTurn was a refusal / error turn
    /// that carried no images, so the attach silently skipped.
    ///
    /// User message TEXT is the stable anchor: both sides record it
    /// byte-identically. We build a FIFO queue keyed by the turn's
    /// user text and, for each DB turn, pull the first matching
    /// transcript turn. Duplicate user texts (the user literally
    /// sending "お願いできる？" twice) are handled by the FIFO — each
    /// DB occurrence consumes one transcript occurrence, in order.
    ///
    /// ## Attachment target within a turn
    ///
    /// User-uploaded images (which live in the transcript's USER
    /// message as `image_asset_pointer` parts inside a
    /// `multimodal_text` wrapper) attach to the DB user message.
    /// Assistant / tool generated images (DALL-E output, typically a
    /// `role: "tool"` transcript node) attach to the LAST assistant
    /// narrative in the DB turn — i.e. the "完成したよ！" reply that
    /// follows the tool response. Splitting the two buckets means the
    /// user bubble shows what they uploaded and the assistant bubble
    /// shows what was generated, without either kind of image
    /// spuriously landing on the other role's message.
    private static func alignAttachments(
        dbMessages: [Message],
        transcript: ConversationTranscript
    ) -> [String: [AssetReference]] {
        let dbTurns = Self.splitIntoTurns(dbMessages: dbMessages)
        let tTurns = Self.splitIntoTurns(transcriptMessages: transcript.messages)

        // FIFO queue per normalized user-text key so duplicates are
        // consumed in order and later identical prompts don't steal
        // an earlier turn's images.
        var transcriptQueue: [String: [[ConversationTranscriptMessage]]] = [:]
        for tTurn in tTurns {
            let key = Self.userKey(transcriptTurn: tTurn)
            transcriptQueue[key, default: []].append(tTurn)
        }

        var result: [String: [AssetReference]] = [:]
        for dbTurn in dbTurns {
            let key = Self.userKey(dbTurn: dbTurn)
            guard var queue = transcriptQueue[key], !queue.isEmpty else { continue }
            let tTurn = queue.removeFirst()
            transcriptQueue[key] = queue

            // Partition image references by which transcript role
            // produced them. User uploads live in the user message;
            // DALL-E output lives in assistant / tool messages.
            var userImages: [AssetReference] = []
            var generatedImages: [AssetReference] = []
            for tMsg in tTurn {
                let refs = Self.imageReferences(in: tMsg.blocks)
                guard !refs.isEmpty else { continue }
                if tMsg.role == .user {
                    userImages.append(contentsOf: refs)
                } else {
                    generatedImages.append(contentsOf: refs)
                }
            }

            if !userImages.isEmpty,
               let dbUser = dbTurn.first, dbUser.role == .user {
                result[dbUser.id, default: []].append(contentsOf: userImages)
            }
            if !generatedImages.isEmpty,
               let target = Self.preferredAttachmentTarget(in: dbTurn) {
                result[target.id, default: []].append(contentsOf: generatedImages)
            }
        }
        return result
    }

    /// Normalized user-text key for a DB turn. Empty string if the
    /// turn doesn't start with a user message (preface turn) — those
    /// won't match any transcript turn's key and are correctly
    /// skipped.
    private static func userKey(dbTurn: [Message]) -> String {
        guard let first = dbTurn.first, first.role == .user else { return "" }
        return Self.normalizeUserText(first.content)
    }

    /// Normalized user-text key for a transcript turn. Flattens the
    /// user message's `.text` blocks the same way
    /// `ChatGPTTranscriptExtractor.multimodalBlocks` joins text parts
    /// — `\n\n` separated — so the concatenation lines up with what
    /// the DB importer stored as the user's `content`.
    private static func userKey(
        transcriptTurn: [ConversationTranscriptMessage]
    ) -> String {
        guard let first = transcriptTurn.first, first.role == .user else { return "" }
        var chunks: [String] = []
        for block in first.blocks {
            if case .text(let s) = block, !s.isEmpty {
                chunks.append(s)
            }
        }
        return Self.normalizeUserText(chunks.joined(separator: "\n\n"))
    }

    /// Trim + collapse runs of whitespace. The DB importer and the
    /// transcript extractor both preserve user text verbatim, but
    /// export-round-tripping can leave leading/trailing whitespace or
    /// normalize CRLF to LF on one side only. A light normalization
    /// here is cheap insurance against a whole turn silently failing
    /// to match because of a trailing newline.
    private static func normalizeUserText(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Split a DB message list into turns. A turn starts at a user
    /// message (or the very beginning, for any preface messages that
    /// precede the first user prompt — rare, but we keep them as turn
    /// zero so the indexing lines up with the transcript's own
    /// preface handling).
    private static func splitIntoTurns(dbMessages: [Message]) -> [[Message]] {
        var turns: [[Message]] = []
        var current: [Message] = []
        for msg in dbMessages {
            if msg.role == .user, !current.isEmpty {
                turns.append(current)
                current = [msg]
            } else {
                current.append(msg)
            }
        }
        if !current.isEmpty { turns.append(current) }
        return turns
    }

    /// Same slicing rule for transcript messages. Keeping this as a
    /// second overload (rather than making the caller generalize)
    /// means we don't have to unify `Message.role` and
    /// `ConversationTranscriptMessage.Role` just to share a helper.
    private static func splitIntoTurns(
        transcriptMessages: [ConversationTranscriptMessage]
    ) -> [[ConversationTranscriptMessage]] {
        var turns: [[ConversationTranscriptMessage]] = []
        var current: [ConversationTranscriptMessage] = []
        for msg in transcriptMessages {
            if msg.role == .user, !current.isEmpty {
                turns.append(current)
                current = [msg]
            } else {
                current.append(msg)
            }
        }
        if !current.isEmpty { turns.append(current) }
        return turns
    }

    /// Pick the DB message in `turn` that should carry this turn's
    /// image references. Scanned newest-first so the chosen target is
    /// always at or near the bottom of the turn (the narrative reply
    /// that follows the tool output).
    ///
    /// Preference order:
    ///   1. Assistant message whose content doesn't start with `{` —
    ///      i.e. plain-prose narrative, not a tool-call JSON blob.
    ///   2. Any assistant message — the turn may be all tool-call
    ///      plumbing (orphan code prompts after a refusal), and
    ///      attaching to one of those is better than dropping.
    ///   3. Last message of any role — defensive fallback so a
    ///      malformed turn can still surface its image.
    private static func preferredAttachmentTarget(in turn: [Message]) -> Message? {
        for msg in turn.reversed() {
            guard msg.role == .assistant else { continue }
            if !Self.looksLikeToolCallJSON(msg.content) {
                return msg
            }
        }
        for msg in turn.reversed() where msg.role == .assistant {
            return msg
        }
        return turn.last
    }

    /// True when the assistant message content is a DALL-E / tool-call
    /// JSON blob rather than a user-facing narrative. These are the
    /// nodes with `content_type: code` and `recipient: dalle.text2im`
    /// in the raw export, which the importer serializes verbatim as
    /// text so the reader can still display them if asked. We don't
    /// want the image hanging off one of these — the user's eye goes
    /// to the narrative that follows, not the prompt blob.
    private static func looksLikeToolCallJSON(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed.hasPrefix("{") else { return false }
        // A narrative might occasionally start with `{` if the model
        // pastes JSON into a reply, so require a `"prompt"` key within
        // the first few dozen characters to be confident it's a
        // tool-call blob. The real exports always key on `prompt`.
        let head = trimmed.prefix(80)
        return head.contains("\"prompt\"")
    }

    private static func imageReferences(
        in blocks: [ConversationTranscriptBlock]
    ) -> [AssetReference] {
        var refs: [AssetReference] = []
        for block in blocks {
            switch block {
            case .image(let ref):
                refs.append(ref)
            case .attachment(let ref, _, _):
                // Only surface image-typed attachments via the image
                // renderer. Audio / video blobs land here too (ChatGPT
                // wraps them in `audio_asset_pointer` /
                // `video_container_asset_pointer`) and rendering them
                // as a silent "photo" placeholder would be misleading.
                // We gate on MIME when the extractor set one; when
                // MIME is absent we skip, since the alternative is
                // to paint a broken image card.
                if let mime = ref.mimeType?.lowercased(),
                   mime.hasPrefix("image/") {
                    refs.append(ref)
                }
            default:
                break
            }
        }
        return refs
    }

}
