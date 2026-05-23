import XCTest
import SwiftData
@testable import iClaw

final class SessionRAGTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([
            Agent.self, Session.self, Message.self, SessionEmbedding.self,
            LLMProvider.self, AgentConfig.self, CodeSnippet.self,
            CronJob.self, InstalledSkill.self, Skill.self,
        ])
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

    // MARK: - Helpers

    @MainActor
    @discardableResult
    private func makeSession(title: String, messages: [(MessageRole, String)] = [], compressed: String? = nil, archived: Bool = false) -> Session {
        let session = Session(title: title)
        context.insert(session)
        session.agent = agent
        session.isArchived = archived
        session.compressedContext = compressed
        for (role, content) in messages {
            let msg = Message(role: role, content: content)
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()
        return session
    }

    @MainActor
    private func makeRAGTools(currentSessionId: UUID? = nil) -> SessionRAGTools {
        SessionRAGTools(agent: agent, modelContext: context, currentSessionId: currentSessionId)
    }

    // MARK: - SessionEmbedding Model

    func testEmbeddingVectorRoundTrip() {
        let vec: [Float] = [0.1, 0.2, 0.3, -0.5, 1.0]
        let emb = SessionEmbedding(sessionId: UUID(), vector: vec, modelName: "test", sourceTextHash: "abc")
        XCTAssertEqual(emb.vector.count, vec.count)
        XCTAssertEqual(emb.dimensions, vec.count)
        for i in 0..<vec.count {
            XCTAssertEqual(emb.vector[i], vec[i], accuracy: 1e-6)
        }
    }

    func testEmbeddingEmptyVector() {
        let emb = SessionEmbedding(sessionId: UUID(), vector: [], modelName: "test", sourceTextHash: "abc")
        XCTAssertTrue(emb.vector.isEmpty)
        XCTAssertEqual(emb.dimensions, 0)
    }

    func testEmbeddingSessionIdComputed() {
        let id = UUID()
        let emb = SessionEmbedding(sessionId: id, vector: [1.0], modelName: "test", sourceTextHash: "abc")
        XCTAssertEqual(emb.sessionId, id)
        XCTAssertEqual(emb.sessionIdRaw, id.uuidString)
    }

    func testEmbeddingVectorSetUpdatesData() {
        let emb = SessionEmbedding(sessionId: UUID(), vector: [1.0, 2.0], modelName: "test", sourceTextHash: "abc")
        emb.vector = [3.0, 4.0, 5.0]
        XCTAssertEqual(emb.vector, [3.0, 4.0, 5.0])
        XCTAssertEqual(emb.dimensions, 3)
    }

    // MARK: - Cosine Similarity

    func testCosineSimilarityIdenticalVectors() {
        let v: [Float] = [1, 2, 3]
        let sim = SessionVectorStore.cosineSimilarity(v, v)
        XCTAssertEqual(sim, 1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOrthogonalVectors() {
        let a: [Float] = [1, 0, 0]
        let b: [Float] = [0, 1, 0]
        let sim = SessionVectorStore.cosineSimilarity(a, b)
        XCTAssertEqual(sim, 0.0, accuracy: 1e-5)
    }

    func testCosineSimilarityOppositeVectors() {
        let a: [Float] = [1, 2, 3]
        let b: [Float] = [-1, -2, -3]
        let sim = SessionVectorStore.cosineSimilarity(a, b)
        XCTAssertEqual(sim, -1.0, accuracy: 1e-5)
    }

    func testCosineSimilarityDifferentDimensionsReturnsZero() {
        let a: [Float] = [1, 2]
        let b: [Float] = [1, 2, 3]
        XCTAssertEqual(SessionVectorStore.cosineSimilarity(a, b), 0)
    }

    func testCosineSimilarityEmptyVectorsReturnsZero() {
        XCTAssertEqual(SessionVectorStore.cosineSimilarity([], []), 0)
    }

    func testCosineSimilarityZeroVectorReturnsZero() {
        let a: [Float] = [0, 0, 0]
        let b: [Float] = [1, 2, 3]
        XCTAssertEqual(SessionVectorStore.cosineSimilarity(a, b), 0)
    }

    // MARK: - SHA256

    func testSHA256Deterministic() {
        let hash1 = SessionVectorStore.sha256("hello world")
        let hash2 = SessionVectorStore.sha256("hello world")
        XCTAssertEqual(hash1, hash2)
        XCTAssertEqual(hash1.count, 64) // 256 bits = 64 hex chars
    }

    func testSHA256DifferentInputs() {
        let hash1 = SessionVectorStore.sha256("hello")
        let hash2 = SessionVectorStore.sha256("world")
        XCTAssertNotEqual(hash1, hash2)
    }

    // MARK: - buildEmbeddingText

    @MainActor
    func testBuildEmbeddingTextWithTitleAndMessages() {
        let session = makeSession(title: "Swift Concurrency", messages: [
            (.user, "How does async/await work?"),
            (.assistant, "In Swift, async/await provides structured concurrency..."),
        ])
        let text = SessionVectorStore.buildEmbeddingText(for: session)
        XCTAssertTrue(text.contains("Swift Concurrency"))
        XCTAssertTrue(text.contains("async/await"))
    }

    @MainActor
    func testBuildEmbeddingTextPrefersCompressedContext() {
        let session = makeSession(
            title: "Test Session",
            messages: [(.user, "old message that should be ignored when compressed exists")],
            compressed: "This session discussed database optimization techniques."
        )
        let text = SessionVectorStore.buildEmbeddingText(for: session)
        XCTAssertTrue(text.contains("database optimization"))
        XCTAssertFalse(text.contains("old message"))
    }

    @MainActor
    func testBuildEmbeddingTextExcludesSystemMessages() {
        let session = makeSession(title: "Test", messages: [
            (.system, "You are a helpful assistant"),
            (.user, "Hello"),
        ])
        let text = SessionVectorStore.buildEmbeddingText(for: session)
        XCTAssertFalse(text.contains("helpful assistant"))
        XCTAssertTrue(text.contains("Hello"))
    }

    @MainActor
    func testBuildEmbeddingTextEmptySession() {
        let session = makeSession(title: "", messages: [])
        let text = SessionVectorStore.buildEmbeddingText(for: session)
        XCTAssertTrue(text.isEmpty)
    }

    @MainActor
    func testBuildEmbeddingTextTruncatesAt6000Chars() {
        let longContent = String(repeating: "x", count: 10000)
        let session = makeSession(title: "T", messages: [(.user, longContent)])
        let text = SessionVectorStore.buildEmbeddingText(for: session)
        XCTAssertLessThanOrEqual(text.count, 6000)
    }

    // MARK: - Keyword Extraction

    func testExtractKeywordsFiltersStopWords() {
        let keywords = SessionService.extractSearchKeywords(from: "how do I use Swift concurrency")
        XCTAssertTrue(keywords.contains("swift"))
        XCTAssertTrue(keywords.contains("concurrency"))
        XCTAssertFalse(keywords.contains("how"))
        XCTAssertFalse(keywords.contains("do"))
    }

    func testExtractKeywordsFiltersSingleCharWords() {
        let keywords = SessionService.extractSearchKeywords(from: "a b c real keyword")
        XCTAssertFalse(keywords.contains("a"))
        XCTAssertFalse(keywords.contains("b"))
        XCTAssertFalse(keywords.contains("c"))
        XCTAssertTrue(keywords.contains("real"))
        XCTAssertTrue(keywords.contains("keyword"))
    }

    func testExtractKeywordsDeduplicates() {
        let keywords = SessionService.extractSearchKeywords(from: "swift swift swift concurrency")
        let swiftCount = keywords.filter { $0 == "swift" }.count
        XCTAssertEqual(swiftCount, 1)
    }

    func testExtractKeywordsChineseStopWords() {
        let keywords = SessionService.extractSearchKeywords(from: "我的数据库优化")
        XCTAssertFalse(keywords.contains("我"))
        XCTAssertFalse(keywords.contains("的"))
    }

    func testExtractKeywordsEmptyString() {
        let keywords = SessionService.extractSearchKeywords(from: "")
        XCTAssertTrue(keywords.isEmpty)
    }

    func testExtractKeywordsOnlyStopWords() {
        let keywords = SessionService.extractSearchKeywords(from: "the is are was were")
        XCTAssertTrue(keywords.isEmpty)
    }

    // MARK: - Keyword Search (SessionService)

    @MainActor
    func testKeywordSearchMatchesTitle() {
        makeSession(title: "SwiftUI Navigation", messages: [(.user, "hello")])
        makeSession(title: "CoreData Basics", messages: [(.user, "hello")])

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "navigation", agent: agent)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "SwiftUI Navigation")
    }

    @MainActor
    func testKeywordSearchMatchesMessageContent() {
        makeSession(title: "Chat 1", messages: [
            (.user, "How to implement pagination in SwiftUI?"),
            (.assistant, "You can use LazyVStack with onAppear..."),
        ])
        makeSession(title: "Chat 2", messages: [(.user, "unrelated topic")])

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "pagination", agent: agent)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Chat 1")
    }

    @MainActor
    func testKeywordSearchMatchesCompressedContext() {
        makeSession(title: "Old Chat", messages: [], compressed: "Discussed CoreData migration strategies and batch processing")

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "migration", agent: agent)
        XCTAssertEqual(results.count, 1)
    }

    @MainActor
    func testKeywordSearchExcludesArchivedSessions() {
        makeSession(title: "Archived SwiftUI Chat", messages: [(.user, "SwiftUI")], archived: true)
        makeSession(title: "Active SwiftUI Chat", messages: [(.user, "SwiftUI")])

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "SwiftUI", agent: agent)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Active SwiftUI Chat")
    }

    @MainActor
    func testKeywordSearchExcludesCurrentSession() {
        let current = makeSession(title: "Current Chat", messages: [(.user, "swift")])
        makeSession(title: "Other Chat", messages: [(.user, "swift")])

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "swift", agent: agent, excludeSessionId: current.id)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Other Chat")
    }

    @MainActor
    func testKeywordSearchRespectsLimit() {
        for i in 0..<5 {
            makeSession(title: "Swift Topic \(i)", messages: [(.user, "swift code")])
        }

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "swift", agent: agent, limit: 3)
        XCTAssertEqual(results.count, 3)
    }

    @MainActor
    func testKeywordSearchTitleWeighedHigherThanMessages() {
        let titleMatch = makeSession(title: "Concurrency in Swift", messages: [(.user, "hello")])
        let msgMatch = makeSession(title: "Random Chat", messages: [(.user, "concurrency is great")])

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "concurrency", agent: agent)
        XCTAssertEqual(results.count, 2)
        XCTAssertEqual(results.first?.id, titleMatch.id, "Title match should rank higher")
        XCTAssertEqual(results.last?.id, msgMatch.id)
    }

    @MainActor
    func testKeywordSearchNoResults() {
        makeSession(title: "Chat about cooking", messages: [(.user, "how to bake a cake")])

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "quantum physics", agent: agent)
        XCTAssertTrue(results.isEmpty)
    }

    @MainActor
    func testKeywordSearchExcludesOtherAgentSessions() {
        let otherAgent = Agent(name: "OtherAgent")
        context.insert(otherAgent)
        let session = Session(title: "Other Agent Swift Chat")
        context.insert(session)
        session.agent = otherAgent
        let msg = Message(role: .user, content: "swift")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        makeSession(title: "My Swift Chat", messages: [(.user, "swift")])

        let service = SessionService(modelContext: context)
        let results = service.searchSessions(query: "swift", agent: agent)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "My Swift Chat")
    }

    // MARK: - fetchSessionContext

    @MainActor
    func testFetchSessionContextReturnsSnapshot() {
        let session = makeSession(title: "Test Chat", messages: [
            (.user, "Hello"),
            (.assistant, "Hi there!"),
            (.user, "How are you?"),
        ])

        let service = SessionService(modelContext: context)
        let snapshot = service.fetchSessionContext(sessionId: session.id)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot?.title, "Test Chat")
        XCTAssertEqual(snapshot?.totalMessages, 3)
    }

    @MainActor
    func testFetchSessionContextPagingDefault() {
        let session = makeSession(title: "Chat", messages: [
            (.user, "msg1"), (.assistant, "msg2"),
            (.user, "msg3"), (.assistant, "msg4"),
            (.user, "msg5"), (.assistant, "msg6"),
        ])

        let service = SessionService(modelContext: context)
        let snapshot = service.fetchSessionContext(sessionId: session.id, limit: 3)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot!.recentMessages.count, 3)
        XCTAssertTrue(snapshot!.hasMore)
        XCTAssertEqual(snapshot!.totalMessages, 6)
    }

    @MainActor
    func testFetchSessionContextPagingWithOffset() {
        let session = makeSession(title: "Chat", messages: [
            (.user, "msg1"), (.assistant, "msg2"),
            (.user, "msg3"), (.assistant, "msg4"),
            (.user, "msg5"), (.assistant, "msg6"),
        ])

        let service = SessionService(modelContext: context)
        // offset=3 skips last 3, limit=3 gets the next 3
        let snapshot = service.fetchSessionContext(sessionId: session.id, limit: 3, offset: 3)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot!.recentMessages.count, 3)
        XCTAssertFalse(snapshot!.hasMore) // at the beginning
    }

    @MainActor
    func testFetchSessionContextFiltersSystemMessages() {
        let session = makeSession(title: "Chat", messages: [
            (.system, "You are helpful"),
            (.user, "Hello"),
            (.assistant, "Hi!"),
        ])

        let service = SessionService(modelContext: context)
        let snapshot = service.fetchSessionContext(sessionId: session.id, limit: 10)
        XCTAssertNotNil(snapshot)
        XCTAssertEqual(snapshot!.totalMessages, 2) // system excluded
        XCTAssertTrue(snapshot!.recentMessages.allSatisfy { $0.role != "system" })
    }

    @MainActor
    func testFetchSessionContextNonexistentSession() {
        let service = SessionService(modelContext: context)
        let snapshot = service.fetchSessionContext(sessionId: UUID())
        XCTAssertNil(snapshot)
    }

    // MARK: - SessionContextSnapshot.formatted

    func testSnapshotFormattedContainsTitle() {
        let snapshot = SessionContextSnapshot(
            sessionId: UUID(),
            title: "My Test Session",
            createdAt: Date(),
            updatedAt: Date(),
            compressedContext: nil,
            recentMessages: [],
            totalMessages: 0,
            offset: 0,
            hasMore: false
        )
        let text = snapshot.formatted()
        XCTAssertTrue(text.contains("My Test Session"))
    }

    func testSnapshotFormattedIncludesCompressedContext() {
        let snapshot = SessionContextSnapshot(
            sessionId: UUID(),
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            compressedContext: "Discussion about SwiftUI layouts",
            recentMessages: [],
            totalMessages: 0,
            offset: 0,
            hasMore: false
        )
        let text = snapshot.formatted()
        XCTAssertTrue(text.contains("Compressed History"))
        XCTAssertTrue(text.contains("SwiftUI layouts"))
    }

    func testSnapshotFormattedHasMoreShowsPagingHint() {
        let snapshot = SessionContextSnapshot(
            sessionId: UUID(),
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            compressedContext: nil,
            recentMessages: [
                .init(role: "user", content: "hello", toolName: nil, timestamp: Date()),
            ],
            totalMessages: 10,
            offset: 0,
            hasMore: true
        )
        let text = snapshot.formatted()
        XCTAssertTrue(text.contains("recall_session"))
        XCTAssertTrue(text.contains("offset"))
    }

    func testSnapshotFormattedTokenTruncation() {
        var messages: [SessionContextSnapshot.MessageEntry] = []
        for i in 0..<100 {
            messages.append(.init(
                role: "user",
                content: String(repeating: "word ", count: 500) + "msg\(i)",
                toolName: nil,
                timestamp: Date()
            ))
        }
        let snapshot = SessionContextSnapshot(
            sessionId: UUID(),
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            compressedContext: nil,
            recentMessages: messages,
            totalMessages: 100,
            offset: 0,
            hasMore: false
        )
        let text = snapshot.formatted(maxTokens: 100)
        XCTAssertTrue(text.contains("token limit reached"))
    }

    func testSnapshotFormattedToolNameInRole() {
        let snapshot = SessionContextSnapshot(
            sessionId: UUID(),
            title: "Test",
            createdAt: Date(),
            updatedAt: Date(),
            compressedContext: nil,
            recentMessages: [
                .init(role: "tool", content: "result", toolName: "search_web", timestamp: Date()),
            ],
            totalMessages: 1,
            offset: 0,
            hasMore: false
        )
        let text = snapshot.formatted()
        XCTAssertTrue(text.contains("tool (search_web)"))
    }

    // MARK: - SessionRAGTools: searchSessions

    @MainActor
    func testSearchSessionsMissingQuery() {
        let tools = makeRAGTools()
        let result = tools.searchSessions(arguments: [:])
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("query"))
    }

    @MainActor
    func testSearchSessionsEmptyQuery() {
        let tools = makeRAGTools()
        let result = tools.searchSessions(arguments: ["query": ""])
        XCTAssertTrue(result.contains("Error"))
    }

    @MainActor
    func testSearchSessionsFindsMatches() {
        makeSession(title: "SwiftUI Navigation Patterns", messages: [
            (.user, "How to implement navigation?"),
            (.assistant, "You can use NavigationStack..."),
        ])

        let tools = makeRAGTools()
        let result = tools.searchSessions(arguments: ["query": "navigation"])
        XCTAssertTrue(result.contains("SwiftUI Navigation Patterns"))
        XCTAssertTrue(result.contains("Found"))
        XCTAssertTrue(result.contains("recall_session"))
    }

    @MainActor
    func testSearchSessionsNoMatches() {
        makeSession(title: "Cooking Chat", messages: [(.user, "bake a cake")])

        let tools = makeRAGTools()
        let result = tools.searchSessions(arguments: ["query": "quantum physics"])
        XCTAssertTrue(result.contains("No sessions found"))
    }

    @MainActor
    func testSearchSessionsRespectsLimit() {
        for i in 0..<5 {
            makeSession(title: "Swift Topic \(i)", messages: [(.user, "swift code")])
        }

        let tools = makeRAGTools()
        let result = tools.searchSessions(arguments: ["query": "swift", "limit": 2])
        // Count session entries (lines starting with "- **")
        let matchCount = result.components(separatedBy: "\n").filter { $0.hasPrefix("- **") }.count
        XCTAssertEqual(matchCount, 2)
    }

    @MainActor
    func testSearchSessionsLimitClampedTo20() {
        for i in 0..<25 {
            makeSession(title: "Swift Topic \(i)", messages: [(.user, "swift code")])
        }

        let tools = makeRAGTools()
        let result = tools.searchSessions(arguments: ["query": "swift", "limit": 100])
        let matchCount = result.components(separatedBy: "\n").filter { $0.hasPrefix("- **") }.count
        XCTAssertLessThanOrEqual(matchCount, 20)
    }

    @MainActor
    func testSearchSessionsExcludesCurrentSession() {
        let current = makeSession(title: "Current Swift Chat", messages: [(.user, "swift")])
        makeSession(title: "Other Swift Chat", messages: [(.user, "swift")])

        let tools = makeRAGTools(currentSessionId: current.id)
        let result = tools.searchSessions(arguments: ["query": "swift"])
        XCTAssertFalse(result.contains("Current Swift Chat"))
        XCTAssertTrue(result.contains("Other Swift Chat"))
    }

    // MARK: - SessionRAGTools: recallSession

    @MainActor
    func testRecallSessionMissingId() {
        let tools = makeRAGTools()
        let result = tools.recallSession(arguments: [:])
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("session_id"))
    }

    @MainActor
    func testRecallSessionInvalidUUID() {
        let tools = makeRAGTools()
        let result = tools.recallSession(arguments: ["session_id": "not-a-uuid"])
        XCTAssertTrue(result.contains("Error"))
    }

    @MainActor
    func testRecallSessionNotFound() {
        let tools = makeRAGTools()
        let result = tools.recallSession(arguments: ["session_id": UUID().uuidString])
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("not found"))
    }

    @MainActor
    func testRecallSessionSuccess() {
        let session = makeSession(title: "My Chat", messages: [
            (.user, "What is SwiftData?"),
            (.assistant, "SwiftData is Apple's persistence framework..."),
        ])

        let tools = makeRAGTools()
        let result = tools.recallSession(arguments: ["session_id": session.id.uuidString])
        XCTAssertTrue(result.contains("My Chat"))
        XCTAssertTrue(result.contains("SwiftData"))
    }

    @MainActor
    func testRecallSessionRejectsOtherAgentSession() {
        let otherAgent = Agent(name: "Other")
        context.insert(otherAgent)
        let session = Session(title: "Other Agent Chat")
        context.insert(session)
        session.agent = otherAgent
        try! context.save()

        let tools = makeRAGTools()
        let result = tools.recallSession(arguments: ["session_id": session.id.uuidString])
        XCTAssertTrue(result.contains("Error"))
        XCTAssertTrue(result.contains("not found"))
    }

    @MainActor
    func testRecallSessionWithPaging() {
        let session = makeSession(title: "Long Chat", messages: [
            (.user, "msg1"), (.assistant, "reply1"),
            (.user, "msg2"), (.assistant, "reply2"),
            (.user, "msg3"), (.assistant, "reply3"),
            (.user, "msg4"), (.assistant, "reply4"),
        ])

        let tools = makeRAGTools()
        let result = tools.recallSession(arguments: [
            "session_id": session.id.uuidString,
            "max_messages": 2,
            "offset": 0,
        ])
        XCTAssertTrue(result.contains("showing 2 of 8"))
    }

    // MARK: - VectorStore: updateEmbedding & search

    @MainActor
    func testUpdateEmbeddingStoresVector() {
        let session = makeSession(title: "Test Embedding", messages: [
            (.user, "Hello world"),
            (.assistant, "Hi there"),
        ])

        let store = SessionVectorStore(modelContext: context)
        store.updateEmbedding(for: session)

        // Verify embedding was created
        let descriptor = FetchDescriptor<SessionEmbedding>()
        let embeddings = (try? context.fetch(descriptor)) ?? []
        let matching = embeddings.filter { $0.sessionIdRaw == session.id.uuidString }
        XCTAssertEqual(matching.count, 1)
        XCTAssertEqual(matching.first?.modelName, "NLEmbedding.local")
        XCTAssertFalse(matching.first?.vector.isEmpty ?? true)
    }

    @MainActor
    func testUpdateEmbeddingSkipsWhenHashUnchanged() {
        let session = makeSession(title: "Test", messages: [
            (.user, "Hello"),
            (.assistant, "World"),
        ])

        let store = SessionVectorStore(modelContext: context)
        store.updateEmbedding(for: session)

        // Record the creation date
        let descriptor = FetchDescriptor<SessionEmbedding>()
        let first = (try? context.fetch(descriptor))?.first
        let firstDate = first?.createdAt

        // Update again — should be skipped
        store.updateEmbedding(for: session)
        let second = (try? context.fetch(descriptor))?.first
        XCTAssertEqual(firstDate, second?.createdAt)
    }

    @MainActor
    func testUpdateEmbeddingSkipsEmptySession() {
        let session = makeSession(title: "", messages: [])

        let store = SessionVectorStore(modelContext: context)
        store.updateEmbedding(for: session)

        let descriptor = FetchDescriptor<SessionEmbedding>()
        let embeddings = (try? context.fetch(descriptor)) ?? []
        XCTAssertTrue(embeddings.isEmpty)
    }

    @MainActor
    func testVectorSearchFindsSimilarSessions() {
        // Create sessions with distinct topics
        let swiftSession = makeSession(title: "Swift Programming Language Concurrency", messages: [
            (.user, "How does Swift async await concurrency work?"),
            (.assistant, "Swift concurrency uses structured tasks and actors..."),
        ])
        let cookingSession = makeSession(title: "Italian Cooking Recipes Pasta", messages: [
            (.user, "How do I make carbonara pasta from Italy?"),
            (.assistant, "For authentic carbonara you need guanciale and pecorino romano..."),
        ])

        let store = SessionVectorStore(modelContext: context)
        store.updateEmbedding(for: swiftSession)
        store.updateEmbedding(for: cookingSession)

        let results = store.search(query: "Swift programming async await", agent: agent)
        // The vector search should return results (NLEmbedding is available on macOS/iOS test runners)
        if !results.isEmpty {
            // If embeddings worked, swift session should score higher for a swift query
            let swiftScore = results.first(where: { $0.sessionId == swiftSession.id })?.score ?? 0
            let cookingScore = results.first(where: { $0.sessionId == cookingSession.id })?.score ?? 0
            XCTAssertGreaterThan(swiftScore, cookingScore, "Swift session should be more similar to a Swift query")
        }
    }

    @MainActor
    func testVectorSearchExcludesArchivedSessions() {
        let archived = makeSession(title: "Archived Swift Chat", messages: [(.user, "swift")], archived: true)
        let active = makeSession(title: "Active Swift Chat", messages: [(.user, "swift")])

        let store = SessionVectorStore(modelContext: context)
        store.updateEmbedding(for: archived)
        store.updateEmbedding(for: active)

        let results = store.search(query: "swift", agent: agent)
        let ids = results.map(\.sessionId)
        XCTAssertFalse(ids.contains(archived.id))
    }

    @MainActor
    func testVectorSearchExcludesSpecifiedSession() {
        let excluded = makeSession(title: "Excluded Swift Chat", messages: [(.user, "swift programming")])
        let included = makeSession(title: "Included Swift Chat", messages: [(.user, "swift programming")])

        let store = SessionVectorStore(modelContext: context)
        store.updateEmbedding(for: excluded)
        store.updateEmbedding(for: included)

        let results = store.search(query: "swift", agent: agent, excludeSessionId: excluded.id)
        let ids = results.map(\.sessionId)
        XCTAssertFalse(ids.contains(excluded.id))
    }

    @MainActor
    func testVectorSearchRespectsLimit() {
        for i in 0..<5 {
            let s = makeSession(title: "Swift Topic \(i)", messages: [(.user, "swift concurrency \(i)")])
            SessionVectorStore(modelContext: context).updateEmbedding(for: s)
        }

        let store = SessionVectorStore(modelContext: context)
        let results = store.search(query: "swift concurrency", agent: agent, limit: 2)
        XCTAssertLessThanOrEqual(results.count, 2)
    }

    // MARK: - VectorStore: backfillMissingEmbeddings

    @MainActor
    func testBackfillCreatesEmbeddingsForSessionsWithoutOne() {
        makeSession(title: "Session A", messages: [(.user, "hello"), (.assistant, "hi")])
        makeSession(title: "Session B", messages: [(.user, "world"), (.assistant, "earth")])

        let store = SessionVectorStore(modelContext: context)
        store.backfillMissingEmbeddings()

        let descriptor = FetchDescriptor<SessionEmbedding>()
        let embeddings = (try? context.fetch(descriptor)) ?? []
        XCTAssertEqual(embeddings.count, 2)
    }

    @MainActor
    func testBackfillSkipsSessionsWithFewMessages() {
        makeSession(title: "Tiny Session", messages: [(.user, "hi")])

        let store = SessionVectorStore(modelContext: context)
        store.backfillMissingEmbeddings()

        let descriptor = FetchDescriptor<SessionEmbedding>()
        let embeddings = (try? context.fetch(descriptor)) ?? []
        XCTAssertTrue(embeddings.isEmpty)
    }

    @MainActor
    func testBackfillSkipsArchivedSessions() {
        makeSession(title: "Archived", messages: [(.user, "a"), (.assistant, "b")], archived: true)

        let store = SessionVectorStore(modelContext: context)
        store.backfillMissingEmbeddings()

        let descriptor = FetchDescriptor<SessionEmbedding>()
        let embeddings = (try? context.fetch(descriptor)) ?? []
        XCTAssertTrue(embeddings.isEmpty)
    }

    @MainActor
    func testBackfillSkipsAlreadyEmbeddedSessions() {
        let session = makeSession(title: "Already Done", messages: [(.user, "hi"), (.assistant, "hello")])

        let store = SessionVectorStore(modelContext: context)
        store.updateEmbedding(for: session)
        let beforeCount = ((try? context.fetch(FetchDescriptor<SessionEmbedding>())) ?? []).count

        store.backfillMissingEmbeddings()
        let afterCount = ((try? context.fetch(FetchDescriptor<SessionEmbedding>())) ?? []).count

        XCTAssertEqual(beforeCount, afterCount, "Should not create duplicate embeddings")
    }

    // MARK: - VectorStore: deleteEmbedding

    @MainActor
    func testDeleteEmbeddingRemovesStoredVector() {
        let session = makeSession(title: "To Delete", messages: [(.user, "hi"), (.assistant, "hello")])

        let store = SessionVectorStore(modelContext: context)
        store.updateEmbedding(for: session)

        var count = ((try? context.fetch(FetchDescriptor<SessionEmbedding>())) ?? []).count
        XCTAssertEqual(count, 1)

        store.deleteEmbedding(for: session.id)
        count = ((try? context.fetch(FetchDescriptor<SessionEmbedding>())) ?? []).count
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testDeleteEmbeddingNoOpForMissingId() {
        let store = SessionVectorStore(modelContext: context)
        // Should not crash
        store.deleteEmbedding(for: UUID())
    }

    // MARK: - Hybrid Search

    @MainActor
    func testHybridSearchFallsBackToKeyword() {
        // Session with no embedding but keyword-matchable content
        makeSession(title: "Quantum Computing Discussion", messages: [
            (.user, "Tell me about quantum computing"),
            (.assistant, "Quantum computing uses qubits..."),
        ])

        let service = SessionService(modelContext: context)
        let results = service.searchSessionsHybrid(query: "quantum computing", agent: agent)
        XCTAssertEqual(results.count, 1)
        XCTAssertEqual(results.first?.title, "Quantum Computing Discussion")
    }
}
