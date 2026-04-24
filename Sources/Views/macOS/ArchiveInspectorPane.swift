#if os(macOS)
import AppKit
import SwiftUI

/// Middle column of the consolidated archive.db surface. Stacks the
/// drop-folder configuration header (pinned) on top of a unified
/// vault-snapshot + intake-activity timeline (scrolls). Selection is
/// single-snapshot and drives the right pane's file list.
///
/// Why this fuses two old surfaces: the user asked us to collapse three
/// sidebar rows — Vault Browser, Auto Intake, and the bare archive.db
/// entry — into one. The old Auto-Intake pane owned the drop-folder
/// config; the old Vault Browser owned the snapshot list. Neither made
/// sense as a separate entry because "configuring the drop folder" and
/// "looking at what the drop folder imported" are two sides of the same
/// question. Merging them gives the user one place to answer both.
///
/// Drop-folder buttons (Copy / Change / Reset) are wired directly to
/// `AppServices` rather than proxied through the VM. The VM's
/// responsibility is vault paging + timeline merging; folder config is
/// stateless UI on top of existing service methods, and routing it
/// through the VM would just add mechanical indirection.
struct ArchiveInspectorPane: View {
    @Bindable var viewModel: ArchiveInspectorViewModel
    @EnvironmentObject private var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            dropFolderHeader
                .padding(16)
            Divider()
            timelineBody
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Archive")
        .task {
            if viewModel.snapshots.isEmpty, viewModel.snapshotsState == .idle {
                await viewModel.loadMoreSnapshots()
            }
        }
    }

    // MARK: - Drop folder header

    /// Pinned configuration block. Clones the old `AutoIntakePane`
    /// header's three buttons (Copy path / Change folder / Reset) plus
    /// the explanatory blurb. Kept inline rather than imported from the
    /// old pane because that pane is about to be deleted — lifting the
    /// bits we still need here is cheaper than trying to share code
    /// across a module we're about to lose.
    private var dropFolderHeader: some View {
        let url = services.intakeDirURL
        let isDefault = url.standardizedFileURL == IntakePaths.intakeDir.standardizedFileURL
        return VStack(alignment: .leading, spacing: 8) {
            Label("Drop folder", systemImage: "tray.and.arrow.down.fill")
                .font(.headline)
            Text(url.path)
                .font(.system(.caption, design: .monospaced))
                .textSelection(.enabled)
                .foregroundStyle(.secondary)
                .lineLimit(2)
                .truncationMode(.middle)
            HStack(spacing: 8) {
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                } label: {
                    Label("Copy path", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
                Button {
                    chooseIntakeDirectory()
                } label: {
                    Label("Change folder…", systemImage: "folder.badge.gearshape")
                }
                .controlSize(.small)
                Button {
                    services.setIntakeDirectory(nil)
                } label: {
                    Label("Reset to default", systemImage: "arrow.uturn.backward")
                }
                .controlSize(.small)
                .disabled(isDefault)
            }
            Text("Drop an export (zip or folder) here to ingest. Re-dropping an already-vaulted export is detected and skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
            if !isDefault {
                Text("Using a custom drop folder. This choice persists until you reset it.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func chooseIntakeDirectory() {
        let panel = NSOpenPanel()
        panel.title = "Choose intake folder"
        panel.prompt = "Use this folder"
        panel.canChooseFiles = false
        panel.canChooseDirectories = true
        panel.canCreateDirectories = true
        panel.allowsMultipleSelection = false
        panel.directoryURL = services.intakeDirURL
        guard panel.runModal() == .OK, let picked = panel.url else { return }
        services.setIntakeDirectory(picked)
    }

    // MARK: - Timeline

    @ViewBuilder
    private var timelineBody: some View {
        // Deferred-write selection binding. Writing through `@Bindable`'s
        // projection synchronously inside SwiftUI's update cycle
        // triggered the same re-entrant @Observable cascade that blanked
        // columns in the old Vault Browser (documented on
        // `VaultBrowserView`). The `Task { @MainActor in ... }` hop
        // moves the mutation to the next main-actor turn so the List's
        // redraw and the per-snapshot reset don't race.
        let snapshotSelection = Binding<Int64?>(
            get: { viewModel.selectedSnapshotID },
            set: { newValue in
                Task { @MainActor in
                    viewModel.selectedSnapshotID = newValue
                }
            }
        )

        let items = viewModel.timeline

        if items.isEmpty && viewModel.snapshotsState == .loaded {
            emptyState
        } else {
            List(selection: snapshotSelection) {
                ForEach(items) { item in
                    row(for: item)
                        // Tag only snapshot rows with a selectable value.
                        // Intake events are informational and shouldn't
                        // move the right pane's file list — leaving them
                        // without a tag keeps the List's selection from
                        // binding to a meaningless id.
                        .tag(tag(for: item))
                }
                if viewModel.hasMoreSnapshots {
                    loadMoreSnapshotsFooter
                }
            }
            .listStyle(.inset)
            .overlay(alignment: .top) {
                if case .failed(let message) = viewModel.snapshotsState {
                    errorBanner(message: message)
                }
            }
        }
    }

    /// Binds a timeline row to the `selectedSnapshotID` column only when
    /// the row is a snapshot. Event rows get `nil` so the List knows
    /// they're non-selectable. Using `Int64??` (double-optional) is
    /// intentional: the outer optional is the tag value; the inner is
    /// `selectedSnapshotID`'s own Optional.
    private func tag(for item: ArchiveInspectorViewModel.TimelineItem) -> Int64?? {
        switch item {
        case .snapshot(let summary):
            return .some(.some(summary.id))
        case .event:
            return nil
        }
    }

    @ViewBuilder
    private func row(for item: ArchiveInspectorViewModel.TimelineItem) -> some View {
        switch item {
        case .snapshot(let summary):
            ArchiveInspectorSnapshotRow(summary: summary)
        case .event(let event):
            ArchiveInspectorEventRow(event: event)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No intake history yet.")
                .font(.headline)
            Text("Drop an export into the folder above to kick off ingestion.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }

    private var loadMoreSnapshotsFooter: some View {
        HStack {
            Spacer()
            if viewModel.snapshotsState == .loading {
                ProgressView().controlSize(.small)
            } else {
                Button("Load more") {
                    Task { await viewModel.loadMoreSnapshots() }
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
                Task { await viewModel.loadMoreSnapshots() }
            }
            .buttonStyle(.borderless)
            .controlSize(.small)
        }
        .padding(8)
        .background(.yellow.opacity(0.18))
    }
}

// MARK: - Rows

/// One vaulted-snapshot row in the timeline. Selectable. Shows the
/// provider label + file count and import time; keeps chrome to a
/// minimum so a long list doesn't feel dense.
private struct ArchiveInspectorSnapshotRow: View {
    let summary: RawExportSnapshotSummary

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "cube.box.fill")
                .foregroundStyle(.blue)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(summary.provider.displayName)
                        .font(.subheadline.weight(.medium))
                    Spacer()
                    Text(importedAtFormatted)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text("\(summary.fileCount) file\(summary.fileCount == 1 ? "" : "s") · \(ByteCountFormatter.string(fromByteCount: summary.originalBytes, countStyle: .file))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                if let source = summary.sourceRoot, !source.isEmpty {
                    Text(source)
                        .font(.caption2.monospaced())
                        .foregroundStyle(.tertiary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
        }
        .padding(.vertical, 4)
    }

    /// Relative time string on recent imports, falling back to an ISO
    /// date on older ones. Matches the activity-log row's cadence so
    /// the merged list reads consistently regardless of which row type
    /// the user's eye lands on.
    private var importedAtFormatted: String {
        let date = GRDBProjectDateCodec.date(from: summary.importedAt)
        let formatter = RelativeDateTimeFormatter()
        formatter.unitsStyle = .abbreviated
        return formatter.localizedString(for: date, relativeTo: Date())
    }
}

/// One ephemeral intake-log row. Non-selectable. Mirrors the icon/color
/// palette from the old `AutoIntakePane` so moving the log into this
/// pane doesn't look like a stylistic reset.
private struct ArchiveInspectorEventRow: View {
    let event: IntakeActivityLog.Event

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: iconName)
                .foregroundStyle(iconColor)
                .frame(width: 20)
            VStack(alignment: .leading, spacing: 2) {
                HStack {
                    Text(event.source)
                        .font(.subheadline.weight(.medium))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    Spacer()
                    Text(event.timestamp, style: .relative)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Text(summary)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
            }
        }
        .padding(.vertical, 4)
    }

    private var iconName: String {
        switch event.kind {
        case .ingested: return "checkmark.circle.fill"
        case .alreadyIngested: return "arrow.triangle.2.circlepath.circle.fill"
        case .importerFailed: return "exclamationmark.triangle.fill"
        case .unrecognized: return "questionmark.circle"
        case .failed: return "xmark.octagon.fill"
        }
    }

    private var iconColor: Color {
        switch event.kind {
        case .ingested: return .green
        case .alreadyIngested: return .blue
        case .importerFailed, .failed: return .red
        case .unrecognized: return .orange
        }
    }

    private var summary: String {
        switch event.kind {
        case .ingested(let id, let count):
            return "Ingested snapshot \(id) — \(count) JSON file\(count == 1 ? "" : "s")."
        case .alreadyIngested(let id):
            return "Already ingested — reused snapshot \(id)."
        case .importerFailed(let id, let detail):
            return "Importer failed (snapshot \(id)): \(detail)"
        case .unrecognized(let reason):
            return reason
        case .failed(let detail):
            return detail
        }
    }
}

private extension RawExportProvider {
    /// Short display name for the provider, e.g. "ChatGPT" / "Claude".
    /// Falls through to the raw identifier for unknown providers so we
    /// never render the row with a blank label.
    var displayName: String {
        switch rawValue.lowercased() {
        case "chatgpt": return "ChatGPT"
        case "claude": return "Claude"
        case "gemini": return "Gemini"
        default: return rawValue
        }
    }
}
#endif
