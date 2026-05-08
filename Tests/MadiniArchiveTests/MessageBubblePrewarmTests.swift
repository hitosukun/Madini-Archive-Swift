import XCTest
@testable import MadiniArchive

/// Coverage for the Phase 3b `MessageBubbleView.prewarmCache(for:)`
/// public API. The companion `_hasCachedBlocks(messageID:)` test hook
/// is the only way to introspect cache state from outside the view.
final class MessageBubblePrewarmTests: XCTestCase {
    private func makeMessage(id: String, content: String) -> Message {
        Message(id: id, role: .user, content: content)
    }

    func testPrewarmPopulatesCacheForUncachedMessage() {
        let id = "prewarm-test-\(UUID().uuidString)"
        let msg = makeMessage(id: id, content: "Hello\n\nworld\n")
        XCTAssertFalse(MessageBubbleView._hasCachedBlocks(messageID: id))
        MessageBubbleView.prewarmCache(for: msg)
        XCTAssertTrue(MessageBubbleView._hasCachedBlocks(messageID: id))
    }

    func testPrewarmIsIdempotent() {
        // Calling prewarm twice on the same message is harmless and
        // doesn't crash — the second call should observe the cache hit
        // and early-return.
        let id = "prewarm-idem-\(UUID().uuidString)"
        let msg = makeMessage(id: id, content: "Same content")
        MessageBubbleView.prewarmCache(for: msg)
        MessageBubbleView.prewarmCache(for: msg)
        XCTAssertTrue(MessageBubbleView._hasCachedBlocks(messageID: id))
    }

    func testPrewarmSkipsOversizedMessages() {
        // Messages over Layout.maxRenderedMessageLength (20_000) get
        // short-circuited in `canRenderMessage`, so caching the parse
        // would be wasted budget. The prewarm path mirrors that gate.
        let id = "prewarm-oversize-\(UUID().uuidString)"
        let huge = String(repeating: "a", count: 25_000)
        let msg = makeMessage(id: id, content: huge)
        MessageBubbleView.prewarmCache(for: msg)
        XCTAssertFalse(MessageBubbleView._hasCachedBlocks(messageID: id))
    }

    func testPrewarmHandlesEmptyContent() {
        // Pathological but possible (malformed import row). Parse
        // returns an empty block list; that's fine to cache.
        let id = "prewarm-empty-\(UUID().uuidString)"
        let msg = makeMessage(id: id, content: "")
        MessageBubbleView.prewarmCache(for: msg)
        XCTAssertTrue(MessageBubbleView._hasCachedBlocks(messageID: id))
    }

    func testPrewarmIsCallableFromBackgroundQueue() async {
        // Decision B-1 puts the deferred batch on
        // `Task.detached(priority: .userInitiated)`. Verify the API
        // doesn't trip @MainActor isolation when called off the main
        // thread.
        let id = "prewarm-bg-\(UUID().uuidString)"
        let msg = makeMessage(id: id, content: "Background prewarm test")
        await Task.detached(priority: .userInitiated) {
            MessageBubbleView.prewarmCache(for: msg)
        }.value
        XCTAssertTrue(MessageBubbleView._hasCachedBlocks(messageID: id))
    }
}
