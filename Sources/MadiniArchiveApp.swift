import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
final class MadiniAppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }
}
#endif

@main
struct MadiniArchiveApp: App {
    @StateObject private var services = AppServices()
    @State private var identityPreferences = IdentityPreferencesStore()
    @State private var archiveEvents = ArchiveEvents()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MadiniAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .environment(identityPreferences)
                .environment(archiveEvents)
                #if os(macOS)
                // Start auto-intake once the main scene appears. `.task`
                // anchors the lifecycle to the root view so the poll loop
                // goes away when the window closes. `startIntake` is
                // idempotent, so scene restores don't spawn a second poller.
                .task {
                    services.startIntake()
                }
                #endif
        }
        #if os(macOS)
        .defaultSize(width: 1200, height: 800)
        .commands {
            AppCommands()
            VaultBrowserCommands()
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsRootView()
                .environment(identityPreferences)
                .environment(archiveEvents)
        }

        // Phase D1: stand-alone raw-export vault browser. Lives in its own
        // Window so it can be opened / closed without touching the main
        // reader UI. Accessible from Window → Vault Browser (⌘⌥V, wired in
        // `VaultBrowserCommands`).
        Window("Vault Browser", id: VaultBrowserCommands.windowID) {
            VaultBrowserView(
                vault: services.rawExportVault,
                assetResolver: services.rawAssetResolver
            )
                .environmentObject(services)
                .frame(minWidth: 720, minHeight: 480)
        }
        .defaultSize(width: 960, height: 640)
        #endif
    }
}

struct RootView: View {
    @EnvironmentObject private var services: AppServices

    var body: some View {
        #if os(macOS)
        DesignMockRootView()
        #else
        IOSRootView(services: services)
        #endif
    }
}

struct BrowseViewModelKey: FocusedValueKey {
    typealias Value = BrowseViewModel
}

struct LibraryViewModelKey: FocusedValueKey {
    typealias Value = LibraryViewModel
}

extension FocusedValues {
    var browseViewModel: BrowseViewModel? {
        get { self[BrowseViewModelKey.self] }
        set { self[BrowseViewModelKey.self] = newValue }
    }

    var libraryViewModel: LibraryViewModel? {
        get { self[LibraryViewModelKey.self] }
        set { self[LibraryViewModelKey.self] = newValue }
    }
}

#if os(macOS)
/// Adds a `Window → Vault Browser` menu entry bound to ⌘⌥V, opening the
/// Phase D1 Vault Browser window scene. Isolated from `AppCommands` so the
/// main-reader navigation shortcuts stay untouched.
struct VaultBrowserCommands: Commands {
    static let windowID = "vault-browser"

    @Environment(\.openWindow) private var openWindow

    var body: some Commands {
        CommandGroup(after: .windowArrangement) {
            Button("Vault Browser") {
                openWindow(id: Self.windowID)
            }
            .keyboardShortcut("v", modifiers: [.command, .option])
        }
    }
}
#endif

struct AppCommands: Commands {
    @FocusedValue(\.browseViewModel) private var viewModel
    @FocusedValue(\.libraryViewModel) private var libraryViewModel

    var body: some Commands {
        CommandGroup(after: .textEditing) {
            Section {
                Button("Next Conversation") {
                    libraryViewModel?.selectNext() ?? viewModel?.selectNext()
                }
                .keyboardShortcut(.downArrow, modifiers: .command)

                Button("Previous Conversation") {
                    libraryViewModel?.selectPrevious() ?? viewModel?.selectPrevious()
                }
                .keyboardShortcut(.upArrow, modifiers: .command)
            }
        }
    }
}
