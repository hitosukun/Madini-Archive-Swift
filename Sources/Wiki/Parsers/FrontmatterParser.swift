import Foundation

/// Splits an Obsidian markdown document into its YAML frontmatter (encoded
/// as JSON) and its body. No external YAML dependency — handles the subset
/// Obsidian's properties feature actually emits: scalar key-values, inline
/// lists (`tags: [a, b]`), and block lists (`-` items on the following lines).
///
/// Returns `(nil, original)` if there is no frontmatter or it is malformed.
/// We deliberately do not throw on parse errors: a partially-recognised
/// frontmatter would leak Obsidian-internal syntax into the page body, so
/// the parser falls back to "no frontmatter" rather than half-parsing.
enum FrontmatterParser {
    /// Result of splitting markdown.
    struct Split: Hashable {
        let frontmatterJSON: String?
        let body: String
    }

    static func split(_ markdown: String) -> Split {
        guard markdown.hasPrefix("---\n") || markdown.hasPrefix("---\r\n") else {
            return Split(frontmatterJSON: nil, body: markdown)
        }

        let lines = markdown.components(separatedBy: "\n")
        var endIndex: Int?
        for i in 1..<lines.count {
            let trimmed = lines[i].trimmingCharacters(in: .whitespaces)
            if trimmed == "---" {
                endIndex = i
                break
            }
        }
        guard let end = endIndex else {
            return Split(frontmatterJSON: nil, body: markdown)
        }

        let yamlLines = Array(lines[1..<end])
        let bodyLines = end + 1 < lines.count ? Array(lines[(end + 1)...]) : []
        let body = bodyLines.joined(separator: "\n")

        guard let parsed = parseYAML(lines: yamlLines),
              let data = try? JSONSerialization.data(
                  withJSONObject: parsed, options: [.sortedKeys]
              ),
              let jsonString = String(data: data, encoding: .utf8)
        else {
            return Split(frontmatterJSON: nil, body: body)
        }
        return Split(frontmatterJSON: jsonString, body: body)
    }

    // MARK: - YAML subset parser

    private static func parseYAML(lines: [String]) -> [String: Any]? {
        var result: [String: Any] = [:]
        var i = 0
        while i < lines.count {
            let line = lines[i]
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty || trimmed.hasPrefix("#") {
                i += 1
                continue
            }
            guard let colonIdx = trimmed.firstIndex(of: ":") else {
                i += 1
                continue
            }
            let key = String(trimmed[..<colonIdx])
                .trimmingCharacters(in: .whitespaces)
            let valueRaw = String(trimmed[trimmed.index(after: colonIdx)...])
                .trimmingCharacters(in: .whitespaces)

            if valueRaw.isEmpty {
                // Look for a block list (`- item` lines) on subsequent lines.
                var listItems: [Any] = []
                var j = i + 1
                while j < lines.count {
                    let nextTrimmed = lines[j].trimmingCharacters(in: .whitespaces)
                    if nextTrimmed.hasPrefix("- ") {
                        let item = String(nextTrimmed.dropFirst(2))
                            .trimmingCharacters(in: .whitespaces)
                        listItems.append(parseScalar(item))
                        j += 1
                    } else if nextTrimmed == "-" {
                        listItems.append(NSNull())
                        j += 1
                    } else if nextTrimmed.isEmpty {
                        j += 1
                    } else {
                        break
                    }
                }
                if !listItems.isEmpty {
                    result[key] = listItems
                    i = j
                } else {
                    result[key] = NSNull()
                    i += 1
                }
            } else if valueRaw.hasPrefix("[") && valueRaw.hasSuffix("]") {
                let inner = String(valueRaw.dropFirst().dropLast())
                let items = inner.split(separator: ",").map {
                    parseScalar(String($0).trimmingCharacters(in: .whitespaces))
                }
                result[key] = items
                i += 1
            } else {
                result[key] = parseScalar(valueRaw)
                i += 1
            }
        }
        return result
    }

    private static func parseScalar(_ value: String) -> Any {
        if value.count >= 2,
           (value.hasPrefix("\"") && value.hasSuffix("\"")) ||
            (value.hasPrefix("'") && value.hasSuffix("'")) {
            return String(value.dropFirst().dropLast())
        }
        if value == "true" { return true }
        if value == "false" { return false }
        if value == "null" || value == "~" || value.isEmpty { return NSNull() }
        if let int = Int(value) { return int }
        if let double = Double(value) { return double }
        return value
    }
}
