import SwiftUI
#if os(macOS)
import AppKit
#endif

#if os(macOS)
final class MadiniAppDelegate: NSObject, NSApplicationDelegate {
    /// Disable macOS-native window tabbing app-wide. We're a single-
    /// window archive viewer — the system "Show Tab Bar" / "Merge All
    /// Windows" / ⌘T flow doesn't compose with the three-pane
    /// navigation model and merged tabs would hide the Library /
    /// Archive / Settings menus behind a tab strip the user didn't ask
    /// for.
    ///
    /// Two-pronged fix because the class-level default and the per-
    /// window mode govern different things:
    ///
    ///   * `NSWindow.allowsAutomaticWindowTabbing = false` fires in
    ///     `applicationWillFinishLaunching` — *before* SwiftUI builds
    ///     the menu bar — and stops AppKit from auto-merging new
    ///     windows into a tab group. Setting it later (in
    ///     `applicationDidFinishLaunching`) doesn't take effect on the
    ///     menu bar because by then SwiftUI has already wired up "Show
    ///     Tab Bar" / "Show All Tabs" using the value it observed
    ///     during scene construction.
    ///   * `window.tabbingMode = .disallowed` runs per-window after the
    ///     scene exists. This is what actually removes "Show Tab Bar"
    ///     and "Show All Tabs" from the View menu and disables
    ///     "Merge All Windows" / drag-to-merge for that specific
    ///     window. We apply it to every window NSApp already knows
    ///     about and observe `didBecomeKey` so any future scene
    ///     (Settings, etc.) gets the same treatment.
    func applicationWillFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        for window in NSApp.windows {
            window.tabbingMode = .disallowed
        }
        NotificationCenter.default.addObserver(
            self,
            selector: #selector(disableTabbingOnWindow(_:)),
            name: NSWindow.didBecomeKeyNotification,
            object: nil
        )

        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            NSApp.windows.first?.makeKeyAndOrderFront(nil)
        }
    }

    @objc private func disableTabbingOnWindow(_ notification: Notification) {
        guard let window = notification.object as? NSWindow else { return }
        window.tabbingMode = .disallowed
    }
}
#endif

@main
struct MadiniArchiveApp: App {
    @StateObject private var services = AppServices()
    @State private var identityPreferences = IdentityPreferencesStore()
    @State private var archiveEvents = ArchiveEvents()
    /// Browser-style body-text zoom shared across every reader scene.
    /// Held by the App so a single instance survives scene restores
    /// and is wired into both the environment (for views) and
    /// `AppCommands` (for the View-menu shortcuts).
    @StateObject private var bodyTextSize = BodyTextSizePreference()
    #if os(macOS)
    @NSApplicationDelegateAdaptor(MadiniAppDelegate.self) private var appDelegate
    #endif

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(services)
                .environment(identityPreferences)
                .environment(archiveEvents)
                .environmentObject(bodyTextSize)
                .environment(\.bodyTextSizeMultiplier, bodyTextSize.multiplier)
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
            AppCommands(bodyTextSize: bodyTextSize)
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
    /// Jump the shell's conversation selection to the first visible row
    /// in the currently-loaded list. Bound to ⌘↑ (mirrors the
    /// macOS-wide "top of document" gesture). Single-step up/down
    /// navigation lives in the List/Table widget itself — plain ↑/↓
    /// with keyboard focus on the middle pane steps one row at a time,
    /// so we don't also bind a menu shortcut for it (doing so would
    /// capture the arrows globally and break text-field navigation).
    /// Nil when the list is empty.
    let selectFirstConversation: (() -> Void)?
    /// ⌘↓ counterpart of `selectFirstConversation` — jump to the last
    /// visible row. Same rationale as above.
    let selectLastConversation: (() -> Void)?
    /// ⌘→ "drill in" one level along the Thread list → Thread → Prompt
    /// hierarchy. In `.table`, switches to `.default`. In `.default` with
    /// no card expanded, opens the selected card (prompts list appears
    /// in center pane). In `.default` with a card already open, no-op.
    /// Nil means the drill is impossible from the current state (e.g.
    /// `.table` with no selection and no rows to auto-pick).
    let drillInSelection: (() -> Void)?
    /// ⌘← counterpart of `drillInSelection`. In `.default` with a card
    /// open, closes the card. In `.default` with no card open, switches
    /// back to `.table`. In `.viewer`, escapes to `.default`. Nil when
    /// already at the leftmost level (`.table`).
    let drillOutSelection: (() -> Void)?
    /// Open the intake drop folder in Finder. Works whether the user is
    /// using the default location or has pointed the app at a custom
    /// folder via the Archive Inspector's header buttons.
    let openDropFolder: () -> Void
    /// Non-nil only when the Archive Inspector is the focused pane AND
    /// a snapshot row is selected. Calling it fires the same
    /// confirmation-alert flow the context menu's "Delete snapshot…"
    /// uses. Nil disables the menu item (SwiftUI renders it grey).
    let deleteSelectedSnapshot: (() -> Void)?
    /// Toggle the browser-style find-in-page bar in the reader.
    /// Bound to ⌘F. Nil when no reader is mounted (archive
    /// inspector / mock-empty modes) so the menu item disables.
    let toggleFindInPage: (() -> Void)?
}

