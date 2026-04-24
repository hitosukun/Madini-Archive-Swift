import XCTest
@testable import MadiniArchive

/// Coverage for the archive's search-query parser. The parser is a thin
/// front-end for FTS5 MATCH syntax, so each test asserts the exact
/// expression string the repo will send to SQLite. Doing it at this
/// level (rather than round-tripping through the DB) keeps the tests
/// fast and lets us exercise edge cases — pure negation, unknown
/// fields, unterminated phrases — that'd be tedious to shape a real
/// index around.
final class SearchQueryParserTests: XCTestCase {
    // MARK: - Empty / whitespace

    func testEmptyInputYieldsNilExpression() {
        XCTAssertNil(SearchQueryParser.parse("").ftsMatchExpression)
    }

    func testWhitespaceOnlyInputYieldsNilExpression() {
        XCTAssertNil(SearchQueryParser.parse("   \n\t").ftsMatchExpression)
    }

    // MARK: - Bare words

    func testSingleBareWord() {
        XCTAssertEqual(
            SearchQueryParser.parse("イラスト").ftsMatchExpression,
            "\"イラスト\""
        )
    }

    func testMultipleBareWordsAreANDed() {
        XCTAssertEqual(
            SearchQueryParser.parse("イラスト 描いて").ftsMatchExpression,
            "\"イラスト\" AND \"描いて\""
        )
    }

    func testHyphenInsideWordIsPreserved() {
        // `gpt-4o` should search for the whole token, not be treated
        // as negation of `4o`. Only leading `-` flips the negation
        // flag.
        XCTAssertEqual(
            SearchQueryParser.parse("gpt-4o").ftsMatchExpression,
            "\"gpt-4o\""
        )
    }

    func testColonInsideWordIsPreservedWhenNotAFieldPrefix() {
        // `url` is not a recognized field, so the whole thing stays as
        // a single token. FTS5's unicode61 tokenizer will split at the
        // colon / slashes at match time.
        XCTAssertEqual(
            SearchQueryParser.parse("url:https://foo.com").ftsMatchExpression,
            "\"url:https://foo.com\""
        )
    }

    // MARK: - Phrases

    func testQuotedPhrase() {
        XCTAssertEqual(
            SearchQueryParser.parse("\"マディニちゃん 描いて\"").ftsMatchExpression,
            "\"マディニちゃん 描いて\""
        )
    }

    func testUnterminatedPhraseRunsToEnd() {
        XCTAssertEqual(
            SearchQueryParser.parse("foo \"bar baz").ftsMatchExpression,
            "\"foo\" AND \"bar baz\""
        )
    }

    func testEmptyPhraseIsDropped() {
        XCTAssertEqual(
            SearchQueryParser.parse("foo \"\" bar").ftsMatchExpression,
            "\"foo\" AND \"bar\""
        )
    }

    func testEmbeddedQuotesInPhraseAreDoubled() {
        // The user types a quoted phrase containing a literal `"`.
        // FTS5's escape is to double the quote — `say ""hi""` inside
        // the outer double-quotes.
        XCTAssertEqual(
            SearchQueryParser.parse("\"say \"\"hi\"\"\"").ftsMatchExpression,
            "\"say \"\"hi\"\"\""
        )
    }

    // MARK: - Field prefixes

    func testKnownFieldWithBareWord() {
        XCTAssertEqual(
            SearchQueryParser.parse("title:イラスト").ftsMatchExpression,
            "title:\"イラスト\""
        )
    }

    func testKnownFieldWithPhrase() {
        XCTAssertEqual(
            SearchQueryParser.parse("title:\"長いタイトル\"").ftsMatchExpression,
            "title:\"長いタイトル\""
        )
    }

    func testKnownFieldIsCaseInsensitive() {
        XCTAssertEqual(
            SearchQueryParser.parse("Title:foo").ftsMatchExpression,
            "title:\"foo\""
        )
    }

    func testUnknownFieldFallsBackToBareWord() {
        // `foo:` isn't a column, so the whole thing stays as one
        // token (FTS5 tokenizer splits on the colon at match time).
        XCTAssertEqual(
            SearchQueryParser.parse("foo:bar").ftsMatchExpression,
            "\"foo:bar\""
        )
    }

    func testFieldWithoutValueIsDropped() {
        // `title:` with nothing after (or trailing whitespace) is
        // meaningless — skip it and continue.
        XCTAssertEqual(
            SearchQueryParser.parse("title: foo").ftsMatchExpression,
            "\"title:\" AND \"foo\""
        )
    }

