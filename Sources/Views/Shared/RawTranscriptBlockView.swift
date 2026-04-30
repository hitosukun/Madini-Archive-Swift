import SwiftUI

/// Renders a single `ConversationTranscriptBlock`. Pulled out of
/// `RawTranscriptReaderView` so each block type stays small and the reader
/// stays focused on message-level composition.
struct RawTranscriptBlockView: View {
    let block: ConversationTranscriptBlock
    let snapshotID: Int64
    let vault: any RawExportVault
    let resolver: any RawAssetResolver

    var body: some View {
        switch block {
        case .text(let string):
            Text(string)
                .textSelection(.enabled)
                .frame(maxWidth: .infinity, alignment: .leading)
        case .code(let language, let source):
            codeBlock(language: language, source: source)
        case .image(let reference):
            RawTranscriptImageView(
                reference: reference,
                snapshotID: snapshotID,
                vault: vault,
                resolver: resolver
            )
        case .attachment(let reference, let name, let sizeBytes):
            attachmentRow(reference: reference, name: name, sizeBytes: sizeBytes)
        case .toolUse(let name, let inputJSON):
            toolUseBlock(name: name, inputJSON: inputJSON)
        case .toolResult(let text):
            toolResultBlock(text)
        case .artifact(_, let title, let kind, let content):
            artifactBlock(title: title, kind: kind, content: content)
        case .unsupported(let summary):
            unsupportedBlock(summary)
        }
    }

    // MARK: - Block renderers

    private func codeBlock(language: String?, source: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            if let language, !language.isEmpty {
                Text(language)
                    .font(.caption2.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(source)
                .font(.system(.callout, design: .monospaced))
                .textSelection(.enabled)
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.primary.opacity(0.05))
                )
        }
    }

    private func attachmentRow(
        reference: AssetReference,
        name: String?,
        sizeBytes: Int64?
    ) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "paperclip")
                .foregroundStyle(.secondary)
            VStack(alignment: .leading, spacing: 2) {
                Text(name ?? reference.reference)
                    .font(.callout.weight(.medium))
                    .lineLimit(1)
                    .truncationMode(.middle)
                if let sizeBytes {
                    Text(Self.formatBytes(sizeBytes))
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
        }
        .padding(8)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    private func toolUseBlock(name: String, inputJSON: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "wrench.and.screwdriver")
                    .foregroundStyle(.orange)
                Text("tool: \(name)")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            if !inputJSON.isEmpty {
                Text(inputJSON)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.orange.opacity(0.08))
                    )
            }
        }
    }

    private func toolResultBlock(_ text: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "terminal")
                    .foregroundStyle(.orange)
                Text("tool result")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            Text(text)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .padding(8)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(
                    RoundedRectangle(cornerRadius: 6)
                        .fill(Color.orange.opacity(0.06))
                )
        }
    }

    private func artifactBlock(title: String?, kind: String?, content: String) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "square.stack.3d.up")
                    .foregroundStyle(.purple)
                Text(title ?? "Artifact")
                    .font(.subheadline.weight(.medium))
                if let kind, !kind.isEmpty {
                    Text(kind)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            if !content.isEmpty {
                Text(content)
                    .font(.system(.caption, design: .monospaced))
                    .textSelection(.enabled)
                    .padding(8)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.purple.opacity(0.08))
                    )
            }
        }
    }

    private func unsupportedBlock(_ summary: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.circle")
                .foregroundStyle(.secondary)
            Text("omitted: \(summary)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .italic()
        }
        .padding(.vertical, 4)
    }

    // MARK: - Utilities

    private static func formatBytes(_ bytes: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: bytes, countStyle: .file)
    }
}
