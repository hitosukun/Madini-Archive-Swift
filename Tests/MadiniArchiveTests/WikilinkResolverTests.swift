import XCTest
@testable import MadiniArchive

final class WikilinkResolverTests: XCTestCase {
    private func page(
        id: Int = 1,
        path: String,
        title: String? = nil
    ) -> WikiPage {
        WikiPage(
            id: id, vaultID: "v",
            path: path, title: title,
            frontmatterJSON: nil, body: "",
            lastModified: "2026-05-02 12:00:00"
        )
    }

    func testExactPathMatch() {
        let pages = [page(path: "notes/sub/page.md")]
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "notes/sub/page", in: pages),
            "notes/sub/page.md"
        )
    }

    func testFilenameStemMatch() {
        let pages = [page(path: "notes/page.md")]
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "page", in: pages),
            "notes/page.md"
        )
    }

    func testTitleMatch() {
        let pages = [page(path: "rgn_0007_コルバ.md", title: "コルバ")]
        // Title match wins before suffix match. Either resolves the
        // same page; here the assertion is just "found something".
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "コルバ", in: pages),
            "rgn_0007_コルバ.md"
        )
    }

    /// The realistic case Jenna's vault hits: id-prefixed filenames,
    /// wikilinks written with the bare label.
    func testIDPrefixedFilenameSuffixMatch() {
        let pages = [
            page(id: 1, path: "設定/ベルヘイム大陸/rgn_0007_コルバ.md"),
            page(id: 2, path: "設定/ベルヘイム大陸/rgn_0008_バレリオ.md"),
            page(id: 3, path: "設定/ベルヘイム大陸/rgn_0011_マカグ.md"),
        ]
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "コルバ", in: pages),
            "設定/ベルヘイム大陸/rgn_0007_コルバ.md"
        )
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "バレリオ", in: pages),
            "設定/ベルヘイム大陸/rgn_0008_バレリオ.md"
        )
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "マカグ", in: pages),
            "設定/ベルヘイム大陸/rgn_0011_マカグ.md"
        )
    }

    func testUnderscoreTokenMatchInMiddle() {
        let pages = [page(path: "chr_0001_zinka_alt.md")]
        // "0001" is one of the tokens; should match.
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "0001", in: pages),
            "chr_0001_zinka_alt.md"
        )
    }

    func testFilenamePrefixFallback() {
        let pages = [page(path: "characters/zinka_full_name.md")]
        // No exact / title / suffix / token match for "zinka"; falls
        // through to prefix match.
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "zinka", in: pages),
            "characters/zinka_full_name.md"
        )
    }

    func testCaseInsensitive() {
        let pages = [page(path: "rgn_0001_コルバ.md")]
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "コルバ", in: pages),
            "rgn_0001_コルバ.md"
        )
    }

    func testEmptyTargetReturnsNil() {
        let pages = [page(path: "a.md")]
        XCTAssertNil(WikilinkResolver.resolve(target: "", in: pages))
        XCTAssertNil(WikilinkResolver.resolve(target: "   ", in: pages))
    }

    func testNoMatchReturnsNil() {
        let pages = [page(path: "a.md")]
        XCTAssertNil(WikilinkResolver.resolve(target: "nonexistent", in: pages))
    }

    /// Title and suffix can both match; the title rule fires first per
    /// the resolver's documented precedence.
    func testTitleBeatsSuffix() {
        let pages = [
            page(id: 1, path: "rgn_0007_コルバ.md", title: nil),
            page(id: 2, path: "another.md", title: "コルバ"),
        ]
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "コルバ", in: pages),
            "another.md"
        )
    }

    func testSuffixBeatsPrefix() {
        let pages = [
            page(id: 1, path: "Adam_test.md"),    // prefix match for "Adam"
            page(id: 2, path: "rgn_0001_Adam.md"), // suffix match for "Adam"
        ]
        // Suffix rule fires first (rule 4) — id-prefixed naming wins
        // over a partial-typing fallback.
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "Adam", in: pages),
            "rgn_0001_Adam.md"
        )
    }

    func testNonAsciiPathRoundtrip() {
        let pages = [page(path: "概念/魔術.md")]
        XCTAssertEqual(
            WikilinkResolver.resolve(target: "魔術", in: pages),
            "概念/魔術.md"
        )
    }
}
