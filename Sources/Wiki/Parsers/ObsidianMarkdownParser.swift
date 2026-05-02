import Foundation

/// Splits an Obsidian markdown document into frontmatter, body, and the
/// list of `[[wikilinks]]` it contains. Pure value transformation — no
/// resolution against the vault. Resolution (matching a wikilink target
/// to an actual `WikiPage`) belongs at the repository or service layer.
enum ObsidianMarkdownParser {
    struct Result: Hashable {
        let frontmatterJSON: String?
        let body: String
        let wikilinks: [Wikilink]
    }

    static func parse(_ markdown: String) -> Result {
        let split = FrontmatterParser.split(markdown)
        let wikilinks = extractWikilinks(from: split.body)
        return Result(
            frontmatterJSON: split.frontmatterJSON,
            body: split.body,
            wikilinks: wikilinks
        )
    }

    // MARK: - Wikilink extraction

    /// Match `[[target]]`, `[[target|display]]`, `[[target#heading]]`,
    /// `[[target^block]]`, and the embed form `![[file.png]]`. The inner
    /// content is then split on `|`, `#`, and `^` to populate the fields.
    private static let wikilinkPattern = #"(!?)\[\[([^\]]+)\]\]"#

    private static func extractWikilinks(from body: String) -> [Wikilink] {
        guard let regex = try? NSRegularExpression(pattern: wikilinkPattern) else {
            return []
        }
        let range = NSRange(body.startIndex..., in: body)
        let matches = regex.matches(in: body, range: range)
        var results: [Wikilink] = []
        for match in matches {
            guard let bangRange = Range(match.range(at: 1), in: body),
                  let innerRange = Range(match.range(at: 2), in: body)
            else { continue }
            let isEmbed = !body[bangRange].isEmpty
            let inner = String(body[innerRange])
            results.append(parseInner(inner, isEmbed: isEmbed))
        }
        return results
    }

    private static func parseInner(_ inner: String, isEmbed: Bool) -> Wikilink {
        // Display alias (`|alias`) is always the trailing segment in
        // Obsidian's grammar, so peel it off first.
        var rest = inner
        var display: String? = nil
        if let pipeIdx = rest.firstIndex(of: "|") {
            display = String(rest[rest.index(after: pipeIdx)...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<pipeIdx])
        }

        var heading: String? = nil
        var blockRef: String? = nil
        // `#section` and `^block-id` are mutually exclusive in Obsidian's
        // canonical syntax. Whichever appears first wins; the other char,
        // if present afterwards, stays as part of the target so we don't
        // silently swallow malformed input.
        if let hashIdx = rest.firstIndex(of: "#") {
            heading = String(rest[rest.index(after: hashIdx)...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<hashIdx])
        } else if let caretIdx = rest.firstIndex(of: "^") {
            blockRef = String(rest[rest.index(after: caretIdx)...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<caretIdx])
        }

        let target = rest.trimmingCharacters(in: .whitespaces)
        return Wikilink(
            target: target,
            display: display,
            heading: heading,
            blockRef: blockRef,
            isEmbed: isEmbed
        )
    }
}
