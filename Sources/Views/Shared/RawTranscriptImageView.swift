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
/// ## Caching and layout stability
///
/// `LazyVStack` tears down cells when they leave the viewport and rebuilds
/// them on return, which would otherwise re-run the resolver + blob load and
/// re-paint the placeholder → image transition every time the user scrolls
/// past. That caused a "can't scroll up" symptom: the growing cell kept
/// pushing content around as the user tried to scroll back, so the viewport
/// never settled. We defend on two fronts:
///
/// 1. `RawTranscriptImageCache` memoizes decoded bitmaps keyed by
///    `(snapshotID, reference)`, so a re-materialized cell snaps back to the
///    loaded state on the first frame.
/// 2. The placeholder and loaded image both reserve the same vertical band
///    (`reservedHeight`). Layout doesn't jump when a cell flips from loading
///    to loaded, which keeps the ScrollView's content extent stable and
///    upward scrolling behaves normally.
struct RawTranscriptImageView: View {
    let reference: AssetReference
    let snapshotID: Int64
    let vault: any RawExportVault
    let resolver: any RawAssetResolver

    @State private var state: LoadState = .idle

    /// Vertical band reserved for both the placeholder and the loaded image.
    /// Sized to be tall enough that most images don't get clamped below
    /// their natural aspect, and short enough that a conversation with
    /// many attachments doesn't feel like wading through giant hero shots.
    private static let reservedHeight: CGFloat = 320

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
        // Match the placeholder's reserved band exactly so the cell
        // height doesn't change when the async load resolves. Without
        // the fixed `height` (we used `maxHeight` before), a tall
        // portrait image would grow from ~40pt placeholder → 480pt,
        // pushing content around and destabilizing upward scrolling in
        // the enclosing LazyVStack.
        #if os(macOS)
        Image(nsImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(height: Self.reservedHeight)
            .clipShape(RoundedRectangle(cornerRadius: 8))
        #else
        Image(uiImage: image)
            .resizable()
            .scaledToFit()
            .frame(maxWidth: .infinity)
            .frame(height: Self.reservedHeight)
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
        // Reserve the same vertical band as the loaded image so the
        // cell doesn't resize on load-complete. `maxWidth: .infinity`
        // lets the card span the bubble width; `height` (not min/max)
        // pins the band exactly.
        .frame(maxWidth: .infinity, alignment: .leading)
        .frame(height: Self.reservedHeight)
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
        // Cache check first: when `LazyVStack` re-materializes a cell
        // the user previously scrolled past, we want the image back on
        // screen on the very next frame rather than cycling through
        // placeholder → re-resolve → re-decode. Skipping the resolve
        // and blob IO here is what makes upward scrolling feel solid.
        let cacheKey = taskKey
        if let cached = RawTranscriptImageCache.get(cacheKey) {
            state = .loaded(cached)
            return
        }

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
                RawTranscriptImageCache.set(cacheKey, image: image)
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

/// Process-wide LRU for decoded transcript image bitmaps, keyed by
/// `"<snapshotID>:<reference>"`. Exists because SwiftUI's `LazyVStack`
/// recycles cells on scroll — without this, every upward scroll would
/// thrash the resolver, re-read the blob, and re-decode the image, and
/// the cell would flip back to its placeholder for a frame each time
/// (visible as content-height chatter that prevents the user from
/// scrolling back to the top). The cache is `@MainActor`-isolated so
/// reads from the view's `load()` don't need locking.
///
/// The eviction bound (`maxEntries`) is intentionally generous: a
/// single ChatGPT conversation with a few dozen attachments fits
/// easily, and NSImage / UIImage hold CGImage backings that are cheap
/// in memory terms compared to the deltas in scroll feel. If a user
/// opens many image-heavy conversations in one session we drop the
/// oldest entries first.
@MainActor
enum RawTranscriptImageCache {
    private static let maxEntries: Int = 200
    private static var storage: [String: CrossPlatformImage] = [:]
    // Insertion-order list used as an LRU. We move keys to the end on
    // read so recently-viewed images survive eviction longer than
    // once-seen ones.
    private static var order: [String] = []

    static func get(_ key: String) -> CrossPlatformImage? {
        guard let image = storage[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return image
    }

    static func set(_ key: String, image: CrossPlatformImage) {
        if storage[key] == nil {
            order.append(key)
        } else if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        storage[key] = image
        while order.count > maxEntries {
            let evict = order.removeFirst()
            storage.removeValue(forKey: evict)
        }
    }
}
