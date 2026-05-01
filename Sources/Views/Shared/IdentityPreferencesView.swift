import SwiftUI
import UniformTypeIdentifiers

/// Root of the Settings window. Uses `TabView` so the current Identity
/// panel sits alongside future panels (data sources, appearance, etc.)
/// without needing a structural refactor later.
struct SettingsRootView: View {
    var body: some View {
        TabView {
            IdentityPreferencesView()
                .tabItem {
                    Label("Profile", systemImage: "person.crop.circle")
                }
        }
        .frame(minWidth: 520, idealWidth: 560, minHeight: 420)
    }
}

struct IdentityPreferencesView: View {
    var body: some View {
        Form {
            ForEach(IdentityPreferenceRole.allCases) { role in
                Section(role.sectionTitle) {
                    IdentityProfileEditorSection(role: role)
                }
            }
        }
        .formStyle(.grouped)
        .padding(20)
    }
}

private struct IdentityProfileEditorSection: View {
    @Environment(IdentityPreferencesStore.self) private var identityPreferences

    let role: IdentityPreferenceRole

    @State private var isImportingImage = false
    @State private var isDropTargeted = false
    @State private var importError: ImportError?
    @State private var isEditingName = false
    @State private var draftName: String = ""
    @FocusState private var nameFieldFocused: Bool

    var body: some View {
        HStack(alignment: .top, spacing: 16) {
            // Large click-to-change avatar. Doubles as a drop target so
            // the user can drag an image file straight from Finder onto
            // it — the most direct physical expression of "replace this
            // picture with that one". Both paths land in the same
            // `setCustomAvatar(for:from:)` call so they're behaviorally
            // identical.
            AvatarDropTarget(
                presentation: previewPresentation,
                isDropTargeted: $isDropTargeted,
                onTap: { isImportingImage = true },
                onDropFile: { url in handleImport(url: url) }
            )

            VStack(alignment: .leading, spacing: 10) {
                // Inline-editable name. Click the text to switch into
                // edit mode; Enter / Escape / blur commits or cancels.
                // There's no separate "Display Name" field — the label
                // the user sees IS the editor, matching Finder Get-Info
                // style rename flow.
                inlineNameEditor

                Text(avatarSubtitle)
                    .font(.caption)
                    .foregroundStyle(.secondary)

                HStack(spacing: 8) {
                    Button {
                        isImportingImage = true
                    } label: {
                        Label("Choose image…", systemImage: "photo.on.rectangle.angled")
                    }
                    .buttonStyle(.bordered)
                    .controlSize(.small)

                    if isCustomAvatar {
                        Button(role: .destructive) {
                            identityPreferences.resetAvatar(for: role)
                        } label: {
                            Label("Reset to default", systemImage: "arrow.uturn.backward")
                        }
                        .buttonStyle(.borderless)
                        .controlSize(.small)
                    }

                    Spacer(minLength: 0)
                }
            }
        }
        .padding(.vertical, 6)
        .fileImporter(
            isPresented: $isImportingImage,
            allowedContentTypes: [.image],
            allowsMultipleSelection: false
        ) { result in
            switch result {
            case .success(let urls):
                if let url = urls.first { handleImport(url: url) }
            case .failure(let error):
                importError = ImportError(message: error.localizedDescription)
            }
        }
        .alert(
            "Couldn’t import image",
            isPresented: Binding(
                get: { importError != nil },
                set: { if !$0 { importError = nil } }
            ),
            presenting: importError
        ) { _ in
            Button("OK", role: .cancel) { importError = nil }
        } message: { error in
            Text(error.message)
        }
    }

