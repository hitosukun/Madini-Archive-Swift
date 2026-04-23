import Foundation

/// Persists the user's chosen intake directory across launches.
///
/// The default location (`IntakePaths.intakeDir` under `~/Documents`) works for
/// most users, but two cases justify an override:
///   1. iCloud Drive syncs `~/Documents` and can stall ingest while
///      placeholder files download.
///   2. The user keeps their exports on an external drive or a project-
///      specific folder and wants to point the watcher straight at it.
///
/// Storage is a plain path string in `UserDefaults` — the app is not
/// sandboxed (see `Package.swift`, no entitlements file), so we don't need
/// security-scoped bookmarks. An absent value means "use the default
/// location", which keeps legacy installs on the old behavior.
enum IntakeLocationStore {
    static let defaultsKey = "IntakeLocationStore.customDirectoryPath"

    /// Returns the persisted override, if any. Absent ⇒ caller should fall
    /// back to `IntakePaths.intakeDir`.
    static func load(defaults: UserDefaults = .standard) -> URL? {
        guard let path = defaults.string(forKey: defaultsKey), !path.isEmpty else {
            return nil
        }
        return URL(fileURLWithPath: path, isDirectory: true)
    }

    /// Persist an override. Pass `nil` to clear back to the default.
    static func save(_ url: URL?, defaults: UserDefaults = .standard) {
        if let url {
            defaults.set(url.path, forKey: defaultsKey)
        } else {
            defaults.removeObject(forKey: defaultsKey)
        }
    }
}
