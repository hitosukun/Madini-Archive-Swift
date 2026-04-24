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

/// Bundle of window-scoped actions the main menu bar's `AppCommands` needs
/// to invoke — layout switching, library reload, archive-inspector delete,
/// drop-folder open. Published by `DesignMockRootView` as a single
/// `FocusedValue` (instead of many) so the command struct stays readable
/// and each new menu entry is a one-line closure wire-up.
///
/// Closures rather than raw state so the shell can do whatever it needs to
/// (mutate `@State`, dispatch async Tasks, reach into
/// `ArchiveInspectorViewModel`) without leaking its internals to the
/// commands layer.
struct ShellCommandActions {
    /// Currently-selected outer layout mode. Used by the menu to show
    /// the check mark next to the active item (SwiftUI doesn't offer a
    /// built-in state indicator for menu items, but comparing here lets
    /// us disable the "set layout" action for the mode we're already in).
    let currentLayout: DesignMockLayoutMode
    let setLayout: (DesignMockLayoutMode) -> Void
    /// Re-run the in-flight library query and re-sync the library view
    /// model's supporting state. Bound to ⌘R (matches the universal
    /// "refresh" shortcut across Safari / Mail / Finder).
    let reloadLibrary: () -> Void
    /// Move the shell's conversation selection forward by one row in the
    /// currently-loaded list. Nil when the list is empty (SwiftUI greys
    /// out the menu item). Wired through the shell rather than through
    /// `LibraryViewModel.selectNext` because the middle pane reads the
    /// shell's `selectedConversationIDs`, not the VM's
    /// `selectedConversationId` — the two were never bridged, so the
    /// previous "route through the VM" approach silently moved an
    /// invisible cursor.
    let selectNextConversation: (() -> Void)?
    /// Symmetric predecessor of `selectNextConversation`. Same rationale
    /// applies — the shell owns the visible selection.
    let selectPreviousConversation: (() -> Void)?
    /// Open the intake drop folder in Finder. Works whether the user is
    /// using the default location or has pointed the app at a custom
    /// folder via the Archive Inspector's header buttons.
    let openDropFolder: () -> Void
    /// Non-nil only when the Archive Inspector is the focused pane AND
    /// a snapshot row is selected. Calling it fires the same
    /// confirmation-alert flow the context menu's "Delete snapshot…"
    /// uses. Nil disables the menu item (SwiftUI renders it grey).
    let deleteSelectedSnapshot: (() -> Void)?
}

struct ShellCommandsKey: FocusedValueKey {
    typealias Value = ShellCommandActions
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

    var shellCommands: ShellCommandActions? {
        get { self[ShellCommandsKey.self] }
        set { self[ShellCommandsKey.self] = newValue }
    }
}

/// Main-menu commands. Follows macOS HIG conventions:
///
/// - **View menu** (via `CommandGroup(after: .sidebar)`) — Finder-style
///   layout switchers on ⌘1 / ⌘2 / ⌘3.
/// - **Library menu** (new top-level via `CommandMenu`) — thread
///   navigation (moved here from the Edit menu where it used to live)
///   plus ⌘R for reload.
/// - **Archive menu** (new top-level) — drop-folder access and
///   snapshot deletion, enabled only when the Archive Inspector is in
///   focus with a selected snapshot.
///
/// Commands that depend on per-window state (layout, archive, library)
/// read through `ShellCommandActions` / `libraryViewModel` /
/// `browseViewModel` FocusedValues. When the focused window doesn't
/// publish these (e.g. Settings scene), the buttons render disabled
/// rather than throwing — matches how Mail and Finder disable their
/// context-specific menu items when the relevant pane isn't the key
/// one.
struct AppCommands: Commands {
    @FocusedValue(\.browseViewModel) private var browseViewModel
    @FocusedValue(\.libraryViewModel) private var libraryViewModel
    @FocusedValue(\.shellCommands) private var shell

    var body: some Commands {
        // View menu — layout switchers. `after: .sidebar` slots them
        // directly beneath the default "Show Sidebar" item SwiftUI
        // already publishes for NavigationSplitView, which is where a
        // user scanning the View menu will look first.
        CommandGroup(after: .sidebar) {
            Divider()
            Button("Table Layout") {
                shell?.setLayout(.table)
            }
            .keyboardShortcut("1", modifiers: .command)
            .disabled(shell == nil)

            Button("Default Layout") {
                shell?.setLayout(.default)
            }
            .keyboardShortcut("2", modifiers: .command)
            .disabled(shell == nil)

            Button("Viewer Layout") {
                shell?.setLayout(.viewer)
            }
            .keyboardShortcut("3", modifiers: .command)
            .disabled(shell == nil)
        }

        // Library menu — thread-level navigation + reload. Lives at
        // the top level (between View and Window) because these are
        // the highest-frequency actions in the app and the Edit menu
        // was getting misused as a catch-all. Mirrors how Mail keeps
        // "Message" as its own top-level menu.
        CommandMenu("Library") {
            // Route through the shell (not through LibraryViewModel /
            // BrowseViewModel) because only the shell owns the
            // user-visible selection state. The legacy BrowseViewModel
            // path stays as a fallback for the iOS-ish `MacOSRootView`
            // code path, but on the shipping macOS shell the
            // `shell?.selectNextConversation` branch is the one that
            // actually moves the middle pane.
            Button("Next Conversation") {
                if let move = shell?.selectNextConversation {
                    move()
                } else {
                    browseViewModel?.selectNext()
                }
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(shell?.selectNextConversation == nil && browseViewModel == nil)

            Button("Previous Conversation") {
                if let move = shell?.selectPreviousConversation {
                    move()
                } else {
                    browseViewModel?.selectPrevious()
                }
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(shell?.selectPreviousConversation == nil && browseViewModel == nil)

            Divider()

            Button("Reload") {
                shell?.reloadLibrary()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(shell == nil)
        }

        // Archive menu — drop-folder access and snapshot deletion.
        // Separate from Library because these act on archive.db
        // (import surface / vaulted snapshots) rather than on the
        // conversation list.
        CommandMenu("Archive") {
            Button("Open Drop Folder") {
                shell?.openDropFolder()
            }
            .keyboardShortcut("o", modifiers: [.command, .shift])
            .disabled(shell == nil)

            Divider()

            // ⌘⌫ matches Finder's "Move to Trash" and Mail's "Delete
            // Message". Plain ⌫ would fire inside text fields (search
            // box) which is unsafe for a destructive action; the
            // ⌘-modified form only fires when the menu item is in the
            // focus path and the archive inspector owns the key
            // column. The shell publishes a nil closure when no
            // snapshot is selected, which greys this out.
            Button("Delete Snapshot…") {
                shell?.deleteSelectedSnapshot?()
            }
            .keyboardShortcut(.delete, modifiers: .command)
            .disabled(shell?.deleteSelectedSnapshot == nil)
        }
    }
}
