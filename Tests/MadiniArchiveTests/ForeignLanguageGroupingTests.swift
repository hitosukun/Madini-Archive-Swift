import XCTest
import NaturalLanguage
@testable import MadiniArchive

/// Regression coverage for `ForeignLanguageGrouping.primaryLanguage`,
/// added alongside the Phase 9 hotfix. The original code computed
/// `remaining = sampleLimit - combined.count` AFTER appending a
/// `"\n\n"` separator, so when an earlier iteration had landed
/// `combined.count` within 1-2 chars of `sampleLimit` the next
/// iteration's `remaining` would be negative and `trimmed.prefix(_:)`
/// would runtime-trap with "Can't take a prefix of negative length
/// from a collection". These tests pin down the boundary cases
/// (separator-induced overshoot, exact fill, sub-limit total, empty
/// inputs) so a future refactor of the sample-window logic can't
/// silently regress the negative-length path.
final class ForeignLanguageGroupingTests: XCTestCase {
    // MARK: - Crash-trigger boundaries

    /// The exact pre-fix crash configuration: first message lands
    /// `combined.count` at `sampleLimit - 1`, the next iteration's
    /// separator append pushes to `sampleLimit + 1`, and the prior
    /// code's `remaining` would be `-1`. With the fix, the early
    /// `remaining <= 0` break short-circuits the second iteration
    /// and the call returns without trapping.
    func testSampleLimitMinusOneFollowedByMore_doesNotTrap() {
        let sampleLimit = 5_000
        let first = String(repeating: "あ", count: sampleLimit - 1)
        let second = String(repeating: "い", count: 50)
        // The contract here is "no trap" — the language hypothesis
        // for a single repeated codepoint isn't meaningful, so we
        // don't assert on the result, only on the function returning.
        _ = ForeignLanguageGrouping.primaryLanguage(
            ofMessageTexts: [first, second],
            sampleLimit: sampleLimit
        )
    }

    /// Fills `combined` exactly to `sampleLimit` with the first
    /// message; the outer `>= sampleLimit` break should catch this
    /// before the second iteration runs. Pre-fix this path was
    /// already safe, but pinning it down keeps it that way.
    func testSampleLimitExactFill_doesNotTrap() {
        let sampleLimit = 5_000
        let first = String(repeating: "あ", count: sampleLimit)
        let second = String(repeating: "い", count: 100)
        _ = ForeignLanguageGrouping.primaryLanguage(
            ofMessageTexts: [first, second],
            sampleLimit: sampleLimit
        )
    }

    /// `combined.count == sampleLimit - 2` is the other separator
    /// boundary: pre-fix `remaining = sampleLimit - (sampleLimit - 2 + 2) = 0`,
    /// which made `prefix(0)` legal but allowed `combined` to
    /// silently end up exactly at `sampleLimit + 0` — no crash, but
    /// the boundary was fragile. Post-fix, `remaining <= 0` breaks
    /// out cleanly without a useless empty append.
    func testSampleLimitMinusTwo_doesNotTrap() {
        let sampleLimit = 5_000
        let first = String(repeating: "あ", count: sampleLimit - 2)
        let second = String(repeating: "い", count: 100)
        _ = ForeignLanguageGrouping.primaryLanguage(
            ofMessageTexts: [first, second],
            sampleLimit: sampleLimit
        )
    }

    // MARK: - Confidence / minimum length

    /// Below `minCharacters` returns nil (caller falls back to
    /// `systemLanguage`). Verifies the early-return path still
    /// works after the loop refactor.
    func testTooShortReturnsNil() {
        let result = ForeignLanguageGrouping.primaryLanguage(
            ofMessageTexts: ["短い"],
            sampleLimit: 5_000,
            minCharacters: 200
        )
        XCTAssertNil(result)
    }

    func testEmptyInputReturnsNil() {
        XCTAssertNil(ForeignLanguageGrouping.primaryLanguage(ofMessageTexts: []))
    }

    func testWhitespaceOnlyInputReturnsNil() {
        XCTAssertNil(
            ForeignLanguageGrouping.primaryLanguage(
                ofMessageTexts: ["   ", "\n\n", "\t"]
            )
        )
    }

    // MARK: - Happy path (sanity)

    /// A clearly-Japanese paragraph at sufficient length should be
    /// detected as `.japanese`. Mostly here to assert the function
    /// still produces a non-nil result for the common case after the
    /// refactor — the value of the assertion is "didn't break the
    /// happy path", not "language detection accuracy".
    func testJapanesePassageIsDetected() {
        let paragraph = String(
            repeating: "今日はとても良い天気で、午後から散歩に出かけました。",
            count: 12
        )
        let result = ForeignLanguageGrouping.primaryLanguage(
            ofMessageTexts: [paragraph],
            sampleLimit: 5_000,
            minCharacters: 200,
            minimumConfidence: 0.5
        )
        XCTAssertEqual(result, .japanese)
    }

    func testEnglishPassageIsDetected() {
        let paragraph = String(
            repeating: "The quick brown fox jumps over the lazy dog. ",
            count: 20
        )
        let result = ForeignLanguageGrouping.primaryLanguage(
            ofMessageTexts: [paragraph],
            sampleLimit: 5_000,
            minCharacters: 200,
            minimumConfidence: 0.5
        )
        XCTAssertEqual(result, .english)
    }
}
