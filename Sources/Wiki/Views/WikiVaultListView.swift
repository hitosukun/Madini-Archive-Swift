import SwiftUI

/// Displays the list of registered vaults as the leftmost column of the
/// Wiki browser. Selecting a vault loads its page list into the file
/// tree column.
struct WikiVaultListView: View {
    let viewModel: WikiBrowserViewModel

    var body: some View {
        List(selection: Binding(
            get: { viewModel.selectedVaultID },
            set: { newValue in
                Task { await viewModel.selectVault(id: newValue) }
            }
        )) {
            Section("Vaults") {
                if viewModel.vaults.isEmpty {
                    Text("Add a vault in Settings → Wiki Vaults.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                } else {
                    ForEach(viewModel.vaults) { vault in
                        Label(vault.name, systemImage: "books.vertical")
                            .tag(vault.id as String?)
                    }
                }
            }
        }
        .listStyle(.sidebar)
    }
}
