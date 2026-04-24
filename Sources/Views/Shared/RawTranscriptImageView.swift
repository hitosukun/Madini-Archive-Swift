import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
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
///
/// ## Interaction
///
/// Tapping an in-line image opens a standalone resizable NSWindow with the
/// Copy / Save / Share actions bound into its titlebar toolbar; right-
/// clicking surfaces the same actions as a context menu without needing the
/// window. Share uses the native macOS sharing service picker — the same
/// mechanism that backs the reader's toolbar share button — and Save
/// materializes the ORIGINAL vaulted bytes rather than the decoded bitmap
/// so no fidelity is lost (DALL-E webps stay as webps, HEIC uploads stay
/// as HEIC).
///
/// The preview is an `NSWindow` (not a SwiftUI sheet) because sheets on
/// macOS are modal to their parent window and can't be resized, minimized,
/// or taken into native full-screen independently. A plain NSWindow gives
/// the user the full traffic-light chrome — including the green full-screen
/// button — plus native resize and a real titlebar toolbar.
///
/// When `orderedReferences` is non-empty the preview window treats the
/// passed list as a gallery: left/right arrow keys navigate between images
/// without closing / reopening the window, re-using the same NSWindow,
/// toolbar, and SwiftUI state. `globalIndex` tells the window which image
/// was clicked so duplicate references still land the user on the exact
/// occurrence they tapped.
struct RawTranscriptImageView: View {
    let reference: AssetReference
    let snapshotID: Int64
    let vault: any RawExportVault
    let resolver: any RawAssetResolver
    /// Position of `reference` inside `orderedReferences`. Ignored when
    /// `orderedReferences` is empty (e.g. the raw transcript reader,
    /// which renders images block-by-block without a conversation-wide
    /// list). Defaults to 0 so callers that don't care don't have to
    /// pass anything.
    var globalIndex: Int = 0
    /// Conversation-wide reading-order list of every vaulted image.
    /// Empty means "no gallery, just this image" — the preview opens
    /// with the single tapped reference and arrow keys do nothing.
    var orderedReferences: [AssetReference] = []

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
            case .loaded(let resolved):
                imageView(resolved.image)
                    .contentShape(Rectangle())
                    .onTapGesture {
                        openPreview()
                    }
                    .contextMenu {
                        ImageActionButtons(
                            resolved: resolved,
                            vault: vault
                        )
                    }
                    .help("クリックで拡大表示")
            }
        }
        .task(id: taskKey) {
            await load()
        }
    }

    private var taskKey: String {
        "\(snapshotID):\(reference.reference)"
    }

    /// Open (or focus + navigate) the standalone preview window for this
    /// snapshot. If the caller supplied a gallery list we pass that
    /// along so the window's arrow-key navigation can span the whole
    /// conversation; otherwise we synthesize a single-entry gallery so
    /// the window code only has one code path for "current image".
    private func openPreview() {
        #if os(macOS)
        let gallery = orderedReferences.isEmpty ? [reference] : orderedReferences
        let clampedIndex: Int
        if orderedReferences.isEmpty {
            clampedIndex = 0
        } else {
            clampedIndex = max(0, min(globalIndex, gallery.count - 1))
        }
        ImagePreviewWindow.show(
            snapshotID: snapshotID,
            references: gallery,
            initialIndex: clampedIndex,
            vault: vault,
            resolver: resolver
        )
        #endif
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

    /// Bundle of everything a loaded image needs at rendering time and at
    /// save / share / copy time: the decoded bitmap for in-line display,
    /// plus the blob hash and vaulted path so the action handlers can
    /// re-fetch the ORIGINAL bytes without re-running the resolver.
    /// Caching this struct instead of the bare image means a cell
    /// re-materialized from the LRU still supports Save / Share without
    /// another database round-trip.
    struct Resolved {
        let image: CrossPlatformImage
        let blobHash: String
        let assetRelativePath: String
        let mimeType: String?
    }

    enum LoadState {
        case idle
        case loading
        case missing
        case failed(String)
        case loaded(Resolved)
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
                let resolved = Resolved(
                    image: image,
                    blobHash: hit.blobHash,
                    assetRelativePath: hit.assetRelativePath,
                    mimeType: hit.mimeType
                )
                RawTranscriptImageCache.set(cacheKey, resolved: resolved)
                state = .loaded(resolved)
            } else {
                state = .failed("Couldn't decode image bytes")
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    static func decode(_ data: Data) -> CrossPlatformImage? {
        #if os(macOS)
        return NSImage(data: data)
        #elseif os(iOS)
        return UIImage(data: data)
        #else
        return nil
        #endif
    }
}

// MARK: - Preview window model

#if os(macOS)
/// Drives the preview window's SwiftUI state. Observable so the SwiftUI
/// body reacts to both in-window navigation (arrow keys) and external
/// navigation (clicking another image in the conversation reuses the
/// open window and bumps `currentIndex` here).
///
/// Kept separate from `ImagePreviewWindow` (the AppKit plumbing) so the
/// SwiftUI side doesn't have to reach into NSWindow internals and vice-
/// versa — they interact through this model.
@MainActor
@Observable
final class ImagePreviewModel {
    var references: [AssetReference]
    var currentIndex: Int
    let snapshotID: Int64
    let vault: any RawExportVault
    let resolver: any RawAssetResolver

    init(
        references: [AssetReference],
        currentIndex: Int,
        snapshotID: Int64,
        vault: any RawExportVault,
        resolver: any RawAssetResolver
    ) {
        self.references = references
        self.currentIndex = currentIndex
        self.snapshotID = snapshotID
        self.vault = vault
        self.resolver = resolver
    }

    /// `currentIndex - 1` clamped to the list. Returns the same index
    /// when already at the first image so the view can disable a
    /// "previous" control without branching on emptiness.
    var canGoPrevious: Bool { currentIndex > 0 }
    var canGoNext: Bool { currentIndex < references.count - 1 }

    func goPrevious() {
        guard canGoPrevious else { return }
        currentIndex -= 1
    }

    func goNext() {
        guard canGoNext else { return }
        currentIndex += 1
    }

    var currentReference: AssetReference {
        references[currentIndex]
    }
}
#endif

// MARK: - Preview window content

#if os(macOS)
/// SwiftUI body hosted inside `ImagePreviewWindow`. The view itself has
/// no sizing preference — the NSWindow owns the frame, so native resize
/// and full-screen just work. Copy / Save / Share live in the NSWindow's
/// titlebar toolbar (wired up by `ImagePreviewWindow`), so this body
/// concentrates on the image and keyboard navigation.
private struct ImagePreviewWindowContent: View {
    @Bindable var model: ImagePreviewModel
    /// Hook the model's `Resolved` state up for the titlebar toolbar
    /// buttons. The window-level toolbar lives in AppKit-land and
    /// reads the current resolved value through this holder so Copy /
    /// Save / Share always operate on the image currently on screen.
    let resolvedHolder: ImagePreviewResolvedHolder
    /// Closure the content view calls to update the NSWindow's title
    /// whenever the current image changes — lets the window stay in
    /// sync without the content view having to reach into AppKit.
    let updateWindowTitle: (String) -> Void

    @State private var state: RawTranscriptImageView.LoadState = .idle
    @State private var isHoveringNav: Bool = false
    @FocusState private var focused: Bool

    var body: some View {
        imageBody
            .focusable()
            .focused($focused)
            .onAppear { focused = true }
            // Track hover at the whole-pane level so the nav chevrons
            // can fade in when the pointer enters anywhere on the
            // image and fade out when it leaves. Using the outer
            // container (instead of `.onHover` on each button) means
            // the chevrons appear as soon as the user's mouse hits
            // the window, not only when they happen to land on one
            // of the button's small hit-targets.
            .onHover { hovering in
                isHoveringNav = hovering
            }
            .onKeyPress(.leftArrow) {
                model.goPrevious()
                return .handled
            }
            .onKeyPress(.rightArrow) {
                model.goNext()
                return .handled
            }
            .task(id: model.currentIndex) {
                await loadCurrent()
            }
            .onChange(of: state) { _, newValue in
                // Propagate loaded state up to the toolbar holder so
                // the NSToolbar's Copy / Save / Share can act on it.
                if case .loaded(let resolved) = newValue {
                    resolvedHolder.resolved = resolved
                    updateWindowTitle(ImageActions.suggestedFilename(for: resolved))
                } else {
                    resolvedHolder.resolved = nil
                }
            }
    }

    @ViewBuilder
    private var imageBody: some View {
        ZStack {
            // Fill with the system window background so letterboxed
            // space around a portrait / wide image reads as "window
            // chrome" rather than a flashy white margin. Adapts to
            // light / dark mode without us hard-coding a color.
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            switch state {
            case .idle, .loading:
                ProgressView()
                    .controlSize(.large)
            case .missing:
                placeholder(systemImage: "photo.badge.exclamationmark", label: "Image not vaulted")
            case .failed(let message):
                placeholder(systemImage: "xmark.octagon", label: message)
            case .loaded(let resolved):
                // No padding — the image extends to the window edges
                // so resizing the window grows the picture, not the
                // surrounding margin. `scaledToFit` still preserves
                // aspect ratio, so portrait / landscape mismatch
                // produces clean letterboxing in the window-
                // background color rather than a white frame.
                Image(nsImage: resolved.image)
                    .resizable()
                    .scaledToFit()
            }
            navigationOverlay
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    /// On-hover nav arrows. Hidden by default so the image gets the
    /// full pane; fade in while the pointer is over the window so
    /// the gallery affordance is still discoverable without
    /// permanent visual weight. Pinned to the window edges (no
    /// surrounding padding) so the chevrons sit in the letterbox
    /// strip rather than biting into the image itself.
    @ViewBuilder
    private var navigationOverlay: some View {
        if model.references.count > 1 {
            HStack(spacing: 0) {
                navButton(systemImage: "chevron.left", enabled: model.canGoPrevious) {
                    model.goPrevious()
                }
                Spacer(minLength: 0)
                navButton(systemImage: "chevron.right", enabled: model.canGoNext) {
                    model.goNext()
                }
            }
            .opacity(isHoveringNav ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHoveringNav)
            // `.allowsHitTesting(false)` while hidden means the
            // chevrons don't steal click-throughs when invisible —
            // the user can still click the image (e.g. to refocus
            // for keyboard navigation) without the hit-test hitting
            // a transparent button first.
            .allowsHitTesting(isHoveringNav)
        }
    }

    private func navButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 0.85 : 0.2)
        .disabled(!enabled)
    }

    private func placeholder(systemImage: String, label: String) -> some View {
        VStack(spacing: 8) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(label)
                .font(.callout)
                .foregroundStyle(.secondary)
        }
    }

    private func loadCurrent() async {
        let reference = model.currentReference
        let taskKey = "\(model.snapshotID):\(reference.reference)"
        if let cached = RawTranscriptImageCache.get(taskKey) {
            state = .loaded(cached)
            return
        }
        state = .loading
        do {
            guard let hit = try await model.resolver.resolveAsset(
                snapshotID: model.snapshotID,
                reference: reference.reference
            ) else {
                state = .missing
                return
            }
            let bytes = try await model.vault.loadBlob(hash: hit.blobHash)
            guard let image = RawTranscriptImageView.decode(bytes) else {
                state = .failed("Couldn't decode image bytes")
                return
            }
            let resolved = RawTranscriptImageView.Resolved(
                image: image,
                blobHash: hit.blobHash,
                assetRelativePath: hit.assetRelativePath,
                mimeType: hit.mimeType
            )
            RawTranscriptImageCache.set(taskKey, resolved: resolved)
            state = .loaded(resolved)
        } catch {
            state = .failed(String(describing: error))
        }
    }
}

