// TEMPORARY — Phase 2 benchmark only. Delete after the report is final.
// Verbatim copy of ContentBlock + Parser from
// Sources/Views/Shared/MessageBubbleView.swift (lines 1777-2494).
// Comments are preserved so anyone re-reading this file can see it
// is a literal copy, not a re-implementation.

import Foundation

enum TableAlignment {
    case leading
    case center
    case trailing
}

enum ContentBlock {
    case paragraph(String)
    case heading(level: Int, text: String)
    case listItem(ordered: Bool, depth: Int, text: String, marker: String)
    case blockquote(String)
    case code(language: String?, code: String)
    case math(String)
    case table(headers: [String], rows: [[String]], alignments: [TableAlignment])
    case horizontalRule
    case image(url: String, alt: String)

    static func parse(_ content: String) -> [ContentBlock] {
        var parser = Parser()
        for line in content.components(separatedBy: "\n") {
            parser.feed(line)
        }
        parser.finish()
        return parser.blocks
    }

    private struct Parser {
        var blocks: [ContentBlock] = []
        private var paragraphLines: [String] = []
        private var codeLines: [String] = []
        private var codeLanguage: String?
        private var codeFenceChar: Character = "`"
        private var codeFenceIndent: Int = 0
        private var mathLines: [String] = []
        private var blockquoteLines: [String] = []
        private var pendingTableLines: [String] = []
        private enum Mode { case text, code, math, indentedCode }
        private var mode: Mode = .text
        private var indentedCodeLines: [String] = []

        mutating func feed(_ line: String) {
            switch mode {
            case .code:
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if Self.isClosingFence(trimmed, fenceChar: codeFenceChar) {
                    blocks.append(.code(
                        language: codeLanguage,
                        code: codeLines.joined(separator: "\n")
                    ))
                    codeLines.removeAll()
                    codeLanguage = nil
                    codeFenceIndent = 0
                    mode = .text
                } else {
                    codeLines.append(Self.stripLeadingSpaces(line, upTo: codeFenceIndent))
                }

            case .indentedCode:
                if line.trimmingCharacters(in: .whitespaces).isEmpty {
                    indentedCodeLines.append("")
                } else if line.hasPrefix("    ") || line.hasPrefix("\t") {
                    let stripped = line.hasPrefix("\t")
                        ? String(line.dropFirst())
                        : String(line.dropFirst(4))
                    indentedCodeLines.append(stripped)
                } else {
                    flushIndentedCode()
                    mode = .text
                    feed(line)
                }

            case .math:
                if line.trimmingCharacters(in: .whitespaces) == "$$"
                    || line.trimmingCharacters(in: .whitespaces) == "\\]" {
                    blocks.append(.math(mathLines.joined(separator: "\n")))
                    mathLines.removeAll()
                    mode = .text
                } else {
                    mathLines.append(line)
                }

            case .text:
                let trimmed = line.trimmingCharacters(in: .whitespaces)

                if let fence = Self.parseFenceOpen(trimmed) {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    codeLanguage = fence.language
                    codeFenceChar = fence.character
                    codeFenceIndent = Self.leadingSpaceCount(line)
                    mode = .code
                    return
                }

                if trimmed == "$$" || trimmed == "\\[" {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    mode = .math
                    return
                }

                if trimmed.hasPrefix("$$") && trimmed.hasSuffix("$$") && trimmed.count >= 4 {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    let inner = String(trimmed.dropFirst(2).dropLast(2))
                        .trimmingCharacters(in: .whitespaces)
                    blocks.append(.math(inner))
                    return
                }

                if Self.isHorizontalRule(trimmed) {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    blocks.append(.horizontalRule)
                    return
                }

                if let image = Self.parseStandaloneImage(trimmed) {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    blocks.append(.image(url: image.url, alt: image.alt))
                    return
                }

                if let heading = Self.parseHeading(trimmed) {
                    flushParagraph()
                    flushBlockquote()
                    flushPendingTable()
                    blocks.append(.heading(level: heading.level, text: heading.text))
                    return
                }

                if trimmed.hasPrefix(">") {
                    flushParagraph()
                    flushPendingTable()
                    let body = trimmed.drop(while: { $0 == ">" || $0 == " " })
                    blockquoteLines.append(String(body))
                    return
                } else {
                    flushBlockquote()
                }

                if Self.looksLikeTableRow(trimmed) {
                    if pendingTableLines.count == 1,
                       let alignments = Self.parseTableSeparator(trimmed) {
                        let header = pendingTableLines[0]
                        pendingTableLines.removeAll()
                        commitTableStart(header: header, alignments: alignments)
                        return
                    }
                    if !tableHeader.isEmpty {
                        tableRows.append(Self.splitTableRow(trimmed))
                        return
                    }
                    pendingTableLines.append(trimmed)
                    return
                } else if !tableHeader.isEmpty {
                    flushTable()
                } else if !pendingTableLines.isEmpty {
                    paragraphLines.append(contentsOf: pendingTableLines)
                    pendingTableLines.removeAll()
                }

                if let listItem = Self.parseListItem(rawLine: line) {
                    flushParagraph()
                    blocks.append(listItem)
                    return
                }

                if paragraphLines.isEmpty,
                   blockquoteLines.isEmpty,
                   (line.hasPrefix("    ") || line.hasPrefix("\t")) {
                    let stripped = line.hasPrefix("\t")
                        ? String(line.dropFirst())
                        : String(line.dropFirst(4))
                    indentedCodeLines.append(stripped)
                    mode = .indentedCode
                    return
                }

                if trimmed.isEmpty {
                    flushParagraph()
                    return
                }

                paragraphLines.append(line)
            }
        }

