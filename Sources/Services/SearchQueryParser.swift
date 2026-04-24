import Foundation

/// Parses the archive's search field into an FTS5 MATCH expression.
///
/// The library's search text used to be a single whitespace-split +
/// AND'd token list, which meant phrase search, field prefixes, and
/// negation silently didn't work — typing `title:"イラスト"` or
/// `"マディニ 画像"` just searched for those strings verbatim (colons,
/// quotes, and all). This parser turns the text into a small AST and
/// then emits syntactically-valid FTS5, so the UI can honour what the
/// user actually asked for.
///
/// ## Supported grammar
///
/// ```
/// query    := clause*
/// clause   := '-'? (field ':')? term '*'?
/// field    := 'title' | 'content'
/// term     := '"' … '"'          (phrase)
///           | non-whitespace+    (word)
/// ```
///
/// - **Bare term** (`イラスト`) — matches both `title` and `content`.
/// - **Quoted phrase** (`"マディニちゃん 描いて"`) — treated as a single
///   FTS5 phrase; the whitespace inside is preserved as token adjacency.
/// - **Field query** (`title:イラスト`, `title:"長いタイトル"`) —
///   restricts to one of the two FTS5 columns. Unknown fields
///   (e.g. `foo:bar`) are treated as a single bare token rather than
///   rejected, because FTS5 would otherwise `no such column` on them.
/// - **Negation** (`-イラスト`, `-title:foo`, `-"phrase"`) — emitted as
///   `NOT term`. FTS5 doesn't accept pure-negation queries; the parser
///   detects that case and drops the search expression entirely so the
///   caller can fall back to "no full-text filter" instead of throwing.
/// - **Prefix** (`foo*`, `title:foo*`, `"hello world"*`) — trailing
///   `*` on a word or phrase becomes FTS5's prefix operator. With the
///   `trigram` tokenizer in use for `search_idx`, the common Japanese
///   "substring" case is already handled by the tokenizer itself; the
///   prefix operator is most useful for English tokens where you want
///   `user*` to match `user`, `users`, `username` but not `reuse`.
///   A lone `*` (or `-*`) is noise and gets dropped. `*` in the
///   middle of a word (`foo*bar`) is preserved verbatim.
/// - **Implicit AND**: multiple clauses are joined with ` AND `.
///
/// ## Out of scope (intentionally)
///
/// - Explicit `OR` / grouping. The AST is shaped to make adding them
///   later non-invasive, but they're not part of this spec because the
///   user's reported complaint was the core three — phrase, field,
///   negation — and shipping those well beats shipping everything badly.
/// - `#tag` tokens: the sidebar search bar promotes these into
///   `ArchiveSearchFilter.bookmarkTags` before calling the parser, so
///   they never reach this code. If one slips through by accident
///   (e.g. a `#` embedded mid-sentence), we treat it as a normal term.
///
/// ## FTS5 quoting
///
/// Every emitted term is double-quoted. Embedded quotes are doubled
/// (`"` → `""`) per SQLite FTS5 rules. The tokenizer (`unicode61`) then
/// tokenises the phrase contents, which gives us the same behaviour as
/// the user typing those tokens adjacently.
enum SearchQueryParser {
    /// Result of parsing one query string. `ftsMatchExpression` is nil
    /// when the input had no effective positive clauses (all whitespace,
    /// only negations, only an invalid operator stub, etc.) — callers
    /// should skip the FTS5 MATCH filter entirely in that case rather
    /// than passing a broken expression to SQLite.
    struct ParsedQuery: Equatable {
        let ftsMatchExpression: String?
    }

    /// Parse `raw` into an FTS5 MATCH expression. Returns `nil`
    /// expression when the text is empty or would degenerate into
    /// an invalid FTS5 query (pure negation).
    static func parse(_ raw: String) -> ParsedQuery {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            return ParsedQuery(ftsMatchExpression: nil)
        }

        let clauses = Self.tokenize(trimmed)
        guard !clauses.isEmpty else {
            return ParsedQuery(ftsMatchExpression: nil)
        }

        // FTS5 rejects expressions where every top-level operand is
        // negated (`NOT a AND NOT b`) — it needs at least one thing to
        // match first. Mirror that: if the user typed only negations,
        // drop the text filter so the non-text filters (sources, tags,
        // date) still return their natural result set instead of
        // throwing a SQL error.
        guard clauses.contains(where: { !$0.isNegated }) else {
            return ParsedQuery(ftsMatchExpression: nil)
        }

