import AppIntents

/// Runs every enabled cron job that is currently due, without bringing the
/// app to the foreground. Used by Shortcuts personal automations as a
/// replacement for the `iclaw://cron/run-due` URL scheme, because the
/// `Open URL` action requires the device to be unlocked on a locked phone.
struct RunDueCronJobsIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource(
        "appIntent.runDue.title",
        defaultValue: "Run Due Cron Jobs"
    )

    static var description = IntentDescription(
        LocalizedStringResource(
            "appIntent.runDue.description",
            defaultValue: "Runs every enabled iClaw cron job whose schedule is currently due. Does not open the app, so automations can fire while the phone is locked."
        )
    )

    /// Must remain `false` so the intent executes in the background without
    /// requiring Face ID / passcode unlock. Covered by a regression test.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @MainActor
    func perform() async throws -> some IntentResult & ReturnsValue<Int> {
        // Bail before touching SwiftData if files are still encrypted —
        // happens when this intent fires before the user has unlocked the
        // device for the first time post-boot. Opening the store under that
        // condition deadlocks `pread` on the WAL and gets us SIGKILL'd by
        // RunningBoard with `0xdead10cc`.
        guard ProtectedDataAvailability.isAvailable else {
            print("[RunDueCronJobsIntent] Protected data unavailable; skipping run.")
            return .result(value: 0)
        }
        let count = await CronJobRunner.runAllDue(container: iClawModelContainer.shared)
        return .result(value: count)
    }
}
