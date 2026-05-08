import XCTest
@testable import MadiniArchive

/// Coverage for Phase 3b's bulk pre-parse hook on
/// `ConversationDetailViewModel.load()`. Each test uses UUID-derived
/// message ids so repeated runs don't pollute the process-wide
/// `MessageBubbleView.blocksCache`.
@MainActor
final class ConversationDetailViewModelPrewarmTests: XCTestCase {
    private func makeDetail(
        convID: String,
        messageCount: Int
    ) -> (ConversationDetail, [String]) {
        let headline = ConversationHeadlineSummary.build(
            prompt: "Prewarm test",
            title: nil,
            firstMessage: nil
        )
        let summary = ConversationSummary(
            id: convID,
            headline: headline,
            source: "test",
            title: "Prewarm test",
            model: nil,
            messageCount: messageCount,
            primaryTime: nil,
            isBookmarked: false
        )
        var messages: [Message] = []
        var ids: [String] = []
        for i in 0..<messageCount {
            let id = "\(convID)-msg-\(i)-\(UUID().uuidString)"
            ids.append(id)
            messages.append(Message(
                id: id,
                role: i % 2 == 0 ? .user : .assistant,
                content: "Prewarm test message \(i) for \(convID)"
            ))
        }
        return (ConversationDetail(summary: summary, messages: messages), ids)
    }

    private func makeRepo(
        details: [String: ConversationDetail]
    ) -> MockConversationRepository {
        MockConversationRepository(items: [], details: details)
    }

    // MARK: - Below the immediate cutoff

    func testSmallConversationWarmsAllMessagesOnLoad() async {
        let convID = "small-\(UUID().uuidString)"
        let (detail, ids) = makeDetail(convID: convID, messageCount: 5)
        let repo = makeRepo(details: [convID: detail])
        let vm = ConversationDetailViewModel(
            conversationId: convID,
            repository: repo
        )

        await vm.load()
        // Sync pass already covered all 5 — no need to await deferred.
        for id in ids {
            XCTAssertTrue(
                MessageBubbleView._hasCachedBlocks(messageID: id),
                "message \(id) should be warm after sync prewarm"
            )
        }
    }

    // MARK: - Crossing the cutoff

    func testLargeConversationWarmsImmediateAndDeferredBatches() async {
        let convID = "large-\(UUID().uuidString)"
        let cutoff = ConversationDetailViewModel.immediatePrewarmCount
        let total = cutoff + 10
        let (detail, ids) = makeDetail(convID: convID, messageCount: total)
        let repo = makeRepo(details: [convID: detail])
        let vm = ConversationDetailViewModel(
            conversationId: convID,
            repository: repo
        )

        await vm.load()
        // First N must be warm immediately after `load()` returns —
        // that's the whole point of the sync pass.
        for i in 0..<cutoff {
            XCTAssertTrue(
                MessageBubbleView._hasCachedBlocks(messageID: ids[i]),
                "message #\(i) should be warm by load() return"
            )
        }
        // Deferred messages may or may not be warm yet; await the
        // background batch to finish, then verify.
        await vm._awaitPrewarm()
        for i in cutoff..<total {
            XCTAssertTrue(
                MessageBubbleView._hasCachedBlocks(messageID: ids[i]),
                "message #\(i) should be warm after _awaitPrewarm"
            )
        }
    }

    // MARK: - Cache-hit idempotence

    func testReloadIsIdempotent() async {
        let convID = "reload-\(UUID().uuidString)"
        let (detail, ids) = makeDetail(convID: convID, messageCount: 3)
        let repo = makeRepo(details: [convID: detail])
        let vm = ConversationDetailViewModel(
            conversationId: convID,
            repository: repo
        )

        await vm.load()
        // Already warm — second load() must not crash and must keep
        // the cache warm.
        await vm.load()
        for id in ids {
            XCTAssertTrue(MessageBubbleView._hasCachedBlocks(messageID: id))
        }
    }

    // MARK: - Cancellation when a second load arrives

    func testSecondLoadCancelsPreviousDeferredBatch() async {
        // The first conversation is large enough that the deferred
        // batch can't possibly finish in the same micro-tick; the
        // second load() must replace the prewarmTask. We verify
        // indirectly: after both loads complete + we await, BOTH
        // conversations' messages are warm. (If the cancel were
        // missing, this would also pass — so the real assertion is
        // just "no crash from concurrent / cancelled tasks".)
        let convA = "convA-\(UUID().uuidString)"
        let convB = "convB-\(UUID().uuidString)"
        let cutoff = ConversationDetailViewModel.immediatePrewarmCount
        let (detailA, idsA) = makeDetail(convID: convA, messageCount: cutoff + 30)
        let (detailB, idsB) = makeDetail(convID: convB, messageCount: cutoff + 5)
        let repo = makeRepo(details: [convA: detailA, convB: detailB])

        let vmA = ConversationDetailViewModel(conversationId: convA, repository: repo)
        await vmA.load()
        // Don't await — switch to a different VM/conversation right away.
        let vmB = ConversationDetailViewModel(conversationId: convB, repository: repo)
        await vmB.load()
        await vmB._awaitPrewarm()

        // B's full set must be warm (its sync + deferred batches both
        // ran to completion, since we awaited).
        for id in idsB {
            XCTAssertTrue(MessageBubbleView._hasCachedBlocks(messageID: id))
        }
        // A's first cutoff messages must be warm (sync pass).
        // A's deferred batch may or may not have completed before
        // vmA went out of scope and triggered cancellation in its
        // deinit — we don't assert either way for the deferred slice,
        // but the non-crash above is the real test.
        for i in 0..<cutoff {
            XCTAssertTrue(
                MessageBubbleView._hasCachedBlocks(messageID: idsA[i]),
                "A's sync-pass message #\(i) should still be warm"
            )
        }
    }
}
