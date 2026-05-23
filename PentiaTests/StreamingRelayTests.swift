import XCTest
import SwiftData
@testable import iClaw

private let testSchema = Schema([
    Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
    CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
    Message.self, SessionEmbedding.self
])

// MARK: - StreamingRelay Unit Tests

final class StreamingRelayUnitTests: XCTestCase {

    @MainActor
    func testSendUpdatesContentAndThinking() {
        let relay = ChatViewModel.StreamingRelay()
        relay.send(content: "Hello", thinking: "reasoning")
        XCTAssertEqual(relay.content, "Hello")
        XCTAssertEqual(relay.thinking, "reasoning")
    }

    @MainActor
    func testLatestContentWins() {
        let relay = ChatViewModel.StreamingRelay()
        relay.send(content: "He", thinking: "")
        relay.send(content: "Hello", thinking: "thought A")
        relay.send(content: "Hello world", thinking: "thought B")
        XCTAssertEqual(relay.content, "Hello world")
        XCTAssertEqual(relay.thinking, "thought B")
    }

    @MainActor
    func testNotifyMessagesChangedSetsFlag() {
        let relay = ChatViewModel.StreamingRelay()
        XCTAssertFalse(relay.messagesDidChange)
        relay.notifyMessagesChanged()
        XCTAssertTrue(relay.messagesDidChange)
        relay.messagesDidChange = false
        XCTAssertFalse(relay.messagesDidChange)
    }

    @MainActor
    func testFinishEndsSubscription() async {
        let relay = ChatViewModel.StreamingRelay()
        let subscription = relay.makeSubscription()

        relay.send(content: "final", thinking: "")
        relay.finish()

        var count = 0
        for await _ in subscription { count += 1 }
        XCTAssertGreaterThanOrEqual(count, 1,
            "Should receive at least the send before finish")
    }

    @MainActor
    func testSubscribeAfterFinishYieldsNothing() async {
        let relay = ChatViewModel.StreamingRelay()
        relay.finish()

        let subscription = relay.makeSubscription()
        var count = 0
        for await _ in subscription { count += 1 }
        XCTAssertEqual(count, 0)
    }

    @MainActor
    func testNewSubscriptionReplacesOldOne() async {
        let relay = ChatViewModel.StreamingRelay()
        let sub1 = relay.makeSubscription()
        _ = relay.makeSubscription()

        var sub1Count = 0
        for await _ in sub1 { sub1Count += 1 }
        XCTAssertEqual(sub1Count, 0,
            "Old subscription should end when a new one is created")
    }

    @MainActor
    func testSubscriptionDeliversMultipleSends() async {
        let relay = ChatViewModel.StreamingRelay()
        let subscription = relay.makeSubscription()

        relay.send(content: "a", thinking: "")
        relay.send(content: "ab", thinking: "")
        relay.send(content: "abc", thinking: "")
        relay.finish()

        var count = 0
        for await _ in subscription { count += 1 }
        XCTAssertGreaterThanOrEqual(count, 1,
            "Subscription should receive sends")
        XCTAssertEqual(relay.content, "abc",
            "Latest accumulated content should be 'abc'")
    }
}

// MARK: - StreamingRelay Monitoring Integration Tests

final class StreamingRelayMonitoringTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    @MainActor
    override func tearDown() {
        if let sessions = try? context.fetch(FetchDescriptor<Session>()) {
            for s in sessions {
                ChatViewModel._clearStreamingRelay(for: s.id)
                ChatViewModel._clearActiveGeneration(for: s.id)
            }
        }
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Helpers

    @MainActor
    private func makeActiveSession(title: String = "Test",
                                   pendingContent: String? = nil) -> Session {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: title)
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.pendingStreamingContent = pendingContent
        try! context.save()
        return session
    }

    // MARK: - Bug 1: Relay fast-path delivers real-time content

    @MainActor
    func testNewVMSubscribesToRelayForRealtimeContent() async throws {
        let session = makeActiveSession(pendingContent: "stale snapshot")
        ChatViewModel._simulateActiveGeneration(for: session.id)
        let relay = ChatViewModel._simulateStreamingRelay(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertTrue(vm.isLoading)

        // Allow monitoring task to start and subscribe.
        try await Task.sleep(for: .milliseconds(50))

        relay.send(content: "Hello world", thinking: "")
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.streamingContent, "Hello world",
            "Monitoring VM must receive real-time content via relay, not stale pendingStreamingContent")
    }

    @MainActor
    func testNewVMReceivesThinkingViaRelay() async throws {
        let session = makeActiveSession()
        ChatViewModel._simulateActiveGeneration(for: session.id)
        let relay = ChatViewModel._simulateStreamingRelay(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)
        try await Task.sleep(for: .milliseconds(50))

        relay.send(content: "answer", thinking: "let me think...")
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.streamingThinking, "let me think...",
            "Monitoring VM must receive thinking content via relay")
        XCTAssertEqual(vm.streamingContent, "answer")
    }

    @MainActor
    func testRelayContentUpdatesIncrementally() async throws {
        let session = makeActiveSession()
        ChatViewModel._simulateActiveGeneration(for: session.id)
        let relay = ChatViewModel._simulateStreamingRelay(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)
        try await Task.sleep(for: .milliseconds(50))

        relay.send(content: "He", thinking: "")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.streamingContent, "He")

        relay.send(content: "Hello", thinking: "")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.streamingContent, "Hello")

        relay.send(content: "Hello world", thinking: "")
        try await Task.sleep(for: .milliseconds(50))
        XCTAssertEqual(vm.streamingContent, "Hello world")
    }

    // MARK: - Relay finish → monitoring completes

    @MainActor
    func testRelayFinishCompletesMonitoring() async throws {
        let session = makeActiveSession()
        ChatViewModel._simulateActiveGeneration(for: session.id)
        let relay = ChatViewModel._simulateStreamingRelay(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)
        try await Task.sleep(for: .milliseconds(50))

        relay.send(content: "done", thinking: "")
        relay.finish()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(vm.isLoading,
            "isLoading must be false after relay finishes")
        XCTAssertEqual(vm.streamingContent, "",
            "streamingContent must be cleared after relay finishes (defer)")
    }

    // MARK: - Fallback to polling when no relay

    @MainActor
    func testFallsBackToPollingWithoutRelay() {
        let session = makeActiveSession(pendingContent: "polling content")
        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)

        XCTAssertTrue(vm.isLoading)
        XCTAssertEqual(vm.streamingContent, "polling content",
            "Without relay, VM should seed from pendingStreamingContent")
    }

    // MARK: - Bug 2 regression: monitoring resilient to isActive race

    @MainActor
    func testPollingContinuesWhenIsActiveFalseButGenerationExists() async throws {
        let session = makeActiveSession()
        ChatViewModel._simulateActiveGeneration(for: session.id)
        // Deliberately no relay → polling path.

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertTrue(vm.isLoading)

        // Simulate the old VM's defer block clearing isActive.
        try await Task.sleep(for: .milliseconds(50))
        session.isActive = false

        // Wait past one poll tick (1 second).
        try await Task.sleep(for: .seconds(1.2))

        XCTAssertTrue(vm.isLoading,
            "Monitoring must NOT exit when isActive is false but activeGenerations still has an entry")
    }

    // MARK: - Cleanup

    @MainActor
    func testCancelAndClearGenerationCleansUpRelay() {
        let session = makeActiveSession()
        ChatViewModel._simulateActiveGeneration(for: session.id)
        ChatViewModel._simulateStreamingRelay(for: session.id)

        XCTAssertTrue(ChatViewModel._hasStreamingRelay(for: session.id))
        XCTAssertTrue(ChatViewModel._hasActiveGeneration(for: session.id))

        ChatViewModel._clearActiveGeneration(for: session.id)

        XCTAssertFalse(ChatViewModel._hasStreamingRelay(for: session.id),
            "cancelAndClearGeneration must also clean up the streaming relay")
        XCTAssertFalse(ChatViewModel._hasActiveGeneration(for: session.id))
    }

    @MainActor
    func testRelayCreatedBySimulateIsAccessible() {
        let id = UUID()
        XCTAssertFalse(ChatViewModel._hasStreamingRelay(for: id))

        let relay = ChatViewModel._simulateStreamingRelay(for: id)
        XCTAssertTrue(ChatViewModel._hasStreamingRelay(for: id))

        relay.send(content: "test", thinking: "")
        XCTAssertEqual(relay.content, "test")

        ChatViewModel._clearStreamingRelay(for: id)
        XCTAssertFalse(ChatViewModel._hasStreamingRelay(for: id))
    }

    // MARK: - Bug 1 regression: existing test still passes with relay path

    @MainActor
    func testNewViewModelRecoversPendingContentViaRelay() {
        let session = makeActiveSession(pendingContent: "Hello, I am responding to your...")
        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)

        XCTAssertTrue(vm.isLoading,
            "ViewModel must show loading for orphaned active session")
        XCTAssertEqual(vm.streamingContent, "Hello, I am responding to your...",
            "ViewModel must recover pendingStreamingContent when no relay content yet")
    }

    // MARK: - Relay messages-changed triggers loadMessages in monitoring

    @MainActor
    func testRelayMessagesChangedTriggersLoadInMonitoring() async throws {
        let session = makeActiveSession()
        ChatViewModel._simulateActiveGeneration(for: session.id)
        let relay = ChatViewModel._simulateStreamingRelay(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)
        try await Task.sleep(for: .milliseconds(50))

        let msg = Message(role: .assistant, content: "tool result")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        relay.notifyMessagesChanged()
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(vm.messages.count, 1,
            "Monitoring VM must load new messages when relay signals messagesDidChange")
    }

    // MARK: - Relay initial seed prefers relay content over pendingStreamingContent

    @MainActor
    func testRelayInitialSeedPrefersRelayContent() async throws {
        let session = makeActiveSession(pendingContent: "stale from disk")
        ChatViewModel._simulateActiveGeneration(for: session.id)
        let relay = ChatViewModel._simulateStreamingRelay(for: session.id)
        relay.send(content: "fresh from relay", thinking: "")

        let vm = ChatViewModel(session: session, modelContext: context)
        try await Task.sleep(for: .milliseconds(50))

        XCTAssertEqual(vm.streamingContent, "fresh from relay",
            "When relay already has content, monitoring should prefer it over stale pendingStreamingContent")
    }
}
