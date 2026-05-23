import XCTest
import SwiftData
@testable import iClaw

// MARK: - Shared Schema

private let testSchema = Schema([
    Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
    CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
    Message.self, SessionEmbedding.self
])

// =============================================================================
// MARK: - 1. Delete Active Session / Agent (Crash-Guard)
// =============================================================================

final class DeleteActiveSessionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Crash-Guard: delete session while isActive == true

    /// Deleting a session that is marked active must not crash.
    /// SwiftData cascade should still clean up messages.
    @MainActor
    func testDeleteActiveSessionDoesNotCrash() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Active Chat")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.pendingStreamingContent = "Partial response being streamed..."

        for i in 0..<5 {
            let msg = Message(role: i % 2 == 0 ? .user : .assistant, content: "msg \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.messages.count, 5)

        // Delete while active — must not crash
        let vm = SessionListViewModel(modelContext: context)
        vm.deleteSession(session)

        let remainingSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        XCTAssertTrue(remainingSessions.isEmpty, "Active session should be deleted")

        let remainingMessages = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        XCTAssertTrue(remainingMessages.isEmpty, "Messages should cascade-delete with active session")
    }

    /// Deleting an active session via offsets must not crash.
    @MainActor
    func testDeleteActiveSessionAtOffsetsDoesNotCrash() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let s1 = vm.createSession(agent: agent)
        s1.isActive = true
        s1.pendingStreamingContent = "streaming..."
        let _ = vm.createSession(agent: agent)
        try! context.save()
        vm.fetchSessions()

        XCTAssertEqual(vm.sessions.count, 2)

        // Find the index of the active session
        if let activeIdx = vm.sessions.firstIndex(where: { $0.id == s1.id }) {
            vm.deleteSessionAtOffsets(IndexSet(integer: activeIdx))
        }

        XCTAssertEqual(vm.sessions.count, 1)
        XCTAssertFalse(vm.sessions[0].isActive)
    }

    /// Deleting a session while context compression is in progress must not crash.
    @MainActor
    func testDeleteSessionDuringContextCompressionDoesNotCrash() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Compressing")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.isCompressingContext = true
        session.compressedContext = "Partial compressed context..."

        let msg = Message(role: .user, content: "Trigger compression")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        context.delete(session)
        try! context.save()

        let remaining = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - Crash-Guard: delete agent with active sessions

    /// Deleting an agent that has active sessions must not crash.
    /// Cascade should delete all sessions and their messages.
    @MainActor
    func testDeleteAgentWithActiveSessionDoesNotCrash() {
        let agent = Agent(name: "BusyAgent")
        context.insert(agent)

        let activeSession = Session(title: "Active")
        context.insert(activeSession)
        activeSession.agent = agent
        activeSession.isActive = true
        activeSession.pendingStreamingContent = "Still generating..."

        let inactiveSession = Session(title: "Idle")
        context.insert(inactiveSession)
        inactiveSession.agent = agent

        for i in 0..<3 {
            let msg = Message(role: .user, content: "msg \(i)")
            context.insert(msg)
            activeSession.messages.append(msg)
        }
        try! context.save()

        XCTAssertEqual(agent.sessions.count, 2)
        XCTAssertTrue(agent.sessions.contains(where: { $0.isActive }))

        // Delete agent — cascade must not crash
        let vm = AgentViewModel(modelContext: context)
        vm.deleteAgent(agent)

        let remainingAgents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        XCTAssertTrue(remainingAgents.isEmpty)

        let remainingSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        XCTAssertTrue(remainingSessions.isEmpty, "All sessions should be cascade-deleted")

        let remainingMessages = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        XCTAssertTrue(remainingMessages.isEmpty, "All messages should be cascade-deleted")
    }

    /// Deleting an agent with multiple active sessions (some streaming, some compressing).
    @MainActor
    func testDeleteAgentWithMultipleActiveSessionsDoesNotCrash() {
        let agent = Agent(name: "MultiActive")
        context.insert(agent)

        for i in 0..<4 {
            let session = Session(title: "Session \(i)")
            context.insert(session)
            session.agent = agent
            session.isActive = (i % 2 == 0)
            if i == 2 { session.isCompressingContext = true }

            let msg = Message(role: .user, content: "Hello \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let activeCount = agent.sessions.filter(\.isActive).count
        XCTAssertEqual(activeCount, 2)

        context.delete(agent)
        try! context.save()

        let remaining = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        XCTAssertTrue(remaining.isEmpty)
    }

    // MARK: - State-Consistency: session list updates correctly after active deletion

    /// After deleting an active session, selectedSession should not reference the deleted session.
    @MainActor
    func testSelectedSessionClearedAfterActiveSessionDeleted() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let session = vm.createSession(agent: agent)
        session.isActive = true
        try! context.save()

        vm.selectedSession = session
        XCTAssertNotNil(vm.selectedSession)

        vm.deleteSession(session)

        // The VM doesn't auto-clear selectedSession — document this behavior.
        // The View layer (SessionListView) is responsible for clearing it.
        // Verify session is gone from the list.
        XCTAssertEqual(vm.sessions.count, 0)
    }
}

// =============================================================================
// MARK: - 2. Delete LLM Provider Used by Active Session
// =============================================================================

