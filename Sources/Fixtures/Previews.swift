// Fixtures/Previews.swift
//
// Xcode Preview 用コード。
// SPM CLI ビルド (`swift build`) では #Preview マクロが使えないため、
// Xcode 上でのみ有効。CLI ビルドでは canImport チェックでスキップされる。
//
// 使い方: Xcode で Package.swift を開き、Previews.swift のプレビューを実行する。

#if canImport(SwiftUI) && DEBUG

import SwiftUI

// Note: #Preview macros require Xcode's PreviewsMacros plugin.
// They compile in Xcode but cause errors in `swift build`.
// If CLI build fails on this file, wrap contents in:
//   #if canImport(PreviewsMacros)
//   ...
//   #endif
// For now, this file serves as documentation of available previews.

// Available previews (use Xcode Canvas):
//
// 1. RootView — full app with mock data
//    RootView().environmentObject(AppServices())
//
// 2. MacOSRootView — browse/search shell
//    MacOSRootView(services: AppServices())
//
// 3. ConversationRowView — single row
//    List(PreviewData.conversations) { conv in
//        ConversationRowView(conversation: conv)
//    }
//
// 4. ConversationDetailView — detail pane
//    ConversationDetailView(conversationId: "conv-001",
//                           repository: MockConversationRepository())
//
// 5. MessageBubbleView — message display
//    VStack { ForEach(PreviewData.messages) { MessageBubbleView(message: $0) } }

#endif
