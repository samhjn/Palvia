import XCTest
import SwiftData
@testable import iClaw

/// Coverage for the App Intents–based cron trigger path. These tests exercise
/// `CronJobRunner`, `CronJobEntityQuery`, and the `openAppWhenRun` flag on
/// the intents. They do **not** spin up a real LLM provider, so jobs hit the
/// "no primary provider" branch inside `CronExecutor.executeJob`, which still
/// finalizes the job (`runCount += 1`) — sufficient to verify the runner
/// wiring without network calls.
final class AppIntentsCronTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([
            Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
            CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
            Message.self, SessionEmbedding.self,
        ])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @MainActor
    @discardableResult
    private func makeJob(
        name: String,
        cron: String = "* * * * *",
        enabled: Bool = true,
        nextRunAt: Date?
    ) -> CronJob {
        let agent = Agent(name: "TestAgent-\(name)")
        context.insert(agent)

        let job = CronJob(
            name: name,
            cronExpression: cron,
            jobHint: "test hint for \(name)",
            isEnabled: enabled
        )
        job.agent = agent
        job.nextRunAt = nextRunAt
        context.insert(job)
        try? context.save()
        return job
    }

    // MARK: - RunDueCronJobsIntent / CronJobRunner.runAllDue

    @MainActor
    func test_runAllDue_runsOnlyDueJobs() async {
        let dueJob = makeJob(name: "A", nextRunAt: Date().addingTimeInterval(-60))
        let futureJob = makeJob(name: "B", nextRunAt: Date().addingTimeInterval(3600))

        let ran = await CronJobRunner.runAllDue(container: container)

        XCTAssertEqual(ran, 1, "Only the due job should have started")

        // Re-fetch to see finalization writes.
        let fresh = ModelContext(container)
        let allJobs = (try? fresh.fetch(FetchDescriptor<CronJob>())) ?? []
        let dueAfter = allJobs.first { $0.id == dueJob.id }
        let futureAfter = allJobs.first { $0.id == futureJob.id }
        XCTAssertEqual(dueAfter?.runCount, 1)
        XCTAssertEqual(futureAfter?.runCount, 0)
    }

    @MainActor
    func test_runAllDue_skipsDisabledJobs() async {
        _ = makeJob(name: "Disabled", enabled: false, nextRunAt: Date().addingTimeInterval(-60))

        let ran = await CronJobRunner.runAllDue(container: container)

        XCTAssertEqual(ran, 0, "Disabled jobs must not run even if due")
    }

    @MainActor
    func test_runAllDue_rechecksNextRunAtToAvoidDoubleRun() async {
        // Seed a job as due, then immediately push its nextRunAt into the future
        // to simulate the foreground CronScheduler having already executed it.
        let job = makeJob(name: "RacedAhead", nextRunAt: Date().addingTimeInterval(-60))
        job.nextRunAt = Date().addingTimeInterval(3600)
        try? context.save()

        // fetchDueJobs uses its own context snapshot, so the runner will observe
        // the updated nextRunAt when it re-checks right before execution.
        let ran = await CronJobRunner.runAllDue(container: container)

        XCTAssertEqual(ran, 0, "Runner must re-check nextRunAt and skip already-advanced jobs")

        let fresh = ModelContext(container)
        let after = (try? fresh.fetch(FetchDescriptor<CronJob>()))?.first { $0.id == job.id }
        XCTAssertEqual(after?.runCount, 0)
    }

    @MainActor
    func test_runAllDue_respectsSoftDeadline() async {
        // Seed several due jobs, then pass a zero-second deadline so the loop
        // exits before starting any. No runCount should increment.
        _ = makeJob(name: "A", nextRunAt: Date().addingTimeInterval(-60))
        _ = makeJob(name: "B", nextRunAt: Date().addingTimeInterval(-60))
        _ = makeJob(name: "C", nextRunAt: Date().addingTimeInterval(-60))

        let ran = await CronJobRunner.runAllDue(container: container, softDeadline: 0)

        XCTAssertEqual(ran, 0, "Zero-second deadline must prevent any job from starting")

        let fresh = ModelContext(container)
        let jobs = (try? fresh.fetch(FetchDescriptor<CronJob>())) ?? []
        XCTAssertTrue(jobs.allSatisfy { $0.runCount == 0 })
    }

    // MARK: - TriggerCronJobIntent / CronJobRunner.runOne

    @MainActor
    func test_runOne_executesSpecificJobRegardlessOfSchedule() async {
        let job = makeJob(name: "Manual", nextRunAt: Date().addingTimeInterval(3600))

        let ok = await CronJobRunner.runOne(jobId: job.id, container: container)

        XCTAssertTrue(ok)

        let fresh = ModelContext(container)
        let after = (try? fresh.fetch(FetchDescriptor<CronJob>()))?.first { $0.id == job.id }
        XCTAssertEqual(after?.runCount, 1)
        XCTAssertNotNil(after?.lastSessionId)
    }

    @MainActor
    func test_runOne_returnsFalseForDisabledJob() async {
        let job = makeJob(name: "Off", enabled: false, nextRunAt: nil)

        let ok = await CronJobRunner.runOne(jobId: job.id, container: container)

        XCTAssertFalse(ok, "Disabled jobs must not run via manual trigger")
    }

    @MainActor
    func test_runOne_returnsFalseForUnknownId() async {
        let ok = await CronJobRunner.runOne(jobId: UUID(), container: container)
        XCTAssertFalse(ok)
    }

    // MARK: - CronJobEntityQuery
    //
    // Note: `CronJobEntityQuery` reads from `iClawModelContainer.shared`, which
    // is the on-disk store. We therefore validate the query's *filtering* by
    // unit-testing the shape of its predicate here against our in-memory
    // container, matching what the production query does.

    @MainActor
    func test_entityQuery_onlyReturnsEnabledJobs() async {
        _ = makeJob(name: "Alpha", enabled: true, nextRunAt: nil)
        _ = makeJob(name: "Beta", enabled: false, nextRunAt: nil)
        _ = makeJob(name: "Gamma", enabled: true, nextRunAt: nil)

        let ctx = ModelContext(container)
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate<CronJob> { $0.isEnabled == true },
            sortBy: [SortDescriptor(\.name)]
        )
        let enabled = (try? ctx.fetch(descriptor)) ?? []

        XCTAssertEqual(enabled.map(\.name), ["Alpha", "Gamma"])
    }

    // MARK: - Regression: concurrent re-trigger after App Intent run
    //
    // Bug: after an App Intent ran a cron job, opening the app would re-trigger
    // the same job. Cause was that `CronExecutor.executeJob` only advanced
    // `nextRunAt` inside `finalizeJob` (after `runAgentLoop`); during the
    // multi-second LLM round-trip a second drain (foreground scheduler resume,
    // BGTask, or a second intent invocation) saw `nextRunAt <= now` and picked
    // the same job up again. The fix advances `nextRunAt` at the START of
    // `executeJob`, so any concurrent path observes a future schedule.

    @MainActor
    func test_claimNextRun_makesJobInvisibleToFetchDueJobs_immediately() {
        // The targeted regression for the bug. `claimNextRun` is what
        // `executeJob` calls *before* `runAgentLoop` to prevent a concurrent
        // foreground drain (or second intent invocation) from picking up the
        // same job mid-flight. Without this claim, the multi-second LLM round
        // trip is a wide-open window for re-trigger.
        let job = makeJob(name: "ClaimRegression", cron: "* * * * *",
                          nextRunAt: Date().addingTimeInterval(-60))

        let beforeCtx = ModelContext(container)
        XCTAssertEqual(CronScheduler.fetchDueJobs(context: beforeCtx, now: Date()).count, 1,
                       "Sanity check: job is initially due")

        let executor = CronExecutor(modelContainer: container)
        executor.claimNextRun(for: job, context: context)

        let afterCtx = ModelContext(container)
        let stillDue = CronScheduler.fetchDueJobs(context: afterCtx, now: Date())
        XCTAssertTrue(stillDue.isEmpty,
                      "After claimNextRun, the job must be invisible to fetchDueJobs even though the agent loop hasn't run yet")

        let fresh = ModelContext(container)
        let after = (try? fresh.fetch(FetchDescriptor<CronJob>()))?.first { $0.id == job.id }
        XCTAssertGreaterThan(after?.nextRunAt ?? .distantPast, Date())
        XCTAssertEqual(after?.runCount, 0, "Claim must not increment runCount — that's finalize's job")
    }

    @MainActor
    func test_runAllDue_advancesNextRunAtBeforeAgentWork_soSecondDrainSkips() async {
        // A cron `* * * * *` due 60s ago. After the first runAllDue, an
        // immediate fetchDueJobs (mimicking the foreground CronScheduler
        // resuming while the intent is still mid-flight or right after) must
        // return zero entries — runCount stays at 1.
        let job = makeJob(name: "EveryMinute", cron: "* * * * *",
                          nextRunAt: Date().addingTimeInterval(-60))

        let firstRan = await CronJobRunner.runAllDue(container: container)
        XCTAssertEqual(firstRan, 1)

        // Simulate the app foregrounding immediately afterwards.
        let ctxAfter = ModelContext(container)
        let stillDue = CronScheduler.fetchDueJobs(context: ctxAfter, now: Date())
        XCTAssertTrue(stillDue.isEmpty,
                      "Job's nextRunAt must be advanced so a foreground drain doesn't re-trigger it")

        let secondRan = await CronJobRunner.runAllDue(container: container)
        XCTAssertEqual(secondRan, 0, "Second back-to-back invocation must not re-execute the same job")

        let fresh = ModelContext(container)
        let after = (try? fresh.fetch(FetchDescriptor<CronJob>()))?.first { $0.id == job.id }
        XCTAssertEqual(after?.runCount, 1, "Job must have executed exactly once across both drains")
    }

    @MainActor
    func test_executeJob_persistsAdvancedNextRunAtBeforeAgentLoop() async {
        // Direct CronExecutor test — confirms the claim is written and
        // committed to the store *before* the agent loop runs (here exercised
        // via the no-provider branch, which still goes through the same
        // up-front claim + initial save).
        let job = makeJob(name: "Claim", cron: "*/5 * * * *",
                          nextRunAt: Date().addingTimeInterval(-60))
        let agent = job.agent!

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job, agent: agent, context: context)

        let fresh = ModelContext(container)
        let after = (try? fresh.fetch(FetchDescriptor<CronJob>()))?.first { $0.id == job.id }
        XCTAssertNotNil(after?.nextRunAt)
        XCTAssertGreaterThan(after?.nextRunAt ?? .distantPast, Date(),
                             "nextRunAt must be advanced into the future after executeJob")
        XCTAssertNotNil(after?.lastRunAt)
        XCTAssertEqual(after?.runCount, 1)
    }

    @MainActor
    func test_runAllDue_concurrentInvocations_runJobOnlyOnce() async {
        // Two CronJobRunner.runAllDue calls fired in parallel must not both
        // execute the same job — the data-layer claim (nextRunAt advance + save
        // before agent work) serializes them. This is the cross-trigger race
        // case (e.g. App Intent + BGTask waking near the same instant).
        _ = makeJob(name: "Concurrent", cron: "* * * * *",
                    nextRunAt: Date().addingTimeInterval(-60))

        async let firstCount = CronJobRunner.runAllDue(container: container)
        async let secondCount = CronJobRunner.runAllDue(container: container)

        let (a, b) = await (firstCount, secondCount)
        XCTAssertEqual(a + b, 1, "Exactly one of the two concurrent drains may execute the job; got \(a + b)")

        let fresh = ModelContext(container)
        let allJobs = (try? fresh.fetch(FetchDescriptor<CronJob>())) ?? []
        XCTAssertEqual(allJobs.first?.runCount, 1)
    }

    // MARK: - Regression: cron-created session must keep its agent reference
    //
    // Bug: cron-task–produced sessions sometimes had `session.agent == nil`
    // when re-fetched from a fresh `ModelContext`. Cause was that
    // `CronExecutor.executeJob` deferred the only `context.save()` until
    // `claimNextRun`, after also mutating `isActive`, inserting the trigger
    // message, and appending it to `session.messages`. Any failure inside that
    // single bundled transaction (`try?`-swallowed) could land the session in
    // the store *without* its agent. Fix: persist the session→agent edge in
    // its own save *before* any other mutations, matching the proven
    // `SessionService.createSession` pattern.

    @MainActor
    func test_executeJob_persistsSessionAgentEdge_inFreshContext() async {
        let job = makeJob(name: "AgentEdge", cron: "*/5 * * * *",
                          nextRunAt: Date().addingTimeInterval(-60))
        let agent = job.agent!
        let agentId = agent.id

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job, agent: agent, context: context)

        // Re-fetch in a brand-new context — only persisted edges are visible.
        let fresh = ModelContext(container)
        let sessions = (try? fresh.fetch(FetchDescriptor<Session>())) ?? []
        let cronSession = sessions.first { $0.title.contains("AgentEdge") }
        XCTAssertNotNil(cronSession,
                        "Cron run must persist a session with the job's name in its title")
        XCTAssertNotNil(cronSession?.agent,
                        "Persisted cron session must keep its agent association")
        XCTAssertEqual(cronSession?.agent?.id, agentId,
                       "Persisted cron session's agent must match the job's agent")
    }

    @MainActor
    func test_executeJob_persistsAgentBeforeMessageInsertion() async {
        // Stronger invariant: after executeJob runs, predicate-based queries
        // that depend on `session.agent?.id` (used by `SessionService` and
        // `SessionRAGTools`) must return the cron session. Without the
        // up-front save, an intermittent failure of the bundled save would
        // leave the session orphaned and invisible to these queries.
        let job = makeJob(name: "QueryByAgent", cron: "* * * * *",
                          nextRunAt: Date().addingTimeInterval(-60))
        let agent = job.agent!
        let agentId = agent.id

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job, agent: agent, context: context)

        let fresh = ModelContext(container)
        var descriptor = FetchDescriptor<Session>()
        descriptor.predicate = #Predicate<Session> { $0.agent?.id == agentId }
        let sessionsForAgent = (try? fresh.fetch(descriptor)) ?? []

        XCTAssertFalse(sessionsForAgent.isEmpty,
                       "Predicate query on session.agent.id must find the cron session")
        XCTAssertTrue(sessionsForAgent.contains { $0.title.contains("QueryByAgent") },
                      "Cron session must be discoverable via the agent-id predicate")
    }

    @MainActor
    func test_executeJob_inverseRelationshipPopulatedOnAgent() async {
        // The inverse side `agent.sessions` (declared with `@Relationship` on
        // Agent) must include the freshly-created cron session in a fresh
        // context. This catches regressions where the session→agent edge is
        // saved late or lost mid-transaction.
        let job = makeJob(name: "InverseEdge", cron: "* * * * *",
                          nextRunAt: Date().addingTimeInterval(-60))
        let agent = job.agent!
        let agentId = agent.id

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job, agent: agent, context: context)

        let fresh = ModelContext(container)
        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate<Agent> { $0.id == agentId }
        )
        let freshAgent = (try? fresh.fetch(descriptor))?.first
        XCTAssertNotNil(freshAgent)
        XCTAssertTrue(freshAgent?.sessions.contains { $0.title.contains("InverseEdge") } ?? false,
                      "Agent.sessions inverse relationship must include the cron session")
    }

    @MainActor
    func test_runOne_persistsSessionAgentEdge() async {
        let job = makeJob(name: "RunOneEdge", nextRunAt: Date().addingTimeInterval(3600))
        let agentId = job.agent!.id

        let ok = await CronJobRunner.runOne(jobId: job.id, container: container)
        XCTAssertTrue(ok)

        let fresh = ModelContext(container)
        let after = (try? fresh.fetch(FetchDescriptor<CronJob>()))?.first { $0.id == job.id }
        guard let lastSessionId = after?.lastSessionId else {
            return XCTFail("runOne must record lastSessionId after finalization")
        }

        var descriptor = FetchDescriptor<Session>()
        descriptor.predicate = #Predicate<Session> { $0.id == lastSessionId }
        let session = (try? fresh.fetch(descriptor))?.first
        XCTAssertNotNil(session)
        XCTAssertEqual(session?.agent?.id, agentId,
                       "Session referenced by job.lastSessionId must be linked to the original agent")
    }

    // MARK: - Regression: openAppWhenRun must stay false

    func test_intents_doNotOpenAppWhenRun() {
        // If someone ever flips these to true, locked-device automations will
        // start requiring Face ID / passcode — defeating the entire purpose of
        // this feature. Fail loudly at test time rather than at the user's
        // wrist.
        XCTAssertFalse(RunDueCronJobsIntent.openAppWhenRun,
                       "RunDueCronJobsIntent must execute in background")
        XCTAssertFalse(TriggerCronJobIntent.openAppWhenRun,
                       "TriggerCronJobIntent must execute in background")
    }
}