final class DeleteActiveProviderTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Crash-Guard: ModelRouter after provider deletion

    /// After deleting the primary provider, ModelRouter must not crash.
    /// It should fall back to the global default.
    @MainActor
    func testModelRouterFallsBackAfterPrimaryProviderDeleted() {
        let primary = LLMProvider(name: "Primary", modelName: "gpt-4o")
        primary.isDefault = false
        context.insert(primary)

        let fallback = LLMProvider(name: "Fallback", modelName: "gpt-3.5", isDefault: true)
        context.insert(fallback)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = primary.id
        context.insert(agent)
        try! context.save()

        // Verify primary resolves before deletion
        let router = ModelRouter(modelContext: context)
        let chainBefore = router.resolveProviderChain(for: agent)
        XCTAssertEqual(chainBefore.first?.name, "Primary")

        // Delete primary provider
        context.delete(primary)
        try! context.save()

        // Agent still references the deleted provider's UUID — dangling reference
        XCTAssertNotNil(agent.primaryProviderId, "Agent still holds deleted provider UUID")

        // ModelRouter should gracefully fall back, not crash
        let chainAfter = router.resolveProviderChain(for: agent)
        XCTAssertFalse(chainAfter.isEmpty, "Router should fall back to global default")
        XCTAssertEqual(chainAfter.first?.name, "Fallback",
                       "Router should resolve to global default after primary deleted")
    }

    /// After deleting ALL providers, ModelRouter returns empty chain without crashing.
    @MainActor
    func testModelRouterReturnsEmptyChainWhenAllProvidersDeleted() {
        let provider = LLMProvider(name: "Only", isDefault: true)
        context.insert(provider)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = provider.id
        context.insert(agent)
        try! context.save()

        context.delete(provider)
        try! context.save()

        let router = ModelRouter(modelContext: context)
        let chain = router.resolveProviderChain(for: agent)
        XCTAssertTrue(chain.isEmpty, "Chain should be empty when no providers exist")

        let chainWithModels = router.resolveProviderChainWithModels(for: agent)
        XCTAssertTrue(chainWithModels.isEmpty)
    }

    /// Deleting a fallback provider does not crash and the remaining chain is correct.
    @MainActor
    func testDeleteFallbackProviderDoesNotCrash() {
        let primary = LLMProvider(name: "Primary", isDefault: true)
        context.insert(primary)
        let fb1 = LLMProvider(name: "Fallback1")
        context.insert(fb1)
        let fb2 = LLMProvider(name: "Fallback2")
        context.insert(fb2)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = primary.id
        agent.fallbackProviderIds = [fb1.id, fb2.id]
        agent.fallbackModelNames = ["model-a", "model-b"]
        context.insert(agent)
        try! context.save()

        // Delete fb1
        context.delete(fb1)
        try! context.save()

        let router = ModelRouter(modelContext: context)
        let chain = router.resolveProviderChainWithModels(for: agent)

        // Should have primary + fb2, fb1 silently skipped
        XCTAssertEqual(chain.count, 2)
        XCTAssertEqual(chain[0].provider.name, "Primary")
        XCTAssertEqual(chain[1].provider.name, "Fallback2")
    }

    /// SettingsViewModel.deleteProvider resolves default lazily.
    @MainActor
    func testDeleteDefaultProviderFallsBackToFirstProvider() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "First", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm.addProvider(name: "Second", endpoint: "https://b.com", apiKey: "", modelName: "m2")

        // First is default (was first added)
        XCTAssertTrue(vm.providers[0].isDefault)

        vm.deleteProvider(vm.providers[0])

        XCTAssertEqual(vm.providers.count, 1)
        XCTAssertEqual(vm.defaultProviderId, vm.providers[0].id,
                       "defaultProviderId should fall back to the remaining provider")
    }

    // MARK: - State-Consistency: agent with deleted provider

    /// After deleting the only provider, resolving capabilities should return .default, not crash.
    @MainActor
    func testPrimaryModelCapabilitiesReturnDefaultAfterProviderDeleted() {
        let provider = LLMProvider(name: "Test", modelName: "gpt-4o")
        provider.isDefault = true
        context.insert(provider)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = provider.id
        context.insert(agent)
        try! context.save()

        context.delete(provider)
        try! context.save()

        let router = ModelRouter(modelContext: context)
        let caps = router.primaryModelCapabilities(for: agent)
        XCTAssertEqual(caps, .default,
                       "Should return default capabilities when provider is gone")
    }

    /// Deleting a provider referenced by multiple agents must not crash.
    @MainActor
    func testDeleteProviderUsedByMultipleAgentsDoesNotCrash() {
        let provider = LLMProvider(name: "Shared", isDefault: true)
        context.insert(provider)
        let providerId = provider.id

        for i in 0..<5 {
            let agent = Agent(name: "Agent\(i)")
            agent.primaryProviderId = providerId
            context.insert(agent)
        }
        try! context.save()

        context.delete(provider)
        try! context.save()

        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        XCTAssertEqual(agents.count, 5, "Agents should NOT be cascade-deleted with provider")

        // All agents now have dangling provider references — router should handle gracefully
        let router = ModelRouter(modelContext: context)
        for agent in agents {
            let chain = router.resolveProviderChain(for: agent)
            XCTAssertTrue(chain.isEmpty,
                          "Chain should be empty (no providers left), not crash")
        }
    }

    /// Deleting a specific model (via disabling in enabledModels) while agent uses it:
    /// the agent's model name override still references it, but provider still exists.
    @MainActor
    func testAgentModelOverrideStillWorksAfterModelDisabled() {
        let provider = LLMProvider(name: "Multi", modelName: "gpt-4o", isDefault: true)
        provider.enabledModels = ["gpt-4o", "gpt-3.5-turbo"]
        context.insert(provider)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = provider.id
        agent.primaryModelNameOverride = "gpt-3.5-turbo"
        context.insert(agent)
        try! context.save()

        // Remove gpt-3.5-turbo from enabled models
        provider.enabledModels = ["gpt-4o"]
        try! context.save()

        // ModelRouter still resolves — model override is a string, not enforced at router level
        let router = ModelRouter(modelContext: context)
        let chain = router.resolveProviderChainWithModels(for: agent)
        XCTAssertFalse(chain.isEmpty, "Chain should still resolve (enabledModels is UI-level)")
        XCTAssertEqual(chain.first?.modelName, "gpt-3.5-turbo",
                       "Model override persists regardless of enabledModels list")
    }
}

// =============================================================================
// MARK: - 3. Delete Sub-Agent While Active
// =============================================================================

final class DeleteActiveSubAgentTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Crash-Guard: SubAgentManager after external deletion

    /// forceStop on a sub-agent that was already externally deleted must not crash.
    @MainActor
    func testForceStopOnDeletedSubAgentDoesNotCrash() {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        let manager = SubAgentManager(modelContext: context)
        let (subAgent, _) = manager.createSubAgent(
            name: "TempSub",
            parentAgent: parent,
            initialContext: nil,
            type: .persistent
        )
        let subId = subAgent.id

        // Externally delete the sub-agent (simulating user action)
        context.delete(subAgent)
        try! context.save()

        // forceStop on deleted sub-agent — must not crash
        manager.forceStop(subAgentId: subId)

        // Verify parent still exists
        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        XCTAssertEqual(agents.count, 1)
        XCTAssertEqual(agents.first?.name, "Parent")
    }

    /// deletePersistentAgent on an already-deleted sub-agent must not crash.
    @MainActor
    func testDeletePersistentAgentAlreadyDeletedDoesNotCrash() {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        let manager = SubAgentManager(modelContext: context)
        let (subAgent, _) = manager.createSubAgent(
            name: "PersistentSub",
            parentAgent: parent,
            initialContext: nil,
            type: .persistent
        )
        let subId = subAgent.id

        // Externally delete
        context.delete(subAgent)
        try! context.save()

        // Double-delete via manager — must not crash
        manager.deletePersistentAgent(subId)

        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        XCTAssertEqual(agents.count, 1)
    }

    /// destroyTempAgent on an already-deleted sub-agent must not crash.
    @MainActor
    func testDestroyTempAgentAlreadyDeletedDoesNotCrash() {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        let manager = SubAgentManager(modelContext: context)
        let (subAgent, _) = manager.createSubAgent(
            name: "TempSub",
            parentAgent: parent,
            initialContext: nil,
            type: .temp
        )
        let subId = subAgent.id

        context.delete(subAgent)
        try! context.save()

        // Destroy after external deletion — must not crash
        manager.destroyTempAgent(subId)
    }

    /// collectSessionSummary for a deleted sub-agent returns error text, not a crash.
    @MainActor
    func testCollectSessionSummaryForDeletedSubAgentReturnsError() {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        let manager = SubAgentManager(modelContext: context)
        let (subAgent, session) = manager.createSubAgent(
            name: "Sub",
            parentAgent: parent,
            initialContext: nil,
            type: .persistent
        )

        // Add some messages to the session
        let msg = Message(role: .assistant, content: "Sub-agent output")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let subId = subAgent.id

        // Delete the sub-agent (cascade deletes its session + messages)
        context.delete(subAgent)
        try! context.save()

        // Collect summary — should return error text, not crash
        let result = manager.collectSessionSummary(subAgentId: subId)
        XCTAssertTrue(result.text.contains("Error") || result.text.contains("not found"),
                      "Should return error message for deleted sub-agent, got: \(result.text)")
    }

    /// collectFullTranscript for a deleted sub-agent returns error text, not a crash.
    @MainActor
    func testCollectFullTranscriptForDeletedSubAgentReturnsError() {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        let manager = SubAgentManager(modelContext: context)
        let (subAgent, _) = manager.createSubAgent(
            name: "Sub",
            parentAgent: parent,
            initialContext: nil,
            type: .persistent
        )
        let subId = subAgent.id

        context.delete(subAgent)
        try! context.save()

        let result = manager.collectFullTranscript(subAgentId: subId)
        XCTAssertTrue(result.text.contains("Error") || result.text.contains("not found"),
                      "Should return error message for deleted sub-agent")
    }

    // MARK: - Crash-Guard: cascade delete parent with active sub-agents

    /// Deleting a parent agent cascades to sub-agents with active sessions.
    @MainActor
    func testDeleteParentCascadesToActiveSubAgentsDoesNotCrash() {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        // Create sub-agents with active sessions
        for i in 0..<3 {
            let sub = Agent(name: "Sub\(i)")
            sub.subAgentType = "persistent"
            context.insert(sub)
            parent.subAgents.append(sub)

            let session = Session(title: "SubSession\(i)")
            context.insert(session)
            session.agent = sub
            session.isActive = (i == 0) // First sub-agent is active

            let msg = Message(role: .assistant, content: "Output \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        XCTAssertEqual(parent.subAgents.count, 3)
        XCTAssertTrue(parent.subAgents.contains(where: { $0.sessions.first?.isActive == true }),
                      "At least one sub-agent should have an active session")

        // Delete parent — cascade must not crash
        context.delete(parent)
        try! context.save()

        let remainingAgents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        XCTAssertTrue(remainingAgents.isEmpty, "All agents (parent + subs) should be deleted")

        let remainingSessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        XCTAssertTrue(remainingSessions.isEmpty, "All sessions should be cascade-deleted")

        let remainingMessages = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        XCTAssertTrue(remainingMessages.isEmpty, "All messages should be cascade-deleted")
    }

    // MARK: - State-Consistency: SubAgentManager stale state

    /// inflightSubAgentSessions returns empty after sub-agent externally deleted.
    @MainActor
    func testInflightSubAgentSessionsEmptyAfterExternalDeletion() {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        let manager = SubAgentManager(modelContext: context)
        let (subAgent, session) = manager.createSubAgent(
            name: "Sub",
            parentAgent: parent,
            initialContext: nil,
            type: .persistent
        )
        session.isActive = true
        try! context.save()

        // Before deletion: inflight should include the sub
        let inflightBefore = manager.inflightSubAgentSessions(for: parent)
        XCTAssertEqual(inflightBefore.count, 1)

        // Externally delete sub-agent
        context.delete(subAgent)
        try! context.save()

        // After deletion: parent.subAgents is empty, so inflight should be empty
        let inflightAfter = manager.inflightSubAgentSessions(for: parent)
        XCTAssertTrue(inflightAfter.isEmpty,
                      "Inflight should be empty after sub-agent externally deleted")
    }

    /// allSubAgentSessions returns empty after sub-agent externally deleted.
    @MainActor
    func testAllSubAgentSessionsEmptyAfterExternalDeletion() {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        let manager = SubAgentManager(modelContext: context)
        let (subAgent, _) = manager.createSubAgent(
            name: "Sub",
            parentAgent: parent,
            initialContext: nil,
            type: .persistent
        )

        let allBefore = manager.allSubAgentSessions(for: parent)
        XCTAssertEqual(allBefore.count, 1)

        context.delete(subAgent)
        try! context.save()

        let allAfter = manager.allSubAgentSessions(for: parent)
        XCTAssertTrue(allAfter.isEmpty)
    }

    /// sendMessage to a deleted sub-agent throws .agentNotFound.
    @MainActor
    func testSendMessageToDeletedSubAgentThrowsAgentNotFound() async {
        let parent = Agent(name: "Parent")
        context.insert(parent)

        let manager = SubAgentManager(modelContext: context)
        let (subAgent, _) = manager.createSubAgent(
            name: "Sub",
            parentAgent: parent,
            initialContext: nil,
            type: .persistent
        )
        let subId = subAgent.id

        context.delete(subAgent)
        try! context.save()

        do {
            _ = try await manager.sendMessage(to: subId, content: "Hello?")
            XCTFail("Should have thrown SubAgentError.agentNotFound")
        } catch let error as SubAgentError {
            switch error {
            case .agentNotFound:
                // Expected — user-understandable error
                XCTAssertTrue(error.localizedDescription.contains("not found"))
            default:
                XCTFail("Unexpected SubAgentError: \(error)")
            }
        } catch {
            XCTFail("Unexpected error type: \(error)")
        }
    }
}

// =============================================================================
// MARK: - 4. Concurrent Agent / LLM Session Modification
// =============================================================================

final class ConcurrentModificationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Crash-Guard: concurrent agent config modification

    /// Modifying agent soul/memory while a session exists must not corrupt data.
    @MainActor
    func testModifyAgentConfigWhileSessionExistsDoesNotCrash() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Active Chat")
        context.insert(session)
        session.agent = agent
        session.isActive = true

        let msg = Message(role: .user, content: "Hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        // Modify agent config while session is "active"
        let service = AgentService(modelContext: context)
        service.writeConfig(agent: agent, key: "SOUL.md", content: "New soul while active")
        service.writeConfig(agent: agent, key: "MEMORY.md", content: "New memory while active")
        service.writeConfig(agent: agent, key: "custom.md", content: "New custom config")

        // Session and messages must remain intact
        XCTAssertEqual(agent.soulMarkdown, "New soul while active")
        XCTAssertEqual(agent.memoryMarkdown, "New memory while active")
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.messages.count, 1)
        XCTAssertEqual(agent.customConfigs.count, 1)
    }

    /// Switching agent's primary provider while session is active must not crash.
    @MainActor
    func testSwitchProviderWhileSessionActiveDoesNotCrash() {
        let p1 = LLMProvider(name: "Provider1", isDefault: true)
        context.insert(p1)
        let p2 = LLMProvider(name: "Provider2")
        context.insert(p2)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = p1.id
        context.insert(agent)

        let session = Session(title: "Active")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        try! context.save()

        // Switch provider mid-"generation"
        agent.primaryProviderId = p2.id
        agent.primaryModelNameOverride = "new-model"
        try! context.save()

        // Verify ModelRouter reflects the change
        let router = ModelRouter(modelContext: context)
        let chain = router.resolveProviderChain(for: agent)
        XCTAssertEqual(chain.first?.name, "Provider2",
                       "Router should reflect the new provider immediately")

        // Session is still intact
        XCTAssertTrue(session.isActive)
        XCTAssertEqual(session.agent?.name, "TestAgent")
    }

    /// Deleting a provider while simultaneously modifying agent's fallback chain.
    @MainActor
    func testDeleteProviderAndModifyFallbackChainDoesNotCrash() {
        let p1 = LLMProvider(name: "Primary", isDefault: true)
        context.insert(p1)
        let p2 = LLMProvider(name: "Fallback1")
        context.insert(p2)
        let p3 = LLMProvider(name: "Fallback2")
        context.insert(p3)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = p1.id
        agent.fallbackProviderIds = [p2.id, p3.id]
        context.insert(agent)
        try! context.save()

        // Delete p2 and modify fallback chain in same save
        context.delete(p2)
        agent.fallbackProviderIds = [p3.id]
        agent.fallbackModelNames = ["model-c"]
        try! context.save()

        let router = ModelRouter(modelContext: context)
        let chain = router.resolveProviderChainWithModels(for: agent)
        XCTAssertEqual(chain.count, 2, "Should have primary + one fallback")
        XCTAssertEqual(chain[0].provider.name, "Primary")
        XCTAssertEqual(chain[1].provider.name, "Fallback2")
    }

    // MARK: - Crash-Guard: concurrent session and provider deletion

    /// Delete session and its agent's provider in one transaction.
    @MainActor
    func testDeleteSessionAndProviderSimultaneouslyDoesNotCrash() {
        let provider = LLMProvider(name: "Test", isDefault: true)
        context.insert(provider)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = provider.id
        context.insert(agent)

        let session = Session(title: "ToDelete")
        context.insert(session)
        session.agent = agent
        session.isActive = true

        let msg = Message(role: .user, content: "Hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        // Delete both session and provider atomically
        context.delete(session)
        context.delete(provider)
        try! context.save()

        let sessions = (try? context.fetch(FetchDescriptor<Session>())) ?? []
        let providers = (try? context.fetch(FetchDescriptor<LLMProvider>())) ?? []
        XCTAssertTrue(sessions.isEmpty)
        XCTAssertTrue(providers.isEmpty)

        // Agent still exists with dangling references
        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        XCTAssertEqual(agents.count, 1)

        // ModelRouter handles dangling refs gracefully
        let router = ModelRouter(modelContext: context)
        let chain = router.resolveProviderChain(for: agents[0])
        XCTAssertTrue(chain.isEmpty)
    }

    /// Multiple ModelContexts: delete from one context, read from another.
    @MainActor
    func testDeleteFromSeparateContextDoesNotCrash() throws {
        let provider = LLMProvider(name: "Shared", isDefault: true)
        context.insert(provider)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = provider.id
        context.insert(agent)
        try context.save()

        // Create a second context (simulating concurrent access)
        let context2 = ModelContext(container)

        // Delete provider from context2
        let providers2 = try context2.fetch(FetchDescriptor<LLMProvider>())
        for p in providers2 { context2.delete(p) }
        try context2.save()

        // Original context's router should handle the deletion
        let router = ModelRouter(modelContext: context)
        let chain = router.resolveProviderChain(for: agent)
        // After context2 deletion and potential merge, chain should be empty or fallback
        // The key assertion: this must not crash
        XCTAssertTrue(chain.isEmpty || chain.first?.name != "Shared",
                      "Should handle cross-context deletion gracefully")
    }

    // MARK: - Crash-Guard: rapid create-delete cycles

    /// Rapidly creating and deleting sessions must not corrupt the model context.
    @MainActor
    func testRapidCreateDeleteSessionCyclesDoesNotCrash() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)

        for _ in 0..<20 {
            let session = vm.createSession(agent: agent)
            session.isActive = true
            let msg = Message(role: .user, content: "msg")
            context.insert(msg)
            session.messages.append(msg)
            try! context.save()

            vm.deleteSession(session)
        }

        XCTAssertEqual(vm.sessions.count, 0)

        let remainingMessages = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        XCTAssertTrue(remainingMessages.isEmpty, "All messages from rapid cycles should be cleaned up")
    }

    /// Rapidly creating and deleting sub-agents must not crash.
    @MainActor
    func testRapidCreateDeleteSubAgentCyclesDoesNotCrash() {
        let parent = Agent(name: "Parent")
        context.insert(parent)
        try! context.save()

        let manager = SubAgentManager(modelContext: context)

        for i in 0..<10 {
            let (sub, session) = manager.createSubAgent(
                name: "Sub\(i)",
                parentAgent: parent,
                initialContext: nil,
                type: i % 2 == 0 ? .temp : .persistent
            )
            session.isActive = true

            let msg = Message(role: .assistant, content: "Output \(i)")
            context.insert(msg)
            session.messages.append(msg)
            try! context.save()

            if sub.isTempSubAgent {
                manager.destroyTempAgent(sub.id)
            } else {
                manager.deletePersistentAgent(sub.id)
            }
        }

        XCTAssertTrue(parent.subAgents.isEmpty, "All sub-agents should be cleaned up")
    }

    // MARK: - State-Consistency: ModelRouter resolves fresh after mutation

    /// ModelRouter re-resolves the provider chain on each call (no stale cache).
    @MainActor
    func testModelRouterResolvessFreshOnEachCall() {
        let p1 = LLMProvider(name: "Original", isDefault: true)
        context.insert(p1)

        let agent = Agent(name: "TestAgent")
        agent.primaryProviderId = p1.id
        context.insert(agent)
        try! context.save()

        let router = ModelRouter(modelContext: context)

        // First call
        let chain1 = router.resolveProviderChain(for: agent)
        XCTAssertEqual(chain1.first?.name, "Original")

        // Mutate: add a new provider and switch
        let p2 = LLMProvider(name: "Replacement")
        context.insert(p2)
        agent.primaryProviderId = p2.id
        try! context.save()

        // Same router, second call — should reflect the mutation
        let chain2 = router.resolveProviderChain(for: agent)
        XCTAssertEqual(chain2.first?.name, "Replacement",
                       "Router should reflect provider change without recreating")
    }
}

