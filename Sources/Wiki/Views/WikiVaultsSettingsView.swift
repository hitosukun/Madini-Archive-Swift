import SwiftUI
#if os(macOS)
import AppKit
#endif

/// Settings tab for managing registered Obsidian vaults. Lists every
/// vault, lets the user add a new one (folder picker), remove an
/// existing one, or trigger a manual reindex. Indexing is read-only
/// against the vault filesystem.
struct WikiVaultsSettingsView: View {
    @EnvironmentObject private var services: AppServices
    @State private var viewModel: WikiBrowserViewModel?
    @State private var loaded = false

    var body: some View {
        Form {
            Section {
                if let vm = viewModel {
                    if vm.vaults.isEmpty {
                        ContentUnavailableView(
                            "No Wiki Vaults",
                            systemImage: "books.vertical",
                            description: Text("Add an Obsidian vault folder to browse it from M.Archive.")
                        )
                        .frame(maxWidth: .infinity, minHeight: 120)
                    } else {
                        ForEach(vm.vaults) { vault in
                            VaultRow(vault: vault, viewModel: vm)
                        }
                    }
                }
            } header: {
                HStack {
                    Text("Registered Vaults")
                    Spacer()
                    Button("Add Vault…") {
                        Task { await addVault() }
                    }
                }
            }

            if let vm = viewModel {
                if let msg = vm.indexingMessage {
                    Section {
                        HStack(spacing: 8) {
                            ProgressView().controlSize(.small)
                            Text(msg).font(.callout)
                        }
                    }
                }
                if let err = vm.errorMessage {
                    Section {
                        Text(err)
                            .font(.callout)
                            .foregroundStyle(.red)
                    }
                }
            }

            Section {
                Text(
                    """
                    M.Archive only reads from the vault. \
                    All indexing writes go to ~/Library/Application Support/Madini Archive/wiki_indexes/. \
                    Vault files are never modified, renamed, or deleted by this app.
                    """
                )
                .font(.footnote)
                .foregroundStyle(.secondary)
            } header: {
                Text("Read-only Guarantee")
            }
        }
        .formStyle(.grouped)
        .padding(20)
        .task {
            guard !loaded else { return }
            loaded = true
            let vm = WikiBrowserViewModel(services: services)
            viewModel = vm
            await vm.reloadVaults()
        }
    }

    @MainActor
    private func addVault() async {
        guard let vm = viewModel else { return }
        #if os(macOS)
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Vault"
        panel.message = "Choose your Obsidian vault folder. M.Archive will read it but never modify it."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        await vm.registerVault(at: url)
        #endif
    }
}

private struct VaultRow: View {
    let vault: WikiVault
    let viewModel: WikiBrowserViewModel
    @State private var confirmingDelete = false

    var body: some View {
        HStack(alignment: .top, spacing: 12) {
            Image(systemName: "books.vertical.fill")
                .foregroundStyle(.tint)
                .frame(width: 24)
            VStack(alignment: .leading, spacing: 2) {
                Text(vault.name).font(.body.weight(.medium))
                Text(vault.path)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .truncationMode(.middle)
                    .lineLimit(1)
                if let last = vault.lastIndexedAt {
                    Text("Last indexed: \(last)")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                } else {
                    Text("Not yet indexed")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            Spacer()
            Button("Re-index") {
                Task { await viewModel.reindex(vault: vault) }
            }
            .controlSize(.small)
            Button(role: .destructive) {
                confirmingDelete = true
            } label: {
                Image(systemName: "trash")
            }
            .buttonStyle(.borderless)
            .confirmationDialog(
                "Remove \(vault.name)?",
                isPresented: $confirmingDelete
            ) {
                Button("Remove", role: .destructive) {
                    Task { await viewModel.unregisterVault(vault) }
                }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("This unregisters the vault from M.Archive. The vault folder itself stays untouched.")
            }
        }
        .padding(.vertical, 4)
    }
}
