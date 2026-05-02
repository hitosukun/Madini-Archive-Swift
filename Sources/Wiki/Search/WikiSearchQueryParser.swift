import Foundation

/// Splits a wiki search query into frontmatter filters and free-text
/// FTS terms.
///
/// Grammar (deliberately small):
///   - `key:value` — frontmatter filter. Matches when the page's
///     frontmatter dictionary has a string at `key` equal to `value`,
///     case-insensitive. Multiple `key:value` clauses AND together.
///   - everything else — concatenated as the FTS5 query passed to
///     `wiki_pages_fts`. Quoted phrases ("foo bar") preserve spaces.
///
/// Examples:
///   `type:chr 錫花`        → filter type=chr, FTS = `錫花`
///   `type:chr status:wip`  → filter type=chr AND status=wip, FTS = (none)
///   `"hello world"`        → FTS = `"hello world"`
///   `錫花`                 → FTS = `錫花`
///
/// Out of scope (Phase A): NOT, OR, list-valued filters, regex.
enum WikiSearchQueryParser {
    struct Parsed: Hashable, Sendable {
        let frontmatterFilters: [(key: String, value: String)]
        let ftsQuery: String

        static func == (lhs: Parsed, rhs: Parsed) -> Bool {
            lhs.ftsQuery == rhs.ftsQuery &&
            lhs.frontmatterFilters.elementsEqual(
                rhs.frontmatterFilters,
                by: { $0.key == $1.key && $0.value == $1.value }
            )
        }

        func hash(into hasher: inout Hasher) {
            hasher.combine(ftsQuery)
            for f in frontmatterFilters {
                hasher.combine(f.key)
                hasher.combine(f.value)
            }
        }

        var hasFTS: Bool { !ftsQuery.isEmpty }
        var hasFilters: Bool { !frontmatterFilters.isEmpty }
        var isEmpty: Bool { !hasFTS && !hasFilters }
    }

    static func parse(_ raw: String) -> Parsed {
        var filters: [(String, String)] = []
        var ftsTokens: [String] = []

        let tokens = tokenize(raw)
        for token in tokens {
            if let colonIndex = token.firstIndex(of: ":"),
               token.startIndex != colonIndex,
               token.index(after: colonIndex) != token.endIndex,
               // Disallow tokens that start with a quote — the colon
               // there is part of the phrase, not a filter separator.
               !token.hasPrefix("\"") && !token.hasPrefix("'") {
                let key = String(token[..<colonIndex])
                    .trimmingCharacters(in: .whitespaces)
                let value = String(token[token.index(after: colonIndex)...])
                    .trimmingCharacters(in: .whitespaces)
                if !key.isEmpty && !value.isEmpty {
                    filters.append((key.lowercased(), unquote(value)))
                    continue
                }
            }
            ftsTokens.append(unquote(token))
        }

        let ftsQuery = ftsTokens
            .filter { !$0.isEmpty }
            .joined(separator: " ")
        return Parsed(
            frontmatterFilters: filters,
            ftsQuery: ftsQuery
        )
    }

    /// Decide whether a given page row passes the parsed query's
    /// frontmatter filters. Pages without frontmatter or with the
    /// requested key absent fail the filter.
    static func passesFilters(
        _ page: WikiPage, filters: [(key: String, value: String)]
    ) -> Bool {
        guard !filters.isEmpty else { return true }
        guard let json = page.frontmatterJSON,
              let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data)
                as? [String: Any]
        else { return false }

        for (key, expected) in filters {
            // Frontmatter keys are case-sensitive in YAML; treat them
            // case-insensitively for search ergonomics.
            let lookup = dict.first { $0.key.lowercased() == key }?.value
            if !valueMatches(lookup, expected: expected) {
                return false
            }
        }
        return true
    }

    // MARK: - Private

    /// Splits the raw query on whitespace, but keeps text inside
    /// matching `"..."` or `'...'` together.
    private static func tokenize(_ raw: String) -> [String] {
        var tokens: [String] = []
        var current = ""
        var quote: Character? = nil
        for ch in raw {
            if let q = quote {
                current.append(ch)
                if ch == q { quote = nil }
            } else if ch == "\"" || ch == "'" {
                current.append(ch)
                quote = ch
            } else if ch.isWhitespace {
                if !current.isEmpty {
                    tokens.append(current)
                    current = ""
                }
            } else {
                current.append(ch)
            }
        }
        if !current.isEmpty {
            tokens.append(current)
        }
        return tokens
    }

    private static func unquote(_ token: String) -> String {
        if token.count >= 2,
           (token.hasPrefix("\"") && token.hasSuffix("\"")) ||
            (token.hasPrefix("'") && token.hasSuffix("'")) {
            return String(token.dropFirst().dropLast())
        }
        return token
    }

    private static func valueMatches(_ value: Any?, expected: String) -> Bool {
        let lowered = expected.lowercased()
        switch value {
        case let s as String:
            return s.lowercased() == lowered
        case let n as NSNumber:
            return n.stringValue.lowercased() == lowered
        case let arr as [Any]:
            return arr.contains { valueMatches($0, expected: expected) }
        default:
            return false
        }
    }
}