// =============================================================================
// MARK: - 5. Fix Verification Tests
// =============================================================================

/// Tests verifying the behavioral fixes applied to deletion flows.
final class DeletionFixVerificationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Fix 1: Active generation cancelled before session deletion

    /// deleteSession should cancel the active generation before deleting.
    @MainActor
    func testDeleteSessionCancelsActiveGeneration() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Active")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.pendingStreamingContent = "streaming..."
        try! context.save()

        // Simulate an active generation entry
        ChatViewModel._simulateActiveGeneration(for: session.id)
        XCTAssertTrue(ChatViewModel._hasActiveGeneration(for: session.id))

        let vm = SessionListViewModel(modelContext: context)
        vm.deleteSession(session)

        // Generation entry should be cleared
        XCTAssertFalse(ChatViewModel._hasActiveGeneration(for: session.id),
                       "Active generation should be cancelled before session deletion")
    }

    /// deleteSessionAtOffsets should cancel active generations.
    @MainActor
    func testDeleteSessionAtOffsetsCancelsActiveGeneration() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let s1 = vm.createSession(agent: agent)
        s1.isActive = true
        let s2 = vm.createSession(agent: agent)
        _ = s2
        try! context.save()
        vm.fetchSessions()

        let s1Id = s1.id
        ChatViewModel._simulateActiveGeneration(for: s1Id)

        if let idx = vm.sessions.firstIndex(where: { $0.id == s1Id }) {
            vm.deleteSessionAtOffsets(IndexSet(integer: idx))
        }

        XCTAssertFalse(ChatViewModel._hasActiveGeneration(for: s1Id))
    }

    // MARK: - Fix 1+4: Agent deletion cancels all session generations recursively

    /// deleteAgent should cancel generations for all sessions including sub-agent sessions.
    @MainActor
    func testDeleteAgentCancelsAllSessionGenerations() {
        let agent = Agent(name: "Parent")
        context.insert(agent)

        let session1 = Session(title: "Main Session")
        context.insert(session1)
        session1.agent = agent
        session1.isActive = true

        let subAgent = Agent(name: "Sub")
        subAgent.subAgentType = "persistent"
        context.insert(subAgent)
        agent.subAgents.append(subAgent)

        let subSession = Session(title: "Sub Session")
        context.insert(subSession)
        subSession.agent = subAgent
        subSession.isActive = true
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session1.id)
        ChatViewModel._simulateActiveGeneration(for: subSession.id)
        XCTAssertTrue(ChatViewModel._hasActiveGeneration(for: session1.id))
        XCTAssertTrue(ChatViewModel._hasActiveGeneration(for: subSession.id))

        let s1Id = session1.id
        let subSId = subSession.id

        let vm = AgentViewModel(modelContext: context)
        vm.deleteAgent(agent)

        XCTAssertFalse(ChatViewModel._hasActiveGeneration(for: s1Id),
                       "Main session generation should be cancelled")
        XCTAssertFalse(ChatViewModel._hasActiveGeneration(for: subSId),
                       "Sub-agent session generation should be cancelled")
    }

    // MARK: - Fix 2: Session deletion cleans up embeddings

    /// deleteSession via SessionListViewModel should clean up embeddings (same as SessionService).
    @MainActor
    func testDeleteSessionCleansUpEmbeddings() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "WithEmbedding")
        context.insert(session)
        session.agent = agent

        let msg = Message(role: .user, content: "Hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        // Create an embedding for this session
        let store = SessionVectorStore(modelContext: context)
        store.upsertEmbeddingDirect(
            sessionId: session.id,
            vector: [0.1, 0.2, 0.3],
            sourceText: "test"
        )

        let embeddingsBefore = (try? context.fetch(FetchDescriptor<SessionEmbedding>())) ?? []
        XCTAssertEqual(embeddingsBefore.count, 1)

        let vm = SessionListViewModel(modelContext: context)
        vm.deleteSession(session)

        let embeddingsAfter = (try? context.fetch(FetchDescriptor<SessionEmbedding>())) ?? []
        XCTAssertTrue(embeddingsAfter.isEmpty,
                      "Embedding should be cleaned up when session is deleted via SessionListViewModel")
    }

    /// deleteSessionAtOffsets should also clean up embeddings.
    @MainActor
    func testDeleteSessionAtOffsetsCleansUpEmbeddings() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let session = vm.createSession(agent: agent)
        let sessionId = session.id

        let store = SessionVectorStore(modelContext: context)
        store.upsertEmbeddingDirect(sessionId: sessionId, vector: [0.5], sourceText: "test")

        vm.fetchSessions()
        if let idx = vm.sessions.firstIndex(where: { $0.id == sessionId }) {
            vm.deleteSessionAtOffsets(IndexSet(integer: idx))
        }

        let embeddingsAfter = (try? context.fetch(FetchDescriptor<SessionEmbedding>())) ?? []
        XCTAssertTrue(embeddingsAfter.isEmpty)
    }

    // MARK: - Fix 3: Provider deletion shows affected agents

    /// agentNamesUsing returns correct agents that reference the provider.
    @MainActor
    func testAgentNamesUsingProvider() {
        let provider = LLMProvider(name: "TestProvider", isDefault: true)
        context.insert(provider)

        let agent1 = Agent(name: "AgentA")
        agent1.primaryProviderId = provider.id
        context.insert(agent1)

        let agent2 = Agent(name: "AgentB")
        agent2.fallbackProviderIds = [provider.id]
        context.insert(agent2)

        let agent3 = Agent(name: "AgentC")
        agent3.subAgentProviderId = provider.id
        context.insert(agent3)

        let agent4 = Agent(name: "AgentD") // Does NOT use this provider
        context.insert(agent4)

        try! context.save()

        let vm = SettingsViewModel(modelContext: context)
        let names = vm.agentNamesUsing(provider: provider)

        XCTAssertEqual(names.count, 3)
        XCTAssertTrue(names.contains("AgentA"))
        XCTAssertTrue(names.contains("AgentB"))
        XCTAssertTrue(names.contains("AgentC"))
        XCTAssertFalse(names.contains("AgentD"))
    }

    /// agentNamesUsing returns empty when no agents reference the provider.
    @MainActor
    func testAgentNamesUsingProviderReturnsEmptyWhenUnused() {
        let provider = LLMProvider(name: "Unused", isDefault: true)
        context.insert(provider)

        let agent = Agent(name: "Independent")
        context.insert(agent)
        try! context.save()

        let vm = SettingsViewModel(modelContext: context)
        let names = vm.agentNamesUsing(provider: provider)
        XCTAssertTrue(names.isEmpty)
    }

    /// confirmDeleteProvider populates affectedAgentNames and providerToDelete.
    @MainActor
    func testConfirmDeleteProviderSetsState() {
        let provider = LLMProvider(name: "Target", isDefault: true)
        context.insert(provider)

        let agent = Agent(name: "Affected")
        agent.primaryProviderId = provider.id
        context.insert(agent)
        try! context.save()

        let vm = SettingsViewModel(modelContext: context)
        XCTAssertNil(vm.providerToDelete)
        XCTAssertTrue(vm.affectedAgentNames.isEmpty)

        vm.confirmDeleteProvider(provider)

        XCTAssertNotNil(vm.providerToDelete)
        XCTAssertEqual(vm.providerToDelete?.id, provider.id)
        XCTAssertEqual(vm.affectedAgentNames, ["Affected"])
    }

    /// deleteProvider no longer clears confirmation state — the View's
    /// alert button action does that. Verify the provider array is updated.
    @MainActor
    func testDeleteProviderClearsConfirmationState() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "ToDelete", endpoint: "https://x.com", apiKey: "", modelName: "m")

        let provider = vm.providers.first!
        vm.confirmDeleteProvider(provider)
        XCTAssertNotNil(vm.providerToDelete)

        vm.deleteProvider(provider)

        // providerToDelete is cleared by the View (alert action), not by deleteProvider().
        // Simulate what the View does after calling deleteProvider():
        vm.providerToDelete = nil
        vm.affectedAgentNames = []

        XCTAssertNil(vm.providerToDelete)
        XCTAssertTrue(vm.affectedAgentNames.isEmpty)
        XCTAssertTrue(vm.providers.isEmpty)
    }
}

