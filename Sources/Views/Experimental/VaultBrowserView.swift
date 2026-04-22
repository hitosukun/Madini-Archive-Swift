import SwiftUI
#if os(macOS)
import AppKit
import UniformTypeIdentifiers
#endif

/// Phase D1 raw-export Vault browser — read-only 2-pane view.
///
/// Left pane: paginated snapshot list (newest first, grouped visually by
/// provider). Right pane: the selected snapshot's file metadata. No file
/// contents yet; that's D2's job.
///
/// Wired in as a standalone `Window` scene from `MadiniArchiveApp` so we
/// don't perturb the main reader UI while the vault surface is being built.
struct VaultBrowserView: View {
    @State private var viewModel: VaultBrowserViewModel
    #if os(macOS)
    @EnvironmentObject private var services: AppServices
    @State private var isImporting = false
    @State private var importError: ImportErrorAlert?
    #endif

    init(
        vault: any RawExportVault,
        assetResolver: any RawAssetResolver
    ) {
        _viewModel = State(
            wrappedValue: VaultBrowserViewModel(
                vault: vault,
                assetResolver: assetResolver
            )
        )
    }

    var body: some View {
        NavigationSplitView {
            snapshotsPane
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } content: {
            filesPane
                .navigationSplitViewColumnWidth(min: 300, ideal: 360, max: 520)
        } detail: {
            contentPane
        }
        .navigationTitle("Vault Browser")
        .task {
            if viewModel.snapshots.isEmpty, viewModel.snapshotsState == .idle {
                await viewModel.loadMoreSnapshots()
            }
        }
        #if os(macOS)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                importToolbarButton
            }
        }
        .alert(
            "Import failed",
            isPresented: Binding(
                get: { importError != nil },
                set: { isPresented in
                    if !isPresented { importError = nil }
                }
            ),
            presenting: importError
        ) { _ in
            Button("OK", role: .cancel) { importError = nil }
        } message: { alert in
            Text(alert.message)
        }
        #endif
    }

    // MARK: - Snapshots pane

    @ViewBuilder
    private var snapshotsPane: some View {
        List(selection: Binding(
            get: { viewModel.selectedSnapshotID },
            set: { viewModel.selectedSnapshotID = $0 }
        )) {
            ForEach(viewModel.snapshots) { snapshot in
                snapshotRow(snapshot)
                    .tag(snapshot.id)
            }
            snapshotsFooter
        }
        .listStyle(.sidebar)
        .overlay {
            if viewModel.snapshots.isEmpty {
                snapshotsPlaceholder
            }
        }
    }

    private func snapshotRow(_ snapshot: RawExportSnapshotSummary) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 8) {
                Text(providerLabel(snapshot.provider))
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 0)
                Text("#\(snapshot.id)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            Text(snapshot.importedAt)
                .font(.callout)
                .lineLimit(1)
                .truncationMode(.middle)
            Text("\(snapshot.fileCount) files · \(Self.byteString(snapshot.originalBytes))")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var snapshotsFooter: some View {
        switch viewModel.snapshotsState {
        case .loading:
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
                .listRowSeparator(.hidden)
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
                .listRowSeparator(.hidden)
        case .idle, .loaded:
            if viewModel.hasMoreSnapshots, !viewModel.snapshots.isEmpty {
                Button("Load more") {
                    Task { await viewModel.loadMoreSnapshots() }
                }
                .buttonStyle(.borderless)
                .listRowSeparator(.hidden)
            }
        }
    }

    @ViewBuilder
    private var snapshotsPlaceholder: some View {
        switch viewModel.snapshotsState {
        case .loading:
            ProgressView("Loading snapshots…")
        case .failed(let message):
            ContentUnavailableView(
                "Couldn't load snapshots",
                systemImage: "exclamationmark.triangle",
                description: Text(message)
            )
        case .idle, .loaded:
            ContentUnavailableView(
                "No snapshots",
                systemImage: "tray",
                description: Text("Drop a ChatGPT / Claude / Gemini export into the main window to ingest one.")
            )
        }
    }

    // MARK: - Files pane

    @ViewBuilder
    private var filesPane: some View {
        if let selectedID = viewModel.selectedSnapshotID,
           let snapshot = viewModel.snapshots.first(where: { $0.id == selectedID })
        {
            filesList(for: snapshot)
        } else {
            ContentUnavailableView(
                "Select a snapshot",
                systemImage: "sidebar.left",
                description: Text("Pick a snapshot on the left to inspect the files it captured.")
            )
        }
    }

    private func filesList(for snapshot: RawExportSnapshotSummary) -> some View {
        List(selection: Binding(
            get: { viewModel.selectedFileID },
            set: { viewModel.selectedFileID = $0 }
        )) {
            Section {
                ForEach(viewModel.files) { entry in
                    fileRow(entry).tag(entry.id)
                }
                filesFooter
            } header: {
                filesHeader(snapshot)
            }
        }
        .task(id: snapshot.id) {
            if viewModel.files.isEmpty, viewModel.filesState == .idle {
                await viewModel.loadMoreFiles()
            }
        }
    }

    // MARK: - Content pane (D2 + D4 chip strip)

    @ViewBuilder
    private var contentPane: some View {
        Group {
            if let entry = viewModel.selectedFileEntry {
                fileContentPane(entry: entry)
            } else if viewModel.selectedSnapshotID != nil {
                ContentUnavailableView(
                    "Select a file",
                    systemImage: "doc.text",
                    description: Text("Pick a file in the middle pane to restore and preview its contents.")
                )
            } else {
                ContentUnavailableView(
                    "Nothing selected",
                    systemImage: "tray",
                    description: Text("Pick a snapshot, then a file, to preview raw bytes.")
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { viewModel.previewingAssetID != nil },
            set: { isPresented in
                if !isPresented { viewModel.previewingAssetID = nil }
            }
        )) {
            assetPreviewSheet
        }
    }

    @ViewBuilder
    private func fileContentPane(entry: RawExportFileEntry) -> some View {
        VStack(spacing: 0) {
            VaultFileContentView(
                entry: entry,
                payload: viewModel.selectedFilePayload,
                state: viewModel.fileContentState,
                onRetry: {
                    Task { await viewModel.loadSelectedFileContent() }
                }
            )
            if !viewModel.referencedAssets.isEmpty
                || viewModel.referencedAssetsState == .loading
            {
                Divider()
                assetChipStrip
            }
        }
        .task(id: entry.id) {
            // Auto-load file bytes + referenced assets on selection change.
            // Both are idempotent, so the chip strip can appear as soon as the
            // resolver returns even if the body is still being restored.
            if viewModel.selectedFilePayload == nil,
               viewModel.fileContentState == .idle
            {
                await viewModel.loadSelectedFileContent()
            }
            if viewModel.referencedAssets.isEmpty,
               viewModel.referencedAssetsState == .idle
            {
                await viewModel.loadMoreReferencedAssets()
            }
        }
    }

    // MARK: - Asset chips (D4)

    @ViewBuilder
    private var assetChipStrip: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Text("Referenced assets")
                    .font(.caption.bold())
                    .foregroundStyle(.secondary)
                if viewModel.referencedAssetsState == .loading {
                    ProgressView().controlSize(.mini)
                }
                Spacer(minLength: 0)
                Text("\(viewModel.referencedAssets.count)")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                    .monospacedDigit()
            }
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(viewModel.referencedAssets) { hit in
                        assetChip(hit)
                    }
                }
            }
        }
        .padding(.horizontal)
        .padding(.vertical, 8)
        .background(.thinMaterial)
    }

    private func assetChip(_ hit: RawAssetHit) -> some View {
        Button {
            viewModel.previewingAssetID = hit.id
        } label: {
            HStack(spacing: 6) {
                Image(systemName: Self.icon(forAssetMime: hit.mimeType, path: hit.assetRelativePath))
                Text(Self.basename(hit.assetRelativePath))
                    .font(.caption.monospaced())
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(Self.byteString(hit.sizeBytes))
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 5)
            .background(
                RoundedRectangle(cornerRadius: 8, style: .continuous)
                    .fill(.quaternary)
            )
        }
        .buttonStyle(.plain)
    }

    @ViewBuilder
    private var assetPreviewSheet: some View {
        if let hit = viewModel.previewingAsset {
            VStack(spacing: 0) {
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(Self.basename(hit.assetRelativePath))
                            .font(.headline)
                            .lineLimit(1)
                            .truncationMode(.middle)
                        Text(hit.assetRelativePath)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer()
                    Button("Done") {
                        viewModel.previewingAssetID = nil
                    }
                    .keyboardShortcut(.cancelAction)
                }
                .padding()
                Divider()
                assetPreviewBody(for: hit)
            }
            .frame(minWidth: 480, minHeight: 360)
            .task(id: viewModel.previewingAssetID) {
                if viewModel.previewedAssetPayload == nil,
                   viewModel.previewedAssetState == .idle
                {
                    await viewModel.loadPreviewedAssetPayload()
                }
            }
        } else {
            // Defensive: should not happen because the sheet only presents
            // when `previewingAssetID != nil`, but keep a visible fallback so
            // a stale binding can't silently deadlock the UI.
            ContentUnavailableView(
                "No asset",
                systemImage: "questionmark.square.dashed"
            )
            .frame(minWidth: 320, minHeight: 200)
        }
    }

    @ViewBuilder
    private func assetPreviewBody(for hit: RawAssetHit) -> some View {
        switch viewModel.previewedAssetState {
        case .idle, .loading:
            VStack {
                Spacer()
                ProgressView("Loading asset…")
                Spacer()
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            VStack(spacing: 12) {
                ContentUnavailableView(
                    "Couldn't load asset",
                    systemImage: "exclamationmark.triangle",
                    description: Text(message)
                )
                Button("Retry") {
                    Task { await viewModel.loadPreviewedAssetPayload() }
                }
                .buttonStyle(.bordered)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .loaded:
            if let payload = viewModel.previewedAssetPayload {
                if VaultAssetPreviewView.renderable(for: payload) != nil {
                    VaultAssetPreviewView(payload: payload)
                } else {
                    ContentUnavailableView(
                        "Preview unavailable",
                        systemImage: "shippingbox",
                        description: Text("\(Self.byteString(hit.sizeBytes)) · \(hit.mimeType ?? "application/octet-stream")")
                    )
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            } else {
                ContentUnavailableView(
                    "No payload",
                    systemImage: "doc",
                    description: Text("The vault returned an empty payload for this asset.")
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func filesHeader(_ snapshot: RawExportSnapshotSummary) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("\(providerLabel(snapshot.provider)) · \(snapshot.fileCount) files")
                .font(.headline)
            Text(snapshot.sourceRoot ?? "(no source path)")
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    private func fileRow(_ entry: RawExportFileEntry) -> some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(entry.relativePath)
                .font(.body.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            HStack(spacing: 12) {
                Label(entry.role, systemImage: roleIcon(entry.role))
                Text(Self.byteString(entry.sizeBytes))
                if entry.compression != "none" {
                    Text("→ \(Self.byteString(entry.storedSizeBytes)) (\(entry.compression))")
                }
                if let mime = entry.mimeType {
                    Text(mime)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
        }
        .padding(.vertical, 2)
    }

    @ViewBuilder
    private var filesFooter: some View {
        switch viewModel.filesState {
        case .loading:
            HStack { Spacer(); ProgressView().controlSize(.small); Spacer() }
        case .failed(let message):
            Text(message)
                .font(.caption)
                .foregroundStyle(.red)
        case .idle, .loaded:
            if viewModel.hasMoreFiles, !viewModel.files.isEmpty {
                Button("Load more files") {
                    Task { await viewModel.loadMoreFiles() }
                }
                .buttonStyle(.borderless)
            }
        }
    }

    // MARK: - Formatting helpers

    private func providerLabel(_ provider: RawExportProvider) -> String {
        switch provider {
        case .chatGPT: return "ChatGPT"
        case .claude: return "Claude"
        case .gemini: return "Gemini"
        case .unknown: return "Unknown"
        }
    }

    private func roleIcon(_ role: String) -> String {
        switch role {
        case "conversation": return "bubble.left.and.bubble.right"
        case "metadata": return "info.circle"
        case "manifest": return "doc.text.magnifyingglass"
        case "asset": return "photo"
        default: return "doc"
        }
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

    /// SF Symbol for an asset chip. Prefers MIME category so that assets with
    /// weird extensions still pick up a reasonable icon, falling back to the
    /// path's extension when MIME is nil (Vault sometimes records that for
    /// provider exports that don't stamp a Content-Type).
    private static func icon(forAssetMime mime: String?, path: String) -> String {
        if let mime {
            if mime.hasPrefix("image/") { return "photo" }
            if mime == "application/pdf" { return "doc.richtext" }
            if mime.hasPrefix("audio/") { return "waveform" }
            if mime.hasPrefix("video/") { return "film" }
            if mime.hasPrefix("text/") { return "doc.text" }
        }
        let ext = URL(fileURLWithPath: path).pathExtension.lowercased()
        switch ext {
        case "png", "jpg", "jpeg", "gif", "webp", "heic", "bmp", "tiff":
            return "photo"
        case "pdf": return "doc.richtext"
        case "mp3", "wav", "m4a", "aac", "flac", "ogg": return "waveform"
        case "mp4", "mov", "avi", "mkv", "webm": return "film"
        case "txt", "md", "csv", "xml", "html", "htm", "log", "yaml", "yml",
             "json":
            return "doc.text"
        default:
            return "doc"
        }
    }

    /// Just the trailing filename component — chips are narrow so the full
    /// relative path is kept in the chip's accessibility label / the sheet
    /// header, and this is what users actually recognise at a glance.
    private static func basename(_ path: String) -> String {
        URL(fileURLWithPath: path).lastPathComponent
    }
}

// MARK: - Import (macOS)

#if os(macOS)
/// Error payload for the `.alert` driving import failures. Modelled as a
/// separate `Identifiable` so we can drive the alert with `presenting:` and
/// keep the message verbatim across re-renders.
struct ImportErrorAlert: Identifiable, Equatable {
    let id = UUID()
    let message: String
}

extension VaultBrowserView {
    @ViewBuilder
    fileprivate var importToolbarButton: some View {
        if isImporting {
            ProgressView()
                .controlSize(.small)
        } else {
            Button {
                Task { await runImport() }
            } label: {
                Label("Import…", systemImage: "square.and.arrow.down")
            }
            .help("Pick one or more export JSON files or folders to ingest into the vault")
        }
    }

    /// Drive a full import cycle from an NSOpenPanel selection through the
    /// `ImportCoordinator`. The coordinator is authoritative for "vaulted /
    /// not vaulted" semantics — we only translate its result into UI state.
    @MainActor
    fileprivate func runImport() async {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = true
        panel.allowsMultipleSelection = true
        panel.allowedContentTypes = [.json, .folder]
        panel.message = "Select ChatGPT / Claude / Gemini export JSON files or folders"
        panel.prompt = "Import"

        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        guard !urls.isEmpty else { return }

        isImporting = true
        defer { isImporting = false }

        do {
            _ = try await ImportCoordinator.importDroppedURLs(urls, services: services)
            await viewModel.reloadSnapshots()
        } catch let coordinatorError as ImportCoordinatorError {
            // .importerFailed preserves the vault snapshot even though the
            // Python importer bailed — refresh so the new row shows up,
            // then surface the detail so the user knows normalization has
            // to be retried.
            if case .importerFailed(_, _, _) = coordinatorError {
                await viewModel.reloadSnapshots()
            }
            importError = ImportErrorAlert(
                message: [
                    coordinatorError.errorDescription,
                    coordinatorError.failureDetail
                ].compactMap { $0 }.joined(separator: "\n\n")
            )
        } catch {
            importError = ImportErrorAlert(message: error.localizedDescription)
        }
    }
}
#endif