struct ShellCommandsKey: FocusedValueKey {
    typealias Value = ShellCommandActions
}

/// Prompt-level navigation actions, published by whichever
/// surface in the scene is best-suited to interpret the gesture.
/// Four independent closures so the menu can bind distinct
/// shortcuts for step-walk vs jump-to-edge:
///
/// - `stepPrev` / `stepNext` → ⌘↑ / ⌘↓ — walk one prompt in the
///   transcript. Useful in `.viewer` where plain ↑/↓ scrolls the
///   reader and there's no list UI to arrow through. State 3's
///   prompt list deliberately leaves these nil (plain ↑/↓ on the
///   focused list already does the job, so a menu duplicate would
///   be redundant) — the menu item greys out and the shell
///   doesn't fall through since step semantics don't translate to
///   thread-level.
/// - `jumpFirst` / `jumpLast` → ⌘⇧↑ / ⌘⇧↓ — jump to the first /
///   last prompt. Both state 3 (visible list) and viewer publish
///   these. Outside viewer / state 3 the menu falls through to
///   `ShellCommandActions.selectFirst/LastConversation` so the
///   ⌘⇧↑/↓ shortcut still jumps thread edges in state 1/2.
///
/// `focusedValue` from a focused subtree takes precedence over
/// `focusedSceneValue`, so state 3's publication (via
/// `focusedValue` on the prompt list) shadows the shell's scene-
/// wide one whenever the prompt list is in tree — preventing the
/// "two publishers, one wins ambiguously" pitfall.
struct PromptNavigationActions {
    /// ⌘↑ action. Nil disables the menu item. Currently only
    /// viewer mode populates this — state 3 relies on plain ↑/↓
    /// which is already wired through the prompt list's focus.
    let stepPrev: (() -> Void)?
    /// ⌘↓ counterpart of `stepPrev`.
    let stepNext: (() -> Void)?
    /// ⌘⇧↑ action: jump to the first prompt of the active outline.
    /// Nil when the outline is empty.
    let jumpFirst: (() -> Void)?
    /// ⌘⇧↓ counterpart of `jumpFirst`.
    let jumpLast: (() -> Void)?
}

struct PromptNavigationKey: FocusedValueKey {
    typealias Value = PromptNavigationActions
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

    var promptNavigation: PromptNavigationActions? {
        get { self[PromptNavigationKey.self] }
        set { self[PromptNavigationKey.self] = newValue }
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
    /// Non-nil only when state 3's prompt list owns keyboard focus.
    /// Takes precedence over `shell`'s thread-level jump closures
    /// so ⌘↑/⌘↓ retarget the prompt rows instead of the cards.
    @FocusedValue(\.promptNavigation) private var promptNav

    /// Browser-style body-text zoom, owned by the App and threaded
    /// through here so the View menu can drive it. `@ObservedObject`
    /// rather than `@StateObject` because the App holds the source
    /// of truth — this is just an observation point.
    @ObservedObject var bodyTextSize: BodyTextSizePreference

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

            Button("Dashboard Layout") {
                shell?.setLayout(.stats)
            }
            .keyboardShortcut("4", modifiers: .command)
            .disabled(shell == nil)

            // Browser-style body-text zoom. Sits in the View menu
            // beneath the layout switchers because both control "how
            // the reader looks" — keeping them in the same group
            // mirrors Mail.app, which co-locates layout and font-size
            // controls under View. Kept enabled at the limits (rather
            // than disabled) so ⌘= at 200 % / ⌘- at 70 % silently no-
            // op instead of triggering the system error beep that an
            // unbound shortcut would.
            Divider()

            Button("Increase Body Text Size") {
                bodyTextSize.stepUp()
            }
            .keyboardShortcut("=", modifiers: .command)

            Button("Decrease Body Text Size") {
                bodyTextSize.stepDown()
            }
            .keyboardShortcut("-", modifiers: .command)

            Button("Reset Body Text Size") {
                bodyTextSize.reset()
            }
            .keyboardShortcut("0", modifiers: .command)
        }

