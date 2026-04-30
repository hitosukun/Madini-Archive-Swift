import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Phase D2: rich-content reader backed by the provider's original JSON in
/// the Raw Export Vault. The canonical `ConversationDetailView` renders the
/// Python-imported text-only projection; this view adds inline images,
/// attachments, code blocks, tool calls, and artifacts by reading the source
/// JSON on demand via `RawConversationLoader`.
///
/// Scope for this first pass:
///   - Text, code, and inline images render fully
///   - Tool use / result / artifact / attachment render as labelled cards
///   - Unsupported content types render as muted placeholders
struct RawTranscriptReaderView: View {
    let conversationID: String
    let loader: any RawConversationLoader
    let vault: any RawExportVault
    let resolver: any RawAssetResolver

    @State private var state: LoadState = .idle

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                ProgressView()
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                ContentUnavailableView(
                    "Source unavailable",
                    systemImage: "xmark.octagon",
                    description: Text(message)
                )
            case .notFound:
                ContentUnavailableView(
                    "No vaulted source",
                    systemImage: "tray",
                    description: Text("This conversation has no matching snapshot in the Raw Export Vault. Re-import the provider export to see the original JSON here.")
                )
            case .unsupported:
                ContentUnavailableView(
                    "Provider not supported",
                    systemImage: "questionmark.folder",
                    description: Text("Source view is only available for ChatGPT and Claude exports.")
                )
            case .loaded(let transcript):
                transcriptBody(transcript)
            }
        }
        .task(id: conversationID) {
            await load()
        }
    }

    // MARK: - Loading

    private enum LoadState {
        case idle
        case loading
        case loaded(ConversationTranscript)
        case notFound
        case unsupported
        case failed(String)
    }

    private func load() async {
        state = .loading
        do {
            guard let rawJSON = try await loader.loadRawJSON(conversationID: conversationID) else {
                state = .notFound
                return
            }
            do {
                let transcript = try ConversationTranscriptExtractor.extract(from: rawJSON)
                state = .loaded(transcript)
            } catch ConversationTranscriptExtractor.Error.unsupportedProvider {
                state = .unsupported
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    // MARK: - Transcript layout

    @ViewBuilder
    private func transcriptBody(_ transcript: ConversationTranscript) -> some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: 16) {
                headerRow(transcript)
                Divider()
                ForEach(transcript.messages) { message in
                    messageCard(message, snapshotID: transcript.snapshotID)
                }
                if transcript.messages.isEmpty {
                    Text("No renderable messages in this transcript.")
                        .foregroundStyle(.secondary)
                        .padding(.vertical, 24)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func headerRow(_ transcript: ConversationTranscript) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let title = transcript.title, !title.isEmpty {
                Text(title)
                    .font(.title2.weight(.semibold))
            } else {
                Text("Untitled conversation")
                    .font(.title2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            HStack(spacing: 8) {
                Label(transcript.provider.rawValue, systemImage: "shippingbox")
                    .labelStyle(.titleAndIcon)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let createdAt = transcript.createdAt {
                    Text("· started \(createdAt, style: .date)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("· \(transcript.messages.count) messages")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(transcript.sourceRelativePath)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .textSelection(.enabled)
        }
    }

    @ViewBuilder
    private func messageCard(
        _ message: ConversationTranscriptMessage,
        snapshotID: Int64
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 8) {
                Image(systemName: roleIcon(message.role))
                    .foregroundStyle(roleColor(message.role))
                Text(roleLabel(message.role))
                    .font(.subheadline.weight(.semibold))
                if let model = message.model {
                    Text(model)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                if let createdAt = message.createdAt {
                    Text(createdAt, style: .time)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            ForEach(Array(message.blocks.enumerated()), id: \.offset) { _, block in
                RawTranscriptBlockView(
                    block: block,
                    snapshotID: snapshotID,
                    vault: vault,
                    resolver: resolver
                )
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(roleBackground(message.role))
        )
    }

    private func roleIcon(_ role: ConversationTranscriptMessage.Role) -> String {
        switch role {
        case .user: return "person.circle.fill"
        case .assistant: return "sparkles"
        case .system: return "gearshape"
        case .tool: return "wrench.and.screwdriver"
        case .unknown: return "questionmark.circle"
        }
    }

    private func roleLabel(_ role: ConversationTranscriptMessage.Role) -> String {
        switch role {
        case .user: return "User"
        case .assistant: return "Assistant"
        case .system: return "System"
        case .tool: return "Tool"
        case .unknown: return "Unknown"
        }
    }

    private func roleColor(_ role: ConversationTranscriptMessage.Role) -> Color {
        switch role {
        case .user: return .accentColor
        case .assistant: return .purple
        case .system: return .gray
        case .tool: return .orange
        case .unknown: return .secondary
        }
    }

    private func roleBackground(_ role: ConversationTranscriptMessage.Role) -> Color {
        switch role {
        case .user: return Color.accentColor.opacity(0.06)
        case .assistant: return Color.purple.opacity(0.05)
        case .system, .unknown: return Color.secondary.opacity(0.05)
        case .tool: return Color.orange.opacity(0.05)
        }
    }
}
