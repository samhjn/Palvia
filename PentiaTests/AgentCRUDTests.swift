import XCTest
import SwiftData
@testable import iClaw

// MARK: - Agent Model Initialization Tests

final class AgentModelTests: XCTestCase {

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

    // MARK: - Basic Initialization

    @MainActor
    func testAgentDefaultInit() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        XCTAssertEqual(agent.name, "Test")
        XCTAssertNotNil(agent.id)
        XCTAssertEqual(agent.soulMarkdown, "")
        XCTAssertEqual(agent.memoryMarkdown, "")
        XCTAssertEqual(agent.userMarkdown, "")
        XCTAssertNil(agent.parentAgent)
        XCTAssertTrue(agent.subAgents.isEmpty)
        XCTAssertTrue(agent.sessions.isEmpty)
        XCTAssertTrue(agent.customConfigs.isEmpty)
        XCTAssertTrue(agent.codeSnippets.isEmpty)
        XCTAssertTrue(agent.cronJobs.isEmpty)
        XCTAssertTrue(agent.installedSkills.isEmpty)
        XCTAssertNil(agent.primaryProviderIdRaw)
        XCTAssertNil(agent.subAgentType)
        XCTAssertEqual(agent.compressionThreshold, 0)
        XCTAssertTrue(agent.isVerbose)
        XCTAssertNotNil(agent.createdAt)
        XCTAssertNotNil(agent.updatedAt)
    }

    @MainActor
    func testAgentInitWithCustomMarkdown() {
        let agent = Agent(
            name: "Custom",
            soulMarkdown: "# Custom Soul",
            memoryMarkdown: "# Custom Memory",
            userMarkdown: "# Custom User"
        )
        context.insert(agent)
        try! context.save()

        XCTAssertEqual(agent.soulMarkdown, "# Custom Soul")
        XCTAssertEqual(agent.memoryMarkdown, "# Custom Memory")
        XCTAssertEqual(agent.userMarkdown, "# Custom User")
    }

    @MainActor
    func testAgentUniqueIds() {
        let a1 = Agent(name: "A")
        let a2 = Agent(name: "B")
        context.insert(a1)
        context.insert(a2)
        try! context.save()

        XCTAssertNotEqual(a1.id, a2.id)
    }

    // MARK: - Primary Provider ID

    @MainActor
    func testPrimaryProviderIdRoundTrip() {
        let agent = Agent(name: "Test")
        context.insert(agent)

        XCTAssertNil(agent.primaryProviderId)

        let providerId = UUID()
        agent.primaryProviderId = providerId
        XCTAssertEqual(agent.primaryProviderId, providerId)
        XCTAssertEqual(agent.primaryProviderIdRaw, providerId.uuidString)

        agent.primaryProviderId = nil
        XCTAssertNil(agent.primaryProviderId)
        XCTAssertNil(agent.primaryProviderIdRaw)
    }

    // MARK: - SubAgent Provider ID

    @MainActor
    func testSubAgentProviderIdRoundTrip() {
        let agent = Agent(name: "Test")
        context.insert(agent)

        XCTAssertNil(agent.subAgentProviderId)

        let providerId = UUID()
        agent.subAgentProviderId = providerId
        XCTAssertEqual(agent.subAgentProviderId, providerId)

        agent.subAgentProviderId = nil
        XCTAssertNil(agent.subAgentProviderId)
    }

    // MARK: - Verbose Mode

    @MainActor
    func testVerboseModeToggle() {
        let agent = Agent(name: "Test")
        context.insert(agent)

        XCTAssertTrue(agent.isVerbose)

        agent.isVerbose = false
        try! context.save()
        XCTAssertFalse(agent.isVerbose)
    }

    // MARK: - Cascade Delete

    @MainActor
    func testDeleteAgentCascadesToSessions() {
        let agent = Agent(name: "Parent")
        context.insert(agent)
        let session = Session(title: "Test Session")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let sessionId = session.id
        context.delete(agent)
        try! context.save()

        let descriptor = FetchDescriptor<Session>(
            predicate: #Predicate { $0.id == sessionId }
        )
        let remaining = try! context.fetch(descriptor)
        XCTAssertTrue(remaining.isEmpty, "Sessions should be cascade deleted with agent")
    }

    @MainActor
    func testDeleteAgentCascadesToSubAgents() {
        let parent = Agent(name: "Parent")
        context.insert(parent)
        let child = Agent(name: "Child")
        context.insert(child)
        parent.subAgents.append(child)
        try! context.save()

        let childId = child.id
        context.delete(parent)
        try! context.save()

        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.id == childId }
        )
        let remaining = try! context.fetch(descriptor)
        XCTAssertTrue(remaining.isEmpty, "Sub-agents should be cascade deleted with parent")
    }

    @MainActor
    func testDeleteAgentCascadesToConfigs() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        let config = AgentConfig(key: "custom.md", content: "Hello")
        context.insert(config)
        agent.customConfigs.append(config)
        try! context.save()

        let configId = config.id
        context.delete(agent)
        try! context.save()

        let descriptor = FetchDescriptor<AgentConfig>(
            predicate: #Predicate { $0.id == configId }
        )
        let remaining = try! context.fetch(descriptor)
        XCTAssertTrue(remaining.isEmpty, "Configs should be cascade deleted with agent")
    }

    @MainActor
    func testDeleteAgentCascadesToCronJobs() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        let job = CronJob(name: "Job", cronExpression: "0 9 * * *", jobHint: "Do stuff")
        context.insert(job)
        agent.cronJobs.append(job)
        try! context.save()

        let jobId = job.id
        context.delete(agent)
        try! context.save()

        let descriptor = FetchDescriptor<CronJob>(
            predicate: #Predicate { $0.id == jobId }
        )
        let remaining = try! context.fetch(descriptor)
        XCTAssertTrue(remaining.isEmpty, "CronJobs should be cascade deleted with agent")
    }

    // MARK: - Parent-Child Relationship

    @MainActor
    func testParentChildRelationship() {
        let parent = Agent(name: "Parent")
        context.insert(parent)
        let child1 = Agent(name: "Child1")
        let child2 = Agent(name: "Child2")
        context.insert(child1)
        context.insert(child2)
        parent.subAgents.append(child1)
        parent.subAgents.append(child2)
        try! context.save()

        XCTAssertEqual(child1.parentAgent?.id, parent.id)
        XCTAssertEqual(child2.parentAgent?.id, parent.id)
        XCTAssertEqual(parent.subAgents.count, 2)
    }
}

