#if os(macOS)
import AppKit
import SwiftUI

/// Library sidebar entry point for the auto-intake feature. Shows the watched
/// folder path (with a button to reveal it in Finder), plus the rolling event
/// log from `IntakeActivityLog`. Read-only — dropping files into the folder
/// happens in Finder, not here.
///
/// Binds to `services.intake.activityLog.events`. Because `IntakeActivityLog`
/// is `@Observable`, SwiftUI re-renders automatically as events arrive.
struct AutoIntakePane: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if let log = services.intakeActivityLog {
                AutoIntakeActivityList(log: log)
            } else {
                disabledBody
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .navigationTitle("Auto Intake")
    }

    private var header: some View {
        let url = services.intakeDirURL
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
                    NSWorkspace.shared.activateFileViewerSelecting([url])
                } label: {
                    Label("Reveal in Finder", systemImage: "folder")
                }
                .controlSize(.small)
                Button {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(url.path, forType: .string)
                } label: {
                    Label("Copy path", systemImage: "doc.on.doc")
                }
                .controlSize(.small)
            }
            Text("Exports dropped here (zip or folder) are ingested automatically. Re-dropping an already-vaulted export is detected and skipped.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(16)
    }

    private var disabledBody: some View {
        // Hit when the app is backed by the mock `DataSource` — intake is not
        // wired up, so activity log access would return `nil`. Keep the path
        // visible so the user can still see where the folder would be, but
        // explain why nothing is happening.
        VStack(alignment: .leading, spacing: 8) {
            Image(systemName: "exclamationmark.triangle")
                .font(.title2)
                .foregroundStyle(.secondary)
            Text("Auto-intake is disabled in mock mode.")
                .font(.headline)
            Text("Run the app against a real archive database to enable drop-folder watching.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
        .padding(24)
    }
}

private struct AutoIntakeActivityList: View {
    let log: IntakeActivityLog

    var body: some View {
        if log.events.isEmpty {
            emptyState
        } else {
            List {
                Section {
                    ForEach(log.events.reversed()) { event in
                        AutoIntakeEventRow(event: event)
                    }
                } header: {
                    HStack {
                        Text("Recent activity")
                        Spacer()
                        Button("Clear") { log.clear() }
                            .controlSize(.small)
                            .buttonStyle(.borderless)
                    }
                }
            }
            .listStyle(.inset)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 8) {
            Image(systemName: "tray")
                .font(.largeTitle)
                .foregroundStyle(.tertiary)
            Text("No intake events yet.")
                .font(.headline)
            Text("Drop an export into the folder above to kick off ingestion.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(24)
    }
}

private struct AutoIntakeEventRow: View {
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

struct AutoIntakeDetailPlaceholder: View {
    var body: some View {
        VStack(spacing: 12) {
            Image(systemName: "tray.and.arrow.down")
                .font(.system(size: 36))
                .foregroundStyle(.tertiary)
            Text("Select an activity row to inspect a snapshot.")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}
#endif