        mutating func finish() {
            switch mode {
            case .code:
                blocks.append(.code(language: codeLanguage, code: codeLines.joined(separator: "\n")))
                codeLines.removeAll()
                codeLanguage = nil
            case .indentedCode:
                flushIndentedCode()
            case .math:
                blocks.append(.math(mathLines.joined(separator: "\n")))
                mathLines.removeAll()
            case .text:
                break
            }
            flushBlockquote()
            if !tableHeader.isEmpty {
                flushTable()
            } else if !pendingTableLines.isEmpty {
                paragraphLines.append(contentsOf: pendingTableLines)
                pendingTableLines.removeAll()
            }
            flushParagraph()
            mode = .text
        }

        private var tableHeader: [String] = []
        private var tableAlignments: [TableAlignment] = []
        private var tableRows: [[String]] = []

        private mutating func commitTableStart(header: String, alignments: [TableAlignment]) {
            tableHeader = Self.splitTableRow(header)
            tableAlignments = alignments
            tableRows = []
        }

        private mutating func flushTable() {
            guard !tableHeader.isEmpty else {
                tableHeader = []
                tableAlignments = []
                tableRows = []
                return
            }
            let columnCount = tableHeader.count
            let paddedRows = tableRows.map { row -> [String] in
                if row.count >= columnCount {
                    return Array(row.prefix(columnCount))
                }
                return row + Array(repeating: "", count: columnCount - row.count)
            }
            let paddedAlignments: [TableAlignment] = {
                if tableAlignments.count >= columnCount {
                    return Array(tableAlignments.prefix(columnCount))
                }
                return tableAlignments + Array(
                    repeating: TableAlignment.leading,
                    count: columnCount - tableAlignments.count
                )
            }()
            blocks.append(.table(
                headers: tableHeader,
                rows: paddedRows,
                alignments: paddedAlignments
            ))
            tableHeader = []
            tableAlignments = []
            tableRows = []
        }

        private mutating func flushPendingTable() {
            if !tableRows.isEmpty || !tableHeader.isEmpty {
                flushTable()
            } else if !pendingTableLines.isEmpty {
                paragraphLines.append(contentsOf: pendingTableLines)
                pendingTableLines.removeAll()
            }
        }

