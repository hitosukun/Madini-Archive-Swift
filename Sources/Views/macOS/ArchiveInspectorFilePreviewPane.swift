#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Inline file preview surface shown in the bottom half of the Archive
/// Inspector's right pane. Replaces (for the in-pane case) the floating
/// `ImagePreviewWindow` / `TextPreviewWindow` that earlier revisions of
/// this surface popped open on every click.
///
/// Why inline: the user asked for "右ペインに展開" — previewing a file
/// should stay visually adjacent to the file list so flipping through
/// rows doesn't require chasing a floating window around the desktop.
/// The floating windows are still available as an explicit "Open in
/// window" escape hatch (via the toolbar button below) for users who
/// want a resizable / full-screenable standalone view.
///
/// What renders:
/// - **Image files** (MIME `image/*` or a known image extension): the
///   decoded bitmap, scaled-to-fit inside the pane. Uses the same
///   resolver + vault pipeline `RawTranscriptImageView` does, but
///   without the tap-to-zoom gesture (this IS the zoomed view).
/// - **Text-like files**: head-truncated to `previewByteCap` bytes,
///   UTF-8 decoded with a binary sniff fallback. Mirrors the existing
///   `TextPreviewWindow` logic so the two code paths stay consistent
///   and a user switching between inline and floating previews sees
///   identical truncation / banner / binary-placeholder behavior.
/// - **Nothing selected**: a plain empty-state prompt steering the
///   user at the file list above.
///
/// State isolation: this view reloads on `.task(id: entry.id)` so
/// paging to a different file swaps contents cleanly without the
/// previous file's bytes bleeding into the new render. We don't use
/// the `RawTranscriptImageCache` here because the inline preview is
/// not inside a scroll-recycled container — each selection replaces
/// the previous one wholesale, and the cache is sized for
/// conversation-scroll workloads rather than single-file inspection.
struct ArchiveInspectorFilePreviewPane: View {
    @EnvironmentObject private var services: AppServices
    let entry: RawExportFileEntry?

    /// Cap shared with `TextPreviewWindow`. Importing the constant
    /// rather than re-declaring it keeps the inline and floating
    /// previews in lock-step — bumping the cap in one place updates
    /// both surfaces.
    fileprivate static var previewByteCap: Int { TextPreviewWindow.previewByteCap }

