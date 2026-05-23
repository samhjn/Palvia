import XCTest
import SwiftData
import BackgroundTasks
@testable import iClaw

// MARK: - LaunchTaskManager Batch Embedding Tests

final class LaunchTaskManagerBatchTests: XCTestCase {

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
    func testRunAllTransitionsPhaseCorrectly() {
        let manager = LaunchTaskManager(container: container)
        XCTAssertEqual(manager.phase, .idle)

        manager.runAll()
        XCTAssertNotEqual(manager.phase, .idle,
                          "Phase should move to running after runAll()")
    }

    @MainActor
    func testRunAllIsIdempotent() {
        let manager = LaunchTaskManager(container: container)
        manager.runAll()
        let phaseAfterFirst = manager.phase

        manager.runAll()
        XCTAssertEqual(manager.phase, phaseAfterFirst,
                       "Second runAll() should be a no-op while already running")
    }

    @MainActor
    func testPhaseReachesDone() async throws {
        let manager = LaunchTaskManager(container: container)
        manager.runAll()

        for _ in 0..<100 {
            if manager.phase == .done { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(manager.phase, .done,
                       "Phase should reach .done after background tasks complete")
        XCTAssertEqual(manager.completedCount, manager.totalCount)
    }

    @MainActor
    func testBatchEmbeddingWithNoSessions() async throws {
        let manager = LaunchTaskManager(container: container)
        manager.runAll()

        for _ in 0..<100 {
            if manager.phase == .done { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(manager.phase, .done,
                       "Should complete without error even with no sessions")
    }

    @MainActor
    func testBatchEmbeddingReusesSingleContext() async throws {
        let context = ModelContext(container)
        let agent = Agent(name: "BatchAgent")
        context.insert(agent)

        for i in 0..<3 {
            let session = Session(title: "Session \(i)")
            context.insert(session)
            session.agent = agent
            for j in 0..<3 {
                let msg = Message(role: j % 2 == 0 ? .user : .assistant,
                                  content: "Message \(j) in session \(i)")
                context.insert(msg)
                session.messages.append(msg)
            }
        }
        try context.save()

        let manager = LaunchTaskManager(container: container)
        manager.runAll()

        for _ in 0..<200 {
            if manager.phase == .done { break }
            try await Task.sleep(for: .milliseconds(50))
        }
        XCTAssertEqual(manager.phase, .done)
    }
}

// MARK: - ModelContext Reuse Safety Tests

final class ModelContextReuseSafetyTests: XCTestCase {

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
    func testSingleContextMultipleEmbeddingUpserts() throws {
        let context = ModelContext(container)
        let agent = Agent(name: "Test")
        context.insert(agent)

        let sessions = (0..<5).map { i -> Session in
            let s = Session(title: "Session \(i)")
            context.insert(s)
            s.agent = agent
            return s
        }
        try context.save()

        let store = SessionVectorStore(modelContext: context)
        for session in sessions {
            let vector: [Float] = (0..<64).map { Float($0) * 0.01 }
            store.upsertEmbeddingDirect(
                sessionId: session.id,
                vector: vector,
                sourceText: "test text for \(session.title)"
            )
        }

        let embeddings = try context.fetch(FetchDescriptor<SessionEmbedding>())
        XCTAssertEqual(embeddings.count, 5,
                       "All 5 embeddings should be persisted via single context")
    }

    @MainActor
    func testUpsertEmbeddingIdempotent() throws {
        let context = ModelContext(container)
        let store = SessionVectorStore(modelContext: context)
        let sessionId = UUID()

        let vector: [Float] = [0.1, 0.2, 0.3]
        store.upsertEmbeddingDirect(sessionId: sessionId, vector: vector, sourceText: "hello")
        store.upsertEmbeddingDirect(sessionId: sessionId, vector: vector, sourceText: "hello")

        let embeddings = try context.fetch(FetchDescriptor<SessionEmbedding>())
        let matching = embeddings.filter { $0.sessionIdRaw == sessionId.uuidString }
        XCTAssertEqual(matching.count, 1,
                       "Duplicate upsert should not create a second embedding")
    }

    @MainActor
    func testUpsertEmbeddingUpdatesExisting() throws {
        let context = ModelContext(container)
        let store = SessionVectorStore(modelContext: context)
        let sessionId = UUID()

        store.upsertEmbeddingDirect(sessionId: sessionId, vector: [0.1, 0.2], sourceText: "v1")
        store.upsertEmbeddingDirect(sessionId: sessionId, vector: [0.3, 0.4], sourceText: "v2")

        let embeddings = try context.fetch(FetchDescriptor<SessionEmbedding>())
        let match = embeddings.first { $0.sessionIdRaw == sessionId.uuidString }
        XCTAssertNotNil(match)
        XCTAssertEqual(match?.vector, [0.3, 0.4],
                       "Upsert should update the vector to the latest value")
    }
}

// MARK: - Stale Session Reset Tests

final class StaleSessionResetTests: XCTestCase {

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
    func testResetStaleActiveSessionsResetsAll() throws {
        let context = ModelContext(container)
        let s1 = Session(title: "Active 1")
        s1.isActive = true
        let s2 = Session(title: "Active 2")
        s2.isActive = true
        let s3 = Session(title: "Inactive")
        s3.isActive = false
        context.insert(s1)
        context.insert(s2)
        context.insert(s3)
        try context.save()

        // Simulate the reset that happens in iClawApp.init()
        let resetCtx = ModelContext(container)
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { $0.isActive == true }
        )
        let stale = try resetCtx.fetch(descriptor)
        for session in stale {
            session.isActive = false
        }
        try resetCtx.save()

        let verifyCtx = ModelContext(container)
        let allSessions = try verifyCtx.fetch(FetchDescriptor<Session>())
        let stillActive = allSessions.filter(\.isActive)
        XCTAssertTrue(stillActive.isEmpty,
                      "All stale active sessions should be reset to inactive")
    }

    @MainActor
    func testResetStaleSessionsDoesNotCrashOnEmptyDB() {
        let context = ModelContext(container)
        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate<Session> { $0.isActive == true }
        )
        let stale = try? context.fetch(descriptor)
        XCTAssertNotNil(stale)
        XCTAssertTrue(stale?.isEmpty ?? true,
                      "Empty database should return empty result, not crash")
    }
}

// MARK: - ImagePreviewCoordinator Tests

final class ImagePreviewCoordinatorTests: XCTestCase {

    func testSharedInstanceIsStable() {
        let a = ImagePreviewCoordinator.shared
        let b = ImagePreviewCoordinator.shared
        XCTAssertTrue(a === b,
                      "Shared coordinator must return the same instance")
    }

    @MainActor
    func testShowAndClose() {
        let coordinator = ImagePreviewCoordinator.shared
        let testImage = UIImage(systemName: "star")!

        coordinator.show(testImage)
        XCTAssertTrue(coordinator.isPresented)
        XCTAssertNotNil(coordinator.image)

        coordinator.close(animated: false)
        XCTAssertFalse(coordinator.isPresented)
    }

    @MainActor
    func testCloseWithoutShowDoesNotCrash() {
        let coordinator = ImagePreviewCoordinator.shared
        coordinator.close(animated: false)
        XCTAssertFalse(coordinator.isPresented)
    }

    @MainActor
    func testCoordinatorAccessibleWithoutState() {
        let coordinator: ImagePreviewCoordinator = .shared
        XCTAssertNotNil(coordinator)
        XCTAssertFalse(coordinator.isPresented,
                       "Coordinator should be accessible via computed property (no @State needed)")
    }
}

// MARK: - BGTask Registration Failure Logging Tests

final class BGTaskRegistrationLoggingTests: XCTestCase {

    override func setUp() {
        super.setUp()
        CronBGTaskCoordinator.resetRegistrationStateForTesting()
    }

    override func tearDown() {
        CronBGTaskCoordinator.resetRegistrationStateForTesting()
        super.tearDown()
    }

    private final class MockRegistrar: BGTaskRegistering, @unchecked Sendable {
        var shouldSucceed = true
        private(set) var registerCallCount = 0

        @discardableResult
        func register(
            forTaskWithIdentifier identifier: String,
            using queue: DispatchQueue?,
            launchHandler: @escaping @Sendable (BGTask) -> Void
        ) -> Bool {
            registerCallCount += 1
            return shouldSucceed
        }
    }

    func testFailedRegistrationDoesNotCrash() {
        let mock = MockRegistrar()
        mock.shouldSucceed = false

        let coordinator = CronBGTaskCoordinator(registrar: mock)
        let result = coordinator.registerCronTask()

        XCTAssertFalse(result)
        XCTAssertFalse(coordinator.isRegistered)
        XCTAssertEqual(mock.registerCallCount, 1)
    }

    func testSuccessfulRegistrationSetsState() {
        let mock = MockRegistrar()
        mock.shouldSucceed = true

        let coordinator = CronBGTaskCoordinator(registrar: mock)
        let result = coordinator.registerCronTask()

        XCTAssertTrue(result)
        XCTAssertTrue(coordinator.isRegistered)
    }

    func testFailedThenSuccessfulRetry() {
        let mock = MockRegistrar()
        mock.shouldSucceed = false
        let coordinator = CronBGTaskCoordinator(registrar: mock)

        XCTAssertFalse(coordinator.registerCronTask())
        XCTAssertFalse(coordinator.isRegistered)

        mock.shouldSucceed = true
        XCTAssertTrue(coordinator.registerCronTask())
        XCTAssertTrue(coordinator.isRegistered)
        XCTAssertEqual(mock.registerCallCount, 2)
    }

    func testCoordinatorWithoutSchedulerHandlesGracefully() {
        let mock = MockRegistrar()
        let coordinator = CronBGTaskCoordinator(registrar: mock)
        coordinator.registerCronTask()

        XCTAssertNil(coordinator.scheduler,
                     "Scheduler should be nil before onAppear phase")
        XCTAssertTrue(coordinator.isRegistered,
                      "Registration should succeed independently of scheduler")
    }
}

// MARK: - SessionVectorStore Cosine Similarity Tests

final class VectorStoreMathTests: XCTestCase {

    func testCosineSimilarityIdenticalVectors() {
        let v: [Float] = [1, 2, 3, 4, 5]
        let sim = SessionVectorStore.cosineSimilarity(v, v)
        XCTAssertEqual(sim, 1.0, accuracy: 0.0001)
    }

    func testCosineSimilarityOrthogonalVectors() {
        let a: [Float] = [1, 0]
        let b: [Float] = [0, 1]
        let sim = SessionVectorStore.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 0.0001)
    }

    func testCosineSimilarityOppositeVectors() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        let sim = SessionVectorStore.cosineSimilarity(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 0.0001)
    }

