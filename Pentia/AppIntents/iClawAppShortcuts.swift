import AppIntents

/// Registers the cron App Intents with the system so they show up in the
/// Shortcuts editor, Siri, and Spotlight. Enumerated automatically by iOS
/// once the app has launched at least once after install.
struct iClawAppShortcuts: AppShortcutsProvider {
    static var appShortcuts: [AppShortcut] {
        AppShortcut(
            intent: RunDueCronJobsIntent(),
            phrases: [
                "Run due cron jobs in \(.applicationName)",
                "Run \(.applicationName) cron jobs",
            ],
            shortTitle: "Run Due Cron Jobs",
            systemImageName: "clock.arrow.circlepath"
        )

        AppShortcut(
            intent: TriggerCronJobIntent(),
            phrases: [
                "Trigger cron job in \(.applicationName)",
                "Run \(.applicationName) scheduled task",
            ],
            shortTitle: "Trigger Cron Job",
            systemImageName: "play.circle"
        )
    }
}
