import Foundation
import SwiftData
import BackgroundTasks

@Observable
@MainActor
final class CronScheduler {
    nonisolated static let bgTaskIdentifier = "com.iclaw.cronjob.refresh"
    private static let checkInterval: TimeInterval = 30

    private(set) var isRunning = false
    private(set) var lastCheckDate: Date?
    /// Jobs currently executing (prevents duplicate scheduling).
    private(set) var runningJobIds: Set<UUID> = []
    /// At most one cron execution per agent at a time (separate jobs queue until the prior run finishes).
    private var runningAgentIds: Set<UUID> = []

    private let modelContainer: ModelContainer
    private var timer: Timer?
    private let executor: CronExecutor
    /// Optional keep-alive manager; set by the app to receive session lifecycle events.
    var keepAliveManager: BackgroundKeepAliveManager? {
        didSet { executor.keepAliveManager = keepAliveManager }
    }

    init(modelContainer: ModelContainer) {
        self.modelContainer = modelContainer
        self.executor = CronExecutor(modelContainer: modelContainer)
    }

    func start() {
        guard !isRunning else { return }
        isRunning = true

        timer = Timer.scheduledTimer(
            withTimeInterval: Self.checkInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.drainDueJobs()
            }
        }
        timer?.tolerance = 5

        Task { await drainDueJobs() }
    }

    func stop() {
        timer?.invalidate()
        timer = nil
        isRunning = false
    }

    /// Suspend the in-process timer while the app is in the background so it
    /// cannot block the main thread during termination. The `BGAppRefreshTask`
    /// path handles background execution instead.
    func pause() {
        timer?.invalidate()
        timer = nil
    }

    /// Re-arm the in-process timer when the app returns to the foreground.
    func resume() {
        guard isRunning, timer == nil else { return }
        timer = Timer.scheduledTimer(
            withTimeInterval: Self.checkInterval,
            repeats: true
        ) { [weak self] _ in
            Task { @MainActor in
                await self?.drainDueJobs()
            }
        }
        timer?.tolerance = 5
        Task { await drainDueJobs() }
    }

    func rescheduleAll() {
        Task { await updateNextRunDates() }
    }

    /// Runs all cron jobs that are due now (used by deep link `iclaw://cron/run-due`).
    func runDueJobsNow() async {
        await drainDueJobs()
    }

    /// Runs one job by id if enabled (used by `iclaw://cron/trigger/{id}`); respects the per-agent mutex.
    func runManualJob(jobId: UUID) async {
        let snapshot = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate<CronJob> { $0.id == jobId }
        )
        guard let job = try? snapshot.fetch(descriptor).first,
              let agent = job.agent,
              job.isEnabled else { return }

        scheduleExecution(jobId: job.id, agentId: agent.id)
    }

    // MARK: - Background Task

    nonisolated func scheduleBackgroundTask() {
        let request = BGAppRefreshTaskRequest(identifier: Self.bgTaskIdentifier)
        request.earliestBeginDate = Date(timeIntervalSinceNow: 60)
        try? BGTaskScheduler.shared.submit(request)
    }

    nonisolated func handleBackgroundTask(_ task: BGAppRefreshTask) {
        scheduleBackgroundTask()

        task.expirationHandler = {
            task.setTaskCompleted(success: false)
        }

        Task { @MainActor [weak self] in
            guard let self else {
                task.setTaskCompleted(success: false)
                return
            }
            await self.drainDueJobs()
            task.setTaskCompleted(success: true)
        }
    }

    // MARK: - Core Loop

    /// Fetches due jobs and starts execution tasks (each with its own `ModelContext`).
    private func drainDueJobs() async {
        let now = Date()
        lastCheckDate = now

        let context = ModelContext(modelContainer)
        let dueJobs = Self.fetchDueJobs(context: context, now: now)
            .sorted {
                ($0.nextRunAt ?? .distantPast) < ($1.nextRunAt ?? .distantPast)
            }

        for job in dueJobs {
            guard let agent = job.agent else { continue }
            scheduleExecution(jobId: job.id, agentId: agent.id)
        }
    }

    /// Acquires locks and spawns an isolated execution task. Skips if the job or agent is already running.
    private func scheduleExecution(jobId: UUID, agentId: UUID) {
        guard !runningJobIds.contains(jobId) else { return }
        guard !runningAgentIds.contains(agentId) else { return }

        runningJobIds.insert(jobId)
        runningAgentIds.insert(agentId)

        let executor = self.executor
        let container = self.modelContainer
        Task { @MainActor in
            let ctx = ModelContext(container)
            let descriptor = FetchDescriptor<CronJob>(
                predicate: #Predicate<CronJob> { $0.id == jobId }
            )
            guard let job = try? ctx.fetch(descriptor).first,
                  let agent = job.agent else {
                Task { @MainActor [weak self] in
                    guard let self else { return }
                    self.releaseLocks(jobId: jobId, agentId: agentId)
                    await self.drainDueJobs()
                }
                return
            }

            await executor.executeJob(job, agent: agent, context: ctx)

            Task { @MainActor [weak self] in
                guard let self else { return }
                self.releaseLocks(jobId: jobId, agentId: agentId)
                await self.drainDueJobs()
            }
        }
    }

    private func releaseLocks(jobId: UUID, agentId: UUID) {
        runningJobIds.remove(jobId)
        runningAgentIds.remove(agentId)
    }

    private func updateNextRunDates() async {
        let context = ModelContext(modelContainer)
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate { $0.isEnabled == true }
        )
        guard let jobs = try? context.fetch(descriptor) else { return }

        let now = Date()
        for job in jobs {
            guard !runningJobIds.contains(job.id) else { continue }
            if let next = try? CronParser.nextFireDate(after: now, for: job.cronExpression) {
                job.nextRunAt = next
            }
        }
        try? context.save()
    }

    static func fetchDueJobs(context: ModelContext, now: Date) -> [CronJob] {
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate { $0.isEnabled == true }
        )
        guard let jobs = try? context.fetch(descriptor) else { return [] }

        return jobs.filter { job in
            guard let nextRun = job.nextRunAt else {
                // Never scheduled — look back 61s so the creation minute itself is considered
                // (nextFireDate always advances ≥1 min past its input).
                let refDate = job.createdAt.addingTimeInterval(-61)
                if let computed = try? CronParser.nextFireDate(after: refDate, for: job.cronExpression) {
                    return computed <= now
                }
                return false
            }
            return nextRun <= now
        }
    }
}
