import Foundation

/// Rewrites Obsidian-specific markdown into vanilla GFM that MarkdownUI
/// can render directly.
///
/// - `[[target]]` → `[target](wiki://target)`
/// - `[[target|display]]` → `[display](wiki://target)`
/// - `[[target#heading]]` → `[heading on target](wiki://target#heading)`
/// - `![[image.png]]` → `![image.png](file:///<vault>/image.png)`
///
/// The vault root is needed for embed rewriting because file:// URLs are
/// absolute. Plain wikilinks use a custom `wiki://` scheme so the page
/// view's `OpenURLAction` can intercept them and trigger in-app
/// navigation rather than handing them to the OS.
enum WikiMarkdownPreprocessor {
    static let wikiURLScheme = "wiki"

    /// Rewrite both wikilinks and embeds. Caller passes the vault path so
    /// `![[diagram.png]]` resolves to a real file URL.
    static func preprocess(_ body: String, vaultPath: String) -> String {
        let withEmbeds = rewriteEmbeds(body, vaultPath: vaultPath)
        return rewriteWikilinks(withEmbeds)
    }

    // MARK: - Wikilinks

    /// Match `[[...]]` not preceded by `!`. We use a lookbehind via a
    /// negative-leading-char workaround: capture the preceding char (or
    /// start-of-string) and only rewrite when it's not `!`.
    private static let wikilinkPattern = #"(^|[^!])\[\[([^\]]+)\]\]"#

    static func rewriteWikilinks(_ body: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: wikilinkPattern) else {
            return body
        }
        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        var result = ""
        var cursor = 0

        regex.enumerateMatches(in: body, range: fullRange) { match, _, _ in
            guard let match else { return }
            let leadingRange = match.range(at: 1)
            let innerRange = match.range(at: 2)
            let matchStart = match.range.location

            // Append everything between cursor and the start of the
            // matched leading char.
            if matchStart > cursor {
                result += nsBody.substring(
                    with: NSRange(location: cursor, length: matchStart - cursor)
                )
            }
            // Re-emit the leading char (it was captured but is *not*
            // part of the wikilink).
            if leadingRange.length > 0 {
                result += nsBody.substring(with: leadingRange)
            }
            let inner = nsBody.substring(with: innerRange)
            result += renderWikilink(inner)
            cursor = match.range.location + match.range.length
        }
        if cursor < nsBody.length {
            result += nsBody.substring(
                with: NSRange(location: cursor, length: nsBody.length - cursor)
            )
        }
        return result
    }

    private static func renderWikilink(_ inner: String) -> String {
        var rest = inner
        var display: String? = nil
        if let pipeIdx = rest.firstIndex(of: "|") {
            display = String(rest[rest.index(after: pipeIdx)...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<pipeIdx])
        }
        var fragment: String? = nil
        if let hashIdx = rest.firstIndex(of: "#") {
            fragment = String(rest[rest.index(after: hashIdx)...])
                .trimmingCharacters(in: .whitespaces)
            rest = String(rest[..<hashIdx])
        }
        let target = rest.trimmingCharacters(in: .whitespaces)
        let label = display ?? (fragment.map { "\(target)#\($0)" } ?? target)
        let escapedTarget = encodeForURL(target)
        let urlString: String
        if let fragment {
            urlString = "\(wikiURLScheme)://\(escapedTarget)#\(encodeForURL(fragment))"
        } else {
            urlString = "\(wikiURLScheme)://\(escapedTarget)"
        }
        return "[\(escapeMarkdown(label))](\(urlString))"
    }

    // MARK: - Embeds

    private static let embedPattern = #"!\[\[([^\]]+)\]\]"#

    static func rewriteEmbeds(_ body: String, vaultPath: String) -> String {
        guard let regex = try? NSRegularExpression(pattern: embedPattern) else {
            return body
        }
        let nsBody = body as NSString
        let fullRange = NSRange(location: 0, length: nsBody.length)
        var result = ""
        var cursor = 0

        regex.enumerateMatches(in: body, range: fullRange) { match, _, _ in
            guard let match else { return }
            let innerRange = match.range(at: 1)
            let matchStart = match.range.location
            if matchStart > cursor {
                result += nsBody.substring(
                    with: NSRange(location: cursor, length: matchStart - cursor)
                )
            }
            let inner = nsBody.substring(with: innerRange)
            result += renderEmbed(inner, vaultPath: vaultPath)
            cursor = match.range.location + match.range.length
        }
        if cursor < nsBody.length {
            result += nsBody.substring(
                with: NSRange(location: cursor, length: nsBody.length - cursor)
            )
        }
        return result
    }

    private static func renderEmbed(_ inner: String, vaultPath: String) -> String {
        // Embeds use `|` for size hints in Obsidian (e.g. `image.png|200`).
        // We don't honor sizing in Phase A — strip the alias portion.
        var rest = inner
        if let pipeIdx = rest.firstIndex(of: "|") {
            rest = String(rest[..<pipeIdx])
        }
        let target = rest.trimmingCharacters(in: .whitespaces)
        let absolute = (vaultPath as NSString).appendingPathComponent(target)
        guard let encoded = absolute.addingPercentEncoding(
            withAllowedCharacters: .urlPathAllowed
        ) else {
            return "![\(target)](file://\(absolute))"
        }
        return "![\(escapeMarkdown(target))](file://\(encoded))"
    }

    // MARK: - Helpers

    private static func encodeForURL(_ value: String) -> String {
        value.addingPercentEncoding(withAllowedCharacters: .urlPathAllowed) ?? value
    }

    /// Markdown link/alt text escape. Brackets and parens would otherwise
    /// confuse the parser when a wikilink display contains them.
    private static func escapeMarkdown(_ value: String) -> String {
        var s = value
        for ch in ["\\", "[", "]", "(", ")"] {
            s = s.replacingOccurrences(of: ch, with: "\\\(ch)")
        }
        return s
    }
}
