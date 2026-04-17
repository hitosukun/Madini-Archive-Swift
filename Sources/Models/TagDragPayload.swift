import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Lightweight drag payload used when the sidebar's tag row is dragged onto
/// a conversation card to attach the tag. The name is the source of truth —
/// the receiving view resolves it back to a `TagEntry` via `LibraryViewModel`.
struct TagDragPayload: Codable, Hashable, Transferable, Sendable {
    let name: String

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .madiniTag)
    }
}

extension UTType {
    /// Private UTI for Madini tag drags. Declared as an exported type only
    /// within this process — no Info.plist entry is needed because drops are
    /// scoped to in-process targets (sidebar tag row → conversation card).
    static let madiniTag = UTType(exportedAs: "app.madini.archive.tag")
}
