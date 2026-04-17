import SwiftUI

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
        .frame(minWidth: 460, idealWidth: 520, minHeight: 360)
    }
}

private struct IdentityProfileEditorSection: View {
    @Environment(IdentityPreferencesStore.self) private var identityPreferences

    let role: IdentityPreferenceRole

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            HStack(spacing: 12) {
                IdentityAvatarView(presentation: previewPresentation, size: 36)

                VStack(alignment: .leading, spacing: 2) {
                    Text(displayName)
                        .font(.headline)

                    Text("Preview")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }

            TextField("Display Name", text: displayNameBinding)
                .textFieldStyle(.roundedBorder)

            VStack(alignment: .leading, spacing: 8) {
                Text("Default Avatar")
                    .font(.subheadline.weight(.medium))

                DefaultAvatarPicker(
                    selection: avatarBinding,
                    accentColor: previewPresentation.accentColor
                )
            }
        }
        .padding(.vertical, 4)
    }

    private var profile: IdentityProfilePreference {
        identityPreferences.profile(for: role)
    }

    private var displayName: String {
        let trimmed = profile.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? role.defaultDisplayName : trimmed
    }

    private var previewPresentation: MessageIdentityPresentation {
        switch role {
        case .user:
            return identityPreferences.presentation(for: .user)
        case .assistant:
            return identityPreferences.presentation(for: .assistant)
        }
    }

    private var displayNameBinding: Binding<String> {
        Binding(
            get: { profile.displayName },
            set: { newValue in
                switch role {
                case .user:
                    identityPreferences.updateUserName(newValue)
                case .assistant:
                    identityPreferences.updateAgentName(newValue)
                }
            }
        )
    }

    private var avatarBinding: Binding<IdentityDefaultAvatar> {
        Binding(
            get: { profile.avatar.defaultAvatar ?? fallbackAvatar },
            set: { newValue in
                let reference = IdentityAvatarReference.defaultAvatar(newValue)

                switch role {
                case .user:
                    identityPreferences.updateUserAvatar(reference)
                case .assistant:
                    identityPreferences.updateAgentAvatar(reference)
                }
            }
        )
    }

    private var fallbackAvatar: IdentityDefaultAvatar {
        switch role {
        case .user:
            return .user
        case .assistant:
            return .agent
        }
    }
}

private struct DefaultAvatarPicker: View {
    @Binding var selection: IdentityDefaultAvatar

    let accentColor: Color

    private let columns = [
        GridItem(.adaptive(minimum: 150), spacing: 10, alignment: .leading)
    ]

    var body: some View {
        LazyVGrid(columns: columns, alignment: .leading, spacing: 10) {
            ForEach(IdentityDefaultAvatar.allCases) { avatar in
                Button {
                    selection = avatar
                } label: {
                    HStack(spacing: 10) {
                        IdentityAvatarView(
                            presentation: MessageIdentityPresentation(
                                displayName: avatar.displayName,
                                avatar: .defaultAvatar(avatar),
                                accentColor: accentColor
                            ),
                            size: 30
                        )

                        VStack(alignment: .leading, spacing: 2) {
                            Text(avatar.displayName)
                                .font(.subheadline.weight(.medium))
                                .foregroundStyle(.primary)

                            Text(selection == avatar ? "Selected" : "Use this avatar")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }

                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 10)
                    .background(background(for: avatar))
                    .overlay {
                        RoundedRectangle(cornerRadius: 12)
                            .strokeBorder(borderColor(for: avatar), lineWidth: selection == avatar ? 1.5 : 1)
                    }
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                }
                .buttonStyle(.plain)
            }
        }
    }

    private func background(for avatar: IdentityDefaultAvatar) -> some ShapeStyle {
        selection == avatar ? accentColor.opacity(0.10) : Color.secondary.opacity(0.06)
    }

    private func borderColor(for avatar: IdentityDefaultAvatar) -> Color {
        selection == avatar ? accentColor.opacity(0.5) : .white.opacity(0.08)
    }
}