        private mutating func flushBlockquote() {
            guard !blockquoteLines.isEmpty else { return }
            blocks.append(.blockquote(blockquoteLines.joined(separator: "\n")))
            blockquoteLines.removeAll()
        }

        private mutating func flushIndentedCode() {
            while indentedCodeLines.last?.isEmpty == true {
                indentedCodeLines.removeLast()
            }
            let body = indentedCodeLines.joined(separator: "\n")
            if !body.isEmpty {
                blocks.append(.code(language: nil, code: body))
            }
            indentedCodeLines.removeAll()
        }

        private mutating func flushParagraph() {
            let joined = paragraphLines
                .joined(separator: "\n")
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if !joined.isEmpty {
                blocks.append(.paragraph(joined))
            }
            paragraphLines.removeAll()
        }

        private static func isHorizontalRule(_ trimmed: String) -> Bool {
            guard trimmed.count >= 3 else { return false }
            let stripped = trimmed.filter { !$0.isWhitespace }
            guard let first = stripped.first, "-*_".contains(first) else { return false }
            return stripped.allSatisfy { $0 == first } && stripped.count >= 3
        }

        private static func parseStandaloneImage(_ trimmed: String) -> (url: String, alt: String)? {
            guard trimmed.hasPrefix("![") else { return nil }
            guard trimmed.hasSuffix(")") else { return nil }
            let chars = Array(trimmed)
            var i = 2
            var altChars: [Character] = []
            while i < chars.count, chars[i] != "]" {
                if chars[i] == "[" { return nil }
                altChars.append(chars[i])
                i += 1
            }
            guard i < chars.count, chars[i] == "]" else { return nil }
            i += 1
            guard i < chars.count, chars[i] == "(" else { return nil }
            i += 1
            var urlChars: [Character] = []
            var parenDepth = 1
            while i < chars.count {
                let c = chars[i]
                if c == "(" {
                    parenDepth += 1
                    urlChars.append(c)
                } else if c == ")" {
                    parenDepth -= 1
                    if parenDepth == 0 {
                        i += 1
                        break
                    }
                    urlChars.append(c)
                } else {
                    urlChars.append(c)
                }
                i += 1
            }
            guard i == chars.count, parenDepth == 0 else { return nil }
            var body = String(urlChars).trimmingCharacters(in: .whitespaces)
            if let lastSpace = body.lastIndex(of: " ") {
                let tail = body[body.index(after: lastSpace)...]
                    .trimmingCharacters(in: .whitespaces)
                if (tail.hasPrefix("\"") && tail.hasSuffix("\"") && tail.count >= 2)
                    || (tail.hasPrefix("'") && tail.hasSuffix("'") && tail.count >= 2) {
                    body = String(body[..<lastSpace]).trimmingCharacters(in: .whitespaces)
                }
            }
            if body.hasPrefix("<") && body.hasSuffix(">") && body.count >= 2 {
                body = String(body.dropFirst().dropLast())
            }
            guard !body.isEmpty else { return nil }
            return (url: body, alt: String(altChars))
        }

        private static func parseHeading(_ trimmed: String) -> (level: Int, text: String)? {
            var hashCount = 0
            for ch in trimmed {
                if ch == "#" { hashCount += 1 } else { break }
                if hashCount > 6 { return nil }
            }
            guard (1...6).contains(hashCount) else { return nil }
            let afterHashes = trimmed.index(trimmed.startIndex, offsetBy: hashCount)
            guard afterHashes < trimmed.endIndex,
                  trimmed[afterHashes] == " " else { return nil }
            let body = trimmed[trimmed.index(after: afterHashes)...]
                .trimmingCharacters(in: .whitespaces)
            return (hashCount, body)
        }

