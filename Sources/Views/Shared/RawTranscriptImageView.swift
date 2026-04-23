import SwiftUI
#if os(macOS)
import AppKit
#elseif os(iOS)
import UIKit
#endif

/// Lazily resolves an image `AssetReference` against the Raw Export Vault and
/// renders the decoded bitmap. Runs the resolver + blob load off the main
/// actor, and degrades to a labelled placeholder when the reference can't be
/// matched or the bytes don't decode as an image.
///
/// Caching is intentionally NOT done here — the enclosing `LazyVStack` only
/// materializes visible cells, so the same image view won't be asked to load
/// twice in a scroll session. If thrashing shows up in real use, add a small
/// LRU keyed on `(snapshotID, reference)` at the service layer.
struct RawTranscriptImageView: View {
    let reference: AssetReference
    let snapshotID: Int64
    let vault: any RawExportVault
    let resolver: any RawAssetResolver

    @State private var state: LoadState = .idle

    var body: some View {
        Group {
            switch state {
            case .idle, .loading:
                placeholder(systemImage: "photo", label: "Loading image…")
            case .missing:
                placeholder(systemImage: "photo.badge.exclamationmark", label: "Image not vaulted")
            case .failed(let message):
                placeholder(systemImage: "xmark.octagon", label: message)
            case .loaded(let image):
                imageView(image)
            }
        }
        .task(id: taskKey) {
            await load()
        }
    }

    private var taskKey: String {
        "\(snapshotID):\(reference.reference)"
    }

    // MARK: - Rendering

    @ViewBuilder
    private func imageView(_ image: CrossPlatformImage) -> some View {
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 480)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        #else
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity, maxHeight: 480)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        #endif
    }

    private func placeholder(systemImage: String, label: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: systemImage)
                .foregroundStyle(.secondary)
            Text(label)
                .font(.caption)
                .foregroundStyle(.secondary)
            Text(reference.reference)
                .font(.caption2.monospaced())
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(
            RoundedRectangle(cornerRadius: 6)
                .fill(Color.primary.opacity(0.04))
        )
    }

    // MARK: - Loading

    private enum LoadState {
        case idle
        case loading
        case missing
        case failed(String)
        case loaded(CrossPlatformImage)
    }

    private func load() async {
        state = .loading
        let snapshotID = self.snapshotID
        let resolver = self.resolver
        let vault = self.vault
        let reference = self.reference.reference

        do {
            guard let hit = try await resolver.resolveAsset(
                snapshotID: snapshotID,
                reference: reference
            ) else {
                state = .missing
                return
            }
            let bytes = try await vault.loadBlob(hash: hit.blobHash)
            if let image = Self.decode(bytes) {
                state = .loaded(image)
            } else {
                state = .failed("Couldn't decode image bytes")
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    private static func decode(_ data: Data) -> CrossPlatformImage? {
        #if os(macOS)
        return NSImage(data: data)
        #elseif os(iOS)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }
}