/// Equatable conformance so `onChange(of: state)` is happy. We only
/// ever compare "did state change shape?", not deep bitmap equality,
/// so discriminating on the case is sufficient.
extension RawTranscriptImageView.LoadState: Equatable {
    static func == (
        lhs: RawTranscriptImageView.LoadState,
        rhs: RawTranscriptImageView.LoadState
    ) -> Bool {
        switch (lhs, rhs) {
        case (.idle, .idle), (.loading, .loading), (.missing, .missing):
            return true
        case (.failed(let l), .failed(let r)):
            return l == r
        case (.loaded(let l), .loaded(let r)):
            return l.blobHash == r.blobHash
        default:
            return false
        }
    }
}
#endif

// MARK: - Toolbar resolved holder

#if os(macOS)
/// Shared handle that ferries the currently-displayed `Resolved` from
/// the SwiftUI content into the AppKit NSToolbar buttons. The toolbar
/// lives in the window's titlebar and is built by AppKit, so SwiftUI's
/// `.toolbar` modifier isn't an option — we bridge through this class
/// instead. KVO-backed so the toolbar buttons can enable/disable in
/// response to Resolved arriving.
@MainActor
final class ImagePreviewResolvedHolder {
    var resolved: RawTranscriptImageView.Resolved? {
        didSet { onChange?(resolved) }
    }
    var onChange: ((RawTranscriptImageView.Resolved?) -> Void)?
}
#endif

