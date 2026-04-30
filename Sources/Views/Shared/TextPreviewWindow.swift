#if os(macOS)
import AppKit
import SwiftUI
import UniformTypeIdentifiers

/// Standalone preview window for non-image vaulted files. Mirrors
/// `ImagePreviewWindow` in shape and feel — a plain `NSWindow` with a
/// titlebar `NSToolbar`, arrow-key gallery navigation across the
/// snapshot's sibling files, and a content view that concentrates on
/// showing the bytes.
///
/// Why a parallel window (not a unified file preview): the image
/// window's content is an `NSImage` decoded into SwiftUI's `Image`, while
/// text wants a scrollable monospaced `Text`. Toolbars differ too —
/// images expose Copy-as-image / Share via macOS sharing services,
/// whereas text exposes "Open Externally" (hand off to TextEdit / VS Code)
/// and "Copy text". Trying to unify these would thread a mode enum through
/// every rendering path for little gain; keeping two small, purpose-built
/// windows is simpler and the sidebar-click dispatch picks between them
/// by MIME / extension.
///
/// Preview cap: the view only renders the first `previewByteCap` bytes of
/// each file. SwiftUI's `Text` is fine for tens of kilobytes but chokes
/// on multi-megabyte strings (each line triggers layout) and the user
/// asked us to lean on "open externally" for heavier inspection anyway.
/// A banner above the preview tells the user when truncation happened
/// and points them at the Open-Externally button.
///
/// We dedupe by snapshot ID (same policy as `ImagePreviewWindow`):
/// clicking another text file in the same snapshot focuses the existing
/// window and navigates to that file rather than stacking duplicates.
enum TextPreviewWindow {
    /// Cap on the number of bytes decoded + shown in the preview pane.
    /// 32 KiB is large enough for almost every conversation.json head
    /// and metadata file we've seen in the wild, and small enough that
    /// SwiftUI text rendering stays snappy on the slowest machines we
    /// support. Breached caps surface a banner + Open-Externally hint.
    static let previewByteCap: Int = 32 * 1024

    @MainActor
    private struct Entry {
        let window: NSWindow
        let model: TextPreviewModel
        let loadedHolder: TextPreviewLoadedHolder
        let toolbarCoordinator: TextPreviewToolbarCoordinator
        let closeObserver: NSObjectProtocol
    }

    @MainActor
    private static var entries: [Int64: Entry] = [:]

    /// Open (or focus + navigate) the preview window for a snapshot.
    /// Passing the same `snapshotID` as an already-open window reuses
    /// that window, updates its gallery list, and jumps to the clicked
    /// entry — no SwiftUI re-mount.
    @MainActor
    static func show(
        snapshotID: Int64,
        entries galleryEntries: [RawExportFileEntry],
        initialIndex: Int,
        vault: any RawExportVault
    ) {
        guard !galleryEntries.isEmpty else { return }
        let clampedIndex = max(0, min(initialIndex, galleryEntries.count - 1))

        if let entry = entries[snapshotID] {
            entry.model.entries = galleryEntries
            entry.model.currentIndex = clampedIndex
            entry.window.makeKeyAndOrderFront(nil)
            return
        }

        let model = TextPreviewModel(
            entries: galleryEntries,
            currentIndex: clampedIndex,
            snapshotID: snapshotID,
            vault: vault
        )
        let loadedHolder = TextPreviewLoadedHolder()
        let toolbarCoordinator = TextPreviewToolbarCoordinator(
            loadedHolder: loadedHolder,
            vault: vault
        )

        let hostingController = NSHostingController(rootView: AnyView(Color.clear))
        let window = NSWindow(contentViewController: hostingController)
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
        window.setContentSize(NSSize(width: 820, height: 640))
        window.minSize = NSSize(width: 360, height: 280)
        window.center()
        window.isReleasedWhenClosed = false
        window.titlebarSeparatorStyle = .line

        let content = TextPreviewWindowContent(
            model: model,
            loadedHolder: loadedHolder,
            updateWindowTitle: { [weak window] title in
                window?.title = title
            }
        )
        hostingController.rootView = AnyView(content)

        let toolbar = NSToolbar(identifier: "MadiniArchive.TextPreview")
        toolbar.delegate = toolbarCoordinator
        toolbar.displayMode = .iconOnly
        toolbar.allowsUserCustomization = false
        toolbar.autosavesConfiguration = false
        window.toolbar = toolbar
        window.toolbarStyle = .unified

        window.title = galleryEntries[clampedIndex].relativePath
            .components(separatedBy: "/").last ?? "プレビュー"

        let observer = NotificationCenter.default.addObserver(
            forName: NSWindow.willCloseNotification,
            object: window,
            queue: .main
        ) { _ in
            MainActor.assumeIsolated {
                if let entry = entries.removeValue(forKey: snapshotID) {
                    NotificationCenter.default.removeObserver(entry.closeObserver)
                }
            }
        }

        let entry = Entry(
            window: window,
            model: model,
            loadedHolder: loadedHolder,
            toolbarCoordinator: toolbarCoordinator,
            closeObserver: observer
        )
        entries[snapshotID] = entry

        window.makeKeyAndOrderFront(nil)
    }
}

