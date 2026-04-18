import SwiftUI

/// Lightweight syntax highlighter for fenced code blocks.
///
/// **Why hand-rolled instead of pulling in a library.** Highlightr
/// (highlight.js via JavaScriptCore), Sourceful, etc. all bring in a
/// large dependency for the same handful of languages we actually see
/// in the archive (Swift, Python, JS/TS, Go, Rust, C/C++, JSON, bash,
/// SQL, Ruby, HTML, CSS). A few hundred lines of regex-free token
/// scanning keep `Package.swift` clean and the binary small.
///
/// **Scope and intentional limitations.** This is a single-pass
/// character-stream tokenizer — strings and comments are recognized
/// first (so `// not a keyword` doesn't get keyword-colored), then
/// word boundaries pick out keywords from a per-language set. We do
/// NOT attempt to disambiguate based on grammar (e.g. distinguishing
/// `class` the keyword from `class:` a JSON key in a Python dict
/// literal — it'll color both the same). The visual benefit is
/// "obvious at a glance: this is code in language X" rather than
/// "perfect IDE-grade highlighting." For unknown languages the
/// highlighter returns the source as plain `AttributedString` with
/// no color attributes, so the renderer always has something
/// usable to display.
///
/// Colors are picked from SwiftUI semantic palettes (`.purple`,
/// `.green`, etc) so they respond to light/dark mode automatically
/// without us threading a `colorScheme` environment value down here.
enum SyntaxHighlighter {

    // MARK: - Public entry point

    /// Tokenize `code` according to `language` (case-insensitive,
    /// matched against `languageDefinitions` plus a small set of
    /// aliases — `js` → `javascript`, `ts` → `typescript`, etc.).
    /// Returns an `AttributedString` ready to drop into a
    /// SwiftUI `Text(_:)`.
    ///
    /// `fontSize` lets the caller match whatever monospaced size their
    /// surrounding view is using (the message body's `bodyFontSize` in
    /// practice). When `nil` we fall back to `.system(.body)` so the
    /// AttributedString stays usable in test contexts that don't
    /// thread a size through.
    static func highlight(_ code: String, language: String?, fontSize: CGFloat? = nil) -> AttributedString {
        var attributed = AttributedString(code)
        // Set monospaced font on the entire string up front. The
        // caller could do this themselves, but baking it in here
        // means every consumer gets uniform font metrics — important
        // because the per-token color attributes we apply below are
        // additive on top of a single base font. Applying `.font()`
        // as a SwiftUI modifier on `Text(AttributedString)` would
        // override what we set here, so callers should NOT also
        // attach `.font(...)` to the Text — pass the size in here.
        if let fontSize {
            attributed.font = .system(size: fontSize, design: .monospaced)
        } else {
            attributed.font = .system(.body, design: .monospaced)
        }

        guard let definition = definition(for: language) else {
            return attributed
        }

        let tokens = Tokenizer(source: code, definition: definition).tokenize()
        for token in tokens {
            guard let color = token.kind.color else { continue }
            // AttributedString uses its own AttributedString.Index
            // domain — translate from the String.Index range we
            // captured during tokenization.
            let lower = AttributedString.Index(token.range.lowerBound, within: attributed)
            let upper = AttributedString.Index(token.range.upperBound, within: attributed)
            if let lower, let upper {
                attributed[lower..<upper].foregroundColor = color
            }
        }

        return attributed
    }

    // MARK: - Language resolution

    /// Map `language` (after lower-casing and alias resolution) to a
    /// `LanguageDefinition`. Returns `nil` for unknown / unset
    /// languages so the caller falls back to plain text.
    private static func definition(for language: String?) -> LanguageDefinition? {
        guard let raw = language?.lowercased(), !raw.isEmpty else { return nil }
        let canonical = aliases[raw] ?? raw
        return languageDefinitions[canonical]
    }

