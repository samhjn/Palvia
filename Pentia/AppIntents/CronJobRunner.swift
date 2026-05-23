import Foundation
import SwiftData

/// Minimal entry point used by App Intents to execute cron jobs.
///
/// Unlike `CronScheduler`, this runner is not tied to the app's SwiftUI
/// lifecycle: no timers, no long-lived state, no keep-alive manager. It
/// reuses `CronScheduler.fetchDueJobs(context:now:)` to decide what to run
/// and `CronExecutor.executeJob(_:agent:context:)` to execute. A soft
/// deadline keeps the total time under the iOS background-execution budget
/// (~30s for App Intents launched from automations on a locked device).
enum CronJobRunner {
    /// Default per-invocation budget. Leaves headroom below the system's
    /// ~30s ceiling so the final `try? context.save()` has a chance to land.
    static let defaultSoftDeadline: TimeInterval = 25

    /// Executes every enabled job whose `nextRunAt` is due at or before `now`.
    ///
    /// - Parameters:
    ///   - container: the shared `ModelContainer`.
    ///   - now: the reference time for due-selection (defaults to `Date()`).
    ///   - softDeadline: stop starting new jobs once this many seconds have
    ///     elapsed. Jobs already running are allowed to finish.
    /// - Returns: the number of jobs whose execution actually started.
    @MainActor
    @discardableResult
    static func runAllDue(
        container: ModelContainer,
        now: Date = Date(),
        softDeadline: TimeInterval = defaultSoftDeadline
    ) async -> Int {
        let ctx = ModelContext(container)
        let due = CronScheduler.fetchDueJobs(context: ctx, now: now)
            .sorted { ($0.nextRunAt ?? .distantPast) < ($1.nextRunAt ?? .distantPast) }

        let executor = CronExecutor(modelContainer: container)
        let startedAt = Date()
        var ran = 0

        for job in due {
            if Date().timeIntervalSince(startedAt) >= softDeadline { break }
            guard let agent = job.agent else { continue }

            // Re-check `nextRunAt` right before executing. The main-process
            // `CronScheduler` timer or a previous BGTask could have already
            // advanced it; we don't want a double-run for a single period.
            if let next = job.nextRunAt, next > Date() { continue }

            await executor.executeJob(job, agent: agent, context: ctx)
            ran += 1
        }

        return ran
    }

    /// Executes a specific job if it is enabled, regardless of schedule.
    ///
    /// - Returns: `true` if the job was found, enabled, and executed.
    @MainActor
    @discardableResult
    static func runOne(
        jobId: UUID,
        container: ModelContainer
    ) async -> Bool {
        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate<CronJob> { $0.id == jobId }
        )
        guard let job = try? ctx.fetch(descriptor).first,
              job.isEnabled,
              let agent = job.agent else {
            return false
        }

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job, agent: agent, context: ctx)
        return true
    }
}