// MARK: - AgentConfig Model Tests

final class AgentConfigModelTests: XCTestCase {

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

    @MainActor
    func testAgentConfigInit() {
        let config = AgentConfig(key: "custom.md", content: "Hello World")
        context.insert(config)
        try! context.save()

        XCTAssertNotNil(config.id)
        XCTAssertEqual(config.key, "custom.md")
        XCTAssertEqual(config.content, "Hello World")
        XCTAssertNil(config.agent)
        XCTAssertNotNil(config.createdAt)
        XCTAssertNotNil(config.updatedAt)
    }

    @MainActor
    func testAgentConfigWithAgent() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        let config = AgentConfig(key: "notes.md", content: "Some notes")
        context.insert(config)
        agent.customConfigs.append(config)
        try! context.save()

        XCTAssertEqual(config.agent?.id, agent.id)
        XCTAssertTrue(agent.customConfigs.contains(where: { $0.id == config.id }))
    }

    @MainActor
    func testMultipleConfigsPerAgent() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        let c1 = AgentConfig(key: "config1.md", content: "Content 1")
        let c2 = AgentConfig(key: "config2.md", content: "Content 2")
        let c3 = AgentConfig(key: "config3.md", content: "Content 3")
        context.insert(c1)
        context.insert(c2)
        context.insert(c3)
        agent.customConfigs.append(c1)
        agent.customConfigs.append(c2)
        agent.customConfigs.append(c3)
        try! context.save()

        XCTAssertEqual(agent.customConfigs.count, 3)
        let keys = Set(agent.customConfigs.map(\.key))
        XCTAssertEqual(keys, ["config1.md", "config2.md", "config3.md"])
    }
}