// MARK: - Action buttons (context menu)

/// Shared Copy / Save / Share button row used inside the in-line image's
/// `.contextMenu`. The standalone preview window renders the same actions
/// as NSToolbar buttons rather than using this row, but both code paths
/// funnel into `ImageActions` so behavior stays identical.
private struct ImageActionButtons: View {
    let resolved: RawTranscriptImageView.Resolved
    let vault: any RawExportVault

    var body: some View {
        Button {
            ImageActions.copyToPasteboard(image: resolved.image)
        } label: {
            Label("画像をコピー", systemImage: "doc.on.doc")
        }

        Button {
            Task { await ImageActions.saveToFile(resolved: resolved, vault: vault) }
        } label: {
            Label("画像を保存…", systemImage: "square.and.arrow.down")
        }

        Button {
            Task { await ImageActions.share(resolved: resolved, vault: vault) }
        } label: {
            Label("共有…", systemImage: "square.and.arrow.up")
        }
    }
}

// MARK: - Image action handlers

/// Side-effect helpers behind the Copy / Save / Share buttons. Kept as a
/// separate namespace so the view code stays declarative and the
/// AppKit-heavy bits (NSSavePanel, NSPasteboard, NSSharingServicePicker)
/// live in one place where their `@MainActor` requirements can be made
/// explicit.
@MainActor
enum ImageActions {
    /// Put the decoded bitmap on the general pasteboard. macOS's image
    /// pasteboard handles cross-app paste (Finder, Preview, Messages,
    /// image editors) through NSImage's built-in `NSPasteboardWriting`
    /// conformance, so we don't have to re-encode to a specific format.
    static func copyToPasteboard(image: CrossPlatformImage) {
        #if os(macOS)
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.writeObjects([image])
        #endif
    }

