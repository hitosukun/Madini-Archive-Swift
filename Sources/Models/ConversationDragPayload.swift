import Foundation
import SwiftUI
import UniformTypeIdentifiers

/// Drag payload for "conversation card → sidebar tag row" attaches.
///
/// Shares `TagDragPayload`'s rationale (no private UTI because SwiftPM
/// executable targets have no Info.plist to register one), but pointedly
/// uses a *different* system UTI — `com.apple.property-list` — so the
/// sidebar tag row's `.dropDestination(for: ConversationDragPayload.self)`
/// and the conversation row's `.dropDestination(for: TagDragPayload.self)`
/// never even *look* at each other's payload bytes.
///
/// Previously both payloads shared `public.json`, which meant every
/// hover of one payload over the other's drop zone triggered a decode
/// attempt that correctly failed on the `kind` discriminator — but
/// SwiftUI logged the rejection as a `DecodingError.dataCorrupted` line,
/// spamming the console during every drag. Splitting the UTIs stops the
/// cross-decode at the item-provider level; the `kind` discriminator
/// remains as belt-and-suspenders in case someone introduces another
/// `.propertyList`-typed payload later.
struct ConversationDragPayload: Codable, Hashable, Transferable, Sendable {
    static let payloadKind = "madini.conversation"

    let ids: [String]

    private var kind: String { Self.payloadKind }

    init(id: String) {
        self.ids = [id]
    }

    init(ids: [String]) {
        let cleaned = Array(NSOrderedSet(array: ids)) as? [String] ?? ids
        self.ids = cleaned.filter { !$0.isEmpty }
    }

    private enum CodingKeys: String, CodingKey {
        case kind
        case id
        case ids
    }

    var conversationIDs: [String] {
        if ids.isEmpty { return [] }
        return ids
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let storedKind = try container.decode(String.self, forKey: .kind)
        guard storedKind == Self.payloadKind else {
            throw DecodingError.dataCorruptedError(
                forKey: .kind,
                in: container,
                debugDescription: "Not a Madini conversation payload (got \(storedKind))."
            )
        }
        if let ids = try container.decodeIfPresent([String].self, forKey: .ids) {
            self.ids = ids
        } else {
            self.ids = [try container.decode(String.self, forKey: .id)]
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        try container.encode(conversationIDs, forKey: .ids)
        try container.encode(conversationIDs.first ?? "", forKey: .id)
    }

    static var transferRepresentation: some TransferRepresentation {
        // Note: different UTI from TagDragPayload (.json). See type doc.
        CodableRepresentation(contentType: .propertyList)
    }
}
