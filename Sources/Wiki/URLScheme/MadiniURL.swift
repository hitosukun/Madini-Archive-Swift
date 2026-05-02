import Foundation

/// Parsed representation of a `madini-archive://...` URL. Pure value
/// type — actual navigation lives in `MadiniURLHandler`.
///
/// Supported shapes (from the Phase A handoff):
///   - `madini-archive://conversation/<conv_id>`
///   - `madini-archive://conversation/<conv_id>/message/<msg_index>`
///   - `madini-archive://search?q=<query>`
///   - `madini-archive://wiki/<vault_id>/<path>`
enum MadiniURL: Equatable, Sendable {
    case conversation(id: String, messageIndex: Int?)
    case search(query: String)
    case wikiPage(vaultID: String, relativePath: String)

    static let scheme = "madini-archive"

    /// Returns nil if the URL doesn't conform to one of the supported
    /// shapes. The handler logs the rejection but otherwise ignores
    /// malformed URLs — we never crash on user-supplied input.
    static func parse(_ url: URL) -> MadiniURL? {
        guard url.scheme?.lowercased() == scheme else { return nil }

        // `madini-archive://X/...` — `host` returns X, `pathComponents`
        // returns the rest with a leading "/".
        guard let host = url.host?.lowercased() else { return nil }
        let trailingComponents = url.pathComponents.filter { $0 != "/" }

        switch host {
        case "conversation":
            guard let convID = trailingComponents.first else { return nil }
            // Optional `/message/<index>` suffix.
            if trailingComponents.count >= 3,
               trailingComponents[1].lowercased() == "message",
               let msgIndex = Int(trailingComponents[2]) {
                return .conversation(id: convID, messageIndex: msgIndex)
            }
            return .conversation(id: convID, messageIndex: nil)

        case "search":
            // Query string `?q=...`
            let q = URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?
                .first(where: { $0.name == "q" })?
                .value
            guard let query = q, !query.isEmpty else { return nil }
            return .search(query: query)

        case "wiki":
            guard let vaultID = trailingComponents.first else { return nil }
            let pathParts = trailingComponents.dropFirst()
            guard !pathParts.isEmpty else { return nil }
            let relativePath = pathParts.joined(separator: "/")
            return .wikiPage(vaultID: vaultID, relativePath: relativePath)

        default:
            return nil
        }
    }
}
