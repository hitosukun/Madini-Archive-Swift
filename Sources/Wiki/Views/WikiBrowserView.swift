import SwiftUI

/// Three-pane browser for the Wiki feature:
///   left = vault list (registered vaults)
///   middle = file tree of the selected vault
///   right = rendered page content
///
/// Lives inside the Wiki window; the main archive window's three-pane
/// layout is unaffected. Loads its own state from `AppServices` on
/// first appearance.
struct WikiBrowserView: View {
    @EnvironmentObject private var services: AppServices
    @State private var viewModel: WikiBrowserViewModel?
    @State private var loaded = false
    @State private var sidebarVisibility: NavigationSplitViewVisibility = .all

    var body: some View {
        Group {
            if let vm = viewModel {
                NavigationSplitView(columnVisibility: $sidebarVisibility) {
                    WikiVaultListView(viewModel: vm)
                        .navigationSplitViewColumnWidth(
                            min: 180, ideal: 220, max: 320
                        )
                } content: {
                    WikiFileTreeView(viewModel: vm)
                        .navigationSplitViewColumnWidth(
                            min: 220, ideal: 300, max: 460
                        )
                } detail: {
                    if let page = vm.currentPage,
                       let vault = vm.currentVault {
                        WikiPageView(page: page, vault: vault, viewModel: vm)
                    } else {
                        WikiPagePlaceholderView(vault: vm.currentVault)
                    }
                }
                .navigationTitle(vm.currentVault?.name ?? "Wikis")
                .toolbar {
                    if let vault = vm.currentVault {
                        ToolbarItem(placement: .primaryAction) {
                            Button {
                                Task { await vm.reindex(vault: vault) }
                            } label: {
                                Label("Re-index", systemImage: "arrow.clockwise")
                            }
                        }
                    }
                }
            } else {
                ProgressView().controlSize(.small)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            let vm = WikiBrowserViewModel(services: services)
            viewModel = vm
            await vm.reloadVaults()
        }
        .onReceive(
            NotificationCenter.default.publisher(
                for: MadiniURLHandler.didRequestWikiPage
            )
        ) { note in
            guard let info = note.userInfo,
                  let vaultID = info["vaultID"] as? String,
                  let relativePath = info["relativePath"] as? String,
                  let vm = viewModel else { return }
            Task { await vm.handleDeeplink(vaultID: vaultID, relativePath: relativePath) }
        }
    }
}