// MARK: - AgentService Tests

final class AgentServiceTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: AgentService!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        service = AgentService(modelContext: context)
    }

    override func tearDown() {
        container = nil
        context = nil
        service = nil
        super.tearDown()
    }

    // MARK: - createAgent

    @MainActor
    func testCreateAgentWithDefaults() {
        let agent = service.createAgent(name: "DefaultAgent")

        XCTAssertEqual(agent.name, "DefaultAgent")
        XCTAssertFalse(agent.soulMarkdown.isEmpty, "Should have default soul")
        XCTAssertNil(agent.parentAgent)
        XCTAssertTrue(agent.isMainAgent)

        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.name == "DefaultAgent" }
        )
        let fetched = try! context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
    }

    @MainActor
    func testCreateAgentWithCustomMarkdown() {
        let agent = service.createAgent(
            name: "Custom",
            soulMarkdown: "Custom soul",
            memoryMarkdown: "Custom memory",
            userMarkdown: "Custom user"
        )

        XCTAssertEqual(agent.soulMarkdown, "Custom soul")
        XCTAssertEqual(agent.memoryMarkdown, "Custom memory")
        XCTAssertEqual(agent.userMarkdown, "Custom user")
    }

    @MainActor
    func testCreateMultipleAgents() {
        let a1 = service.createAgent(name: "Agent1")
        let a2 = service.createAgent(name: "Agent2")
        let a3 = service.createAgent(name: "Agent3")

        XCTAssertNotEqual(a1.id, a2.id)
        XCTAssertNotEqual(a2.id, a3.id)

        let descriptor = FetchDescriptor<Agent>()
        let all = try! context.fetch(descriptor)
        XCTAssertEqual(all.count, 3)
    }

    // MARK: - createSubAgent

    @MainActor
    func testCreateSubAgentInheritsParentConfig() {
        let parent = service.createAgent(
            name: "Parent",
            soulMarkdown: "Parent soul",
            userMarkdown: "Parent user"
        )

        let sub = service.createSubAgent(name: "Sub", parentAgent: parent)

        XCTAssertEqual(sub.name, "Sub")
        XCTAssertEqual(sub.soulMarkdown, "Parent soul")
        XCTAssertEqual(sub.userMarkdown, "Parent user")
        XCTAssertEqual(sub.memoryMarkdown, "")
        XCTAssertEqual(sub.parentAgent?.id, parent.id)
        XCTAssertTrue(sub.isSubAgent)
    }

    @MainActor
    func testCreateSubAgentAppearsInParentSubAgents() {
        let parent = service.createAgent(name: "Parent")
        let sub1 = service.createSubAgent(name: "Sub1", parentAgent: parent)
        let sub2 = service.createSubAgent(name: "Sub2", parentAgent: parent)

        XCTAssertEqual(parent.subAgents.count, 2)
        let subIds = Set(parent.subAgents.map(\.id))
        XCTAssertTrue(subIds.contains(sub1.id))
        XCTAssertTrue(subIds.contains(sub2.id))
    }

    // MARK: - fetchAgent

    @MainActor
    func testFetchAgentByIdFound() {
        let agent = service.createAgent(name: "Findme")
        let fetched = service.fetchAgent(id: agent.id)

        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.id, agent.id)
        XCTAssertEqual(fetched?.name, "Findme")
    }

    @MainActor
    func testFetchAgentByIdNotFound() {
        let fetched = service.fetchAgent(id: UUID())
        XCTAssertNil(fetched)
    }

    // MARK: - readConfig

    @MainActor
    func testReadConfigBuiltInKeys() {
        let agent = service.createAgent(
            name: "Test",
            soulMarkdown: "Soul content",
            memoryMarkdown: "Memory content",
            userMarkdown: "User content"
        )

        XCTAssertEqual(service.readConfig(agent: agent, key: "SOUL.md"), "Soul content")
        XCTAssertEqual(service.readConfig(agent: agent, key: "soul.md"), "Soul content")
        XCTAssertEqual(service.readConfig(agent: agent, key: "soul"), "Soul content")

        XCTAssertEqual(service.readConfig(agent: agent, key: "MEMORY.md"), "Memory content")
        XCTAssertEqual(service.readConfig(agent: agent, key: "memory"), "Memory content")

        XCTAssertEqual(service.readConfig(agent: agent, key: "USER.md"), "User content")
        XCTAssertEqual(service.readConfig(agent: agent, key: "user"), "User content")
    }

    @MainActor
    func testReadConfigCustomKey() {
        let agent = service.createAgent(name: "Test")
        let config = AgentConfig(key: "notes.md", content: "Custom note")
        context.insert(config)
        agent.customConfigs.append(config)
        try! context.save()

        XCTAssertEqual(service.readConfig(agent: agent, key: "notes.md"), "Custom note")
    }

    @MainActor
    func testReadConfigNonExistentKey() {
        let agent = service.createAgent(name: "Test")
        XCTAssertNil(service.readConfig(agent: agent, key: "nonexistent.md"))
    }

    // MARK: - writeConfig

    @MainActor
    func testWriteConfigBuiltInSoul() {
        let agent = service.createAgent(name: "Test")
        service.writeConfig(agent: agent, key: "SOUL.md", content: "New soul")

        XCTAssertEqual(agent.soulMarkdown, "New soul")
    }

    @MainActor
    func testWriteConfigBuiltInMemory() {
        let agent = service.createAgent(name: "Test")
        service.writeConfig(agent: agent, key: "memory", content: "New memory")

        XCTAssertEqual(agent.memoryMarkdown, "New memory")
    }

    @MainActor
    func testWriteConfigBuiltInUser() {
        let agent = service.createAgent(name: "Test")
        service.writeConfig(agent: agent, key: "USER.md", content: "New user")

        XCTAssertEqual(agent.userMarkdown, "New user")
    }

    @MainActor
    func testWriteConfigCustomKeyCreatesNew() {
        let agent = service.createAgent(name: "Test")

        service.writeConfig(agent: agent, key: "custom.md", content: "Custom content")

        XCTAssertEqual(agent.customConfigs.count, 1)
        XCTAssertEqual(agent.customConfigs.first?.key, "custom.md")
        XCTAssertEqual(agent.customConfigs.first?.content, "Custom content")
    }

    @MainActor
    func testWriteConfigCustomKeyUpdatesExisting() {
        let agent = service.createAgent(name: "Test")

        service.writeConfig(agent: agent, key: "custom.md", content: "Version 1")
        XCTAssertEqual(agent.customConfigs.count, 1)

        service.writeConfig(agent: agent, key: "custom.md", content: "Version 2")
        XCTAssertEqual(agent.customConfigs.count, 1, "Should update, not duplicate")
        XCTAssertEqual(agent.customConfigs.first?.content, "Version 2")
    }

    @MainActor
    func testWriteConfigUpdatesTimestamp() {
        let agent = service.createAgent(name: "Test")
        let originalDate = agent.updatedAt

        Thread.sleep(forTimeInterval: 0.01)
        service.writeConfig(agent: agent, key: "SOUL.md", content: "Updated")

        XCTAssertGreaterThan(agent.updatedAt, originalDate)
    }

    // MARK: - listConfigs

    @MainActor
    func testListConfigsDefault() {
        let agent = service.createAgent(name: "Test")
        let configs = service.listConfigs(agent: agent)

        XCTAssertTrue(configs.contains("SOUL.md"))
        XCTAssertTrue(configs.contains("MEMORY.md"))
        XCTAssertTrue(configs.contains("USER.md"))
        XCTAssertEqual(configs.count, 3)
    }

    @MainActor
    func testListConfigsWithCustom() {
        let agent = service.createAgent(name: "Test")
        service.writeConfig(agent: agent, key: "notes.md", content: "Notes")
        service.writeConfig(agent: agent, key: "todo.md", content: "Tasks")

        let configs = service.listConfigs(agent: agent)
        XCTAssertTrue(configs.contains("SOUL.md"))
        XCTAssertTrue(configs.contains("MEMORY.md"))
        XCTAssertTrue(configs.contains("USER.md"))
        XCTAssertTrue(configs.contains("notes.md"))
        XCTAssertTrue(configs.contains("todo.md"))
        XCTAssertEqual(configs.count, 5)
    }
}

