import Foundation
import Observation
import SwiftUI

struct IdentityPreferences: Codable, Hashable, Sendable {
    var user: IdentityProfilePreference
    var agent: IdentityProfilePreference

    /// Defaults shipped with the app on first run. Both names are the
    /// author's personal handles in alphabetic form so they survive
    /// systems without Japanese fonts and don't trap a non-IME user
    /// in a hard-to-edit field. Anything customizable at runtime —
    /// see Settings → Identity (`IdentityPreferencesView`).
    static let `default` = IdentityPreferences(
        user: IdentityProfilePreference(
            displayName: "Jenna",
            avatar: .defaultAvatar(.user)
        ),
        agent: IdentityProfilePreference(
            displayName: "Madini",
            avatar: .defaultAvatar(.agent)
        )
    )
}

struct IdentityProfilePreference: Codable, Hashable, Sendable {
    var displayName: String
    var avatar: IdentityAvatarReference
}

enum IdentityDefaultAvatar: String, Codable, Hashable, Sendable, CaseIterable, Identifiable {
    case user
    case agent

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .user:
            return "Jenna"
        case .agent:
            return "Madini"
        }
    }

    /// Bundled image filename for the default avatar, or `nil` to fall
    /// through to the SF Symbol fallback in `IdentityAvatarView`.
    /// Public release ships both default avatars: the user side is
    /// "Jenna" (the author's handle), the agent side is "Madini" (the
    /// app's namesake AI persona). Either side can be replaced from
    /// Settings → Identity, and `resetAvatar(for:)` returns to these
    /// bundled defaults.
    var bundledImageName: String? {
        switch self {
        case .user:
            return "avatar_jenna"
        case .agent:
            return "avatar_madini"
        }
    }

    var fallbackSymbolName: String {
        switch self {
        case .user:
            return "person.crop.circle.fill"
        case .agent:
            return "brain.head.profile"
        }
    }
}

struct IdentityAvatarReference: Codable, Hashable, Sendable {
    enum StorageKind: String, Codable, Hashable, Sendable {
        case defaultAvatar
        case customFile
        case systemSymbol
    }

    let kind: StorageKind
    let identifier: String

    static func defaultAvatar(_ avatar: IdentityDefaultAvatar) -> IdentityAvatarReference {
        IdentityAvatarReference(kind: .defaultAvatar, identifier: avatar.rawValue)
    }

    static func customFile(path: String) -> IdentityAvatarReference {
        IdentityAvatarReference(kind: .customFile, identifier: path)
    }

    static func systemSymbol(_ symbolName: String) -> IdentityAvatarReference {
        IdentityAvatarReference(kind: .systemSymbol, identifier: symbolName)
    }

    var defaultAvatar: IdentityDefaultAvatar? {
        guard kind == .defaultAvatar else {
            return nil
        }

        return IdentityDefaultAvatar(rawValue: identifier)
    }
}

struct MessageIdentityPresentation {
    let displayName: String
    let avatar: IdentityAvatarReference?
    let accentColor: Color
}

struct MessageIdentityContext: Hashable, Sendable {
    let source: String?
    let model: String?
}

enum IdentityPreferenceRole: String, CaseIterable, Identifiable, Sendable {
    case user
    case assistant

    var id: String { rawValue }

    var sectionTitle: LocalizedStringKey {
        switch self {
        case .user:
            return "User"
        case .assistant:
            return "Assistant"
        }
    }

    var defaultDisplayName: String {
        switch self {
        case .user:
            return "User"
        case .assistant:
            return "Madini"
        }
    }
}

@MainActor
@Observable
final class IdentityPreferencesStore {
    private let defaults: UserDefaults
    private let storageKey = "madini.identity.preferences"

    var preferences: IdentityPreferences {
        didSet {
            persist()
        }
    }

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults

        if let data = defaults.data(forKey: storageKey),
           let decoded = try? JSONDecoder().decode(IdentityPreferences.self, from: data) {
            self.preferences = decoded
        } else {
            self.preferences = .default
        }
    }

    func presentation(for role: MessageRole, context: MessageIdentityContext? = nil) -> MessageIdentityPresentation {
        // The assistant name is intentionally always the user-configured
        // agent name ("Madini" by default) regardless of which LLM the
        // conversation came from. Per-source overrides used to emit
        // "Claude 3.5 Sonnet" / "Gemini 1.5 Pro" headers in orange/blue;
        // that confused the visual with the card's source chip, so both
        // the label and the color are now unified.
        _ = context
        switch role {
        case .user:
            return MessageIdentityPresentation(
                displayName: preferences.user.displayName,
                avatar: preferences.user.avatar,
                accentColor: .accentColor
            )
        case .assistant:
            return MessageIdentityPresentation(
                displayName: preferences.agent.displayName,
                avatar: preferences.agent.avatar,
                accentColor: .secondary
            )
        case .tool:
            return MessageIdentityPresentation(
                displayName: "Tool",
                avatar: nil,
                accentColor: .teal
            )
        case .system:
            return MessageIdentityPresentation(
                displayName: "System",
                avatar: nil,
                accentColor: .orange
            )
        }
    }

    func updateUserName(_ name: String) {
        preferences.user.displayName = name
    }

    func updateAgentName(_ name: String) {
        preferences.agent.displayName = name
    }

    func updateUserAvatar(_ avatar: IdentityAvatarReference) {
        preferences.user.avatar = avatar
    }

    func updateAgentAvatar(_ avatar: IdentityAvatarReference) {
        preferences.agent.avatar = avatar
    }

    func profile(for role: IdentityPreferenceRole) -> IdentityProfilePreference {
        switch role {
        case .user:
            return preferences.user
        case .assistant:
            return preferences.agent
        }
    }

    /// Copy a user-chosen image into Application Support so the avatar
    /// survives moves of the original file, and point the preference at
    /// the copy. We write to a UUID-suffixed filename so the image cache
    /// (`AvatarImageCache`, keyed by absolute path) naturally invalidates
    /// on replace — overwriting the same path would keep the stale image
    /// visible until relaunch.
    @discardableResult
    func setCustomAvatar(for role: IdentityPreferenceRole, from sourceURL: URL) throws -> URL {
        AppPaths.ensureUserDataDir()
        let fm = FileManager.default
        let dir = AppPaths.userDataDir.appendingPathComponent("avatars", isDirectory: true)
        try fm.createDirectory(at: dir, withIntermediateDirectories: true)

        let needsRelease = sourceURL.startAccessingSecurityScopedResource()
        defer { if needsRelease { sourceURL.stopAccessingSecurityScopedResource() } }

        let ext = sourceURL.pathExtension.isEmpty ? "png" : sourceURL.pathExtension
        let filename = "\(role.rawValue)-\(UUID().uuidString).\(ext)"
        let dest = dir.appendingPathComponent(filename)
        try fm.copyItem(at: sourceURL, to: dest)

        // Remove the prior custom file for this role (if any) so the
        // avatars directory doesn't grow unboundedly with every swap.
        let previous = profile(for: role).avatar
        if previous.kind == .customFile, previous.identifier != dest.path {
            try? fm.removeItem(atPath: previous.identifier)
        }

        let reference = IdentityAvatarReference.customFile(path: dest.path)
        switch role {
        case .user:
            updateUserAvatar(reference)
        case .assistant:
            updateAgentAvatar(reference)
        }
        return dest
    }

    /// Restore the role to its bundled default avatar. Any custom file
    /// previously imported for this role is deleted from Application
    /// Support so the user's storage stays tidy.
    func resetAvatar(for role: IdentityPreferenceRole) {
        let current = profile(for: role).avatar
        if current.kind == .customFile {
            try? FileManager.default.removeItem(atPath: current.identifier)
        }
        let fallback: IdentityAvatarReference
        switch role {
        case .user:
            fallback = .defaultAvatar(.user)
        case .assistant:
            fallback = .defaultAvatar(.agent)
        }
        switch role {
        case .user:
            updateUserAvatar(fallback)
        case .assistant:
            updateAgentAvatar(fallback)
        }
    }

    private func persist() {
        guard let data = try? JSONEncoder().encode(preferences) else {
            return
        }

        defaults.set(data, forKey: storageKey)
    }
}