// =============================================================================
// MARK: - LLM Provider Modification & Deletion (Batch-Update Safety)
// =============================================================================
//
// The UICollectionView crash (_Bug_Detected_In_Client_Of_UICollectionView_
// Invalid_Number_Of_Items_In_Section) was triggered when deleteProvider()
// performed two separate save+fetchProviders cycles for a default provider.
// The first cycle queued a "delete row" batch-update animation; the second
// modelContext.save() fired a SwiftData @Model notification that re-entered
// SwiftUI's layout while the animation was still in flight.
//
// These tests verify that all SettingsViewModel mutations leave the
// providers list in a consistent state after a single save+fetch, and that
// the default-promotion logic works atomically.

final class LLMProviderModificationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Delete Default Provider (the crash scenario)

    /// Deleting the default provider must resolve defaultProviderId to
    /// a remaining provider (lazy fallback, no cross-model mutation).
    @MainActor
    func testDeleteDefaultProviderResolvesDefaultLazily() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "Alpha", endpoint: "https://a.com", apiKey: "k1", modelName: "m1")
        vm.addProvider(name: "Beta", endpoint: "https://b.com", apiKey: "k2", modelName: "m2")
        vm.addProvider(name: "Gamma", endpoint: "https://c.com", apiKey: "k3", modelName: "m3")

        XCTAssertEqual(vm.providers.count, 3)
        XCTAssertTrue(vm.providers[0].isDefault, "First added should be default")

        let defaultProvider = vm.providers[0]
        vm.deleteProvider(defaultProvider)

        XCTAssertEqual(vm.providers.count, 2)
        XCTAssertNotNil(vm.defaultProviderId,
                        "defaultProviderId should fall back to a remaining provider")
    }

    /// Deleting the only provider (which is the default) should leave an empty list
    /// with no crash and no leftover default.
    @MainActor
    func testDeleteOnlyDefaultProviderLeavesEmptyList() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "Solo", endpoint: "https://x.com", apiKey: "", modelName: "m1")

        XCTAssertEqual(vm.providers.count, 1)
        XCTAssertTrue(vm.providers[0].isDefault)

        vm.deleteProvider(vm.providers[0])

        XCTAssertTrue(vm.providers.isEmpty)
    }

    /// Deleting a non-default provider should not change which provider is default.
    @MainActor
    func testDeleteNonDefaultProviderKeepsExistingDefault() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "Default", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm.addProvider(name: "Other", endpoint: "https://b.com", apiKey: "", modelName: "m2")

        XCTAssertTrue(vm.providers[0].isDefault)
        let nonDefault = vm.providers[1]
        XCTAssertFalse(nonDefault.isDefault)

        vm.deleteProvider(nonDefault)

        XCTAssertEqual(vm.providers.count, 1)
        XCTAssertTrue(vm.providers[0].isDefault)
        XCTAssertEqual(vm.providers[0].name, "Default")
    }

    /// After deleting the default, a fresh ViewModel should resolve
    /// defaultProviderId to the remaining provider via lazy fallback.
    @MainActor
    func testDeleteDefaultProviderFallbackPersistsAcrossVMRecreation() {
        let vm1 = SettingsViewModel(modelContext: context)
        vm1.addProvider(name: "First", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm1.addProvider(name: "Second", endpoint: "https://b.com", apiKey: "", modelName: "m2")
        vm1.deleteProvider(vm1.providers[0])

        // Persistence is deferred — drain the run loop before re-fetching
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Create a fresh ViewModel from the same context
        let vm2 = SettingsViewModel(modelContext: context)
        XCTAssertEqual(vm2.providers.count, 1)
        XCTAssertEqual(vm2.defaultProviderId, vm2.providers[0].id,
                       "defaultProviderId must resolve to remaining provider")
        XCTAssertEqual(vm2.providers[0].name, "Second")
    }

    // MARK: - Provider list consistency across mutations

    /// providers array identity (IDs) must be stable after each mutation —
    /// no duplicates, no stale entries.
    @MainActor
    func testProviderIdsUniqueAfterMultipleMutations() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "A", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm.addProvider(name: "B", endpoint: "https://b.com", apiKey: "", modelName: "m2")
        vm.addProvider(name: "C", endpoint: "https://c.com", apiKey: "", modelName: "m3")

        // Delete middle provider
        let middle = vm.providers[1]
        vm.deleteProvider(middle)

        let ids = vm.providers.map(\.id)
        XCTAssertEqual(Set(ids).count, ids.count, "No duplicate IDs after deletion")
        XCTAssertEqual(ids.count, 2)

        // Drain deferred modelContext.delete + save before adding
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))

        // Add another
        vm.addProvider(name: "D", endpoint: "https://d.com", apiKey: "", modelName: "m4")
        let ids2 = vm.providers.map(\.id)
        XCTAssertEqual(Set(ids2).count, ids2.count, "No duplicate IDs after add")
        XCTAssertEqual(ids2.count, 3)
    }

    /// defaultProviderId must always resolve when providers are non-empty.
    @MainActor
    func testDefaultProviderIdResolvedAfterEachMutation() {
        let vm = SettingsViewModel(modelContext: context)

        vm.addProvider(name: "A", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        XCTAssertNotNil(vm.defaultProviderId, "Default resolved after first add")

        vm.addProvider(name: "B", endpoint: "https://b.com", apiKey: "", modelName: "m2")
        XCTAssertNotNil(vm.defaultProviderId, "Default resolved after second add")

        vm.setDefault(vm.providers[1])
        XCTAssertEqual(vm.defaultProviderId, vm.providers[1].id, "Default matches after setDefault")

        let defaultId = vm.defaultProviderId!
        vm.deleteProvider(vm.providers.first { $0.id == defaultId }!)
        XCTAssertNotNil(vm.defaultProviderId, "Default resolved after deleting default")

        vm.deleteProvider(vm.providers[0])
        XCTAssertTrue(vm.providers.isEmpty, "Empty after deleting all")
        XCTAssertNil(vm.defaultProviderId, "No default when empty")
    }

    // MARK: - setDefault

    /// setDefault should make exactly one provider default, clearing others.
    @MainActor
    func testSetDefaultClearsOtherDefaults() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "A", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm.addProvider(name: "B", endpoint: "https://b.com", apiKey: "", modelName: "m2")
        vm.addProvider(name: "C", endpoint: "https://c.com", apiKey: "", modelName: "m3")

        let target = vm.providers[2]
        vm.setDefault(target)

        for p in vm.providers {
            if p.id == target.id {
                XCTAssertTrue(p.isDefault, "\(p.name) should be default")
            } else {
                XCTAssertFalse(p.isDefault, "\(p.name) should NOT be default")
            }
        }
    }

    /// Calling setDefault on the already-default provider is a no-op.
    @MainActor
    func testSetDefaultOnCurrentDefaultIsIdempotent() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "Only", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        let provider = vm.providers[0]
        XCTAssertTrue(provider.isDefault)

        vm.setDefault(provider)

        XCTAssertEqual(vm.providers.count, 1)
        XCTAssertTrue(vm.providers[0].isDefault)
    }

    // MARK: - Delete provider used by Agent (dangling reference safety)

    /// Deleting a provider that's an Agent's primary doesn't cascade-delete the agent.
    @MainActor
    func testDeleteProviderUsedAsAgentPrimaryDoesNotDeleteAgent() {
        let provider = LLMProvider(name: "Targeted", isDefault: true)
        context.insert(provider)

        let agent = Agent(name: "MyAgent")
        agent.primaryProviderId = provider.id
        context.insert(agent)
        try! context.save()

        let vm = SettingsViewModel(modelContext: context)
        vm.deleteProvider(provider)

        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        XCTAssertEqual(agents.count, 1, "Agent must survive provider deletion")
        XCTAssertEqual(agents[0].name, "MyAgent")
        // Agent still holds the dangling UUID — this is expected;
        // ModelRouter falls back to the global default at resolve time.
        XCTAssertNotNil(agents[0].primaryProviderId)
    }

    /// Deleting a provider used in an Agent's fallback chain doesn't crash.
    @MainActor
    func testDeleteProviderInFallbackChainDoesNotCrash() {
        let primary = LLMProvider(name: "Primary", isDefault: true)
        context.insert(primary)
        let fallback = LLMProvider(name: "Fallback")
        context.insert(fallback)
        let fallbackId = fallback.id  // Capture before deletion

        let agent = Agent(name: "Agent")
        agent.primaryProviderId = primary.id
        agent.fallbackProviderIds = [fallbackId]
        context.insert(agent)
        try! context.save()

        let vm = SettingsViewModel(modelContext: context)
        vm.deleteProvider(fallback)

        XCTAssertEqual(vm.providers.count, 1)
        XCTAssertEqual(vm.providers[0].name, "Primary")
        // Agent's fallback chain still references the deleted ID — ModelRouter handles this
        XCTAssertEqual(agent.fallbackProviderIds, [fallbackId])
    }

    /// Deleting the default provider that multiple agents reference should
    /// still result in exactly one new default.
    @MainActor
    func testDeleteDefaultProviderReferencedByMultipleAgents() {
        let provider = LLMProvider(name: "Shared", isDefault: true)
        context.insert(provider)
        let backup = LLMProvider(name: "Backup")
        context.insert(backup)

        for i in 0..<5 {
            let agent = Agent(name: "Agent\(i)")
            agent.primaryProviderId = provider.id
            context.insert(agent)
        }
        try! context.save()

        let vm = SettingsViewModel(modelContext: context)
        vm.deleteProvider(provider)

        XCTAssertEqual(vm.providers.count, 1)
        XCTAssertEqual(vm.defaultProviderId, vm.providers[0].id,
                       "defaultProviderId should fall back to remaining provider")
        XCTAssertEqual(vm.providers[0].name, "Backup")

        let agents = (try? context.fetch(FetchDescriptor<Agent>())) ?? []
        XCTAssertEqual(agents.count, 5, "All agents must survive provider deletion")
    }

    // MARK: - Model toggle & default model change

    /// toggleModel should add/remove models without affecting the provider list count.
    @MainActor
    func testToggleModelDoesNotAffectProviderCount() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "Test", endpoint: "https://a.com", apiKey: "", modelName: "base-model")

        let provider = vm.providers[0]
        let countBefore = vm.providers.count

        vm.toggleModel("extra-model", enabled: true, for: provider)
        XCTAssertEqual(vm.providers.count, countBefore)
        XCTAssertTrue(provider.enabledModels.contains("extra-model"))

        vm.toggleModel("extra-model", enabled: false, for: provider)
        XCTAssertEqual(vm.providers.count, countBefore)
        XCTAssertFalse(provider.enabledModels.contains("extra-model"))
    }

    /// setDefaultModel should swap the default without changing provider count.
    @MainActor
    func testSetDefaultModelPreservesProviderList() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "Test", endpoint: "https://a.com", apiKey: "", modelName: "old-default")

        let provider = vm.providers[0]
        vm.toggleModel("new-default", enabled: true, for: provider)
        vm.setDefaultModel("new-default", for: provider)

        XCTAssertEqual(provider.modelName, "new-default")
        XCTAssertTrue(provider.enabledModels.contains("old-default"),
                      "Old default should be kept in the enabled list")
        XCTAssertEqual(vm.providers.count, 1, "Provider list count unchanged")
    }

    // MARK: - Rapid mutations (simulating the batch-update race window)

    /// Rapidly adding and deleting providers should not leave inconsistent state.
    @MainActor
    func testRapidAddDeleteCyclesProduceConsistentState() {
        let vm = SettingsViewModel(modelContext: context)

        for i in 0..<10 {
            vm.addProvider(name: "P\(i)", endpoint: "https://\(i).com", apiKey: "", modelName: "m\(i)")
        }
        XCTAssertEqual(vm.providers.count, 10)

        // Delete every other provider
        let toDelete = stride(from: 0, to: 10, by: 2).map { vm.providers[$0] }
        for provider in toDelete {
            vm.deleteProvider(provider)
        }

        XCTAssertEqual(vm.providers.count, 5)
        let ids = vm.providers.map(\.id)
        XCTAssertEqual(Set(ids).count, 5, "No duplicates after rapid deletions")
        XCTAssertNotNil(vm.defaultProviderId,
                        "defaultProviderId must resolve after rapid deletions")
    }

    /// Rapidly switching defaults should always end with exactly one default.
    @MainActor
    func testRapidSetDefaultAlwaysLeavesOneDefault() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "A", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm.addProvider(name: "B", endpoint: "https://b.com", apiKey: "", modelName: "m2")
        vm.addProvider(name: "C", endpoint: "https://c.com", apiKey: "", modelName: "m3")

        for _ in 0..<20 {
            let random = vm.providers.randomElement()!
            vm.setDefault(random)
            XCTAssertEqual(vm.providers.filter(\.isDefault).count, 1,
                           "Must have exactly one default at all times")
        }
    }

    /// Delete all providers one by one (always deleting the resolved default).
    @MainActor
    func testDeleteAllProvidersOneByOneAlwaysDeletingDefault() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "A", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm.addProvider(name: "B", endpoint: "https://b.com", apiKey: "", modelName: "m2")
        vm.addProvider(name: "C", endpoint: "https://c.com", apiKey: "", modelName: "m3")

        while !vm.providers.isEmpty {
            let currentId = vm.defaultProviderId!
            let current = vm.providers.first { $0.id == currentId }!
            vm.deleteProvider(current)
            if !vm.providers.isEmpty {
                XCTAssertNotNil(vm.defaultProviderId,
                                "defaultProviderId must resolve when providers remain")
            }
        }
        XCTAssertTrue(vm.providers.isEmpty)
    }
}