// MARK: - AgentViewModel Tests

final class AgentViewModelTests: XCTestCase {

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

    // MARK: - fetchAgents

    @MainActor
    func testFetchAgentsEmpty() {
        let vm = AgentViewModel(modelContext: context)
        XCTAssertTrue(vm.agents.isEmpty)
    }

    @MainActor
    func testFetchAgentsOnlyTopLevel() {
        let parent = Agent(name: "Parent")
        context.insert(parent)
        let child = Agent(name: "Child")
        child.subAgentType = "temp"
        context.insert(child)
        parent.subAgents.append(child)
        try! context.save()

        let vm = AgentViewModel(modelContext: context)
        XCTAssertEqual(vm.agents.count, 1)
        XCTAssertEqual(vm.agents.first?.name, "Parent")
    }

    @MainActor
    func testFetchAgentsSortedByUpdatedAt() {
        let a1 = Agent(name: "Old")
        a1.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(a1)

        let a2 = Agent(name: "New")
        a2.updatedAt = Date(timeIntervalSince1970: 2000)
        context.insert(a2)

        let a3 = Agent(name: "Middle")
        a3.updatedAt = Date(timeIntervalSince1970: 1500)
        context.insert(a3)

        try! context.save()

        let vm = AgentViewModel(modelContext: context)
        XCTAssertEqual(vm.agents.count, 3)
        XCTAssertEqual(vm.agents[0].name, "New")
        XCTAssertEqual(vm.agents[1].name, "Middle")
        XCTAssertEqual(vm.agents[2].name, "Old")
    }

