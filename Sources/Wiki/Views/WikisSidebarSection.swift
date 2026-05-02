import SwiftUI

/// Sidebar entry for the Wiki feature. Shows a per-vault row plus an
/// "Open Wiki Browser" affordance. Each row opens the dedicated Wiki
/// window via `openWindow(id:)` so the main archive layout is unaffected.
struct WikisSidebarSection: View {
    @EnvironmentObject private var services: AppServices
    @Environment(\.openWindow) private var openWindow
    @State private var vaults: [WikiVault] = []
    @State private var loaded = false

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            if vaults.isEmpty {
                Button {
                    openWindow(id: "wiki-browser")
                } label: {
                    Label("Add a vault…", systemImage: "plus.circle")
                        .font(.callout)
                }
                .buttonStyle(.plain)
                .help("Open the Wiki window to register a vault, or add one in Settings → Wiki Vaults.")
            } else {
                ForEach(vaults) { vault in
                    Button {
                        openWindow(id: "wiki-browser")
                    } label: {
                        Label(vault.name, systemImage: "books.vertical")
                            .font(.callout)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                    }
                    .buttonStyle(.plain)
                }
                Button {
                    openWindow(id: "wiki-browser")
                } label: {
                    Label("Open Wiki Browser", systemImage: "rectangle.stack")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.plain)
                .padding(.top, 4)
            }
        }
        .task {
            guard !loaded else { return }
            loaded = true
            await reload()
        }
    }

    private func reload() async {
        do {
            vaults = try await services.wikiVaults.listVaults(offset: 0, limit: 200)
        } catch {
            vaults = []
        }
    }
}
