import Foundation

struct Wikilink: Hashable, Sendable {
    let target: String
    let display: String?
    let heading: String?
    let blockRef: String?
}