    // MARK: - createAgent

    @MainActor
    func testViewModelCreateAgent() {
        let vm = AgentViewModel(modelContext: context)
        XCTAssertTrue(vm.agents.isEmpty)

        let agent = vm.createAgent(name: "New Agent")

        XCTAssertEqual(agent.name, "New Agent")
        XCTAssertFalse(agent.soulMarkdown.isEmpty, "Should have default soul")
        XCTAssertFalse(agent.memoryMarkdown.isEmpty, "Should have default memory")
        XCTAssertFalse(agent.userMarkdown.isEmpty, "Should have default user")
        XCTAssertEqual(vm.agents.count, 1)
        XCTAssertEqual(vm.agents.first?.id, agent.id)
    }

    @MainActor
    func testViewModelCreateMultipleAgents() {
        let vm = AgentViewModel(modelContext: context)

        _ = vm.createAgent(name: "Agent 1")
        _ = vm.createAgent(name: "Agent 2")
        _ = vm.createAgent(name: "Agent 3")

        XCTAssertEqual(vm.agents.count, 3)
    }

    @MainActor
    func testViewModelCreateAgentPersistsToDatabase() {
        let vm = AgentViewModel(modelContext: context)
        let agent = vm.createAgent(name: "Persisted")
        let agentId = agent.id

        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.id == agentId }
        )
        let fetched = try! context.fetch(descriptor)
        XCTAssertEqual(fetched.count, 1)
        XCTAssertEqual(fetched.first?.name, "Persisted")
    }

    // MARK: - deleteAgent

    @MainActor
    func testViewModelDeleteAgent() {
        let vm = AgentViewModel(modelContext: context)
        let agent = vm.createAgent(name: "ToDelete")
        XCTAssertEqual(vm.agents.count, 1)

        vm.deleteAgent(agent)

        XCTAssertTrue(vm.agents.isEmpty)

        let descriptor = FetchDescriptor<Agent>()
        let remaining = try! context.fetch(descriptor)
        XCTAssertTrue(remaining.isEmpty)
    }

    @MainActor
    func testViewModelDeleteAgentFromMultiple() {
        let vm = AgentViewModel(modelContext: context)
        let a1 = vm.createAgent(name: "Keep1")
        let a2 = vm.createAgent(name: "Delete")
        let a3 = vm.createAgent(name: "Keep2")
        XCTAssertEqual(vm.agents.count, 3)

        vm.deleteAgent(a2)

        XCTAssertEqual(vm.agents.count, 2)
        let names = Set(vm.agents.map(\.name))
        XCTAssertTrue(names.contains("Keep1"))
        XCTAssertTrue(names.contains("Keep2"))
        XCTAssertFalse(names.contains("Delete"))
        _ = a1; _ = a3
    }

    // MARK: - renameAgent

    @MainActor
    func testViewModelRenameAgent() {
        let vm = AgentViewModel(modelContext: context)
        let agent = vm.createAgent(name: "Original")

        vm.renameAgent(agent, to: "Renamed")

        XCTAssertEqual(agent.name, "Renamed")
    }

    @MainActor
    func testViewModelRenameTrimsWhitespace() {
        let vm = AgentViewModel(modelContext: context)
        let agent = vm.createAgent(name: "Original")

        vm.renameAgent(agent, to: "  Trimmed  \n")

        XCTAssertEqual(agent.name, "Trimmed")
    }

    @MainActor
    func testViewModelRenameRejectsEmpty() {
        let vm = AgentViewModel(modelContext: context)
        let agent = vm.createAgent(name: "Original")

        vm.renameAgent(agent, to: "")
        XCTAssertEqual(agent.name, "Original")

        vm.renameAgent(agent, to: "   ")
        XCTAssertEqual(agent.name, "Original")

        vm.renameAgent(agent, to: "\n\t")
        XCTAssertEqual(agent.name, "Original")
    }

    // MARK: - updateAgent

    @MainActor
    func testViewModelUpdateAgentTimestamp() {
        let vm = AgentViewModel(modelContext: context)
        let agent = vm.createAgent(name: "Test")
        let originalDate = agent.updatedAt

        Thread.sleep(forTimeInterval: 0.01)
        vm.updateAgent(agent)

        XCTAssertGreaterThan(agent.updatedAt, originalDate)
    }

    @MainActor
    func testViewModelUpdateAgentRefreshesList() {
        let vm = AgentViewModel(modelContext: context)
        let a1 = vm.createAgent(name: "First")
        let a2 = vm.createAgent(name: "Second")

        a1.updatedAt = Date(timeIntervalSince1970: 1000)
        a2.updatedAt = Date(timeIntervalSince1970: 2000)
        try! context.save()
        vm.fetchAgents()

        XCTAssertEqual(vm.agents.first?.name, "Second")

        Thread.sleep(forTimeInterval: 0.01)
        vm.updateAgent(a1)

        XCTAssertEqual(vm.agents.first?.name, "First",
                       "Updated agent should move to top of list")
    }

    // MARK: - agentToDelete

    @MainActor
    func testAgentToDeleteProperty() {
        let vm = AgentViewModel(modelContext: context)
        XCTAssertNil(vm.agentToDelete)

        let agent = vm.createAgent(name: "Test")
        vm.agentToDelete = agent
        XCTAssertNotNil(vm.agentToDelete)
        XCTAssertEqual(vm.agentToDelete?.id, agent.id)

        vm.agentToDelete = nil
        XCTAssertNil(vm.agentToDelete)
    }
}