        // Library menu — thread-level navigation + reload. Lives at
        // the top level (between View and Window) because these are
        // the highest-frequency actions in the app and the Edit menu
        // was getting misused as a catch-all. Mirrors how Mail keeps
        // "Message" as its own top-level menu.
        CommandMenu("Library") {
            // ⌘↑ / ⌘↓ jump to the first / last visible row. Single-
            // step up/down is handled by the focused List/Table
            // itself — plain ↑/↓ with the middle pane focused steps
            // one row at a time, and binding that here would capture
            // the arrow keys globally (breaking text-field cursor
            // movement in the search box). Matches the macOS-wide
            // "top of document / end of document" convention for ⌘↑
            // and ⌘↓.
            // Target resolution: prompt list wins when focused
            // (state 3), otherwise fall through to the shell's
            // thread-list jump closures. Both the call-site and
            // the disabled-state evaluation mirror that order, so
            // the menu item's enablement reflects whatever list
            // the user is currently navigating.
            // ⌘↑ / ⌘↓ — Step through prompts in the transcript.
            // Only active in viewer mode; state 3 leaves these
            // closures nil because the prompt list's plain ↑ / ↓
            // already steps rows and a duplicate menu binding
            // would be noise. In state 1/2 no `promptNav` is
            // published, so the items grey out — ⌘↑ / ⌘↓ have no
            // thread-level meaning now that edge-jump moved to
            // ⌘⇧↑ / ⌘⇧↓.
            Button("Previous Prompt") {
                promptNav?.stepPrev?()
            }
            .keyboardShortcut(.upArrow, modifiers: .command)
            .disabled(promptNav?.stepPrev == nil)

            Button("Next Prompt") {
                promptNav?.stepNext?()
            }
            .keyboardShortcut(.downArrow, modifiers: .command)
            .disabled(promptNav?.stepNext == nil)

            Divider()

            // ⌘⇧↑ / ⌘⇧↓ — Jump to the first / last row of
            // whichever list is currently in focus. Resolution
            // order: prompt-level jump when a prompt surface is
            // focused (state 3 or viewer), otherwise thread-level
            // via the shell. User ask: "先頭と最後尾にジャンプ
            // するのは、cmd+shift+上下に統一した方がいいかな？" —
            // unifies edge-jump under a single shortcut family
            // across all three list tiers.
            Button("First Conversation") {
                if let jump = promptNav?.jumpFirst {
                    jump()
                } else {
                    shell?.selectFirstConversation?()
                }
            }
            .keyboardShortcut(.upArrow, modifiers: [.command, .shift])
            .disabled(promptNav?.jumpFirst == nil && shell?.selectFirstConversation == nil)

            Button("Last Conversation") {
                if let jump = promptNav?.jumpLast {
                    jump()
                } else {
                    shell?.selectLastConversation?()
                }
            }
            .keyboardShortcut(.downArrow, modifiers: [.command, .shift])
            .disabled(promptNav?.jumpLast == nil && shell?.selectLastConversation == nil)

            Divider()

            // ⌘→ / ⌘← drill the user along the
            // Thread list → Thread → Prompt hierarchy. The shell owns
            // the state machine (layout mode × card-expanded flag), so
            // the menu just forwards the gesture — when the user is
            // already at an edge (⌘← in `.table`, ⌘→ in `.default`
            // with card open), the shell ships nil and SwiftUI greys
            // the item out.
            //
            // Labels are deliberately plain — "Open Selection" /
            // "Close Selection" reads for someone who has never seen
            // the drill model before but can infer "open" = "dig
            // deeper into what I've selected" from Finder's ⌘O.
            Button("Open Selection") {
                shell?.drillInSelection?()
            }
            .keyboardShortcut(.rightArrow, modifiers: .command)
            .disabled(shell?.drillInSelection == nil)

            Button("Close Selection") {
                shell?.drillOutSelection?()
            }
            .keyboardShortcut(.leftArrow, modifiers: .command)
            .disabled(shell?.drillOutSelection == nil)

            Divider()

            Button("Reload") {
                shell?.reloadLibrary()
            }
            .keyboardShortcut("r", modifiers: .command)
            .disabled(shell == nil)
        }

        // ⌘F — toggle the reader's browser-style find bar. Slotted
        // into the standard Edit menu's text-editing group so it
        // sits next to "Find Next" / "Find Previous" in the place
        // a user would scan for it.
        CommandGroup(after: .textEditing) {
            Button("Find") {
                shell?.toggleFindInPage?()
            }
            .keyboardShortcut("f", modifiers: .command)
            .disabled(shell?.toggleFindInPage == nil)
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