    private static let aliases: [String: String] = [
        "js": "javascript",
        "jsx": "javascript",
        "ts": "typescript",
        "tsx": "typescript",
        "py": "python",
        "rb": "ruby",
        "sh": "bash",
        "shell": "bash",
        "zsh": "bash",
        "yml": "yaml",
        "objc": "c",
        "objective-c": "c",
        "h": "c",
        "hpp": "cpp",
        "c++": "cpp",
        "cs": "csharp",
        "kt": "kotlin",
    ]
}

// MARK: - Token model

private struct Token {
    let kind: Kind
    let range: Range<String.Index>

    enum Kind {
        case keyword
        case type
        case string
        case comment
        case number

        /// `nil` means "leave default" — identifiers, operators, and
        /// whitespace fall through to the AttributedString's base
        /// foreground color (which inherits the surrounding text
        /// color and so participates correctly in light/dark mode).
        var color: Color? {
            switch self {
            case .keyword: return .purple
            case .type: return .teal
            case .string: return Color(red: 0.78, green: 0.36, blue: 0.27)
            case .comment: return .secondary
            case .number: return .blue
            }
        }
    }
}

// MARK: - Language definitions

private struct LanguageDefinition {
    /// Reserved words colored as keywords.
    let keywords: Set<String>
    /// Built-in / standard-library types colored as types. Optional —
    /// languages without a curated type list (bash, json) leave this
    /// empty and the type pass becomes a no-op.
    let types: Set<String>
    /// Line-comment prefixes, e.g. `["//"]` for C-family or `["#"]`
    /// for Python/bash. Multiple entries supported because some
    /// languages mix them (e.g. PHP allows both `//` and `#`).
    let lineCommentPrefixes: [String]
    /// Optional block-comment delimiters — `("/*", "*/")` for C-style.
    /// `nil` for languages without block comments (Python's `"""..."""`
    /// is treated as a string, not a comment, since that's what it
    /// actually is at the language level).
    let blockComment: (open: String, close: String)?
    /// Single-character string delimiters. `"` is universal; `'` is
    /// added for languages that allow single-quoted strings (Python,
    /// JS, Ruby) and omitted where it'd be a character literal we'd
    /// rather not color (Rust, C — though we still include them; the
    /// occasional miscolored `'a'` is acceptable noise).
    let stringDelimiters: [Character]
}

