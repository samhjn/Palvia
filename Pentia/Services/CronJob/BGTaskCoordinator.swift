import Foundation
import BackgroundTasks

/// Abstraction over `BGTaskScheduler` to enable unit testing of registration lifecycle.
protocol BGTaskRegistering {
    @discardableResult
    func register(
        forTaskWithIdentifier identifier: String,
        using queue: DispatchQueue?,
        launchHandler: @escaping @Sendable (BGTask) -> Void
    ) -> Bool
}

extension BGTaskScheduler: BGTaskRegistering {}

/// Coordinates BGTask registration with `CronScheduler` lifecycle.
///
/// Registration **must** happen during app launch (`App.init`). The scheduler
/// is created later (in `onAppear`) and linked via the ``scheduler`` property.
/// Separating these two phases prevents the `BGTaskScheduler` assertion failure
/// that occurs when `register(forTaskWithIdentifier:)` is called after launch.
final class CronBGTaskCoordinator: @unchecked Sendable {
    /// Process-wide flag preventing duplicate `BGTaskScheduler` registration.
    /// SwiftUI may recreate the `App` struct (and thus this coordinator) during
    /// view updates, so an instance-level guard alone is not sufficient.
    private static var _hasRegistered = false

    private(set) var isRegistered = false
    var scheduler: CronScheduler?
    private let registrar: any BGTaskRegistering

    init(registrar: any BGTaskRegistering = BGTaskScheduler.shared) {
        self.registrar = registrar
    }

    #if DEBUG
    /// Reset the process-wide registration flag. **Test-only.**
    static func resetRegistrationStateForTesting() {
        _hasRegistered = false
    }
    #endif

    /// Register the cron background refresh task.
    ///
    /// - Returns: `false` if already registered or if the system rejected the registration.
    @discardableResult
    func registerCronTask() -> Bool {
        guard !isRegistered else { return false }
        guard !Self._hasRegistered else {
            isRegistered = true
            return false
        }

        let identifier = CronScheduler.bgTaskIdentifier
        let registered = registrar.register(
            forTaskWithIdentifier: identifier,
            using: nil
        ) { [weak self] task in
            guard let refreshTask = task as? BGAppRefreshTask else {
                task.setTaskCompleted(success: false)
                return
            }
            Task { @MainActor in
                // The system can fire BGAppRefreshTask before the user has
                // unlocked post-boot. Touching SwiftData under that condition
                // blocks `pread` on the encrypted WAL and gets us SIGKILL'd
                // by RunningBoard with `0xdead10cc`. Decline gracefully —
                // iOS will reschedule.
                guard ProtectedDataAvailability.isAvailable else {
                    print("[BGTaskCoordinator] Protected data unavailable; deferring task.")
                    task.setTaskCompleted(success: false)
                    return
                }
                guard let scheduler = self?.scheduler else {
                    task.setTaskCompleted(success: false)
                    return
                }
                scheduler.handleBackgroundTask(refreshTask)
            }
        }

        isRegistered = registered
        if registered {
            Self._hasRegistered = true
        }
        if !registered {
            print("[BGTaskCoordinator] Registration failed for '\(identifier)'. "
                  + "Verify BGTaskSchedulerPermittedIdentifiers in Info.plist.")
        }
        return registered
    }
}
