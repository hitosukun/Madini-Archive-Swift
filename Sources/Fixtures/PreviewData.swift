// Fixtures/PreviewData.swift
//
// SwiftUI Preview 用のサンプルデータ。

import Foundation

enum PreviewData {

    static let conversations: [ConversationSummary] = [
        ConversationSummary(
            id: "conv-001",
            headline: .build(
                prompt: "SwiftUI の NavigationSplitView で sidebar / detail 構成を作るとき、選択状態はどう管理すべき？",
                title: "SwiftUI の NavigationSplitView について",
                firstMessage: nil
            ),
            source: "ChatGPT",
            title: "SwiftUI の NavigationSplitView について",
            model: "gpt-4o",
            messageCount: 12,
            primaryTime: "2025-03-15",
            isBookmarked: true
        ),
        ConversationSummary(
            id: "conv-002",
            headline: .build(
                prompt: "Rust の所有権って結局どう覚えるのがいい？",
                title: "Rust の所有権システムを理解する",
                firstMessage: nil
            ),
            source: "Claude",
            title: "Rust の所有権システムを理解する",
            model: "claude-3.5-sonnet",
            messageCount: 8,
            primaryTime: "2025-03-10",
            isBookmarked: false
        ),
        ConversationSummary(
            id: "conv-003",
            headline: .build(
                prompt: "量子コンピューティングの基礎をあとで読み返しやすい形で整理して",
                title: "量子コンピューティングの基礎",
                firstMessage: nil
            ),
            source: "Gemini",
            title: "量子コンピューティングの基礎",
            model: "gemini-1.5-pro",
            messageCount: 6,
            primaryTime: "2025-02-28",
            isBookmarked: false
        ),
        ConversationSummary(
            id: "conv-004",
            headline: .build(
                prompt: "Python の decorator パターンを、あとで archive で見返しやすいように例付きで残したい",
                title: "Python のデコレータパターン",
                firstMessage: nil
            ),
            source: "ChatGPT",
            title: "Python のデコレータパターン",
            model: "gpt-4o-mini",
            messageCount: 4,
            primaryTime: "2025-02-20",
            isBookmarked: false
        ),
        ConversationSummary(
            id: "conv-005",
            headline: .build(
                prompt: nil,
                title: nil,
                firstMessage: "タイトルが空でも、最初のメッセージ断片が headline fallback になるようにしておきたい"
            ),
            source: "Claude",
            title: nil,
            model: "claude-3-opus",
            messageCount: 22,
            primaryTime: "2025-01-15",
            isBookmarked: true
        ),
    ]

    static let messages: [Message] = [
        Message(
            id: "msg-001",
            role: .user,
            content: "SwiftUI の NavigationSplitView で sidebar / detail 構成を作るとき、選択状態はどう管理すべき？"
        ),
        Message(
            id: "msg-002",
            role: .assistant,
            content: """
            `NavigationSplitView` では、選択状態を `@State` で管理するのが基本です。

            ```swift
            @State private var selectedId: String?

            NavigationSplitView {
                List(items, selection: $selectedId) { item in
                    Text(item.name).tag(item.id)
                }
            } detail: {
                if let id = selectedId {
                    DetailView(id: id)
                }
            }
            ```

            ポイント:
            - `selection` は `Binding<String?>` で渡す
            - 各行に `.tag()` を付ける
            - detail 側で `nil` チェックして空状態を表示
            """
        ),
        Message(
            id: "msg-003",
            role: .user,
            content: "ありがとう。ViewModel に切り出すときはどうする？"
        ),
        Message(
            id: "msg-004",
            role: .assistant,
            content: """
            `@Observable` を使うと自然に切り出せます:

            ```swift
            @Observable
            class SidebarViewModel {
                var selectedId: String?
                var items: [Item] = []

                func load() async {
                    items = try await repository.fetchAll()
                }
            }
            ```

            View 側では `@State` で ViewModel を保持し、`selectedId` をバインドします。
            """
        ),
    ]

    static let detail = ConversationDetail(summary: conversations[0], messages: messages)

    static let secondDetail = ConversationDetail(
        summary: conversations[1],
        messages: [
            Message(id: "msg-005", role: .user, content: "Rust の所有権って結局どう覚えるのがいい？"),
            Message(id: "msg-006", role: .assistant, content: "まずは `move`, `borrow`, `mutable borrow` の 3 つを、値の所有者が誰かという視点で読むと掴みやすいよ。")
        ]
    )

    static let details: [String: ConversationDetail] = [
        "conv-001": detail,
        "conv-002": secondDetail,
    ]
}