    /// Prompt the user for a destination via `NSSavePanel`, then write
    /// the ORIGINAL vaulted bytes (not the re-encoded bitmap) so a
    /// DALL-E webp saves as a webp, an uploaded HEIC saves as a HEIC,
    /// and EXIF / color profiles survive the round trip. Failures
    /// surface via `NSAlert` rather than silently swallowing — the user
    /// typically only invokes Save deliberately, so eating an error
    /// without explanation is frustrating.
    static func saveToFile(
        resolved: RawTranscriptImageView.Resolved,
        vault: any RawExportVault
    ) async {
        #if os(macOS)
        let panel = NSSavePanel()
        panel.nameFieldStringValue = suggestedFilename(for: resolved)
        panel.canCreateDirectories = true
        if let contentType = contentType(for: resolved) {
            panel.allowedContentTypes = [contentType]
        }
        let response = await panel.beginAsSheetModalAsync()
        guard response == .OK, let url = panel.url else { return }
        do {
            let bytes = try await vault.loadBlob(hash: resolved.blobHash)
            try bytes.write(to: url, options: .atomic)
        } catch {
            presentError(title: "保存に失敗しました", error: error)
        }
        #endif
    }

    /// Materialize the original bytes into a temp file under
    /// `<tmp>/madini-image-share/`, then hand the URL to the native
    /// `NSSharingServicePicker` so AirDrop, Mail, Messages, Notes,
    /// "Save to Files", and any installed share extensions all light
    /// up — the same menu the reader's toolbar Share button shows for
    /// the Markdown export. Writing a file (rather than just the
    /// NSImage) is what unlocks the full picker; passing a raw image
    /// collapses the picker to image-only destinations and loses the
    /// original encoding.
    static func share(
        resolved: RawTranscriptImageView.Resolved,
        vault: any RawExportVault
    ) async {
        #if os(macOS)
        do {
            let bytes = try await vault.loadBlob(hash: resolved.blobHash)
            let url = try writeTempFile(
                bytes: bytes,
                resolved: resolved
            )
            presentSharingPicker(url: url)
        } catch {
            presentError(title: "共有に失敗しました", error: error)
        }
        #endif
    }

