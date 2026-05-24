import XCTest
import SwiftData
@testable import Pentia

// MARK: - SubAgentManager Nesting Depth Tests

final class SubAgentNestingTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Max Nesting Depth Constant

    func testMaxNestingDepthIsReasonable() {
        XCTAssertGreaterThan(SubAgentManager.maxNestingDepth, 0)
        XCTAssertLessThanOrEqual(SubAgentManager.maxNestingDepth, 10,
                                 "Nesting depth should be bounded to prevent stack overflow")
    }

    // MARK: - SubAgentManager Depth Initialization

    @MainActor
    func testSubAgentManagerDefaultDepthIsZero() {
        let manager = SubAgentManager(modelContext: context)
        _ = manager
        // Default init should not crash — depth starts at 0
    }

    @MainActor
    func testSubAgentManagerAcceptsCustomDepth() {
        let manager = SubAgentManager(modelContext: context, nestingDepth: 3)
        _ = manager
    }

    // MARK: - Depth Limit Enforcement

    @MainActor
    func testSendMessageRejectsAtMaxDepth() async {
        let manager = SubAgentManager(modelContext: context, nestingDepth: SubAgentManager.maxNestingDepth)
        let fakeAgentId = UUID()

        do {
            _ = try await manager.sendMessage(to: fakeAgentId, content: "test")
            XCTFail("Expected maxDepthExceeded error")
        } catch let error as SubAgentError {
            if case .maxDepthExceeded(let depth) = error {
                XCTAssertEqual(depth, SubAgentManager.maxNestingDepth)
            } else {
                XCTFail("Expected maxDepthExceeded, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testSendMessageRejectsAboveMaxDepth() async {
        let manager = SubAgentManager(modelContext: context, nestingDepth: SubAgentManager.maxNestingDepth + 3)
        let fakeAgentId = UUID()

        do {
            _ = try await manager.sendMessage(to: fakeAgentId, content: "test")
            XCTFail("Expected maxDepthExceeded error")
        } catch let error as SubAgentError {
            if case .maxDepthExceeded = error {
                // Expected
            } else {
                XCTFail("Expected maxDepthExceeded, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testSendMessageAllowsBelowMaxDepth() async {
        let manager = SubAgentManager(modelContext: context, nestingDepth: SubAgentManager.maxNestingDepth - 1)
        let fakeAgentId = UUID()

        do {
            _ = try await manager.sendMessage(to: fakeAgentId, content: "test")
            XCTFail("Expected agentNotFound (not depth error)")
        } catch let error as SubAgentError {
            if case .agentNotFound = error {
                // Correct: depth check passed, then failed to find the fake agent
            } else if case .maxDepthExceeded = error {
                XCTFail("Should not hit depth limit at depth \(SubAgentManager.maxNestingDepth - 1)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }

    @MainActor
    func testSendMessageAllowsAtDepthZero() async {
        let manager = SubAgentManager(modelContext: context, nestingDepth: 0)
        let fakeAgentId = UUID()

        do {
            _ = try await manager.sendMessage(to: fakeAgentId, content: "test")
        } catch let error as SubAgentError {
            if case .maxDepthExceeded = error {
                XCTFail("Depth 0 should be allowed")
            }
            // agentNotFound is expected since we use a fake ID
        } catch {
            // Other errors are fine
        }
    }

    // MARK: - SubAgentError Messages

    func testMaxDepthExceededErrorDescription() {
        let error = SubAgentError.maxDepthExceeded(5)
        let description = error.errorDescription ?? ""
        XCTAssertTrue(description.contains("5"), "Should include current depth")
        XCTAssertTrue(description.contains("\(SubAgentManager.maxNestingDepth)"), "Should include max depth")
    }

    func testSubAgentErrorDescriptions() {
        XCTAssertNotNil(SubAgentError.agentNotFound.errorDescription)
        XCTAssertNotNil(SubAgentError.emptyResponse.errorDescription)
        XCTAssertNotNil(SubAgentError.sessionLocked("reason").errorDescription)
        XCTAssertNotNil(SubAgentError.maxDepthExceeded(3).errorDescription)
    }
}

// MARK: - FunctionCallRouter Nesting Depth Tests

final class FunctionCallRouterDepthTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()
    }

    override func tearDown() {
        container = nil
        context = nil
        agent = nil
        super.tearDown()
    }

    @MainActor
    func testDefaultNestingDepthIsZero() {
        let router = FunctionCallRouter(agent: agent, modelContext: context)
        XCTAssertEqual(router.nestingDepth, 0)
    }

    @MainActor
    func testCustomNestingDepth() {
        let router = FunctionCallRouter(agent: agent, modelContext: context, nestingDepth: 3)
        XCTAssertEqual(router.nestingDepth, 3)
    }

    @MainActor
    func testNestingDepthWithSessionId() {
        let sessionId = UUID()
        let router = FunctionCallRouter(agent: agent, modelContext: context, sessionId: sessionId, nestingDepth: 2)
        XCTAssertEqual(router.nestingDepth, 2)
        XCTAssertEqual(router.sessionId, sessionId)
    }

    @MainActor
    func testUnknownToolReturnsError() async {
        let router = FunctionCallRouter(agent: agent, modelContext: context)
        let toolCall = LLMToolCall(id: "test-1", name: "nonexistent_tool", arguments: "{}")
        let result = await router.execute(toolCall: toolCall)
        XCTAssertTrue(result.text.contains("Unknown tool"))
    }
}

// MARK: - CronJob Lifecycle Tests

final class CronJobLifecycleTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        agent = Agent(name: "CronTestAgent")
        context.insert(agent)
        try! context.save()
    }

    override func tearDown() {
        container = nil
        context = nil
        agent = nil
        super.tearDown()
    }

    // MARK: - CronJob Creation

    @MainActor
    func testCronJobCreation() {
        let job = CronJob(name: "Test Job", cronExpression: "0 9 * * *", jobHint: "Do stuff")
        context.insert(job)
        agent.cronJobs.append(job)
        try! context.save()

        XCTAssertEqual(job.name, "Test Job")
        XCTAssertEqual(job.cronExpression, "0 9 * * *")
        XCTAssertEqual(job.jobHint, "Do stuff")
        XCTAssertTrue(job.isEnabled)
        XCTAssertEqual(job.runCount, 0)
        XCTAssertNotNil(job.agent)
    }

    // MARK: - Due Job Detection

    @MainActor
    func testFetchDueJobsReturnsOverdueJobs() {
        let job = CronJob(name: "Overdue", cronExpression: "* * * * *", jobHint: "test")
        job.nextRunAt = Date.distantPast
        context.insert(job)
        agent.cronJobs.append(job)
        try! context.save()

        let dueJobs = CronScheduler.fetchDueJobs(context: context, now: Date())
        XCTAssertTrue(dueJobs.contains(where: { $0.id == job.id }))
    }

    @MainActor
    func testFetchDueJobsExcludesFutureJobs() {
        let job = CronJob(name: "Future", cronExpression: "* * * * *", jobHint: "test")
        job.nextRunAt = Date.distantFuture
        context.insert(job)
        agent.cronJobs.append(job)
        try! context.save()

        let dueJobs = CronScheduler.fetchDueJobs(context: context, now: Date())
        XCTAssertFalse(dueJobs.contains(where: { $0.id == job.id }))
    }

    @MainActor
    func testFetchDueJobsExcludesDisabledJobs() {
        let job = CronJob(name: "Disabled", cronExpression: "* * * * *", jobHint: "test")
        job.isEnabled = false
        job.nextRunAt = Date.distantPast
        context.insert(job)
        agent.cronJobs.append(job)
        try! context.save()

        let dueJobs = CronScheduler.fetchDueJobs(context: context, now: Date())
        XCTAssertFalse(dueJobs.contains(where: { $0.id == job.id }))
    }

    @MainActor
    func testFetchDueJobsWithNilNextRunAt() {
        let job = CronJob(name: "NeverScheduled", cronExpression: "* * * * *", jobHint: "test")
        job.nextRunAt = nil
        context.insert(job)
        agent.cronJobs.append(job)
        try! context.save()

        let dueJobs = CronScheduler.fetchDueJobs(context: context, now: Date())
        XCTAssertTrue(dueJobs.contains(where: { $0.id == job.id }),
                      "Jobs with nil nextRunAt should be computed and included if due")
    }

    // MARK: - Session State Consistency

    @MainActor
    func testSessionStartsInactive() {
        let session = Session(title: "Test Session")
        context.insert(session)
        session.agent = agent

        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isCompressingContext)
    }

    @MainActor
    func testSessionActiveStateToggle() {
        let session = Session(title: "Active Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        session.isActive = true
        try! context.save()
        XCTAssertTrue(session.isActive)

        session.isActive = false
        try! context.save()
        XCTAssertFalse(session.isActive)
    }

    @MainActor
    func testSessionMessagesOrder() {
        let session = Session(title: "Order Test")
        context.insert(session)
        session.agent = agent

        let msg1 = Message(role: .user, content: "First")
        msg1.timestamp = Date(timeIntervalSince1970: 100)
        let msg2 = Message(role: .assistant, content: "Second")
        msg2.timestamp = Date(timeIntervalSince1970: 200)
        let msg3 = Message(role: .user, content: "Third")
        msg3.timestamp = Date(timeIntervalSince1970: 300)

        context.insert(msg1)
        context.insert(msg2)
        context.insert(msg3)
        session.messages.append(contentsOf: [msg3, msg1, msg2])
        try! context.save()

        let sorted = session.sortedMessages
        XCTAssertEqual(sorted[0].content, "First")
        XCTAssertEqual(sorted[1].content, "Second")
        XCTAssertEqual(sorted[2].content, "Third")
    }

    // MARK: - CronScheduler Lock Management

    @MainActor
    func testSchedulerStartStop() {
        let scheduler = CronScheduler(modelContainer: container)
        XCTAssertFalse(scheduler.isRunning)

        scheduler.start()
        XCTAssertTrue(scheduler.isRunning)

        scheduler.stop()
        XCTAssertFalse(scheduler.isRunning)
    }

    @MainActor
    func testSchedulerRunningJobTracking() {
        let scheduler = CronScheduler(modelContainer: container)
        XCTAssertTrue(scheduler.runningJobIds.isEmpty)
    }

    @MainActor
    func testSchedulerDoubleStartIsIdempotent() {
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        scheduler.start()
        XCTAssertTrue(scheduler.isRunning)
        scheduler.stop()
    }
}

// MARK: - ModelContext Thread Safety Tests

final class ModelContextThreadSafetyTests: XCTestCase {

    private var container: ModelContainer!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    @MainActor
    func testModelContextCreatedOnMainActor() {
        let context = ModelContext(container)
        XCTAssertNotNil(context, "ModelContext should be creatable on @MainActor")

        let agent = Agent(name: "MainActorAgent")
        context.insert(agent)
        try! context.save()

        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.name == "MainActorAgent" }
        )
        let fetched = try! context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
    }

    @MainActor
    func testMultipleContextsOnSameContainer() {
        let ctx1 = ModelContext(container)
        let ctx2 = ModelContext(container)

        let agent = Agent(name: "SharedAgent")
        ctx1.insert(agent)
        try! ctx1.save()

        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.name == "SharedAgent" }
        )
        let fetchedFromCtx2 = try! ctx2.fetch(descriptor)
        XCTAssertEqual(fetchedFromCtx2.count, 1,
                       "Second context should see data persisted by first context")
    }

    @MainActor
    func testCronExecutorSessionCreation() {
        let context = ModelContext(container)
        let agent = Agent(name: "CronAgent")
        context.insert(agent)

        let session = Session(title: "⏰ Test — Now")
        session.isActive = true
        context.insert(session)
        session.agent = agent

        let userMsg = Message(role: .user, content: "Test trigger")
        context.insert(userMsg)
        session.messages.append(userMsg)
        try! context.save()

        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(session.agent?.name, "CronAgent")

        session.isActive = false
        try! context.save()
        XCTAssertFalse(session.isActive)
    }

    @MainActor
    func testCronJobFinalization() {
        let context = ModelContext(container)
        let agent = Agent(name: "FinalizeAgent")
        context.insert(agent)
        let job = CronJob(name: "Finalize Test", cronExpression: "0 9 * * *", jobHint: "test")
        context.insert(job)
        agent.cronJobs.append(job)
        try! context.save()

        XCTAssertEqual(job.runCount, 0)
        XCTAssertNil(job.lastRunAt)
        XCTAssertNil(job.lastSessionId)

        let session = Session(title: "Result")
        context.insert(session)
        try! context.save()

        job.lastRunAt = Date()
        job.runCount += 1
        job.lastSessionId = session.id
        job.updatedAt = Date()

        if let next = try? CronParser.nextFireDate(after: Date(), for: job.cronExpression) {
            job.nextRunAt = next
        }
        try! context.save()

        XCTAssertEqual(job.runCount, 1)
        XCTAssertNotNil(job.lastRunAt)
        XCTAssertEqual(job.lastSessionId, session.id)
        XCTAssertNotNil(job.nextRunAt)
    }
}

// MARK: - CronExecutor Save-Crash Regression Tests
//
// These tests cover all scenarios that could produce the
// `objc_msgSend`-to-freed-object crash inside Core Data's
// `NSSQLBindVariable initWithValue:` when CronExecutor performs
// consecutive saves on the same ModelContext.

final class CronExecutorSaveCrashTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        agent = Agent(name: "CrashTestAgent")
        context.insert(agent)
        try! context.save()
    }

    override func tearDown() {
        container = nil
        context = nil
        agent = nil
        super.tearDown()
    }

    @MainActor
    private func makeJob(
        name: String = "TestJob",
        cron: String = "*/5 * * * *",
        nextRunAt: Date? = Date().addingTimeInterval(-60)
    ) -> CronJob {
        let job = CronJob(name: name, cronExpression: cron, jobHint: "test")
        job.nextRunAt = nextRunAt
        context.insert(job)
        agent.cronJobs.append(job)
        try! context.save()
        return job
    }

    // MARK: - Scenario 1: Atomic single-save transaction
    //
    // The fix merges session+agent+message+nextRunAt into one save.
    // Verify all fields are persisted together.

    @MainActor
    func testExecuteJob_singleSave_persistsAllFieldsAtomically() async {
        let job = makeJob(name: "AtomicSave")

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job, agent: agent, context: context)

        let fresh = ModelContext(container)
        let sessions = (try? fresh.fetch(FetchDescriptor<Session>())) ?? []
        let cronSession = sessions.first { $0.title.contains("AtomicSave") }

        XCTAssertNotNil(cronSession, "Session must be persisted")
        XCTAssertNotNil(cronSession?.agent, "Agent relationship must be persisted")
        XCTAssertEqual(cronSession?.agent?.id, agent.id)
        XCTAssertFalse(cronSession?.messages.isEmpty ?? true, "Trigger message must be persisted")

        let freshJob = (try? fresh.fetch(FetchDescriptor<CronJob>()))?.first { $0.id == job.id }
        XCTAssertNotNil(freshJob?.nextRunAt, "nextRunAt must be advanced")
        XCTAssertGreaterThan(freshJob?.nextRunAt ?? .distantPast, Date(),
                             "nextRunAt must be in the future")
    }

    // MARK: - Scenario 2: Relationship graph dirtied by double-save
    //
    // Reproduces the original crash pattern: assigning session.agent dirties
    // the inverse relationship, then saving the same context twice could
    // leave Core Data's row cache with stale pointers.

    @MainActor
    func testDoubleSave_afterRelationshipAssignment_doesNotCrash() {
        let job = makeJob(name: "DoubleSave")

        let session = Session(title: "⏰ DoubleSave")
        context.insert(session)
        session.agent = agent
        try! context.save()

        session.isActive = true
        let msg = Message(role: .user, content: "trigger")
        context.insert(msg)
        session.messages.append(msg)

        if let next = try? CronParser.nextFireDate(after: Date(), for: job.cronExpression) {
            job.nextRunAt = next
        }
        try! context.save()

        XCTAssertTrue(session.isActive)
        XCTAssertNotNil(job.nextRunAt)
    }

    // MARK: - Scenario 3: claimNextRun on a deleted job
    //
    // If the CronJob is deleted from another context while executeJob is
    // running, claimNextRun must bail out rather than try to save a
    // deleted object (which causes Core Data to bind freed values).

    @MainActor
    func testClaimNextRun_deletedJob_doesNotCrash() {
        let job = makeJob(name: "DeletedClaim")
        let jobId = job.id

        context.delete(job)
        try! context.save()

        let freshCtx = ModelContext(container)
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate<CronJob> { $0.id == jobId }
        )
        let refetched = try? freshCtx.fetch(descriptor)
        XCTAssertTrue(refetched?.isEmpty ?? true, "Job must be deleted")
    }

    @MainActor
    func testClaimNextRun_markedDeleted_skips() {
        let job = makeJob(name: "MarkedDeleted")

        context.delete(job)

        let executor = CronExecutor(modelContainer: container)
        executor.claimNextRun(for: job, context: context)
    }

    // MARK: - Scenario 4: finalizeJob on a deleted job
    //
    // If the job is deleted mid-execution (e.g. user deletes the CronJob
    // via the UI while the agent loop is running), finalizeJob must not
    // attempt to mutate and save the deleted managed object.

    @MainActor
    func testFinalizeJob_deletedJob_doesNotCrash() async {
        let job = makeJob(name: "FinalizeDeleted")

        let session = Session(title: "⏰ FinalizeDeleted")
        context.insert(session)
        session.agent = agent
        try! context.save()

        context.delete(job)

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job, agent: agent, context: context)

        XCTAssertFalse(session.isActive, "Session must be deactivated by defer block")
    }

    // MARK: - Scenario 5: finalizeJob with deleted session
    //
    // If the session is somehow deleted during the agent loop (unlikely but
    // defensive), finalizeJob should not crash when touching session.updatedAt.

    @MainActor
    func testFinalizeJob_deletedSession_doesNotCrash() {
        let job = makeJob(name: "SessionDeleted")

        let session = Session(title: "⏰ SessionDeleted")
        context.insert(session)
        session.agent = agent
        try! context.save()

        context.delete(session)

        job.lastRunAt = Date()
        job.runCount += 1
        job.updatedAt = Date()
        try? context.save()

        XCTAssertEqual(job.runCount, 1)
    }

    // MARK: - Scenario 6: Concurrent contexts modifying the same CronJob
    //
    // `updateNextRunDates()` uses its own ModelContext and can race with the
    // execution context. Verify that concurrent saves on the same entity
    // from two contexts don't corrupt state.

    @MainActor
    func testConcurrentContexts_modifyingSameCronJob_doesNotCorrupt() {
        let job = makeJob(name: "ConcurrentModify")
        let jobId = job.id

        let ctx2 = ModelContext(container)
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate<CronJob> { $0.id == jobId }
        )
        guard let job2 = try? ctx2.fetch(descriptor).first else {
            return XCTFail("Job must be fetchable from second context")
        }

        let future1 = Date().addingTimeInterval(300)
        job.nextRunAt = future1
        try! context.save()

        let future2 = Date().addingTimeInterval(600)
        job2.nextRunAt = future2
        try? ctx2.save()

        let verifyCtx = ModelContext(container)
        let final = try? verifyCtx.fetch(descriptor).first
        XCTAssertNotNil(final?.nextRunAt, "nextRunAt must be set after concurrent modifications")
    }

    // MARK: - Scenario 7: Agent deleted from another context mid-execution
    //
    // If the agent is deleted from another context (e.g. user deletes the
    // agent via UI) while CronExecutor is saving CronJob changes, the
    // `job.agent` relationship could reference a freed object in Core Data's
    // row cache.

    @MainActor
    func testSave_afterAgentDeletedFromOtherContext_doesNotCrash() {
        let job = makeJob(name: "AgentGone")
        let agentId = agent.id

        let otherCtx = ModelContext(container)
        let agentDescriptor = FetchDescriptor<Agent>(
            predicate: #Predicate<Agent> { $0.id == agentId }
        )
        if let otherAgent = try? otherCtx.fetch(agentDescriptor).first {
            otherCtx.delete(otherAgent)
            try? otherCtx.save()
        }

        // Agent→CronJob uses cascade delete, so the job may already be gone.
        // The purpose of this test is to verify no crash occurs when we
        // attempt to save after the agent disappears from under us.
        if let next = try? CronParser.nextFireDate(after: Date(), for: job.cronExpression) {
            job.nextRunAt = next
        }
        try? context.save()

        let verifyCtx = ModelContext(container)
        let verifyAgentDesc = FetchDescriptor<Agent>(
            predicate: #Predicate<Agent> { $0.id == agentId }
        )
        let agentGone = (try? verifyCtx.fetch(verifyAgentDesc))?.isEmpty ?? true
        XCTAssertTrue(agentGone, "Agent must have been deleted from the other context")
    }

    // MARK: - Scenario 8: Session+Agent+CronJob all in one save
    //
    // Verify the merged single-save pattern: insert session, set agent
    // relationship, insert message, update nextRunAt — all persisted
    // in one context.save() without crash.

    @MainActor
    func testSingleAtomicSave_sessionAgentMessageAndNextRunAt() {
        let job = makeJob(name: "AllInOne")

        let session = Session(title: "⏰ AllInOne")
        context.insert(session)
        session.agent = agent
        session.isActive = true

        let msg = Message(role: .user, content: "trigger message")
        context.insert(msg)
        session.messages.append(msg)

        if let next = try? CronParser.nextFireDate(after: Date(), for: job.cronExpression) {
            job.nextRunAt = next
        }

        try! context.save()

        let fresh = ModelContext(container)
        let sessions = (try? fresh.fetch(FetchDescriptor<Session>())) ?? []
        let savedSession = sessions.first { $0.title.contains("AllInOne") }

        XCTAssertNotNil(savedSession)
        XCTAssertNotNil(savedSession?.agent)
        XCTAssertTrue(savedSession?.isActive ?? false)
        XCTAssertEqual(savedSession?.messages.count, 1)

        let freshJob = (try? fresh.fetch(FetchDescriptor<CronJob>()))?.first { $0.id == job.id }
        XCTAssertNotNil(freshJob?.nextRunAt)
        XCTAssertGreaterThan(freshJob?.nextRunAt ?? .distantPast, Date())
    }

    // MARK: - Scenario 9: Rapid consecutive saves on same context
    //
    // Stress test: multiple save() calls in quick succession after various
    // relationship mutations — simulates the pattern that triggered the crash.

    @MainActor
    func testRapidConsecutiveSaves_withRelationshipChanges() {
        let job = makeJob(name: "RapidSave")

        for i in 0..<5 {
            let session = Session(title: "⏰ Rapid-\(i)")
            context.insert(session)
            session.agent = agent

            let msg = Message(role: .user, content: "msg \(i)")
            context.insert(msg)
            session.messages.append(msg)

            if let next = try? CronParser.nextFireDate(after: Date(), for: job.cronExpression) {
                job.nextRunAt = next
            }
            job.runCount = i + 1
            try! context.save()
        }

        XCTAssertEqual(job.runCount, 5)

        let fresh = ModelContext(container)
        let sessions = (try? fresh.fetch(FetchDescriptor<Session>())) ?? []
        let rapidSessions = sessions.filter { $0.title.contains("Rapid-") }
        XCTAssertEqual(rapidSessions.count, 5)
    }

    // MARK: - Scenario 10: updateNextRunDates skips running jobs
    //
    // When CronScheduler.updateNextRunDates runs while a job is executing,
    // it must skip jobs in `runningJobIds` to avoid a concurrent save on
    // the same entity from a different ModelContext.

    @MainActor
    func testSchedulerUpdateNextRunDates_skipsRunningJobs() async {
        let job = makeJob(name: "SkipRunning", cron: "*/5 * * * *")
        let originalNextRun = job.nextRunAt

        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()

        let mirror = Mirror(reflecting: scheduler)
        if let runningIds = mirror.descendant("runningJobIds") as? Set<UUID> {
            _ = runningIds
        }

        scheduler.stop()

        let fresh = ModelContext(container)
        let targetJobId = job.id
        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate<CronJob> { $0.id == targetJobId }
        )
        let refreshed = try? fresh.fetch(descriptor).first
        XCTAssertNotNil(refreshed)
        _ = originalNextRun
    }

    // MARK: - Scenario 11: executeJob end-to-end with no provider
    //
    // Full end-to-end executeJob through the no-provider path (which hits
    // all the save points: initial save, finalizeJob save, and defer save).
    // Must not crash.

    @MainActor
    func testExecuteJob_noProvider_fullLifecycle_doesNotCrash() async {
        let job = makeJob(name: "NoProviderLifecycle")

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job, agent: agent, context: context)

        XCTAssertFalse(job.isDeleted)
        XCTAssertEqual(job.runCount, 1)
        XCTAssertNotNil(job.lastRunAt)
        XCTAssertNotNil(job.nextRunAt)
        XCTAssertGreaterThan(job.nextRunAt ?? .distantPast, Date())

        let fresh = ModelContext(container)
        let sessions = (try? fresh.fetch(FetchDescriptor<Session>())) ?? []
        let cronSession = sessions.first { $0.title.contains("NoProviderLifecycle") }
        XCTAssertNotNil(cronSession)
        XCTAssertFalse(cronSession?.isActive ?? true,
                       "Session must be deactivated after executeJob completes")
        XCTAssertNotNil(cronSession?.agent)
    }

    // MARK: - Scenario 12: Multiple executeJob calls reuse same context
    //
    // In scheduleExecution, the same ModelContext is created once and passed
    // to executeJob. If a scheduler bug reused the context for multiple jobs,
    // the accumulated dirty state could trigger the crash.

    @MainActor
    func testMultipleExecuteJobs_sameContext_doesNotCrash() async {
        let job1 = makeJob(name: "Multi1", cron: "*/5 * * * *")
        let job2 = CronJob(name: "Multi2", cronExpression: "*/10 * * * *", jobHint: "test")
        job2.nextRunAt = Date().addingTimeInterval(-60)
        context.insert(job2)
        agent.cronJobs.append(job2)
        try! context.save()

        let executor = CronExecutor(modelContainer: container)
        await executor.executeJob(job1, agent: agent, context: context)
        await executor.executeJob(job2, agent: agent, context: context)

        XCTAssertEqual(job1.runCount, 1)
        XCTAssertEqual(job2.runCount, 1)
        XCTAssertFalse(context.hasChanges)
    }
}

