import XCTest
@testable import MadiniArchive

final class MadiniURLTests: XCTestCase {
    private func parse(_ string: String) -> MadiniURL? {
        guard let url = URL(string: string) else { return nil }
        return MadiniURL.parse(url)
    }

    // MARK: - Conversation

    func testConversationByID() {
        XCTAssertEqual(
            parse("madini-archive://conversation/abc123"),
            .conversation(id: "abc123", messageIndex: nil)
        )
    }

    func testConversationWithMessageIndex() {
        XCTAssertEqual(
            parse("madini-archive://conversation/abc123/message/42"),
            .conversation(id: "abc123", messageIndex: 42)
        )
    }

    func testConversationWithBadMessageIndex() {
        // Non-numeric index → fall back to no-message form.
        XCTAssertEqual(
            parse("madini-archive://conversation/abc/message/oops"),
            .conversation(id: "abc", messageIndex: nil)
        )
    }

    func testConversationMissingIDReturnsNil() {
        XCTAssertNil(parse("madini-archive://conversation/"))
        XCTAssertNil(parse("madini-archive://conversation"))
    }

    // MARK: - Search

    func testSearchWithQuery() {
        XCTAssertEqual(
            parse("madini-archive://search?q=hello"),
            .search(query: "hello")
        )
    }

    func testSearchPercentEncoded() {
        XCTAssertEqual(
            parse("madini-archive://search?q=%E9%8C%AB%E8%8A%B1"),
            .search(query: "錫花")
        )
    }

    func testSearchWithoutQueryReturnsNil() {
        XCTAssertNil(parse("madini-archive://search"))
        XCTAssertNil(parse("madini-archive://search?q="))
    }

    // MARK: - Wiki page

    func testWikiPageSimple() {
        XCTAssertEqual(
            parse("madini-archive://wiki/vault-uuid/notes/page.md"),
            .wikiPage(vaultID: "vault-uuid", relativePath: "notes/page.md")
        )
    }

    func testWikiPageWithDeepPath() {
        XCTAssertEqual(
            parse("madini-archive://wiki/vault/a/b/c/d.md"),
            .wikiPage(vaultID: "vault", relativePath: "a/b/c/d.md")
        )
    }

    func testWikiPageMissingPathReturnsNil() {
        XCTAssertNil(parse("madini-archive://wiki/vault-only"))
    }

    func testWikiPageMissingVaultReturnsNil() {
        XCTAssertNil(parse("madini-archive://wiki/"))
    }

    // MARK: - Reject other schemes / shapes

    func testNonMadiniSchemeReturnsNil() {
        XCTAssertNil(parse("https://example.com"))
        XCTAssertNil(parse("file:///tmp"))
    }

    func testUnknownHostReturnsNil() {
        XCTAssertNil(parse("madini-archive://unknown-route"))
    }

    func testCaseInsensitiveScheme() {
        XCTAssertEqual(
            parse("MADINI-ARCHIVE://conversation/abc"),
            .conversation(id: "abc", messageIndex: nil)
        )
    }
}