    // MARK: - Filename and type derivation

    /// Best-effort user-facing filename. Prefers the vaulted relative
    /// path's last component (which already encodes the original
    /// extension), falling back to a synthesized name keyed on the
    /// blob hash prefix when the relative path is empty (unlinked
    /// assets resolved via the `raw_export_files` fallback).
    static func suggestedFilename(
        for resolved: RawTranscriptImageView.Resolved
    ) -> String {
        let name = (resolved.assetRelativePath as NSString).lastPathComponent
        if !name.isEmpty, name != "/" {
            return name
        }
        let ext = preferredExtension(for: resolved.mimeType) ?? "bin"
        let stem = String(resolved.blobHash.prefix(16))
        return "\(stem).\(ext)"
    }

    #if os(macOS)
    /// UTType matching the resolved image's MIME. Used to constrain
    /// the save panel so the user can't accidentally save a webp as
    /// a png and end up with a mis-typed file on disk. Returns nil
    /// when we don't recognize the MIME, in which case the panel
    /// accepts any extension.
    private static func contentType(
        for resolved: RawTranscriptImageView.Resolved
    ) -> UTType? {
        guard let mime = resolved.mimeType, !mime.isEmpty else { return nil }
        return UTType(mimeType: mime)
    }
    #endif

    /// Map a handful of common image MIMEs to file extensions. We only
    /// bother with the formats ChatGPT / Claude exports actually use
    /// in practice — everything else falls back to `bin`, which is
    /// ugly but loud, signalling that a new format slipped through.
    private static func preferredExtension(for mime: String?) -> String? {
        guard let mime = mime?.lowercased() else { return nil }
        switch mime {
        case "image/jpeg", "image/jpg": return "jpg"
        case "image/png": return "png"
        case "image/webp": return "webp"
        case "image/gif": return "gif"
        case "image/heic": return "heic"
        case "image/heif": return "heif"
        default: return nil
        }
    }

