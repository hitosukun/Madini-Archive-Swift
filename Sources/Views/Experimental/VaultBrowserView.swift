import SwiftUI

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

    init(vault: any RawExportVault) {
        _viewModel = State(wrappedValue: VaultBrowserViewModel(vault: vault))
    }

    var body: some View {
        NavigationSplitView {
            snapshotsPane
                .navigationSplitViewColumnWidth(min: 260, ideal: 320, max: 420)
        } detail: {
            filesPane
        }
        .navigationTitle("Vault Browser")
        .task {
            if viewModel.snapshots.isEmpty, viewModel.snapshotsState == .idle {
                await viewModel.loadMoreSnapshots()
            }
        }
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
        List {
            Section {
                ForEach(viewModel.files) { entry in
                    fileRow(entry)
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
}
