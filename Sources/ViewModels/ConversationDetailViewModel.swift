// ViewModels/ConversationDetailViewModel.swift
//
// 個別会話の詳細表示に関する UI 状態を管理する。

import Observation

@MainActor
@Observable
final class ConversationDetailViewModel {
    var detail: ConversationDetail?
    var isLoading: Bool = false
    var errorText: String?

    private let repository: any ConversationRepository
    let conversationId: String

    init(conversationId: String, repository: any ConversationRepository) {
        self.conversationId = conversationId
        self.repository = repository
    }

    func load() async {
        isLoading = true
        errorText = nil
        defer { isLoading = false }

        do {
            detail = try await repository.fetchDetail(id: conversationId)
        } catch {
            detail = nil
            errorText = error.localizedDescription
            print("Failed to load detail: \(error)")
        }
    }
}