    #if os(macOS)
    /// Write `bytes` to a stable temp location whose filename matches
    /// what the user would see in Finder. The subdirectory
    /// (`madini-image-share`) groups our share spools so macOS's
    /// periodic temp-directory sweep reclaims them together, and so a
    /// human inspecting `/tmp` / `TMPDIR` can tell at a glance where
    /// the files came from.
    private static func writeTempFile(
        bytes: Data,
        resolved: RawTranscriptImageView.Resolved
    ) throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("madini-image-share", isDirectory: true)
        try FileManager.default.createDirectory(
            at: dir,
            withIntermediateDirectories: true
        )
        let url = dir.appendingPathComponent(suggestedFilename(for: resolved))
        try bytes.write(to: url, options: .atomic)
        return url
    }

    /// Anchor the sharing picker to the current key window's content
    /// view. From inside a context menu / sheet button we don't have
    /// easy access to the clicked rect, and `.zero` relative to the
    /// content view is the documented fallback Apple itself uses for
    /// toolbar-initiated shares (see `NSSharingServicePicker`'s
    /// sample code).
    static func presentSharingPicker(url: URL) {
        let picker = NSSharingServicePicker(items: [url])
        guard let window = NSApp.keyWindow ?? NSApp.mainWindow,
              let contentView = window.contentView else {
            return
        }
        picker.show(relativeTo: .zero, of: contentView, preferredEdge: .minY)
    }

    /// Surface a save / share failure as an alert attached to the
    /// current window so the user knows *why* their action didn't
    /// land. `print`-only error handling leaves the UI looking
    /// successful (the panel or picker just closes), which reads as
    /// a silent bug.
    static func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
    #endif
}

#if os(macOS)
private extension NSSavePanel {
    /// Swift-concurrency wrapper for `beginSheetModal`. Anchors the
    /// sheet to the current key window so it animates in over the
    /// reader pane the way other native Save panels do, rather than
    /// popping as a floating window detached from the app's chrome.
    func beginAsSheetModalAsync() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            let anchor = NSApp.keyWindow ?? NSApp.mainWindow
            if let anchor {
                self.beginSheetModal(for: anchor) { response in
                    continuation.resume(returning: response)
                }
            } else {
                self.begin { response in
                    continuation.resume(returning: response)
                }
            }
        }
    }
}
#endif

// MARK: - Preview window host

#if os(macOS)
/// Owns the AppKit-side NSWindow that hosts the image preview. A plain
/// SwiftUI sheet is modal to its parent window and can't be resized or
/// taken fullscreen independently; an NSWindow gives the user the full
/// traffic-light chrome (close / minimize / full-screen) plus native
/// resize, which is what was asked for. We also attach a real NSToolbar
/// to the window's titlebar so Copy / Save / Share appear next to the
/// traffic lights — space inside the window then goes entirely to the
/// image itself.
///
/// We dedupe by snapshot ID: clicking a second image in the same
/// conversation focuses the existing window and navigates to that
/// image instead of opening a second copy. That matches macOS
/// convention (think Preview app) and avoids stacking duplicate
/// windows during a browsing session.
@MainActor
enum ImagePreviewWindow {
    private struct Entry {
        let window: NSWindow
        let model: ImagePreviewModel
        let resolvedHolder: ImagePreviewResolvedHolder
        let toolbarCoordinator: ImagePreviewToolbarCoordinator
        let closeObserver: NSObjectProtocol
    }

    private static var entries: [Int64: Entry] = [:]