// MARK: - AgentService Config Integration Tests

final class AgentConfigIntegrationTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var service: AgentService!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        service = AgentService(modelContext: context)
    }

    override func tearDown() {
        container = nil
        context = nil
        service = nil
        super.tearDown()
    }

    @MainActor
    func testWriteThenReadRoundTrip() {
        let agent = service.createAgent(name: "Test")

        service.writeConfig(agent: agent, key: "SOUL.md", content: "Updated soul")
        service.writeConfig(agent: agent, key: "notes.md", content: "Some notes")

        XCTAssertEqual(service.readConfig(agent: agent, key: "SOUL.md"), "Updated soul")
        XCTAssertEqual(service.readConfig(agent: agent, key: "notes.md"), "Some notes")
    }

    @MainActor
    func testMultipleCustomConfigsIndependent() {
        let agent = service.createAgent(name: "Test")

        service.writeConfig(agent: agent, key: "config_a", content: "Value A")
        service.writeConfig(agent: agent, key: "config_b", content: "Value B")
        service.writeConfig(agent: agent, key: "config_c", content: "Value C")

        XCTAssertEqual(service.readConfig(agent: agent, key: "config_a"), "Value A")
        XCTAssertEqual(service.readConfig(agent: agent, key: "config_b"), "Value B")
        XCTAssertEqual(service.readConfig(agent: agent, key: "config_c"), "Value C")

        service.writeConfig(agent: agent, key: "config_b", content: "Updated B")
        XCTAssertEqual(service.readConfig(agent: agent, key: "config_a"), "Value A")
        XCTAssertEqual(service.readConfig(agent: agent, key: "config_b"), "Updated B")
        XCTAssertEqual(service.readConfig(agent: agent, key: "config_c"), "Value C")
    }

    @MainActor
    func testConfigsIsolatedBetweenAgents() {
        let a1 = service.createAgent(name: "Agent1")
        let a2 = service.createAgent(name: "Agent2")

        service.writeConfig(agent: a1, key: "shared_key", content: "Agent1 value")
        service.writeConfig(agent: a2, key: "shared_key", content: "Agent2 value")

        XCTAssertEqual(service.readConfig(agent: a1, key: "shared_key"), "Agent1 value")
        XCTAssertEqual(service.readConfig(agent: a2, key: "shared_key"), "Agent2 value")
    }

    @MainActor
    func testWriteEmptyContentAllowed() {
        let agent = service.createAgent(name: "Test")

        service.writeConfig(agent: agent, key: "SOUL.md", content: "")
        XCTAssertEqual(service.readConfig(agent: agent, key: "SOUL.md"), "")

        service.writeConfig(agent: agent, key: "custom.md", content: "")
        XCTAssertEqual(service.readConfig(agent: agent, key: "custom.md"), "")
    }

    @MainActor
    func testWriteLargeContent() {
        let agent = service.createAgent(name: "Test")
        let largeContent = String(repeating: "A", count: 100_000)

        service.writeConfig(agent: agent, key: "big.md", content: largeContent)
        XCTAssertEqual(service.readConfig(agent: agent, key: "big.md"), largeContent)
    }

    @MainActor
    func testBuiltInKeyCaseInsensitive() {
        let agent = service.createAgent(name: "Test")

        service.writeConfig(agent: agent, key: "SOUL.MD", content: "Uppercase")
        XCTAssertEqual(agent.soulMarkdown, "Uppercase")

        service.writeConfig(agent: agent, key: "Soul", content: "Mixed")
        XCTAssertEqual(agent.soulMarkdown, "Mixed")

        XCTAssertEqual(service.readConfig(agent: agent, key: "SOUL"), "Mixed")
        XCTAssertEqual(service.readConfig(agent: agent, key: "soul.md"), "Mixed")
    }

    @MainActor
    func testFetchAgentAfterConfigChange() {
        let agent = service.createAgent(name: "Test")
        let agentId = agent.id

        service.writeConfig(agent: agent, key: "SOUL.md", content: "New soul")

        let fetched = service.fetchAgent(id: agentId)
        XCTAssertNotNil(fetched)
        XCTAssertEqual(fetched?.soulMarkdown, "New soul")
    }
}