    func testCosineSimilarityDifferentLengthsReturnsZero() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [1, 2]
        XCTAssertEqual(SessionVectorStore.cosineSimilarity(a, b), 0.0)
    }

    func testCosineSimilarityEmptyVectorsReturnsZero() {
        let empty: [Float] = []
        XCTAssertEqual(SessionVectorStore.cosineSimilarity(empty, empty), 0.0)
    }
}

// MARK: - App Init Safety Tests

final class AppInitSafetyTests: XCTestCase {

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
    func testModelContainerCreationWithFullSchema() {
        XCTAssertNotNil(container,
                        "ModelContainer should be creatable with all model types")
    }

    @MainActor
    func testAllModelTypesInsertable() throws {
        let context = ModelContext(container)

        let provider = LLMProvider(name: "Test")
        context.insert(provider)

        let agent = Agent(name: "Test Agent")
        context.insert(agent)

        let session = Session(title: "Test Session")
        context.insert(session)
        session.agent = agent

        let message = Message(role: .user, content: "Hello")
        context.insert(message)
        session.messages.append(message)

        let config = AgentConfig(key: "test", content: "value")
        context.insert(config)
        agent.customConfigs.append(config)

        let embedding = SessionEmbedding(
            sessionId: session.id,
            vector: [0.1, 0.2, 0.3],
            modelName: "test",
            sourceTextHash: "abc123"
        )
        context.insert(embedding)

        try context.save()

        XCTAssertEqual(try context.fetch(FetchDescriptor<Agent>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<Session>()).count, 1)
        XCTAssertEqual(try context.fetch(FetchDescriptor<SessionEmbedding>()).count, 1)
    }

    @MainActor
    func testConcurrentModelContextCreation() throws {
        let contexts = (0..<10).map { _ in ModelContext(container) }

        for (i, ctx) in contexts.enumerated() {
            let agent = Agent(name: "Agent-\(i)")
            ctx.insert(agent)
            try ctx.save()
        }

        let verifyCtx = ModelContext(container)
        let allAgents = try verifyCtx.fetch(FetchDescriptor<Agent>())
        XCTAssertEqual(allAgents.count, 10,
                       "All agents from different contexts should be persisted")
    }
}