    static func show(
        snapshotID: Int64,
        references: [AssetReference],
        initialIndex: Int,
        vault: any RawExportVault,
        resolver: any RawAssetResolver
    ) {
        // Existing window for this snapshot: reuse it. Update the
        // gallery list (in case a late-arriving attachment extended
        // it) and jump to the clicked image, then bring the window
        // forward. No new window, no SwiftUI re-mount.
        if let entry = entries[snapshotID] {
            entry.model.references = references
            let clamped = max(0, min(initialIndex, references.count - 1))
            entry.model.currentIndex = clamped
            entry.window.makeKeyAndOrderFront(nil)
            return
        }

        let model = ImagePreviewModel(
            references: references,
            currentIndex: max(0, min(initialIndex, references.count - 1)),
            snapshotID: snapshotID,
            vault: vault,
            resolver: resolver
        )
        let resolvedHolder = ImagePreviewResolvedHolder()
        let toolbarCoordinator = ImagePreviewToolbarCoordinator(
            resolvedHolder: resolvedHolder,
            vault: vault
        )

        // Build the window first so the content's `updateWindowTitle`
        // closure can capture a `weak` reference to it. Using a blank
        // placeholder hosting controller sidesteps the chicken-and-
        // egg between needing the window to build the closure and
        // needing the content to build the window.
        let hostingController = NSHostingController(
            rootView: AnyView(Color.clear)
        )
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 760, height: 700))
        window.minSize = NSSize(width: 320, height: 280)
        window.center()
        window.isReleasedWhenClosed = false
        // Drop the blue separator under the toolbar — the Preview-app
        // look we're going for has no line under the titlebar, just
        // the image pane butting up against the traffic lights.
        window.titlebarSeparatorStyle = .none

        let content = ImagePreviewWindowContent(
            model: model,
            resolvedHolder: resolvedHolder,
            updateWindowTitle: { [weak window] title in
                window?.title = title
            }
        )
        hostingController.rootView = AnyView(content)

        // Titlebar toolbar: Copy / Save / Share. NSToolbar lives in
        // AppKit, so the buttons dispatch through
        // `ImagePreviewToolbarCoordinator` which reads the current
        // resolved image from `resolvedHolder`.
        let toolbar = NSToolbar(identifier: "MadiniArchive.ImagePreview")
        toolbar.delegate = toolbarCoordinator
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        // Initial title — the async load will replace it with the
        // actual filename once the first image resolves.
        if let firstRef = references.first {
            window.title = (firstRef.reference as NSString).lastPathComponent
        } else {
            window.title = "画像プレビュー"
        }

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let entry = entries.removeValue(forKey: snapshotID) {
                    NotificationCenter.default.removeObserver(entry.closeObserver)
                }
            }
        }

        let entry = Entry(
            window: window,
            model: model,
            resolvedHolder: resolvedHolder,
            toolbarCoordinator: toolbarCoordinator,
            closeObserver: observer
        )
        entries[snapshotID] = entry

        window.makeKeyAndOrderFront(nil)
    }
}
#endif

// MARK: - Titlebar toolbar bridge

#if os(macOS)
/// `NSToolbarDelegate` for the image-preview window. Owns three
/// NSToolbarItem buttons (Copy / Save / Share), wires them to the
/// shared `ImageActions` helpers, and flips each button's enabled
/// state based on whether `resolvedHolder` has a currently-displayed
/// image. We build the items in code rather than in IB because this
/// toolbar isn't reused anywhere else and the button set is stable.
@MainActor
final class ImagePreviewToolbarCoordinator: NSObject, NSToolbarDelegate {
    private let resolvedHolder: ImagePreviewResolvedHolder
    private let vault: any RawExportVault

    private static let copyID = NSToolbarItem.Identifier("MadiniArchive.ImagePreview.Copy")
    private static let saveID = NSToolbarItem.Identifier("MadiniArchive.ImagePreview.Save")
    private static let shareID = NSToolbarItem.Identifier("MadiniArchive.ImagePreview.Share")

    /// Strong references to the buttons so their enabled state can be
    /// updated imperatively as `resolvedHolder` changes. NSToolbar
    /// doesn't expose a way to re-fetch items by identifier without
    /// going through the delegate again, and item lookup via
    /// `toolbar.items` returns copies in some macOS versions.
    private var copyButton: NSButton?
    private var saveButton: NSButton?
    private var shareButton: NSButton?

