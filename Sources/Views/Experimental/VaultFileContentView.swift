import Foundation
import SwiftUI

/// Phase D2 content pane for the Vault Browser.
///
/// Given a selected file entry + an optional payload, this view decides how
/// to render the bytes: monospaced plain text, pretty-printed JSON, or a
/// minimal "this is a binary blob" placeholder. No writer actions yet —
/// exporting a blob to disk needs explicit user permission and is deferred
/// past D2.
struct VaultFileContentView: View {
    let entry: RawExportFileEntry
    let payload: RawExportFilePayload?
    let state: VaultBrowserViewModel.LoadState
    let onRetry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal)
                .padding(.vertical, 8)
                .background(.thinMaterial)
            Divider()
            body(for: state, payload: payload)
        }
    }

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(entry.relativePath)
                .font(.headline.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                Text("\(entry.role)")
                Text(Self.byteString(entry.sizeBytes))
                if entry.compression != "none" {
                    Text("\(entry.compression) · \(Self.byteString(entry.storedSizeBytes)) on disk")
                }
                if let mime = entry.mimeType {
                    Text(mime)
                }
                Spacer(minLength: 0)
                Text("sha256: \(entry.blobHash.prefix(12))…")
                    .foregroundStyle(.tertiary)
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
    }

    @ViewBuilder
    private func body(for state: VaultBrowserViewModel.LoadState, payload: RawExportFilePayload?) -> some View {
        switch state {
        case .idle, .loading:
            VStack(spacing: 12) {
                Spacer()
                ProgressView(state == .loading ? "Restoring…" : "Preparing…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .failed(let message):
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "Couldn't restore this file",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                Button("Retry", action: onRetry)
                    .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

        case .loaded:
            if let payload {
                rendered(payload)
            } else {
                ContentUnavailableView(
                    "No payload",
                    systemImage: "doc",
                    description: Text("The vault returned an empty payload for this file.")
                )
            }
        }
    }

    @ViewBuilder
    private func rendered(_ payload: RawExportFilePayload) -> some View {
        if let text = Self.textRepresentation(for: payload) {
            ScrollView([.vertical, .horizontal]) {
                Text(text)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding()
            }
        } else {
            binaryPlaceholder(for: payload)
        }
    }

    private func binaryPlaceholder(for payload: RawExportFilePayload) -> some View {
        VStack(spacing: 12) {
            Image(systemName: "shippingbox")
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text("Binary file")
                .font(.headline)
            Text("\(Self.byteString(payload.entry.sizeBytes)) · \(payload.entry.mimeType ?? "application/octet-stream")")
                .font(.caption)
                .foregroundStyle(.secondary)
            Text("Preview isn't available yet. Asset viewers land in D3.")
                .font(.caption)
                .foregroundStyle(.tertiary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding()
    }

    // MARK: - Text detection + pretty print

    /// Returns a printable string for the payload, or `nil` if the bytes look
    /// binary. Tries JSON pretty-printing first for JSON roles / MIME, then
    /// falls back to raw UTF-8.
    static func textRepresentation(for payload: RawExportFilePayload) -> String? {
        let entry = payload.entry
        // Never try to decode huge blobs as text — the SwiftUI `Text` wrap
        // cost dominates well before we hit interesting content.
        guard entry.sizeBytes <= 10_000_000 else { return nil }

        let looksJSON = entry.mimeType == "application/json"
            || entry.relativePath.lowercased().hasSuffix(".json")
            || entry.role == "manifest"
        if looksJSON, let pretty = prettyPrintedJSON(payload.data) {
            return pretty
        }

        let looksTextual = (entry.mimeType?.hasPrefix("text/") == true)
            || entry.role == "conversation"
            || entry.role == "metadata"
            || entry.role == "manifest"
            || Self.textExtensions.contains(URL(fileURLWithPath: entry.relativePath).pathExtension.lowercased())
        guard looksTextual else { return nil }

        return String(data: payload.data, encoding: .utf8)
    }

    private static let textExtensions: Set<String> = [
        "txt", "md", "csv", "xml", "html", "htm", "log", "yaml", "yml"
    ]

    private static func prettyPrintedJSON(_ data: Data) -> String? {
        guard let object = try? JSONSerialization.jsonObject(with: data, options: [.fragmentsAllowed]) else {
            return nil
        }
        let encoded = try? JSONSerialization.data(
            withJSONObject: object,
            options: [.prettyPrinted, .sortedKeys]
        )
        return encoded.flatMap { String(data: $0, encoding: .utf8) }
    }

    private static let byteFormatter: ByteCountFormatter = {
        let formatter = ByteCountFormatter()
        formatter.countStyle = .file
        formatter.allowsNonnumericFormatting = false
        return formatter
    }()

    private static func byteString(_ bytes: Int64) -> String {
        byteFormatter.string(fromByteCount: bytes)
    }
}