// MARK: - Model

/// Observable state driving the preview window's SwiftUI body. Separate
/// from `TextPreviewWindow` (AppKit plumbing) so the SwiftUI side doesn't
/// have to reach into NSWindow internals and vice versa — they meet
/// through this model + `TextPreviewLoadedHolder`.
@MainActor
@Observable
final class TextPreviewModel {
    var entries: [RawExportFileEntry]
    var currentIndex: Int
    let snapshotID: Int64
    let vault: any RawExportVault

    init(
        entries: [RawExportFileEntry],
        currentIndex: Int,
        snapshotID: Int64,
        vault: any RawExportVault
    ) {
        self.entries = entries
        self.currentIndex = currentIndex
        self.snapshotID = snapshotID
        self.vault = vault
    }

    var canGoPrevious: Bool { currentIndex > 0 }
    var canGoNext: Bool { currentIndex < entries.count - 1 }

    func goPrevious() {
        guard canGoPrevious else { return }
        currentIndex -= 1
    }

    func goNext() {
        guard canGoNext else { return }
        currentIndex += 1
    }

    var currentEntry: RawExportFileEntry {
        entries[currentIndex]
    }
}

// MARK: - Loaded state holder

/// The result of loading a single file — either decoded text (possibly
/// truncated), a "binary / undecodable" flag so the UI can push the user
/// toward Open-Externally, or an error message. Shared between the
/// SwiftUI content view and the AppKit toolbar coordinator so the
/// toolbar buttons operate on whatever is currently on screen.
struct TextPreviewLoaded {
    let entry: RawExportFileEntry
    let previewText: String
    /// True when `fullByteCount > previewText.utf8.count` — i.e. the
    /// preview shown on screen is a head-truncation of the vaulted
    /// file. Drives the truncation banner and the "save the FULL
    /// bytes, not the preview" behavior in toolbar actions.
    let isTruncated: Bool
    let fullByteCount: Int
    /// `nil` when the bytes decoded as UTF-8. Non-nil carries a short
    /// human explanation ("Binary content — 2.4 MB of data that isn't
    /// UTF-8 text") for the content view.
    let binaryReason: String?
}

@MainActor
final class TextPreviewLoadedHolder {
    var loaded: TextPreviewLoaded? {
        didSet { onChange?(loaded) }
    }
    var onChange: ((TextPreviewLoaded?) -> Void)?
}

// MARK: - SwiftUI content

private struct TextPreviewWindowContent: View {
    @Bindable var model: TextPreviewModel
    let loadedHolder: TextPreviewLoadedHolder
    let updateWindowTitle: (String) -> Void

    @State private var state: LoadState = .idle
    @State private var isHoveringNav: Bool = false
    @FocusState private var focused: Bool

    enum LoadState: Equatable {
        case idle
        case loading
        case failed(String)
        case loaded(TextPreviewLoaded)

        static func == (lhs: LoadState, rhs: LoadState) -> Bool {
            switch (lhs, rhs) {
            case (.idle, .idle), (.loading, .loading):
                return true
            case (.failed(let l), .failed(let r)):
                return l == r
            case (.loaded(let l), .loaded(let r)):
                return l.entry.id == r.entry.id
                    && l.isTruncated == r.isTruncated
                    && l.fullByteCount == r.fullByteCount
            default:
                return false
            }
        }
    }

    var body: some View {
        ZStack {
            Color(nsColor: .windowBackgroundColor)
                .ignoresSafeArea()
            bodyContent
            navigationOverlay
        }
        .focusable()
        .focused($focused)
        .onAppear { focused = true }
        .onHover { hovering in
            isHoveringNav = hovering
        }
        .onKeyPress(.leftArrow) {
            model.goPrevious()
            return .handled
        }
        .onKeyPress(.rightArrow) {
            model.goNext()
            return .handled
        }
        .task(id: model.currentIndex) {
            await loadCurrent()
        }
        .onChange(of: state) { _, newValue in
            if case .loaded(let loaded) = newValue {
                loadedHolder.loaded = loaded
                updateWindowTitle(filename(for: loaded.entry))
            } else {
                loadedHolder.loaded = nil
                updateWindowTitle(filename(for: model.currentEntry))
            }
        }
    }