    init(resolvedHolder: ImagePreviewResolvedHolder, vault: any RawExportVault) {
        self.resolvedHolder = resolvedHolder
        self.vault = vault
        super.init()
        resolvedHolder.onChange = { [weak self] resolved in
            self?.updateEnabledState(hasImage: resolved != nil)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.copyID,
            Self.saveID,
            Self.shareID
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .space,
            Self.copyID,
            Self.saveID,
            Self.shareID
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.copyID:
            return makeItem(
                identifier: itemIdentifier,
                label: "画像をコピー",
                symbol: "doc.on.doc",
                action: #selector(copyTapped),
                buttonKey: \.copyButton
            )
        case Self.saveID:
            return makeItem(
                identifier: itemIdentifier,
                label: "画像を保存",
                symbol: "square.and.arrow.down",
                action: #selector(saveTapped),
                buttonKey: \.saveButton
            )
        case Self.shareID:
            return makeItem(
                identifier: itemIdentifier,
                label: "共有",
                symbol: "square.and.arrow.up",
                action: #selector(shareTapped),
                buttonKey: \.shareButton
            )
        default:
            return nil
        }
    }

    /// Build a single icon-only NSToolbarItem backed by an NSButton.
    /// Stashes the button into `buttonKey` so we can re-drive its
    /// `.isEnabled` without re-creating the item.
    private func makeItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        buttonKey: ReferenceWritableKeyPath<ImagePreviewToolbarCoordinator, NSButton?>
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.isEnabled = resolvedHolder.resolved != nil
        item.view = button
        item.label = label
        item.toolTip = label
        self[keyPath: buttonKey] = button
        return item
    }

    private func updateEnabledState(hasImage: Bool) {
        copyButton?.isEnabled = hasImage
        saveButton?.isEnabled = hasImage
        shareButton?.isEnabled = hasImage
    }

    @objc private func copyTapped() {
        guard let resolved = resolvedHolder.resolved else { return }
        ImageActions.copyToPasteboard(image: resolved.image)
    }

    @objc private func saveTapped() {
        guard let resolved = resolvedHolder.resolved else { return }
        let vault = self.vault
        Task { @MainActor in
            await ImageActions.saveToFile(resolved: resolved, vault: vault)
        }
    }

    @objc private func shareTapped() {
        guard let resolved = resolvedHolder.resolved else { return }
        let vault = self.vault
        Task { @MainActor in
            await ImageActions.share(resolved: resolved, vault: vault)
        }
    }
}
#endif

// MARK: - Cache

/// Process-wide LRU for decoded transcript image bitmaps, keyed by
/// `"<snapshotID>:<reference>"`. Exists because SwiftUI's `LazyVStack`
/// recycles cells on scroll — without this, every upward scroll would
/// thrash the resolver, re-read the blob, and re-decode the image, and
/// the cell would flip back to its placeholder for a frame each time
/// (visible as content-height chatter that prevents the user from
/// scrolling back to the top). The cache is `@MainActor`-isolated so
/// reads from the view's `load()` don't need locking.
///
/// The entry is a `Resolved` (not the bare bitmap) so re-materialized
/// cells can drive Save / Share / Copy without re-running the
/// resolver — the blob hash and relative path come back alongside the
/// image, ready to hand to `ImageActions`.
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
    private static var storage: [String: RawTranscriptImageView.Resolved] = [:]
    // Insertion-order list used as an LRU. We move keys to the end on
    // read so recently-viewed images survive eviction longer than
    // once-seen ones.
    private static var order: [String] = []

    static func get(_ key: String) -> RawTranscriptImageView.Resolved? {
        guard let resolved = storage[key] else { return nil }
        if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        return resolved
    }

    static func set(_ key: String, resolved: RawTranscriptImageView.Resolved) {
        if storage[key] == nil {
            order.append(key)
        } else if let idx = order.firstIndex(of: key) {
            order.remove(at: idx)
            order.append(key)
        }
        storage[key] = resolved
        while order.count > maxEntries {
            let evict = order.removeFirst()
            storage.removeValue(forKey: evict)
        }
    }
}