    func testContentField() {
        XCTAssertEqual(
            SearchQueryParser.parse("content:猫").ftsMatchExpression,
            "content:\"猫\""
        )
    }

    // MARK: - Negation

    func testNegationWithPositiveClause() {
        XCTAssertEqual(
            SearchQueryParser.parse("foo -bar").ftsMatchExpression,
            "\"foo\" AND NOT \"bar\""
        )
    }

    func testNegationOfPhrase() {
        XCTAssertEqual(
            SearchQueryParser.parse("foo -\"bar baz\"").ftsMatchExpression,
            "\"foo\" AND NOT \"bar baz\""
        )
    }

    func testNegationOfFieldQuery() {
        XCTAssertEqual(
            SearchQueryParser.parse("foo -title:bar").ftsMatchExpression,
            "\"foo\" AND NOT title:\"bar\""
        )
    }

    func testPureNegationYieldsNilExpression() {
        // FTS5 rejects `NOT a AND NOT b`; the parser degrades to nil
        // so the repo can bail instead of erroring.
        XCTAssertNil(SearchQueryParser.parse("-foo").ftsMatchExpression)
        XCTAssertNil(SearchQueryParser.parse("-foo -bar").ftsMatchExpression)
    }

    // MARK: - Mixed

    func testFieldPhraseAndNegation() {
        XCTAssertEqual(
            SearchQueryParser.parse("title:\"マディニ\" 描いて -猫").ftsMatchExpression,
            "title:\"マディニ\" AND \"描いて\" AND NOT \"猫\""
        )
    }

    // MARK: - Prefix (`*`)

    func testBareWordPrefix() {
        // `foo*` becomes FTS5 prefix operator. With a trigram index
        // this is subtly different from just "foo" — here it means
        // "token starting with foo" as a single token constraint,
        // whereas bare "foo" with trigram tokenization means "any
        // document whose trigram set includes the three trigrams of
        // foo." Different recall shape; we keep both operators
        // available.
        XCTAssertEqual(
            SearchQueryParser.parse("foo*").ftsMatchExpression,
            "\"foo\"*"
        )
    }

    func testFieldWithPrefix() {
        XCTAssertEqual(
            SearchQueryParser.parse("title:foo*").ftsMatchExpression,
            "title:\"foo\"*"
        )
    }

    func testPhrasePrefix() {
        // FTS5 allows prefix on a phrase — the FINAL token of the
        // phrase is the one that gets the prefix match. Users rarely
        // need this, but accepting it is free once the grammar has
        // a general `term '*'?` rule.
        XCTAssertEqual(
            SearchQueryParser.parse("\"hello world\"*").ftsMatchExpression,
            "\"hello world\"*"
        )
    }

    func testNegatedPrefix() {
        XCTAssertEqual(
            SearchQueryParser.parse("-foo*").ftsMatchExpression,
            nil // `-foo*` alone is still pure negation → drop.
        )
        XCTAssertEqual(
            SearchQueryParser.parse("bar -foo*").ftsMatchExpression,
            "\"bar\" AND NOT \"foo\"*"
        )
    }

    func testLoneStarIsDropped() {
        // A lone `*` as a term is meaningless (prefix of nothing
        // matches everything → almost never what the user wanted).
        // Treat it the same way as a lone `-`: consume and continue.
        XCTAssertNil(SearchQueryParser.parse("*").ftsMatchExpression)
        XCTAssertEqual(
            SearchQueryParser.parse("foo *").ftsMatchExpression,
            "\"foo\""
        )
    }

    func testMidWordStarIsPreserved() {
        // Only the trailing `*` is treated as the prefix marker.
        // `foo*bar` stays as one word; the `*` is part of the token.
        XCTAssertEqual(
            SearchQueryParser.parse("foo*bar").ftsMatchExpression,
            "\"foo*bar\""
        )
    }

    // MARK: - Edge cases

    func testLoneDashIsIgnored() {
        XCTAssertEqual(
            SearchQueryParser.parse("- foo").ftsMatchExpression,
            "\"foo\""
        )
    }

    func testTrailingDashIsDropped() {
        XCTAssertEqual(
            SearchQueryParser.parse("foo -").ftsMatchExpression,
            "\"foo\""
        )
    }

    func testDoubleDashTreatedAsNegationOfDash() {
        // Hard edge case: `--foo` → negate `-foo` — the second `-` is
        // part of the word. The whole thing becomes `NOT "-foo"` and
        // then falls into the pure-negation degradation.
        XCTAssertNil(SearchQueryParser.parse("--foo").ftsMatchExpression)
    }
}