        private static func parseListItem(rawLine: String) -> ContentBlock? {
            var leadingSpaces = 0
            for ch in rawLine {
                if ch == " " { leadingSpaces += 1 } else { break }
            }
            let stripped = rawLine.dropFirst(leadingSpaces)
            if let first = stripped.first, "-*+".contains(first),
               stripped.dropFirst().first == " " {
                let body = stripped.dropFirst(2).trimmingCharacters(in: .whitespaces)
                return .listItem(
                    ordered: false,
                    depth: leadingSpaces / 2,
                    text: String(body),
                    marker: "•"
                )
            }
            var digitCount = 0
            for ch in stripped {
                if ch.isNumber { digitCount += 1 } else { break }
            }
            guard digitCount > 0 else { return nil }
            let afterDigits = stripped.index(stripped.startIndex, offsetBy: digitCount)
            guard afterDigits < stripped.endIndex,
                  stripped[afterDigits] == ".",
                  stripped.index(after: afterDigits) < stripped.endIndex,
                  stripped[stripped.index(after: afterDigits)] == " " else { return nil }
            let number = String(stripped.prefix(digitCount))
            let body = stripped[stripped.index(afterDigits, offsetBy: 2)...]
                .trimmingCharacters(in: .whitespaces)
            return .listItem(
                ordered: true,
                depth: leadingSpaces / 2,
                text: String(body),
                marker: "\(number)."
            )
        }

        private static func parseFenceOpen(_ trimmed: String) -> (character: Character, language: String?)? {
            guard let first = trimmed.first, first == "`" || first == "~" else { return nil }
            var runLength = 0
            for ch in trimmed {
                if ch == first { runLength += 1 } else { break }
            }
            guard runLength >= 3 else { return nil }
            let afterFence = trimmed.dropFirst(runLength).trimmingCharacters(in: .whitespaces)
            if first == "`" && afterFence.contains("`") { return nil }
            return (first, afterFence.isEmpty ? nil : String(afterFence))
        }

        private static func isClosingFence(_ trimmed: String, fenceChar: Character) -> Bool {
            guard trimmed.count >= 3 else { return false }
            return trimmed.allSatisfy { $0 == fenceChar }
        }

        private static func leadingSpaceCount(_ line: String) -> Int {
            var n = 0
            for ch in line {
                if ch == " " { n += 1 } else { break }
            }
            return n
        }

        private static func stripLeadingSpaces(_ line: String, upTo: Int) -> String {
            guard upTo > 0 else { return line }
            var remaining = upTo
            var index = line.startIndex
            while index < line.endIndex, remaining > 0, line[index] == " " {
                index = line.index(after: index)
                remaining -= 1
            }
            return String(line[index...])
        }

        private static func looksLikeTableRow(_ trimmed: String) -> Bool {
            guard trimmed.hasPrefix("|"), trimmed.hasSuffix("|"), trimmed.count >= 3 else {
                return false
            }
            let inner = String(trimmed.dropFirst().dropLast())
            return inner.contains("|")
        }

        private static func parseTableSeparator(_ trimmed: String) -> [TableAlignment]? {
            let cells = splitTableRow(trimmed)
            guard !cells.isEmpty else { return nil }
            var alignments: [TableAlignment] = []
            for cell in cells {
                let c = cell.trimmingCharacters(in: .whitespaces)
                guard c.count >= 3 else { return nil }
                let hasLeadingColon = c.hasPrefix(":")
                let hasTrailingColon = c.hasSuffix(":")
                let dashBody = c.drop(while: { $0 == ":" })
                    .reversed().drop(while: { $0 == ":" }).reversed()
                guard !dashBody.isEmpty, dashBody.allSatisfy({ $0 == "-" }) else {
                    return nil
                }
                switch (hasLeadingColon, hasTrailingColon) {
                case (true, true): alignments.append(.center)
                case (false, true): alignments.append(.trailing)
                case (true, false): alignments.append(.leading)
                case (false, false): alignments.append(.leading)
                }
            }
            return alignments
        }

        private static func splitTableRow(_ trimmed: String) -> [String] {
            var line = trimmed
            if line.hasPrefix("|") { line.removeFirst() }
            if line.hasSuffix("|") { line.removeLast() }
            return line.split(separator: "|", omittingEmptySubsequences: false).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
        }
    }
}
