#if os(macOS)
import SwiftUI

/// Right column of the consolidated archive.db surface. Split
/// vertically into a file list (top) and an inline preview (bottom) —
/// picking a row loads its bytes into the preview below, so flipping
/// through rows doesn't require chasing a floating window around the
/// desktop.
///
/// The floating `ImagePreviewWindow` / `TextPreviewWindow` aren't
/// retired; the inline preview's toolbar still has an "Open in window"
/// button that detaches into the full-resizable / full-screenable
/// standalone view when the user wants more room. Inline is the
/// default, window is the escape hatch.
///
/// Why a vertical split (rather than moving the file list to the
/// middle pane or using a NavigationStack in the right pane): keeping
/// the file list in view as the user previews each row matches how a
/// `Mail.app`-style list-and-reader feels. Moving the list into the
/// middle pane would crowd the timeline; a NavigationStack would make
/// "back to the list" a click, which is friction when the user wants
/// to scan a handful of files in a row.
struct ArchiveInspectorFileListPane: View {
    @Bindable var viewModel: ArchiveInspectorViewModel

    var body: some View {
        Group {
            if viewModel.selectedSnapshotID == nil {
                emptyState
            } else {
                splitBody
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

    /// Vertical split: file list on top (fixed-ish height seeded by the
    /// split ideal), inline preview on the bottom. We use
    /// `VSplitView` so the user can drag the divider to give either
    /// half more room. The ideal heights are set so the preview gets
    /// the majority of the pane by default — opening a file is the
    /// action that brought the user here, and the list can scroll
    /// within its allotted band.
    @ViewBuilder
    private var splitBody: some View {
        VSplitView {
            fileList
                .frame(minHeight: 140, idealHeight: 240)
            ArchiveInspectorFilePreviewPane(entry: viewModel.selectedFile)
                .frame(minHeight: 200)
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
        // Direct `@Bindable` binding — unlike the snapshot selection
        // (which triggers a `.task(id:)` that mutates the VM inside a
        // SwiftUI update pass and needed a deferred `Task { ... }`
        // indirection to avoid the re-entrant blanking bug), the file
        // selection only drives a downstream preview rebuild and has
        // no cascading observed mutations. A synchronous write keeps
        // List's native row-highlight in lock-step with the click.
        List(selection: $viewModel.selectedFileID) {
            ForEach(viewModel.files) { entry in
                ArchiveInspectorFileRow(entry: entry)
                    .tag(entry.id)
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
