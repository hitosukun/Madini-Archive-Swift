import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Drag payload for "tag row → conversation card" attaches.
///
/// We deliberately piggy-back on the system-registered `public.json`
/// UTI rather than defining a private one. SwiftPM executable targets
/// do not expose Info.plist, so private UTIs declared with
/// `UTType(exportedAs:)` / `UTType(importedAs:)` are never actually
/// registered — Xcode warns about it, and more importantly the
/// `NSItemProvider` produced for the drag carries a type the system
/// doesn't recognize, which silently breaks `.dropDestination` matching.
///
/// Using `.json` + a `kind` discriminator inside the Codable payload
/// keeps in-app DnD reliable without a bundle plist. The companion
/// `ConversationDragPayload` uses `.propertyList` instead of `.json`
/// so cross-type drops reject at the item-provider layer (no decode
/// attempt, no console spam). The `kind` discriminator remains as a
/// cheap safety net.
struct TagDragPayload: Codable, Hashable, Transferable, Sendable {
    static let payloadKind = "madini.tag"

    let name: String

    private var kind: String { Self.payloadKind }

    init(name: String) {
        self.name = name
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case name
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedKind = try container.decode(String.self, forKey: .kind)
        guard storedKind == Self.payloadKind else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Not a Madini tag payload (got \(storedKind))."
            )
        }
        self.name = try container.decode(String.self, forKey: .name)
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(name, forKey: .name)
    }

    static var transferRepresentation: some TransferRepresentation {
        CodableRepresentation(contentType: .json)
    }
}