    var body: some View {
        Group {
            if let entry {
                PreviewHost(entry: entry)
                    .id(entry.id) // force SwiftUI to rebuild state on swap
            } else {
                emptyState
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Color(nsColor: .windowBackgroundColor))
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "doc.text.magnifyingglass")
                .font(.system(size: 28))
                .foregroundStyle(.tertiary)
            Text("Select a file to preview it here.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Host

/// Inner view that owns the async load state per selected file. Split
/// out so the parent can gate on `entry != nil` without dragging state
/// across selection changes (the `.id(entry.id)` on the parent ensures
/// SwiftUI tears this down and rebuilds it when the file changes —
/// cheaper and less error-prone than a `.task(id:)` inside here).
private struct PreviewHost: View {
    @EnvironmentObject private var services: AppServices
    let entry: RawExportFileEntry

    @State private var state: PreviewState = .loading

    var body: some View {
        Group {
            switch state {
            case .loading:
                ProgressView()
                    .controlSize(.small)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            case .failed(let message):
                placeholder(
                    systemImage: "xmark.octagon",
                    title: String(localized: "Failed to load"),
                    detail: message
                )
            case .image(let image):
                ImagePreviewBody(entry: entry, image: image)
            case .text(let loaded):
                TextPreviewBody(entry: entry, loaded: loaded)
            case .binary(let reason):
                placeholder(
                    systemImage: "doc.badge.gearshape",
                    title: String(localized: "File type not previewable"),
                    detail: reason
                )
            }
        }
        .task {
            await load()
        }
    }

    // MARK: Load state

    private enum PreviewState {
        case loading
        case failed(String)
        case image(NSImage)
        case text(TextPreviewLoaded)
        case binary(String)
    }

    /// Branch on MIME / extension to decide whether to run the image
    /// resolver or the text-bytes path. Unknown extensions fall through
    /// to text (which handles the binary-sniff placeholder), so a
    /// misclassified payload still shows something rather than nothing.
    private func load() async {
        if isImage(entry) {
            await loadImage()
        } else {
            await loadText()
        }
    }

    private func loadImage() async {
        // Re-use the full image-resolver pipeline so we get the same
        // `raw_assets` lookup + fallback-to-`raw_export_files` behavior
        // the in-bubble images do. Inline failures degrade to the
        // text path so a broken reference doesn't leave the pane
        // blank — we show the placeholder with a reason instead.
        let reference = AssetReference(
            reference: entry.relativePath,
            mimeType: entry.mimeType
        )
        do {
            if let hit = try await services.rawAssetResolver.resolveAsset(
                snapshotID: entry.snapshotID,
                reference: reference.reference
            ) {
                let bytes = try await services.rawExportVault.loadBlob(hash: hit.blobHash)
                if let image = NSImage(data: bytes) {
                    state = .image(image)
                    return
                }
                state = .failed(String(localized: "Couldn’t decode as image."))
                return
            }
            // Fall back: load the raw bytes directly through the
            // vault using the file entry's blob hash. Some snapshots
            // don't index every asset in `raw_assets`, and the file
            // list we're previewing came from `raw_export_files`
            // anyway — so we already know the hash.
            let bytes = try await services.rawExportVault.loadBlob(hash: entry.blobHash)
            if let image = NSImage(data: bytes) {
                state = .image(image)
            } else {
                state = .failed(String(localized: "Couldn’t decode as image."))
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    private func loadText() async {
        do {
            let bytes = try await services.rawExportVault.loadBlob(hash: entry.blobHash)
            let fullByteCount = bytes.count
            let head: Data
            let truncated: Bool
            if fullByteCount > ArchiveInspectorFilePreviewPane.previewByteCap {
                head = bytes.prefix(ArchiveInspectorFilePreviewPane.previewByteCap)
                truncated = true
            } else {
                head = bytes
                truncated = false
            }
            switch decodeUTF8(head: head) {
            case .text(let s):
                state = .text(
                    TextPreviewLoaded(
                        entry: entry,
                        previewText: s,
                        isTruncated: truncated,
                        fullByteCount: fullByteCount,
                        binaryReason: nil
                    )
                )
            case .binary:
                state = .binary(
                    String(localized: "Bytes don’t decode as UTF-8 (\(formatBytes(fullByteCount))). Use “Open Externally” to open it in the default app.")
                )
            }
        } catch {
            state = .failed(String(describing: error))
        }
    }

    // MARK: - Helpers

    private func isImage(_ entry: RawExportFileEntry) -> Bool {
        if let mime = entry.mimeType?.lowercased(), mime.hasPrefix("image/") {
            return true
        }
        let ext = (entry.relativePath as NSString).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "bmp":
            return true
        default:
            return false
        }
    }

    /// Cheap binary sniff (mirrors `TextPreviewWindow.decodeUTF8`) so
    /// the inline and floating previews agree on which files render as
    /// text. Real text rarely contains NUL bytes; binary formats are
    /// riddled with them.
    private func decodeUTF8(head: Data) -> DecodedBytes {
        let probe = head.prefix(512)
        let nulCount = probe.reduce(into: 0) { acc, byte in
            if byte == 0 { acc += 1 }
        }
        if probe.count >= 16, nulCount > max(1, probe.count / 32) {
            return .binary
        }
        if let decoded = String(data: head, encoding: .utf8) {
            return .text(decoded)
        }
        return .text(String(decoding: head, as: UTF8.self))
    }

    private enum DecodedBytes {
        case text(String)
        case binary
    }

    private func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }

    private func placeholder(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 32))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Image body

/// Inline image preview with a compact toolbar. Mirrors the floating
/// window's Copy / Save / Share actions but renders flat against the
/// pane's background instead of in its own NSWindow.
private struct ImagePreviewBody: View {
    @EnvironmentObject private var services: AppServices
    let entry: RawExportFileEntry
    let image: NSImage

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ZStack {
                Color(nsColor: .windowBackgroundColor)
                Image(nsImage: image)
                    .resizable()
                    .scaledToFit()
                    .padding(8)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: "photo")
                .foregroundStyle(.green)
            Text(filename)
                .font(.system(.callout, design: .default).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                copyImage()
            } label: {
                Label("Copy", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            Button {
                saveImage()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            Button {
                openInWindow()
            } label: {
                Label("Open in New Window", systemImage: "macwindow")
            }
            .controlSize(.small)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var filename: String {
        let name = (entry.relativePath as NSString).lastPathComponent
        return name.isEmpty ? entry.relativePath : name
    }

    private func copyImage() {
        ImageActions.copyToPasteboard(image: image)
    }

    private func saveImage() {
        let resolved = RawTranscriptImageView.Resolved(
            image: image,
            blobHash: entry.blobHash,
            assetRelativePath: entry.relativePath,
            mimeType: entry.mimeType
        )
        Task { @MainActor in
            await ImageActions.saveToFile(
                resolved: resolved,
                vault: services.rawExportVault
            )
        }
    }

    private func openInWindow() {
        let reference = AssetReference(
            reference: entry.relativePath,
            mimeType: entry.mimeType
        )
        ImagePreviewWindow.show(
            snapshotID: entry.snapshotID,
            references: [reference],
            initialIndex: 0,
            vault: services.rawExportVault,
            resolver: services.rawAssetResolver
        )
    }
}

// MARK: - Text body

/// Inline text preview. Uses the same `TextPreviewLoaded` DTO the
/// floating window uses — including the truncation banner and binary
/// placeholder — so the two surfaces render identically. The key
/// differences from the floating window: a compact header row instead
/// of a titlebar NSToolbar, and an "Open in window" button that
/// detaches into the full-resizable floating preview when the user
/// wants more room.
private struct TextPreviewBody: View {
    @EnvironmentObject private var services: AppServices
    let entry: RawExportFileEntry
    let loaded: TextPreviewLoaded

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if loaded.isTruncated {
                truncationBanner
                Divider()
            }
            ScrollView([.vertical, .horizontal]) {
                Text(loaded.previewText)
                    .font(.system(.callout, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(12)
            }
        }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Image(systemName: icon)
                .foregroundStyle(iconColor)
            Text(filename)
                .font(.system(.callout, design: .default).weight(.medium))
                .lineLimit(1)
                .truncationMode(.middle)
            Spacer(minLength: 8)
            Button {
                copyText()
            } label: {
                Label("Copy Text", systemImage: "doc.on.doc")
            }
            .controlSize(.small)
            Button {
                saveFile()
            } label: {
                Label("Save", systemImage: "square.and.arrow.down")
            }
            .controlSize(.small)
            Button {
                openExternally()
            } label: {
                Label("Open Externally", systemImage: "arrow.up.forward.app")
            }
            .controlSize(.small)
            Button {
                openInWindow()
            } label: {
                Label("Open in New Window", systemImage: "macwindow")
            }
            .controlSize(.small)
        }
        .labelStyle(.iconOnly)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private var truncationBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
                .foregroundStyle(.secondary)
            Text("Showing only the first \(Self.formatBytes(TextPreviewWindow.previewByteCap)) (total \(Self.formatBytes(loaded.fullByteCount))). Use “Open Externally” to see the rest.")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    private var filename: String {
        let name = (entry.relativePath as NSString).lastPathComponent
        return name.isEmpty ? entry.relativePath : name
    }

    private var icon: String {
        let ext = (entry.relativePath as NSString).pathExtension.lowercased()
        switch ext {
        case "json": return "curlybraces"
        case "txt", "md", "markdown", "log": return "doc.text"
        case "html", "htm": return "doc.richtext"
        default: return "doc"
        }
    }

    private var iconColor: Color {
        let ext = (entry.relativePath as NSString).pathExtension.lowercased()
        switch ext {
        case "json": return .orange
        case "txt", "md", "markdown", "log", "html", "htm": return .blue
        default: return .secondary
        }
    }

    private func copyText() {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(loaded.previewText, forType: .string)
    }

    private func saveFile() {
        let loaded = self.loaded
        let vault = services.rawExportVault
        Task { @MainActor in
            await TextPreviewToolbarCoordinator.saveToFile(
                loaded: loaded,
                vault: vault
            )
        }
    }

    private func openExternally() {
        let loaded = self.loaded
        let vault = services.rawExportVault
        Task { @MainActor in
            await TextPreviewToolbarCoordinator.openExternally(
                loaded: loaded,
                vault: vault
            )
        }
    }

    private func openInWindow() {
        TextPreviewWindow.show(
            snapshotID: entry.snapshotID,
            entries: [entry],
            initialIndex: 0,
            vault: services.rawExportVault
        )
    }

    private static func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}

#endif
