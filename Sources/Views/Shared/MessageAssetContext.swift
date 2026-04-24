import SwiftUI

/// Per-conversation handle that lets `MessageBubbleView` render image
/// attachments pulled from the raw export transcript — images that
/// never land in the flat `messages.content` text stored in the DB.
///
/// ## Why the reader can't just use markdown
///
/// ChatGPT stores user-uploaded images as `image_asset_pointer` nodes
/// inside `multimodal_text` message parts. Those pointers never get
/// serialized into the `content` column of `messages`, so the reader's
/// canonical markdown path has nothing to render from — even though
/// the assistant's reply repeatedly refers to "1枚目", "2枚目" etc. The
/// raw transcript view already resolves the pointers via
/// `RawTranscriptImageView`. This context carries the same three
/// handles that view needs — vault + resolver + snapshot id — plus a
/// per-DB-message lookup of the asset references attached to each
/// message, so bubbles can paint the images in-line without
/// `ConversationDetailView` having to fan out a second data-flow path
/// to every call site.
///
/// ## Lifecycle
///
/// `ConversationDetailViewModel` owns the single instance: it starts
/// out `nil`, gets populated once after the DB detail loads and the
/// raw transcript extraction finishes, and is wiped when the view
/// model switches conversations. Publishing it through
/// `EnvironmentValues.messageAssetContext` (rather than drilling it
/// through every init) keeps the zero-attachments fast path
/// touch-free — bubbles just see `nil` and render the way they always
/// did.
struct MessageAssetContext {
    let vault: any RawExportVault
    let resolver: any RawAssetResolver
    let snapshotID: Int64
    /// Maps `Message.id` (the DB-side synthetic `"<conv>:<row>"`
    /// identifier) to the ordered asset references attached to that
    /// message. Missing keys / empty values mean "no attachments" —
    /// the bubble renders text only.
    let attachmentsByMessageID: [String: [AssetReference]]
}

private struct MessageAssetContextKey: EnvironmentKey {
    static let defaultValue: MessageAssetContext? = nil
}

extension EnvironmentValues {
    var messageAssetContext: MessageAssetContext? {
        get { self[MessageAssetContextKey.self] }
        set { self[MessageAssetContextKey.self] = newValue }
    }
}
