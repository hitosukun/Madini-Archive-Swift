#if os(macOS)
import Foundation

/// Owns the intake watcher + processor pair and the activity log they share.
/// Instantiated once by `AppServices`; started from the app scene so the
/// polling loop only runs while the app is visible.
///
/// Failures inside the processor don't bubble out here — the activity log is
/// the one surface users see, and `ImportCoordinator` is already responsible
/// for preserving the Vault snapshot regardless of normalization outcome.
@MainActor
final class IntakeService {
    let activityLog: IntakeActivityLog
    let intakeDir: URL

    private let services: AppServices
    private var watcher: IntakeWatcher?
    private let settleInterval: TimeInterval

    init(
        services: AppServices,
        intakeDir: URL = IntakePaths.intakeDir,
        settleInterval: TimeInterval = 2.0,
        activityLog: IntakeActivityLog? = nil
    ) {
        self.services = services
        self.intakeDir = intakeDir
        self.settleInterval = settleInterval
        // `IntakeActivityLog` is `@MainActor`, so we can't default the
        // parameter to `IntakeActivityLog()` in a nonisolated signature.
        // Constructing it here is fine because the initializer itself is
        // `@MainActor` via the enclosing class annotation.
        self.activityLog = activityLog ?? IntakeActivityLog()
    }

    /// Start watching the intake directory. Idempotent.
    func start() {
        guard watcher == nil else { return }
        // Ensure the directory exists so Finder can reveal it immediately and
        // so the first scan doesn't silently no-op if the user hasn't dropped
        // anything yet.
        IntakePaths.ensureIntakeDir()

        let processor = IntakeProcessor(services: services, activityLog: activityLog)
        let watcher = IntakeWatcher(
            directory: intakeDir,
            pollInterval: settleInterval,
            settleInterval: settleInterval,
            handler: { item in
                await processor.process(item)
            }
        )
        watcher.start()
        self.watcher = watcher
    }

    func stop() {
        watcher?.stop()
        watcher = nil
    }
}
#endif
