#if os(macOS)
import SwiftUI

/// Right column of the consolidated archive.db surface. Lists the files
/// inside the currently selected snapshot, paginating as the user scrolls,
/// and routes clicks into the standalone preview windows
/// (`ImagePreviewWindow` for bitmaps, `TextPreviewWindow` for everything
/// else). Shows an empty-state prompt when no snapshot is selected.
///
/// Why preview lives in a floating window, not in a detail pane inside
/// this view: the user explicitly asked for the image-preview window to
/// be "reused" for file contents so the consolidated surface doesn't
/// have to carry a fourth pane just for bytes. Dispatching to the
/// existing image window (and its new text sibling) keeps the layout at
/// three panes total and lets the user keep a file open in its own
/// resizable / full-screenable window while they scroll past it in the
/// list.
///
/// Why we pass the gallery list at click time: both preview windows
/// accept `(entries, initialIndex)` so arrow-key navigation spans the
/// whole snapshot (or the currently-loaded page of it — we keep the
/// list the window sees in sync with the paged files). Shipping the
/// list on every open means a later "Load more" that extends the right
/// pane also extends the window's arrow-key range the next time the
/// user clicks.
struct ArchiveInspectorFileListPane: View {
    @Bindable var viewModel: ArchiveInspectorViewModel
    @EnvironmentObject private var services: AppServices

    var body: some View {
        Group {
            if viewModel.selectedSnapshotID == nil {
                emptyState
            } else {
                fileList
            }
        }
        .frame(minWidth: 360)
        .navigationTitle("Files")
        // `.task(id:)` runs the reset + first-page load in one
        // continuation per selection change, which side-steps the
        // `.onChange(of:)` race that blanked the pane in the old Vault
        // Browser. Keying on the optional lets us handle both "snapshot
        // picked" and "snapshot cleared" cleanly.
        .task(id: viewModel.selectedSnapshotID) {
            viewModel.handleSnapshotSelectionChanged()
            if viewModel.selectedSnapshotID != nil {
                await viewModel.loadMoreFiles()
            }
        }
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Select a snapshot to browse its files.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    // MARK: - File list

    @ViewBuilder
    private var fileList: some View {
        List {
            ForEach(viewModel.files) { entry in
                Button {
                    openPreview(for: entry)
                } label: {
                    ArchiveInspectorFileRow(entry: entry)
                }
                .buttonStyle(.plain)
            }
            if viewModel.hasMoreFiles {
                loadMoreFooter
            }
            if case .failed(let message) = viewModel.filesState {
                errorBanner(message: message)
            }
        }
        .listStyle(.inset)
    }

    private var loadMoreFooter: some View {
        HStack {
            Spacer()
            if viewModel.filesState == .loading {
                ProgressView().controlSize(.small)
            } else {
                Button("Load more") {
                    Task { await viewModel.loadMoreFiles() }
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
            }
            Spacer()
        }
        .padding(.vertical, 6)
    }

    private func errorBanner(message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            Text(message)
                .font(.caption)
            Spacer()
            Button("Retry") {
                Task { await viewModel.loadMoreFiles() }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(8)
        .background(.yellow.opacity(0.18))
    }

    // MARK: - Preview dispatch

    /// Route a click into either `ImagePreviewWindow` (bitmap-ish
    /// files) or `TextPreviewWindow` (everything else). The routing
    /// decision is driven by MIME / extension so the two windows stay
    /// purpose-built — we don't need a generic "file preview" window
    /// that tries to handle both, which would compromise the toolbar
    /// and body of each.
    ///
    /// `AssetReference`-based navigation isn't used here because the
    /// right pane enumerates raw `RawExportFileEntry` rows, not
    /// reader-resolved asset references. For images we build a
    /// single-entry gallery from the clicked row's relative path; for
    /// text we pass the whole currently-loaded file list so arrow-key
    /// navigation spans the snapshot.
    private func openPreview(for entry: RawExportFileEntry) {
        if isImage(entry) {
            openImage(entry: entry)
        } else {
            openText(entry: entry)
        }
    }

    private func openImage(entry: RawExportFileEntry) {
        // The image window takes `AssetReference`s, not
        // `RawExportFileEntry`. The vaulted path is a stable reference
        // key the resolver accepts directly, so we build a one-shot
        // AssetReference for the clicked row and hand it to the
        // existing preview infrastructure.
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

    private func openText(entry: RawExportFileEntry) {
        // Gallery spans the loaded page. We start at the clicked
        // entry's index in `viewModel.files` so arrow keys in the
        // window walk adjacent rows as the user sees them in the
        // list.
        let gallery = viewModel.files
        let index = gallery.firstIndex(where: { $0.id == entry.id }) ?? 0
        TextPreviewWindow.show(
            snapshotID: entry.snapshotID,
            entries: gallery,
            initialIndex: index,
            vault: services.rawExportVault
        )
    }

    /// Conservative "should this open in the image window" check:
    /// trust the MIME first, fall back to the extension, refuse
    /// everything else. Unknown extensions fall through to the text
    /// preview (which handles binary with a "open externally" prompt)
    /// so a misclassified payload still opens in *something* rather
    /// than nothing.
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
}

// MARK: - Row

private struct ArchiveInspectorFileRow: View {
    let entry: RawExportFileEntry

    var body: some View {
        HStack(alignment: .center, spacing: 10) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 2) {
                Text(filename)
                    .font(.system(.body, design: .default))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(subtitleLine)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
        .padding(.vertical, 2)
    }

    private var filename: String {
        let name = (entry.relativePath as NSString).lastPathComponent
        return name.isEmpty ? entry.relativePath : name
    }

    /// "{parent-dir} · {size}" — compact line that identifies which
    /// directory inside the snapshot the file came from without
    /// truncating the main filename row.
    private var subtitleLine: String {
        let parent = (entry.relativePath as NSString).deletingLastPathComponent
        let size = ByteCountFormatter.string(
            fromByteCount: entry.sizeBytes,
            countStyle: .file
        )
        if parent.isEmpty || parent == "/" {
            return size
        }
        return "\(parent) · \(size)"
    }

    /// Lightweight icon palette: green image, yellow JSON/text, neutral
    /// for everything else. We key on MIME / extension rather than the
    /// `role` string because role is provider-specific and we want the
    /// same icon for "conversation.json" regardless of which exporter
    /// produced it.
    private var iconName: String {
        let ext = (entry.relativePath as NSString).pathExtension.lowercased()
        if let mime = entry.mimeType?.lowercased(), mime.hasPrefix("image/") {
            return "photo"
        }
        switch ext {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "heif", "tiff", "bmp":
            return "photo"
        case "json":
            return "curlybraces"
        case "txt", "md", "markdown", "log":
            return "doc.text"
        case "html", "htm":
            return "doc.richtext"
        case "zip", "tar", "gz":
            return "shippingbox"
        default:
            return "doc"
        }
    }

    private var iconColor: Color {
        let ext = (entry.relativePath as NSString).pathExtension.lowercased()
        if let mime = entry.mimeType?.lowercased(), mime.hasPrefix("image/") {
            return .green
        }
        switch ext {
        case "png", "jpg", "jpeg", "webp", "gif", "heic", "heif":
            return .green
        case "json":
            return .orange
        case "txt", "md", "markdown", "log", "html", "htm":
            return .blue
        default:
            return .secondary
        }
    }
}
#endif