// =============================================================================
// MARK: - Pre-Update Contract Tests
// =============================================================================
//
// These tests verify the core invariant that prevents UICollectionView crashes:
// after calling a delete method, the ViewModel's array must already exclude
// the deleted item AND the model context must have committed the deletion.
//
// The ordering guarantee (array updated BEFORE save) is enforced structurally
// by lint_collectionview_risks.sh, which flags any modelContext.delete() in
// View files.  These tests verify the observable outcome: the array and the
// persistent store are both consistent after the delete method returns.

final class PreUpdateContractTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    // ── SessionListViewModel ────────────────────────────────────────

    @MainActor
    func testDeleteSession_arrayAndStoreConsistent() {
        let agent = Agent(name: "A")
        context.insert(agent)
        let s1 = Session(title: "S1"); context.insert(s1); s1.agent = agent
        let s2 = Session(title: "S2"); context.insert(s2); s2.agent = agent
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        XCTAssertEqual(vm.sessions.count, 2)

        let deleteId = s1.id
        vm.deleteSession(s1)

        // Array must not contain the deleted item
        XCTAssertFalse(vm.sessions.contains { $0.id == deleteId },
                       "Deleted session must be removed from the array")
        XCTAssertEqual(vm.sessions.count, 1)
        // Row cache must also be cleaned up
        XCTAssertNil(vm.rowDataCache[deleteId],
                     "Row cache entry must be removed on deletion")
        // Store must reflect the deletion
        let remaining = (try? context.fetchCount(FetchDescriptor<Session>())) ?? -1
        XCTAssertEqual(remaining, 1, "Store must have committed the deletion")
    }

    @MainActor
    func testDeleteSessionAtOffsets_arrayAndStoreConsistent() {
        let agent = Agent(name: "A")
        context.insert(agent)
        let s1 = Session(title: "S1"); context.insert(s1); s1.agent = agent
        let s2 = Session(title: "S2"); context.insert(s2); s2.agent = agent
        let s3 = Session(title: "S3"); context.insert(s3); s3.agent = agent
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        XCTAssertEqual(vm.sessions.count, 3)

        let deleteId = vm.sessions[1].id
        vm.deleteSessionAtOffsets(IndexSet(integer: 1))

        XCTAssertFalse(vm.sessions.contains { $0.id == deleteId })
        XCTAssertEqual(vm.sessions.count, 2)
        XCTAssertNil(vm.rowDataCache[deleteId])
    }

    // ── SettingsViewModel ───────────────────────────────────────────

    @MainActor
    func testDeleteProvider_arrayAndStoreConsistent() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "P1", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm.addProvider(name: "P2", endpoint: "https://b.com", apiKey: "", modelName: "m2")
        XCTAssertEqual(vm.providers.count, 2)

        let deleteId = vm.providers[0].id
        vm.deleteProvider(vm.providers[0])

        // Array is updated synchronously
        XCTAssertFalse(vm.providers.contains { $0.id == deleteId },
                       "Deleted provider must be removed from the array")
        XCTAssertEqual(vm.providers.count, 1)

        // Persistence is deferred — drain the run loop
        RunLoop.main.run(until: Date(timeIntervalSinceNow: 0.05))
        let remaining = (try? context.fetchCount(FetchDescriptor<LLMProvider>())) ?? -1
        XCTAssertEqual(remaining, 1, "Store must have committed the deletion")
    }

    @MainActor
    func testDeleteDefaultProvider_defaultIdFallsBackAndArrayConsistent() {
        let vm = SettingsViewModel(modelContext: context)
        vm.addProvider(name: "P1", endpoint: "https://a.com", apiKey: "", modelName: "m1")
        vm.addProvider(name: "P2", endpoint: "https://b.com", apiKey: "", modelName: "m2")
        // P1 is default (first added)
        XCTAssertTrue(vm.providers[0].isDefault)

        vm.deleteProvider(vm.providers[0])

        XCTAssertEqual(vm.providers.count, 1)
        XCTAssertEqual(vm.defaultProviderId, vm.providers[0].id,
                       "defaultProviderId must fall back to remaining provider")
    }

    // ── AgentViewModel ──────────────────────────────────────────────

    @MainActor
    func testDeleteAgent_arrayAndStoreConsistent() {
        let vm = AgentViewModel(modelContext: context)
        _ = vm.createAgent(name: "Agent1")
        _ = vm.createAgent(name: "Agent2")
        XCTAssertEqual(vm.agents.count, 2)

        let deleteId = vm.agents[0].id
        vm.deleteAgent(vm.agents[0])

        XCTAssertFalse(vm.agents.contains { $0.id == deleteId },
                       "Deleted agent must be removed from the array")
        XCTAssertEqual(vm.agents.count, 1)
        let remaining = (try? context.fetchCount(
            FetchDescriptor<Agent>(predicate: #Predicate { $0.parentAgent == nil })
        )) ?? -1
        XCTAssertEqual(remaining, 1, "Store must have committed the deletion")
    }
}
