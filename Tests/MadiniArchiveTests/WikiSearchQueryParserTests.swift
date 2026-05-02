import XCTest
@testable import MadiniArchive

final class WikiSearchQueryParserTests: XCTestCase {
    // MARK: - Tokenization

    func testEmptyQuery() {
        let p = WikiSearchQueryParser.parse("")
        XCTAssertTrue(p.isEmpty)
        XCTAssertEqual(p.ftsQuery, "")
        XCTAssertTrue(p.frontmatterFilters.isEmpty)
    }

    func testFreeTextOnly() {
        let p = WikiSearchQueryParser.parse("錫花")
        XCTAssertEqual(p.ftsQuery, "錫花")
        XCTAssertTrue(p.frontmatterFilters.isEmpty)
    }

    func testMultipleFreeTextTerms() {
        let p = WikiSearchQueryParser.parse("foo bar baz")
        XCTAssertEqual(p.ftsQuery, "foo bar baz")
    }

    // MARK: - Frontmatter filters

    func testSingleFilter() {
        let p = WikiSearchQueryParser.parse("type:chr")
        XCTAssertEqual(p.frontmatterFilters.count, 1)
        XCTAssertEqual(p.frontmatterFilters[0].key, "type")
        XCTAssertEqual(p.frontmatterFilters[0].value, "chr")
        XCTAssertEqual(p.ftsQuery, "")
    }

    func testFilterPlusFreeText() {
        let p = WikiSearchQueryParser.parse("type:chr 錫花")
        XCTAssertEqual(p.frontmatterFilters.count, 1)
        XCTAssertEqual(p.frontmatterFilters[0].key, "type")
        XCTAssertEqual(p.frontmatterFilters[0].value, "chr")
        XCTAssertEqual(p.ftsQuery, "錫花")
    }

    func testMultipleFilters() {
        let p = WikiSearchQueryParser.parse("type:chr status:wip")
        XCTAssertEqual(p.frontmatterFilters.count, 2)
        XCTAssertEqual(p.frontmatterFilters.map(\.key), ["type", "status"])
        XCTAssertEqual(p.ftsQuery, "")
    }

    func testFilterKeyLowercased() {
        let p = WikiSearchQueryParser.parse("Type:Chr")
        XCTAssertEqual(p.frontmatterFilters[0].key, "type")
        // Value preserves original case (compared case-insensitively at filter time).
        XCTAssertEqual(p.frontmatterFilters[0].value, "Chr")
    }

    // MARK: - Quoting

    func testQuotedPhraseStaysIntact() {
        let p = WikiSearchQueryParser.parse("\"hello world\"")
        XCTAssertEqual(p.ftsQuery, "hello world")
    }

    func testQuotedValueInFilter() {
        let p = WikiSearchQueryParser.parse(#"name:"Suzuka Hana""#)
        XCTAssertEqual(p.frontmatterFilters.count, 1)
        XCTAssertEqual(p.frontmatterFilters[0].value, "Suzuka Hana")
    }

    func testQuoteInsideTokenIsNotAFilter() {
        // A token starting with " is treated as a quoted phrase, not
        // misinterpreted as a `key:value` even if it contains a colon.
        let p = WikiSearchQueryParser.parse("\"key:value\"")
        XCTAssertEqual(p.ftsQuery, "key:value")
        XCTAssertTrue(p.frontmatterFilters.isEmpty)
    }

    // MARK: - Filter passing

    private func page(frontmatter: [String: Any]?) -> WikiPage {
        let json = frontmatter.flatMap {
            try? JSONSerialization.data(withJSONObject: $0)
        }.flatMap { String(data: $0, encoding: .utf8) }
        return WikiPage(
            id: 1, vaultID: "v",
            path: "p.md", title: nil,
            frontmatterJSON: json, body: "",
            lastModified: "2026-05-02 12:00:00"
        )
    }

    func testPassesFiltersExactStringMatch() {
        let p = page(frontmatter: ["type": "chr"])
        XCTAssertTrue(WikiSearchQueryParser.passesFilters(
            p, filters: [(key: "type", value: "chr")]
        ))
    }

    func testPassesFiltersCaseInsensitiveValue() {
        let p = page(frontmatter: ["type": "CHR"])
        XCTAssertTrue(WikiSearchQueryParser.passesFilters(
            p, filters: [(key: "type", value: "chr")]
        ))
    }

    func testPassesFiltersArrayContains() {
        // tags: [character, novel] — match if any element equals expected.
        let p = page(frontmatter: ["tags": ["character", "novel"]])
        XCTAssertTrue(WikiSearchQueryParser.passesFilters(
            p, filters: [(key: "tags", value: "novel")]
        ))
        XCTAssertFalse(WikiSearchQueryParser.passesFilters(
            p, filters: [(key: "tags", value: "missing")]
        ))
    }

    func testPassesFiltersNumberMatch() {
        let p = page(frontmatter: ["chapter": 5])
        XCTAssertTrue(WikiSearchQueryParser.passesFilters(
            p, filters: [(key: "chapter", value: "5")]
        ))
    }

    func testPassesFiltersFailsWhenKeyMissing() {
        let p = page(frontmatter: ["other": "value"])
        XCTAssertFalse(WikiSearchQueryParser.passesFilters(
            p, filters: [(key: "type", value: "chr")]
        ))
    }

    func testPassesFiltersFailsWithoutFrontmatter() {
        let p = page(frontmatter: nil)
        XCTAssertFalse(WikiSearchQueryParser.passesFilters(
            p, filters: [(key: "type", value: "chr")]
        ))
    }

    func testPassesFiltersANDsMultipleClauses() {
        let p = page(frontmatter: ["type": "chr", "status": "wip"])
        XCTAssertTrue(WikiSearchQueryParser.passesFilters(
            p, filters: [
                (key: "type", value: "chr"),
                (key: "status", value: "wip"),
            ]
        ))
        XCTAssertFalse(WikiSearchQueryParser.passesFilters(
            p, filters: [
                (key: "type", value: "chr"),
                (key: "status", value: "done"),
            ]
        ))
    }
}