    @ViewBuilder
    private var inlineNameEditor: some View {
        if isEditingName {
            TextField("", text: $draftName)
                .textFieldStyle(.plain)
                .font(.headline)
                .focused($nameFieldFocused)
                .onSubmit { commitName() }
                .onExitCommand { cancelNameEdit() }
                .onChange(of: nameFieldFocused) { _, focused in
                    // Blurring commits — matches Finder rename, and
                    // prevents the editor from getting stuck in edit
                    // mode if the user clicks elsewhere.
                    if !focused && isEditingName { commitName() }
                }
        } else {
            Text(displayName)
                .font(.headline)
                .contentShape(Rectangle())
                .onTapGesture { beginNameEdit() }
                .help("Click to rename")
        }
    }

    private func beginNameEdit() {
        draftName = profile.displayName
        isEditingName = true
        // Focus on the next runloop tick so the TextField has been
        // installed before we try to make it first responder.
        DispatchQueue.main.async { nameFieldFocused = true }
    }

    private func commitName() {
        let trimmed = draftName.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            switch role {
            case .user:
                identityPreferences.updateUserName(trimmed)
            case .assistant:
                identityPreferences.updateAgentName(trimmed)
            }
        }
        isEditingName = false
        nameFieldFocused = false
    }

    private func cancelNameEdit() {
        isEditingName = false
        nameFieldFocused = false
    }

    private func handleImport(url: URL) {
        do {
            try identityPreferences.setCustomAvatar(for: role, from: url)
        } catch {
            importError = ImportError(message: error.localizedDescription)
        }
    }

    private var profile: IdentityProfilePreference {
        identityPreferences.profile(for: role)
    }

    private var displayName: String {
        let trimmed = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role.defaultDisplayName : trimmed
    }

    private var isCustomAvatar: Bool {
        profile.avatar.kind == .customFile
    }

    private var avatarSubtitle: String {
        if isCustomAvatar {
            return String(localized: "Custom image")
        }
        if let defaultAvatar = profile.avatar.defaultAvatar {
            return String(localized: "Default (\(defaultAvatar.displayName))")
        }
        return String(localized: "Default")
    }

    private var previewPresentation: MessageIdentityPresentation {
        switch role {
        case .user:
            return identityPreferences.presentation(for: .user)
        case .assistant:
            return identityPreferences.presentation(for: .assistant)
        }
    }

    private struct ImportError: Identifiable {
        let id = UUID()
        let message: String
    }
}

/// Large circular avatar that advertises "click or drop an image here"
/// with a hover overlay and a drop-targeted accent ring. The camera
/// glyph appears on hover so the affordance is discoverable without
/// cluttering the resting state.
private struct AvatarDropTarget: View {
    let presentation: MessageIdentityPresentation
    @Binding var isDropTargeted: Bool
    let onTap: () -> Void
    let onDropFile: (URL) -> Void

    @State private var isHovering = false

    private let size: CGFloat = 72

    var body: some View {
        Button(action: onTap) {
            ZStack {
                IdentityAvatarView(presentation: presentation, size: size)

                // Hover / drop overlay. Darkens the image a touch and
                // surfaces a camera glyph so the "click to change"
                // affordance is explicit at the moment of intent.
                if isHovering || isDropTargeted {
                    Circle()
                        .fill(.black.opacity(isDropTargeted ? 0.35 : 0.25))
                        .overlay {
                            Image(systemName: "camera.fill")
                                .font(.system(size: size * 0.28, weight: .semibold))
                                .foregroundStyle(.white)
                        }
                }
            }
            .frame(width: size, height: size)
            .overlay {
                Circle()
                    .strokeBorder(
                        isDropTargeted ? Color.accentColor : Color.secondary.opacity(0.25),
                        lineWidth: isDropTargeted ? 2 : 0.5
                    )
            }
            .animation(.easeOut(duration: 0.12), value: isHovering)
            .animation(.easeOut(duration: 0.12), value: isDropTargeted)
            .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .onHover { isHovering = $0 }
        .help("Click or drop an image to change the icon")
        .dropDestination(for: URL.self) { urls, _ in
            guard let url = urls.first else { return false }
            onDropFile(url)
            return true
        } isTargeted: { newValue in
            if isDropTargeted != newValue { isDropTargeted = newValue }
        }
    }
}
