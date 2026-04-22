import Foundation

/// Filesystem locations for the auto-intake folder.
///
/// The intake folder is the user-facing "drop zone" for export data: anything
/// the user copies or drags in is auto-detected by `IntakeWatcher`, vaulted
/// through `ImportCoordinator`, and then left in place. Keeping the folder
/// inside `~/Documents` (vs. `~/Library/Application Support`) is deliberate —
/// users need to see it in Finder and drag files in, which is awkward when
/// the folder sits inside a hidden library directory.
enum IntakePaths {
    static let intakeDirName = "Madini Archive Intake"

    static var intakeDir: URL {
        let documents = FileManager.default
            .urls(for: .documentDirectory, in: .userDomainMask)
            .first!
        return documents.appendingPathComponent(intakeDirName, isDirectory: true)
    }

    /// Create the intake directory if missing. Idempotent. Called by
    /// `IntakeWatcher.start()` so the first launch after an install doesn't
    /// need a separate "initialize intake" step.
    @discardableResult
    static func ensureIntakeDir() -> URL {
        let url = intakeDir
        try? FileManager.default.createDirectory(
            at: url,
            withIntermediateDirectories: true
        )
        return url
    }
}