private let languageDefinitions: [String: LanguageDefinition] = [
    "swift": LanguageDefinition(
        keywords: [
            "associatedtype", "class", "deinit", "enum", "extension", "fileprivate",
            "func", "import", "init", "inout", "internal", "let", "open", "operator",
            "private", "protocol", "public", "rethrows", "static", "struct", "subscript",
            "typealias", "var", "break", "case", "continue", "default", "defer", "do",
            "else", "fallthrough", "for", "guard", "if", "in", "repeat", "return",
            "switch", "where", "while", "as", "Any", "catch", "false", "is", "nil",
            "super", "self", "Self", "throw", "throws", "true", "try", "async", "await",
            "actor", "some", "any", "borrowing", "consuming", "isolated", "mutating",
            "nonmutating", "lazy", "weak", "unowned", "final", "override", "convenience",
            "required", "optional", "indirect", "dynamic", "willSet", "didSet", "set",
            "get", "throws", "@escaping", "@autoclosure", "@discardableResult", "@MainActor"
        ],
        types: [
            "String", "Int", "Double", "Float", "Bool", "Character", "Array",
            "Dictionary", "Set", "Optional", "Result", "Error", "URL", "UUID",
            "Date", "Data", "View", "Text", "Image", "VStack", "HStack", "ZStack",
            "Color", "Font", "Binding", "State", "Environment", "ObservableObject",
            "AttributedString", "CGFloat", "CGSize", "CGPoint", "CGRect"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""]
    ),
    "python": LanguageDefinition(
        keywords: [
            "False", "None", "True", "and", "as", "assert", "async", "await",
            "break", "class", "continue", "def", "del", "elif", "else", "except",
            "finally", "for", "from", "global", "if", "import", "in", "is",
            "lambda", "nonlocal", "not", "or", "pass", "raise", "return", "try",
            "while", "with", "yield", "match", "case", "self", "cls"
        ],
        types: [
            "int", "float", "str", "bool", "list", "dict", "tuple", "set",
            "frozenset", "bytes", "bytearray", "complex", "object", "type",
            "Optional", "Union", "List", "Dict", "Tuple", "Set", "Any", "Callable"
        ],
        lineCommentPrefixes: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"]
    ),
    "javascript": LanguageDefinition(
        keywords: [
            "var", "let", "const", "function", "return", "if", "else", "for",
            "while", "do", "switch", "case", "default", "break", "continue",
            "new", "delete", "typeof", "instanceof", "in", "of", "class",
            "extends", "super", "this", "import", "export", "from", "as",
            "async", "await", "yield", "try", "catch", "finally", "throw",
            "true", "false", "null", "undefined", "void", "static", "get",
            "set", "enum", "interface", "implements", "package", "private",
            "protected", "public"
        ],
        types: [
            "Array", "Object", "String", "Number", "Boolean", "Function",
            "Promise", "Map", "Set", "Symbol", "Date", "RegExp", "Error",
            "JSON", "Math", "console"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'", "`"]
    ),
    "typescript": LanguageDefinition(
        keywords: [
            "var", "let", "const", "function", "return", "if", "else", "for",
            "while", "do", "switch", "case", "default", "break", "continue",
            "new", "delete", "typeof", "instanceof", "in", "of", "class",
            "extends", "super", "this", "import", "export", "from", "as",
            "async", "await", "yield", "try", "catch", "finally", "throw",
            "true", "false", "null", "undefined", "void", "static", "get",
            "set", "enum", "interface", "implements", "type", "namespace",
            "private", "protected", "public", "readonly", "abstract",
            "keyof", "infer", "satisfies", "is", "asserts"
        ],
        types: [
            "string", "number", "boolean", "any", "unknown", "never", "object",
            "Array", "Promise", "Record", "Partial", "Readonly", "Required",
            "Pick", "Omit", "Exclude", "Extract", "ReturnType", "Map", "Set"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'", "`"]
    ),
    "go": LanguageDefinition(
        keywords: [
            "break", "case", "chan", "const", "continue", "default", "defer",
            "else", "fallthrough", "for", "func", "go", "goto", "if", "import",
            "interface", "map", "package", "range", "return", "select", "struct",
            "switch", "type", "var", "true", "false", "nil", "iota"
        ],
        types: [
            "bool", "byte", "complex64", "complex128", "error", "float32",
            "float64", "int", "int8", "int16", "int32", "int64", "rune",
            "string", "uint", "uint8", "uint16", "uint32", "uint64", "uintptr"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "`"]
    ),
    "rust": LanguageDefinition(
        keywords: [
            "as", "break", "const", "continue", "crate", "else", "enum", "extern",
            "false", "fn", "for", "if", "impl", "in", "let", "loop", "match",
            "mod", "move", "mut", "pub", "ref", "return", "self", "Self",
            "static", "struct", "super", "trait", "true", "type", "unsafe",
            "use", "where", "while", "async", "await", "dyn", "abstract"
        ],
        types: [
            "bool", "char", "i8", "i16", "i32", "i64", "i128", "isize",
            "u8", "u16", "u32", "u64", "u128", "usize", "f32", "f64",
            "str", "String", "Vec", "Option", "Result", "Box", "Rc", "Arc",
            "HashMap", "HashSet", "BTreeMap", "BTreeSet"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""]
    ),
    "c": LanguageDefinition(
        keywords: [
            "auto", "break", "case", "char", "const", "continue", "default",
            "do", "double", "else", "enum", "extern", "float", "for", "goto",
            "if", "inline", "int", "long", "register", "restrict", "return",
            "short", "signed", "sizeof", "static", "struct", "switch", "typedef",
            "union", "unsigned", "void", "volatile", "while", "_Bool", "_Complex",
            "_Imaginary", "true", "false", "NULL"
        ],
        types: [
            "size_t", "ptrdiff_t", "FILE", "uint8_t", "uint16_t", "uint32_t",
            "uint64_t", "int8_t", "int16_t", "int32_t", "int64_t"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""]
    ),
    "cpp": LanguageDefinition(
        keywords: [
            "alignas", "alignof", "and", "auto", "bool", "break", "case", "catch",
            "char", "class", "const", "constexpr", "const_cast", "continue",
            "decltype", "default", "delete", "do", "double", "dynamic_cast",
            "else", "enum", "explicit", "export", "extern", "false", "float",
            "for", "friend", "goto", "if", "inline", "int", "long", "mutable",
            "namespace", "new", "noexcept", "not", "nullptr", "operator", "or",
            "private", "protected", "public", "register", "reinterpret_cast",
            "return", "short", "signed", "sizeof", "static", "static_assert",
            "static_cast", "struct", "switch", "template", "this", "thread_local",
            "throw", "true", "try", "typedef", "typeid", "typename", "union",
            "unsigned", "using", "virtual", "void", "volatile", "while", "xor"
        ],
        types: [
            "string", "vector", "map", "set", "unordered_map", "unordered_set",
            "pair", "tuple", "shared_ptr", "unique_ptr", "weak_ptr", "size_t"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""]
    ),
    "json": LanguageDefinition(
        keywords: ["true", "false", "null"],
        types: [],
        lineCommentPrefixes: [],
        blockComment: nil,
        stringDelimiters: ["\""]
    ),
    "bash": LanguageDefinition(
        keywords: [
            "if", "then", "else", "elif", "fi", "case", "esac", "for", "while",
            "until", "do", "done", "in", "function", "return", "break", "continue",
            "exit", "export", "local", "readonly", "declare", "unset", "echo",
            "printf", "read", "shift", "test", "true", "false"
        ],
        types: [],
        lineCommentPrefixes: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"]
    ),
    "sql": LanguageDefinition(
        keywords: [
            "SELECT", "FROM", "WHERE", "INSERT", "INTO", "VALUES", "UPDATE",
            "SET", "DELETE", "CREATE", "TABLE", "DROP", "ALTER", "ADD", "INDEX",
            "JOIN", "LEFT", "RIGHT", "INNER", "OUTER", "FULL", "ON", "AS",
            "AND", "OR", "NOT", "NULL", "IS", "IN", "LIKE", "BETWEEN", "EXISTS",
            "GROUP", "BY", "ORDER", "HAVING", "LIMIT", "OFFSET", "UNION",
            "ALL", "DISTINCT", "COUNT", "SUM", "AVG", "MIN", "MAX",
            "PRIMARY", "KEY", "FOREIGN", "REFERENCES", "CONSTRAINT", "UNIQUE",
            "DEFAULT", "CHECK", "CASCADE", "BEGIN", "COMMIT", "ROLLBACK",
            "TRANSACTION", "WITH", "RECURSIVE", "CASE", "WHEN", "THEN", "END",
            "ELSE", "TRUE", "FALSE",
            "select", "from", "where", "insert", "into", "values", "update",
            "set", "delete", "create", "table", "drop", "alter", "add", "index",
            "join", "left", "right", "inner", "outer", "full", "on", "as",
            "and", "or", "not", "null", "is", "in", "like", "between", "exists",
            "group", "by", "order", "having", "limit", "offset", "union",
            "all", "distinct", "count", "sum", "avg", "min", "max",
            "primary", "key", "foreign", "references", "constraint", "unique",
            "default", "check", "cascade", "begin", "commit", "rollback",
            "transaction", "with", "recursive", "case", "when", "then", "end",
            "else", "true", "false"
        ],
        types: [
            "INTEGER", "TEXT", "VARCHAR", "CHAR", "REAL", "BLOB", "DATE",
            "TIME", "TIMESTAMP", "BOOLEAN", "NUMERIC", "DECIMAL", "FLOAT",
            "DOUBLE", "BIGINT", "SMALLINT",
            "integer", "text", "varchar", "char", "real", "blob", "date",
            "time", "timestamp", "boolean", "numeric", "decimal", "float",
            "double", "bigint", "smallint"
        ],
        lineCommentPrefixes: ["--"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["'", "\""]
    ),
    "ruby": LanguageDefinition(
        keywords: [
            "BEGIN", "END", "alias", "and", "begin", "break", "case", "class",
            "def", "defined?", "do", "else", "elsif", "end", "ensure", "false",
            "for", "if", "in", "module", "next", "nil", "not", "or", "redo",
            "rescue", "retry", "return", "self", "super", "then", "true",
            "undef", "unless", "until", "when", "while", "yield", "require",
            "include", "extend", "attr_accessor", "attr_reader", "attr_writer"
        ],
        types: [],
        lineCommentPrefixes: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"]
    ),
    "html": LanguageDefinition(
        keywords: [],
        types: [],
        lineCommentPrefixes: [],
        blockComment: ("<!--", "-->"),
        stringDelimiters: ["\"", "'"]
    ),
    "css": LanguageDefinition(
        keywords: [
            "important", "inherit", "initial", "unset", "auto", "none",
            "block", "inline", "flex", "grid", "absolute", "relative",
            "fixed", "static", "sticky"
        ],
        types: [],
        lineCommentPrefixes: [],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\"", "'"]
    ),
    "yaml": LanguageDefinition(
        keywords: ["true", "false", "null", "yes", "no", "on", "off"],
        types: [],
        lineCommentPrefixes: ["#"],
        blockComment: nil,
        stringDelimiters: ["\"", "'"]
    ),
    "kotlin": LanguageDefinition(
        keywords: [
            "as", "break", "class", "continue", "do", "else", "false", "for",
            "fun", "if", "in", "interface", "is", "null", "object", "package",
            "return", "super", "this", "throw", "true", "try", "typealias",
            "typeof", "val", "var", "when", "while", "by", "catch", "constructor",
            "delegate", "dynamic", "field", "file", "finally", "get", "import",
            "init", "param", "property", "receiver", "set", "setparam", "value",
            "where", "abstract", "actual", "annotation", "companion", "const",
            "crossinline", "data", "enum", "expect", "external", "final", "infix",
            "inline", "inner", "internal", "lateinit", "noinline", "open",
            "operator", "out", "override", "private", "protected", "public",
            "reified", "sealed", "suspend", "tailrec", "vararg"
        ],
        types: [
            "Int", "Long", "Short", "Byte", "Float", "Double", "Boolean",
            "Char", "String", "Array", "List", "Map", "Set", "Pair", "Triple",
            "Any", "Unit", "Nothing"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""]
    ),
    "csharp": LanguageDefinition(
        keywords: [
            "abstract", "as", "base", "bool", "break", "byte", "case", "catch",
            "char", "checked", "class", "const", "continue", "decimal", "default",
            "delegate", "do", "double", "else", "enum", "event", "explicit",
            "extern", "false", "finally", "fixed", "float", "for", "foreach",
            "goto", "if", "implicit", "in", "int", "interface", "internal", "is",
            "lock", "long", "namespace", "new", "null", "object", "operator",
            "out", "override", "params", "private", "protected", "public",
            "readonly", "ref", "return", "sbyte", "sealed", "short", "sizeof",
            "stackalloc", "static", "string", "struct", "switch", "this", "throw",
            "true", "try", "typeof", "uint", "ulong", "unchecked", "unsafe",
            "ushort", "using", "virtual", "void", "volatile", "while", "async",
            "await", "var", "dynamic", "yield", "nameof", "when", "global"
        ],
        types: [
            "Object", "String", "Int32", "Int64", "Boolean", "List", "Dictionary",
            "IEnumerable", "Task", "Func", "Action", "Nullable"
        ],
        lineCommentPrefixes: ["//"],
        blockComment: ("/*", "*/"),
        stringDelimiters: ["\""]
    ),
]

// MARK: - Tokenizer

/// Single-pass character-stream tokenizer. Walks `source` index by
/// index, branching on the character under the cursor:
///   1. A line- or block-comment opener → consume to the line end /
///      close marker, emit `.comment`.
///   2. A string delimiter → consume to the matching delimiter
///      (respecting backslash escapes), emit `.string`.
///   3. A digit → consume the number literal, emit `.number`.
///   4. A letter / underscore → consume the word, classify against
///      the language's `keywords` / `types` sets, emit `.keyword` /
///      `.type` or skip if neither matches.
///   5. Anything else (punctuation, operators, whitespace) → step
///      forward without emitting.
///
/// The output is a flat `[Token]` keyed by source range. The renderer
/// applies these as foreground-color attributes to an
/// `AttributedString` built from the same source — so token order
/// matches source order and there's no need to rebuild the string.
private struct Tokenizer {
    let source: String
    let definition: LanguageDefinition

    func tokenize() -> [Token] {
        var tokens: [Token] = []
        var index = source.startIndex

        while index < source.endIndex {
            let char = source[index]

            // 1. Comments
            if let token = matchLineComment(at: index) {
                tokens.append(token)
                index = token.range.upperBound
                continue
            }
            if let token = matchBlockComment(at: index) {
                tokens.append(token)
                index = token.range.upperBound
                continue
            }

            // 2. Strings
            if definition.stringDelimiters.contains(char),
               let token = matchString(at: index, delimiter: char) {
                tokens.append(token)
                index = token.range.upperBound
                continue
            }

            // 3. Numbers
            if char.isNumber,
               let token = matchNumber(at: index) {
                tokens.append(token)
                index = token.range.upperBound
                continue
            }

            // 4. Identifiers / keywords / types
            if char.isLetter || char == "_" || char == "@" || char == "#",
               let (token, word) = matchWord(at: index) {
                if definition.keywords.contains(word) {
                    tokens.append(Token(kind: .keyword, range: token.range))
                } else if definition.types.contains(word) {
                    tokens.append(Token(kind: .type, range: token.range))
                }
                index = token.range.upperBound
                continue
            }

            // 5. Default — advance one character.
            index = source.index(after: index)
        }

        return tokens
    }

    // MARK: - Sub-matchers

    /// Matches at-cursor against any of the language's line-comment
    /// prefixes (e.g. `//`, `#`, `--`). Consumes through end of line.
    private func matchLineComment(at index: String.Index) -> Token? {
        for prefix in definition.lineCommentPrefixes {
            if matches(prefix: prefix, at: index) {
                let end = endOfLine(from: index)
                return Token(kind: .comment, range: index..<end)
            }
        }
        return nil
    }

    /// Matches at-cursor against the language's block-comment open
    /// delimiter and consumes through the close delimiter (or to end
    /// of source if unterminated, which is rare but possible mid-edit).
    private func matchBlockComment(at index: String.Index) -> Token? {
        guard let block = definition.blockComment,
              matches(prefix: block.open, at: index) else {
            return nil
        }
        let afterOpen = source.index(index, offsetBy: block.open.count, limitedBy: source.endIndex)
            ?? source.endIndex
        var cursor = afterOpen
        while cursor < source.endIndex {
            if matches(prefix: block.close, at: cursor) {
                let end = source.index(cursor, offsetBy: block.close.count, limitedBy: source.endIndex)
                    ?? source.endIndex
                return Token(kind: .comment, range: index..<end)
            }
            cursor = source.index(after: cursor)
        }
        // Unterminated — color the rest of the source as comment.
        return Token(kind: .comment, range: index..<source.endIndex)
    }

    /// Consumes a string literal starting at `index` whose opening
    /// (and closing) delimiter is `delimiter`. Honors `\` escapes so
    /// `"a\"b"` doesn't terminate at the middle quote.
    private func matchString(at index: String.Index, delimiter: Character) -> Token? {
        let afterOpen = source.index(after: index)
        var cursor = afterOpen
        while cursor < source.endIndex {
            let c = source[cursor]
            if c == "\\" {
                // Skip the backslash AND the escaped character so an
                // escaped delimiter doesn't end the string. `index(_:
                // offsetBy:limitedBy:)` clamps so we don't run off
                // the end on a trailing lone backslash.
                cursor = source.index(cursor, offsetBy: 2, limitedBy: source.endIndex) ?? source.endIndex
                continue
            }
            if c == delimiter {
                let end = source.index(after: cursor)
                return Token(kind: .string, range: index..<end)
            }
            // String literals don't span unescaped newlines for any of
            // the languages we support, so terminate at end-of-line if
            // we hit one. Prevents an unclosed `"` from coloring the
            // entire rest of the file as a string.
            if c.isNewline {
                return Token(kind: .string, range: index..<cursor)
            }
            cursor = source.index(after: cursor)
        }
        return Token(kind: .string, range: index..<source.endIndex)
    }

    /// Consumes a numeric literal — integer or float. Doesn't try to
    /// validate exotic forms (hex, binary, suffixes); just walks while
    /// the character looks number-ish (digit, `.`, `_`, `x`/`b` for
    /// hex/binary prefixes, etc.). Imperfect but visually fine.
    private func matchNumber(at index: String.Index) -> Token? {
        var cursor = index
        while cursor < source.endIndex {
            let c = source[cursor]
            if c.isNumber || c == "." || c == "_" {
                cursor = source.index(after: cursor)
            } else if "xXbBoO".contains(c), cursor == source.index(after: index) {
                // Allow base prefix like `0x`, `0b`, `0o` immediately
                // after the leading digit.
                cursor = source.index(after: cursor)
            } else if "abcdefABCDEF".contains(c) {
                // Tolerate hex digits — over-eager for plain integers
                // followed by an identifier, but the dominance of
                // word-boundary rules above means we only get here
                // when we already started in a number context.
                cursor = source.index(after: cursor)
            } else {
                break
            }
        }
        return cursor > index ? Token(kind: .number, range: index..<cursor) : nil
    }

    /// Consumes an identifier-shaped run — letters, digits, `_`,
    /// and a leading `@`/`#` sigil if present (Swift attributes,
    /// Python decorators, C preprocessor directives). Returns the
    /// span and the captured word so the caller can look it up in
    /// the keyword / type sets.
    private func matchWord(at index: String.Index) -> (Token, String)? {
        var cursor = index
        // Allow a single leading sigil character (@, #).
        let first = source[cursor]
        if first == "@" || first == "#" {
            cursor = source.index(after: cursor)
        }
        while cursor < source.endIndex {
            let c = source[cursor]
            if c.isLetter || c.isNumber || c == "_" {
                cursor = source.index(after: cursor)
            } else {
                break
            }
        }
        guard cursor > index else { return nil }
        let word = String(source[index..<cursor])
        // Single-character "@" or "#" alone isn't a word — bail.
        guard word.count > 1 || (word.first?.isLetter ?? false) || word.first == "_" else {
            return nil
        }
        return (Token(kind: .keyword /* placeholder, reclassified by caller */, range: index..<cursor), word)
    }

    // MARK: - Helpers

    private func matches(prefix: String, at index: String.Index) -> Bool {
        guard let end = source.index(index, offsetBy: prefix.count, limitedBy: source.endIndex) else {
            return false
        }
        return source[index..<end] == prefix
    }

    private func endOfLine(from index: String.Index) -> String.Index {
        var cursor = index
        while cursor < source.endIndex, !source[cursor].isNewline {
            cursor = source.index(after: cursor)
        }
        return cursor
    }
}