    @ViewBuilder
    private var bodyContent: some View {
        switch state {
        case .idle, .loading:
            ProgressView()
                .controlSize(.large)
        case .failed(let message):
            placeholder(
                systemImage: "xmark.octagon",
                title: "読み込みに失敗しました",
                detail: message
            )
        case .loaded(let loaded):
            if let binaryReason = loaded.binaryReason {
                placeholder(
                    systemImage: "doc.badge.gearshape",
                    title: "プレビュー非対応のファイル",
                    detail: binaryReason
                )
            } else {
                textContent(loaded: loaded)
            }
        }
    }

    @ViewBuilder
    private func textContent(loaded: TextPreviewLoaded) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            if loaded.isTruncated {
                truncationBanner(fullByteCount: loaded.fullByteCount)
                Divider()
            }
            ScrollView([.vertical, .horizontal]) {
                Text(loaded.previewText)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(16)
            }
        }
    }

    private func truncationBanner(fullByteCount: Int) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "scissors")
                .foregroundStyle(.secondary)
            Text("先頭 \(Self.formatBytes(TextPreviewWindow.previewByteCap)) のみ表示しています（全体 \(Self.formatBytes(fullByteCount))）。続きは「外部で開く」から。")
                .font(.caption)
                .foregroundStyle(.secondary)
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.yellow.opacity(0.12))
    }

    private func placeholder(systemImage: String, title: String, detail: String) -> some View {
        VStack(spacing: 10) {
            Image(systemName: systemImage)
                .font(.system(size: 36))
                .foregroundStyle(.secondary)
            Text(title)
                .font(.headline)
            Text(detail)
                .font(.callout)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .padding(24)
        .frame(maxWidth: 520)
    }

    @ViewBuilder
    private var navigationOverlay: some View {
        if model.entries.count > 1 {
            HStack(spacing: 0) {
                navButton(systemImage: "chevron.left", enabled: model.canGoPrevious) {
                    model.goPrevious()
                }
                Spacer(minLength: 0)
                navButton(systemImage: "chevron.right", enabled: model.canGoNext) {
                    model.goNext()
                }
            }
            .opacity(isHoveringNav ? 1 : 0)
            .animation(.easeInOut(duration: 0.12), value: isHoveringNav)
            .allowsHitTesting(isHoveringNav)
        }
    }

    private func navButton(systemImage: String, enabled: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(.white)
                .padding(10)
                .background(.black.opacity(0.35), in: Circle())
        }
        .buttonStyle(.plain)
        .opacity(enabled ? 0.85 : 0.2)
        .disabled(!enabled)
        .padding(.horizontal, 8)
    }

    private func filename(for entry: RawExportFileEntry) -> String {
        (entry.relativePath as NSString).lastPathComponent
    }

    private func loadCurrent() async {
        let entry = model.currentEntry
        state = .loading
        do {
            let bytes = try await model.vault.loadBlob(hash: entry.blobHash)
            let fullByteCount = bytes.count
            let head: Data
            let truncated: Bool
            if fullByteCount > TextPreviewWindow.previewByteCap {
                head = bytes.prefix(TextPreviewWindow.previewByteCap)
                truncated = true
            } else {
                head = bytes
                truncated = false
            }
            let decoded = decodeUTF8(head: head)
            let binaryReason: String?
            let previewText: String
            switch decoded {
            case .text(let s):
                previewText = s
                binaryReason = nil
            case .binary:
                previewText = ""
                binaryReason = "UTF-8 として読めないバイト列です（\(Self.formatBytes(fullByteCount))）。「外部で開く」から既定のアプリで開いてください。"
            }
            let loaded = TextPreviewLoaded(
                entry: entry,
                previewText: previewText,
                isTruncated: truncated,
                fullByteCount: fullByteCount,
                binaryReason: binaryReason
            )
            state = .loaded(loaded)
        } catch {
            state = .failed(String(describing: error))
        }
    }

    // MARK: - UTF-8 decoding

    private enum DecodedBytes {
        case text(String)
        case binary
    }

    /// UTF-8 decode with a sniff for obviously-binary payloads. A single
    /// lossy decode gives us readable text for "mostly UTF-8" inputs
    /// (JSON with a stray invalid byte shouldn't blank the preview) but
    /// we still refuse to render pure binary — a blob that's 80% NULs
    /// would paint the view with replacement characters and feel broken.
    private func decodeUTF8(head: Data) -> DecodedBytes {
        // Cheap binary sniff: count NULs in the first 512 bytes. Real
        // text rarely contains any; binary formats (sqlite pages, zip
        // entries, images) are riddled with them.
        let probe = head.prefix(512)
        let nulCount = probe.reduce(into: 0) { acc, byte in
            if byte == 0 { acc += 1 }
        }
        if probe.count >= 16, nulCount > max(1, probe.count / 32) {
            return .binary
        }
        guard let decoded = String(data: head, encoding: .utf8) else {
            // Lossy fallback — replace invalid sequences with U+FFFD so
            // a single bad byte doesn't drop the whole preview.
            let lossy = String(decoding: head, as: UTF8.self)
            return .text(lossy)
        }
        return .text(decoded)
    }

    // MARK: - Formatting

    private static func formatBytes(_ count: Int) -> String {
        let formatter = ByteCountFormatter()
        formatter.allowedUnits = [.useKB, .useMB, .useGB]
        formatter.countStyle = .file
        return formatter.string(fromByteCount: Int64(count))
    }
}

