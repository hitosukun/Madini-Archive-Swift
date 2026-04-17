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
    /// Private UTI for Madini tag drags. Declared as `importedAs` rather
    /// than `exportedAs` so we do not need a matching entry in the app
    /// bundle's Info.plist — Xcode logs a warning like
    /// `Type "app.madini.archive.tag" was expected to be declared and
    /// exported in the Info.plist` when `exportedAs` is used without a
    /// bundle declaration. Drops are scoped in-process (sidebar tag row
    /// → conversation card), so either kind works functionally.
    static let madiniTag = UTType(importedAs: "app.madini.archive.tag")
}