        let expression = clauses
            .map { $0.ftsFragment }
            .joined(separator: " AND ")
        return ParsedQuery(ftsMatchExpression: expression)
    }

    // MARK: - AST

    /// One parsed clause — the unit that gets ANDed with the others.
    /// Kept internal so tests exercise the full pipeline via `parse`
    /// rather than poking at the AST directly; the AST shape is an
    /// implementation detail and has room to grow (e.g. adding `OR`
    /// would introduce a nested `[Clause]` here).
    fileprivate struct Clause {
        var isNegated: Bool
        var field: Field?
        var match: Match
        /// Trailing `*` was present on the source term. Emitted as
        /// FTS5's prefix operator outside the quoted term — `"foo"*`
        /// matches any token starting with `foo`. Equally valid on a
        /// phrase; FTS5 treats `"hello world"*` as "the phrase, with
        /// the final token allowed to be a prefix."
        var isPrefix: Bool
    }

    fileprivate enum Field: String {
        case title
        case content
    }

    fileprivate enum Match {
        case word(String)
        case phrase(String)
    }

    // MARK: - Tokenizer

    /// Walks the input character-by-character producing clauses.
    /// We roll our own scanner (rather than regex) because the rules
    /// are context-sensitive — `-` is negation only at the head of a
    /// token, `:` splits off a field only when the left side is a
    /// known field name, and quotes can contain anything including
    /// delimiters. A regex handling all of that would be unreadable.
    private static func tokenize(_ input: String) -> [Clause] {
        var clauses: [Clause] = []
        let scalars = Array(input)
        var index = 0

        while index < scalars.count {
            // Skip whitespace between clauses.
            while index < scalars.count, scalars[index].isWhitespace {
                index += 1
            }
            guard index < scalars.count else { break }

            // Leading `-` is negation when it prefixes a term; `-`
            // appearing later in a word (e.g. `gpt-4o`) is just part
            // of the word and handled by the word scanner below.
            //
            // A lone `-` (followed by whitespace or end-of-input) is
            // meaningless — FTS5's tokenizer would drop it anyway —
            // so we swallow it as noise and restart the token loop.
            // This keeps inputs like `foo -` and `- foo` from
            // emitting a bogus `"-"` phrase.
            var isNegated = false
            if scalars[index] == "-" {
                let next = index + 1 < scalars.count ? scalars[index + 1] : nil
                if let next, !next.isWhitespace {
                    // `--foo`: only the first `-` is consumed as the
                    // negation marker. The second `-` becomes part of
                    // the word (`-foo`), which degrades to pure-
                    // negation and gets dropped at assembly time.
                    isNegated = true
                    index += 1
                } else {
                    index += 1
                    continue
                }
            }

            // Peek for a field prefix: `fieldName:` where fieldName is
            // a known column. If the left side isn't a known field, we
            // fall back to word/phrase scanning and the colon ends up
            // inside the bare word (which FTS5's unicode61 tokenizer
            // will split on at query-time — equivalent behaviour).
            let (field, afterField) = Self.consumeFieldPrefix(scalars: scalars, from: index)
            index = afterField

            // Scan the term — either a quoted phrase or a bare word.
            guard index < scalars.count else {
                // A lone `-title:` with nothing after — drop silently.
                break
            }

            let match: Match
            var isPrefix = false
            if scalars[index] == "\"" {
                let (content, after) = Self.consumePhrase(scalars: scalars, from: index)
                index = after
                // Empty phrase (`""`) carries no information; skip it.
                guard !content.isEmpty else { continue }
                match = .phrase(content)
                // Prefix marker sits outside the closing quote:
                // `"foo"*`. Consume it if present.
                if index < scalars.count, scalars[index] == "*" {
                    isPrefix = true
                    index += 1
                }
            } else {
                let (word, after) = Self.consumeWord(scalars: scalars, from: index)
                index = after
                guard !word.isEmpty else { continue }
                // Trailing `*` on a bare word is a prefix marker —
                // `foo*` → match tokens starting with `foo`. A `*` in
                // the middle (`foo*bar`) is preserved verbatim as part
                // of the word, since FTS5's trigram/unicode61
                // tokenizers handle `*` as a regular symbol at match
                // time. If stripping the trailing `*` leaves nothing
                // (input was a lone `*`), drop the clause silently —
                // an empty prefix matches everything and is almost
                // certainly a mistyped query.
                var wordText = word
                if wordText.hasSuffix("*") {
                    wordText.removeLast()
                    isPrefix = true
                }
                guard !wordText.isEmpty else { continue }
                match = .word(wordText)
            }

            clauses.append(
                Clause(
                    isNegated: isNegated,
                    field: field,
                    match: match,
                    isPrefix: isPrefix
                )
            )
        }

        return clauses
    }

    /// Try to consume a `field:` prefix starting at `start`. Returns the
    /// parsed field (if the left side is a recognized FTS column name)
    /// and the index to continue scanning from. If the prefix isn't a
    /// known field, returns `(nil, start)` so the caller re-scans the
    /// same bytes as a bare word — that way `https://foo.com` lands as
    /// a word, not as a broken `https` field query.
    private static func consumeFieldPrefix(
        scalars: [Character],
        from start: Int
    ) -> (Field?, Int) {
        var cursor = start
        var name = ""
        while cursor < scalars.count {
            let c = scalars[cursor]
            if c.isLetter {
                name.append(c)
                cursor += 1
            } else {
                break
            }
        }
        // Require `name:` with the colon present and the right side
        // non-empty (or a phrase opener). `title:` at end of input or
        // `title: foo` (colon followed by space) doesn't count.
        guard
            cursor < scalars.count,
            scalars[cursor] == ":",
            cursor + 1 < scalars.count,
            !scalars[cursor + 1].isWhitespace,
            let field = Field(rawValue: name.lowercased())
        else {
            return (nil, start)
        }
        return (field, cursor + 1)
    }

    /// Consume a `"…"` phrase starting at the opening quote at `start`.
    /// Stops at the matching closing quote. An unterminated phrase runs
    /// to end-of-input (so a user who types `foo "bar` still gets a
    /// search for `bar` as a phrase, matching everyday shell/search-bar
    /// mental models instead of dropping the whole tail).
    ///
    /// Embedded quotes follow FTS5's doubling convention: a `""` inside
    /// the phrase is treated as a single literal `"` in the content,
    /// rather than closing + reopening the phrase. This means a user who
    /// types `"say ""hi"""` gets one phrase with an embedded quote — the
    /// same escape the parser's output stage re-applies on emit, so the
    /// round-trip is lossless.
    private static func consumePhrase(
        scalars: [Character],
        from start: Int
    ) -> (String, Int) {
        var cursor = start + 1 // skip opening quote
        var content = ""
        while cursor < scalars.count {
            let c = scalars[cursor]
            if c == "\"" {
                // FTS5-style escape: `""` inside a phrase is a literal
                // quote, not a terminator. Peek ahead; if the next char
                // is also `"`, consume both and append one.
                let next = cursor + 1 < scalars.count ? scalars[cursor + 1] : nil
                if next == "\"" {
                    content.append("\"")
                    cursor += 2
                    continue
                }
                return (content, cursor + 1)
            }
            content.append(c)
            cursor += 1
        }
        return (content, cursor)
    }

    /// Consume a bare word — every non-whitespace, non-quote character
    /// until the next separator. Colons inside the word are preserved
    /// (e.g. `https://foo`) because we've already given the field-prefix
    /// pass a chance to peel them off.
    private static func consumeWord(
        scalars: [Character],
        from start: Int
    ) -> (String, Int) {
        var cursor = start
        var word = ""
        while cursor < scalars.count {
            let c = scalars[cursor]
            if c.isWhitespace || c == "\"" {
                break
            }
            word.append(c)
            cursor += 1
        }
        return (word, cursor)
    }
}