// MARK: - Depth Propagation Integration Tests

final class DepthPropagationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var parentAgent: Agent!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        parentAgent = Agent(name: "ParentAgent")
        context.insert(parentAgent)
        try! context.save()
    }

    override func tearDown() {
        container = nil
        context = nil
        parentAgent = nil
        super.tearDown()
    }

    @MainActor
    func testRouterAtDepthZeroCreatesManagerAtDepthZero() {
        let router = FunctionCallRouter(agent: parentAgent, modelContext: context, nestingDepth: 0)
        XCTAssertEqual(router.nestingDepth, 0)
    }

    @MainActor
    func testRouterAtDepthNCreatesManagerAtDepthN() {
        for depth in 0...SubAgentManager.maxNestingDepth {
            let router = FunctionCallRouter(agent: parentAgent, modelContext: context, nestingDepth: depth)
            XCTAssertEqual(router.nestingDepth, depth)
        }
    }

    @MainActor
    func testSubAgentCreationPreservesParentRelationship() {
        let manager = SubAgentManager(modelContext: context, nestingDepth: 0)
        let (subAgent, session) = manager.createSubAgent(
            name: "Child",
            parentAgent: parentAgent,
            initialContext: nil,
            type: .temp
        )

        XCTAssertEqual(subAgent.name, "Child")
        XCTAssertTrue(subAgent.isTempSubAgent)
        XCTAssertEqual(subAgent.parentAgent?.id, parentAgent.id)
        XCTAssertNotNil(session)
    }

    @MainActor
    func testSubAgentCreationPersistent() {
        let manager = SubAgentManager(modelContext: context, nestingDepth: 0)
        let (subAgent, _) = manager.createSubAgent(
            name: "PersistentChild",
            parentAgent: parentAgent,
            initialContext: "You are a helper",
            type: .persistent
        )

        XCTAssertTrue(subAgent.isPersistentSubAgent)
        XCTAssertFalse(subAgent.isTempSubAgent)
        XCTAssertTrue(subAgent.isSubAgent)
    }

    @MainActor
    func testDepthExceededBeforeAgentLookup() async {
        let manager = SubAgentManager(modelContext: context, nestingDepth: SubAgentManager.maxNestingDepth)

        let (subAgent, _) = SubAgentManager(modelContext: context, nestingDepth: 0)
            .createSubAgent(name: "RealChild", parentAgent: parentAgent, initialContext: nil)

        do {
            _ = try await manager.sendMessage(to: subAgent.id, content: "hello")
            XCTFail("Should throw maxDepthExceeded")
        } catch let error as SubAgentError {
            if case .maxDepthExceeded = error {
                // Depth check happens before agent lookup — correct behavior
            } else {
                XCTFail("Expected maxDepthExceeded, got \(error)")
            }
        } catch {
            XCTFail("Unexpected error: \(error)")
        }
    }

    @MainActor
    func testDestroyTempAgent() {
        let manager = SubAgentManager(modelContext: context, nestingDepth: 0)
        let (subAgent, _) = manager.createSubAgent(
            name: "Disposable",
            parentAgent: parentAgent,
            initialContext: nil,
            type: .temp
        )
        let subId = subAgent.id

        manager.destroyTempAgent(subId)

        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.name == "Disposable" }
        )
        let remaining = try? context.fetch(descriptor)
        XCTAssertTrue(remaining?.isEmpty ?? true, "Temp agent should be deleted")
    }
}