// MARK: - Toolbar coordinator

@MainActor
final class TextPreviewToolbarCoordinator: NSObject, NSToolbarDelegate {
    private let loadedHolder: TextPreviewLoadedHolder
    private let vault: any RawExportVault

    private static let openExternallyID = NSToolbarItem.Identifier("MadiniArchive.TextPreview.OpenExternally")
    private static let copyID = NSToolbarItem.Identifier("MadiniArchive.TextPreview.Copy")
    private static let saveID = NSToolbarItem.Identifier("MadiniArchive.TextPreview.Save")

    private var openExternallyButton: NSButton?
    private var copyButton: NSButton?
    private var saveButton: NSButton?

    init(loadedHolder: TextPreviewLoadedHolder, vault: any RawExportVault) {
        self.loadedHolder = loadedHolder
        self.vault = vault
        super.init()
        loadedHolder.onChange = { [weak self] loaded in
            self?.updateEnabledState(loaded: loaded)
        }
    }

    func toolbarDefaultItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            Self.copyID,
            Self.saveID,
            Self.openExternallyID
        ]
    }

    func toolbarAllowedItemIdentifiers(_ toolbar: NSToolbar) -> [NSToolbarItem.Identifier] {
        [
            .flexibleSpace,
            .space,
            Self.copyID,
            Self.saveID,
            Self.openExternallyID
        ]
    }

    func toolbar(
        _ toolbar: NSToolbar,
        itemForItemIdentifier itemIdentifier: NSToolbarItem.Identifier,
        willBeInsertedIntoToolbar flag: Bool
    ) -> NSToolbarItem? {
        switch itemIdentifier {
        case Self.copyID:
            return makeItem(
                identifier: itemIdentifier,
                label: "テキストをコピー",
                symbol: "doc.on.doc",
                action: #selector(copyTapped),
                buttonKey: \.copyButton
            )
        case Self.saveID:
            return makeItem(
                identifier: itemIdentifier,
                label: "ファイルを保存",
                symbol: "square.and.arrow.down",
                action: #selector(saveTapped),
                buttonKey: \.saveButton
            )
        case Self.openExternallyID:
            return makeItem(
                identifier: itemIdentifier,
                label: "外部で開く",
                symbol: "arrow.up.forward.app",
                action: #selector(openExternallyTapped),
                buttonKey: \.openExternallyButton
            )
        default:
            return nil
        }
    }

    private func makeItem(
        identifier: NSToolbarItem.Identifier,
        label: String,
        symbol: String,
        action: Selector,
        buttonKey: ReferenceWritableKeyPath<TextPreviewToolbarCoordinator, NSButton?>
    ) -> NSToolbarItem {
        let item = NSToolbarItem(itemIdentifier: identifier)
        let button = NSButton()
        button.bezelStyle = .texturedRounded
        button.image = NSImage(
            systemSymbolName: symbol,
            accessibilityDescription: label
        )
        button.imagePosition = .imageOnly
        button.target = self
        button.action = action
        button.isEnabled = false
        item.view = button
        item.label = label
        item.toolTip = label
        self[keyPath: buttonKey] = button
        return item
    }

    /// Enable the Copy button only when we have text (binary previews
    /// have nothing sensible to copy), but keep Save / Open-Externally
    /// available in either case — a user who opens a binary entry
    /// still reasonably wants to save or launch it.
    private func updateEnabledState(loaded: TextPreviewLoaded?) {
        let hasAnything = loaded != nil
        let hasText = loaded?.binaryReason == nil && !(loaded?.previewText.isEmpty ?? true)
        copyButton?.isEnabled = hasText
        saveButton?.isEnabled = hasAnything
        openExternallyButton?.isEnabled = hasAnything
    }

    @objc private func copyTapped() {
        guard let loaded = loadedHolder.loaded, loaded.binaryReason == nil else { return }
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(loaded.previewText, forType: .string)
    }

    @objc private func saveTapped() {
        guard let loaded = loadedHolder.loaded else { return }
        let vault = self.vault
        Task { @MainActor in
            await Self.saveToFile(loaded: loaded, vault: vault)
        }
    }

    @objc private func openExternallyTapped() {
        guard let loaded = loadedHolder.loaded else { return }
        let vault = self.vault
        Task { @MainActor in
            await Self.openExternally(loaded: loaded, vault: vault)
        }
    }

    // MARK: - Actions

    /// Prompt the user for a destination and write the ORIGINAL vaulted
    /// bytes (not the possibly-truncated preview string). Failures
    /// surface via `NSAlert` — silent-swallow reads as a bug when the
    /// save panel closes and nothing shows up in Finder.
    static func saveToFile(
        loaded: TextPreviewLoaded,
        vault: any RawExportVault
    ) async {
        let panel = NSSavePanel()
        let suggested = (loaded.entry.relativePath as NSString).lastPathComponent
        panel.nameFieldStringValue = suggested.isEmpty ? "preview.txt" : suggested
        panel.canCreateDirectories = true
        if let contentType = contentType(for: loaded.entry) {
            panel.allowedContentTypes = [contentType]
        }
        let response = await panel.beginAsSheetModalAsync()
        guard response == .OK, let url = panel.url else { return }
        do {
            let bytes = try await vault.loadBlob(hash: loaded.entry.blobHash)
            try bytes.write(to: url, options: .atomic)
        } catch {
            presentError(title: "保存に失敗しました", error: error)
        }
    }

    /// Materialize the file to a temp spool with its original filename
    /// (so Finder / the receiving app sees the right extension), then
    /// hand the URL to `NSWorkspace`. The `madini-text-preview/`
    /// subdirectory keeps our spools grouped under `TMPDIR` so macOS's
    /// periodic sweep reclaims them together and a human inspecting
    /// `/tmp` can tell where they came from.
    static func openExternally(
        loaded: TextPreviewLoaded,
        vault: any RawExportVault
    ) async {
        do {
            let bytes = try await vault.loadBlob(hash: loaded.entry.blobHash)
            let dir = FileManager.default.temporaryDirectory
                .appendingPathComponent("madini-text-preview", isDirectory: true)
            try FileManager.default.createDirectory(
                at: dir,
                withIntermediateDirectories: true
            )
            let basename = (loaded.entry.relativePath as NSString).lastPathComponent
            let filename = basename.isEmpty ? "file-\(String(loaded.entry.blobHash.prefix(12)))" : basename
            let url = dir.appendingPathComponent(filename)
            try bytes.write(to: url, options: .atomic)
            NSWorkspace.shared.open(url)
        } catch {
            presentError(title: "外部アプリで開けませんでした", error: error)
        }
    }

    /// Best-effort UTType from the file's MIME. When MIME is absent we
    /// fall through to the extension on disk. Returns nil when neither
    /// pans out, in which case NSSavePanel accepts any extension.
    private static func contentType(for entry: RawExportFileEntry) -> UTType? {
        if let mime = entry.mimeType, !mime.isEmpty,
           let type = UTType(mimeType: mime) {
            return type
        }
        let ext = (entry.relativePath as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return UTType(filenameExtension: ext)
    }

    private static func presentError(title: String, error: Error) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = error.localizedDescription
        alert.alertStyle = .warning
        alert.addButton(withTitle: "OK")
        if let window = NSApp.keyWindow ?? NSApp.mainWindow {
            alert.beginSheetModal(for: window, completionHandler: nil)
        } else {
            alert.runModal()
        }
    }
}

private extension NSSavePanel {
    func beginAsSheetModalAsync() async -> NSApplication.ModalResponse {
        await withCheckedContinuation { (continuation: CheckedContinuation<NSApplication.ModalResponse, Never>) in
            let anchor = NSApp.keyWindow ?? NSApp.mainWindow
            if let anchor {
                self.beginSheetModal(for: anchor) { response in
                    continuation.resume(returning: response)
                }
            } else {
                self.begin { response in
                    continuation.resume(returning: response)
                }
            }
        }
    }
}

#endif
