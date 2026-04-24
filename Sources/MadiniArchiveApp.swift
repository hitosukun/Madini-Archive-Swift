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
        }
        #endif

        #if os(macOS)
        Settings {
            SettingsRootView()
                .environment(identityPreferences)
                .environment(archiveEvents)
        }
        // The standalone Vault Browser window scene and its ⌘⌥V menu
        // binding have been retired. Everything that surface used to
        // show — snapshot list, per-snapshot files, file-content
        // preview — now lives inside the sidebar's archive.db entry
        // (see `ArchiveInspectorPane` + `ArchiveInspectorFileListPane`),
        // which keeps the vault browsing surface discoverable from one
        // place instead of three.
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