// MARK: - AST → FTS5

private extension SearchQueryParser.Clause {
    /// Emit the clause as an FTS5 fragment. Negation is a binary
    /// operator in FTS5, but when combined with `AND` at the outer
    /// level we can express "exclude X" as `AND NOT X`. The final
    /// expression assembler in `parse` wraps this with ` AND ` between
    /// clauses, so a negated clause contributes `NOT "…"` on its own.
    ///
    /// The prefix `*` marker, when set, appears immediately after the
    /// quoted term (and before nothing else). FTS5 expects `"foo"*`
    /// or `col:"foo"*`, never `"foo*"` (which would be a literal
    /// star inside the token).
    var ftsFragment: String {
        let suffix = isPrefix ? "*" : ""
        let term = "\(match.ftsQuoted)\(suffix)"
        let core = field.map { "\($0.rawValue):\(term)" } ?? term
        return isNegated ? "NOT \(core)" : core
    }
}

private extension SearchQueryParser.Match {
    /// Return the FTS5-escaped literal for this match. Both words and
    /// phrases are double-quoted — FTS5 tokenizes phrase contents the
    /// same way it tokenizes unquoted tokens, so "word" and word
    /// behave equivalently for single-token matches, but the quoted
    /// form is robust against special characters the user might embed
    /// in a term (`:`, `-`, `(`, operator keywords like `AND` / `OR`).
    /// Embedded double quotes are doubled per FTS5 rules.
    var ftsQuoted: String {
        switch self {
        case .word(let s), .phrase(let s):
            return "\"\(s.replacingOccurrences(of: "\"", with: "\"\""))\""
        }
    }
}
