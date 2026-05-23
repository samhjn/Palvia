import AppIntents

/// Runs a specific cron job by name, regardless of its schedule, in the
/// background. Replacement for the `iclaw://cron/trigger/{jobId}` URL
/// scheme for locked-device automations.
struct TriggerCronJobIntent: AppIntent {
    static var title: LocalizedStringResource = LocalizedStringResource(
        "appIntent.trigger.title",
        defaultValue: "Trigger Cron Job"
    )

    static var description = IntentDescription(
        LocalizedStringResource(
            "appIntent.trigger.description",
            defaultValue: "Runs the selected iClaw cron job now. Does not open the app, so automations can fire while the phone is locked."
        )
    )

    /// Must remain `false` so the intent executes in the background without
    /// requiring Face ID / passcode unlock. Covered by a regression test.
    static var openAppWhenRun: Bool = false
    static var isDiscoverable: Bool = true

    @Parameter(title: LocalizedStringResource(
        "appIntent.parameter.cronJob",
        defaultValue: "Cron Job"
    ))
    var job: CronJobEntity

    @MainActor
    func perform() async throws -> some IntentResult {
        // Bail before touching SwiftData if files are still encrypted — see
        // `RunDueCronJobsIntent.perform()` for the `0xdead10cc` rationale.
        guard ProtectedDataAvailability.isAvailable else {
            print("[TriggerCronJobIntent] Protected data unavailable; skipping run.")
            return .result()
        }
        _ = await CronJobRunner.runOne(jobId: job.id, container: iClawModelContainer.shared)
        return .result()
    }
}
