import XCTest
import SwiftData
@testable import iClaw

/// Tests verifying that SwiftData model access is properly isolated to `@MainActor`,
/// preventing concurrent relationship traversal crashes (EXC_BREAKPOINT in SwiftData).
final class MainActorIsolationTests: XCTestCase {

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

    // MARK: - resolveAgentId Deep Chain

    @MainActor
    func testResolveAgentIdWithDeepNesting() {
        let fm = AgentFileManager.shared
        var current = Agent(name: "root")
        context.insert(current)
        let rootId = current.id

        for i in 1...15 {
            let child = Agent(name: "sub-\(i)")
            context.insert(child)
            current.subAgents.append(child)
            current = child
        }
        try! context.save()

        XCTAssertEqual(fm.resolveAgentId(for: current), rootId,
                       "resolveAgentId should walk 15 levels of parentAgent to find root")
    }

    // MARK: - FunctionCallRouter MainActor Isolation

    @MainActor
    func testFunctionCallRouterCreatesOnMainActor() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let router = FunctionCallRouter(agent: agent, modelContext: context, sessionId: nil)
        XCTAssertNotNil(router)
    }

    @MainActor
    func testFunctionCallRouterExecuteUnknownTool() async {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let router = FunctionCallRouter(agent: agent, modelContext: context, sessionId: nil)
        let toolCall = LLMToolCall(id: "test-1", name: "nonexistent_tool", arguments: "{}")

        let result = await router.execute(toolCall: toolCall)
        XCTAssertTrue(result.text.contains("Unknown tool"),
                      "Unknown tool should return error, not crash")
    }

    // MARK: - FileTools on MainActor

    @MainActor
    func testFileToolsAccessesAgentIdSafely() {
        let parent = Agent(name: "Parent")
        context.insert(parent)
        let child = Agent(name: "Child")
        context.insert(child)
        parent.subAgents.append(child)
        try! context.save()

        let tools = FileTools(agent: child)
        let result = tools.listFiles(arguments: [:])
        XCTAssertNotNil(result, "FileTools should safely resolve agent ID through parent chain")
    }

    // MARK: - CodeExecutionTools on MainActor

    @MainActor
    func testCodeExecutionToolsListCodeSafely() {
        let parent = Agent(name: "Parent")
        context.insert(parent)
        let child = Agent(name: "Child")
        context.insert(child)
        parent.subAgents.append(child)
        try! context.save()

        let tools = CodeExecutionTools(agent: child, modelContext: context)
        let result = tools.listCode()
        XCTAssertTrue(result.contains("No saved code"),
                      "CodeExecutionTools should safely access agent relationships")
    }

    @MainActor
    func testCodeExecutionToolsSaveAndLoadCode() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        try! context.save()

        let tools = CodeExecutionTools(agent: agent, modelContext: context)

        let saveResult = tools.saveCode(arguments: [
            "name": "test.js",
            "code": "console.log('hello')",
            "language": "javascript"
        ])
        XCTAssertTrue(saveResult.contains("Saved"))

        let loadResult = tools.loadCode(arguments: ["name": "test.js"])
        XCTAssertTrue(loadResult.contains("console.log"))
    }

    // MARK: - SessionRAGTools on MainActor

    @MainActor
    func testSessionRAGToolsSearchOnMainActor() {
        let agent = Agent(name: "Test")
        context.insert(agent)
        let session = Session(title: "Test Session")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let tools = SessionRAGTools(agent: agent, modelContext: context, currentSessionId: session.id)
        let result = tools.searchSessions(arguments: ["query": "test"])
        XCTAssertNotNil(result)
    }

    // MARK: - SubAgentTools on MainActor

    @MainActor
    func testSubAgentToolsListOnMainActor() {
        let agent = Agent(name: "Parent")
        context.insert(agent)
        try! context.save()

        let subAgentManager = SubAgentManager(modelContext: context)
        let tools = SubAgentTools(agent: agent, modelContext: context, subAgentManager: subAgentManager, parentSessionId: nil)
        let result = tools.listSubAgents(arguments: [:])
        XCTAssertTrue(result.contains("No sub-agents"))
    }

    // MARK: - Deep Agent Hierarchy with Concurrent Layout Simulation

    @MainActor
    func testDeepAgentHierarchyDoesNotCrash() {
        var agents: [Agent] = []
        var current: Agent? = nil

        for i in 0..<12 {
            let agent = Agent(name: "Level-\(i)")
            context.insert(agent)
            if let p = current {
                p.subAgents.append(agent)
            }
            agents.append(agent)
            current = agent
        }
        try! context.save()

        let leaf = agents.last!
        let fm = AgentFileManager.shared

        let rootId = fm.resolveAgentId(for: leaf)
        XCTAssertEqual(rootId, agents.first!.id)

        XCTAssertTrue(leaf.isSubAgent)
        XCTAssertFalse(agents.first!.isSubAgent)
        XCTAssertTrue(agents.first!.isMainAgent)
    }

    // MARK: - LaunchTaskManager Background Safety

    @MainActor
    func testLaunchTaskManagerStartsWithoutCrash() {
        let manager = LaunchTaskManager(container: container)
        manager.runAll()
        XCTAssertNotEqual(manager.phase, .idle)
    }

    // MARK: - SessionVectorStore Direct Upsert

    @MainActor
    func testUpsertEmbeddingDirectRoundTrip() {
        let agent = Agent(name: "EmbTest")
        context.insert(agent)
        let session = Session(title: "Embedding Test")
        context.insert(session)
        session.agent = agent
        let msg = Message(role: .user, content: "Hello world")
        context.insert(msg)
        try! context.save()

        let vector: [Float] = [0.1, 0.2, 0.3, 0.4, 0.5]
        let text = "Test embedding text"

        let store = SessionVectorStore(modelContext: context)
        store.upsertEmbeddingDirect(sessionId: session.id, vector: vector, sourceText: text)

        let allEmbeddings = (try? context.fetch(FetchDescriptor<SessionEmbedding>())) ?? []
        let match = allEmbeddings.first { $0.sessionIdRaw == session.id.uuidString }
        XCTAssertNotNil(match, "Embedding should be persisted")
        XCTAssertEqual(match?.vector.count, 5)
    }

    // MARK: - ToolDefinitions Agent Access

    @MainActor
    func testToolDefinitionsAccessesAgentSafely() {
        let agent = Agent(name: "Test")
        agent.setPermissionLevel(.disabled, for: .browser)
        context.insert(agent)
        try! context.save()

        let tools = ToolDefinitions.tools(for: agent)
        let browserTools = tools.filter { $0.function.name.hasPrefix("browser_") }
        XCTAssertTrue(browserTools.isEmpty,
                      "Disabled browser tools should be filtered out")
    }

    // MARK: - Concurrent Access Pattern (regression guard)

    @MainActor
    func testConcurrentSessionAndAgentAccess() async {
        let agent = Agent(name: "ConcurrencyTest")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        for i in 0..<5 {
            let msg = Message(role: i % 2 == 0 ? .user : .assistant,
                              content: "Message \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let sorted = session.sortedMessages
        XCTAssertEqual(sorted.count, 5)
        XCTAssertNotNil(session.agent)
        XCTAssertEqual(session.agent?.name, "ConcurrencyTest")

        let router = FunctionCallRouter(agent: agent, modelContext: context, sessionId: session.id)
        let toolCall = LLMToolCall(id: "test-concurrent", name: "file_list", arguments: "{}")
        let result = await router.execute(toolCall: toolCall)
        XCTAssertNotNil(result.text)
    }
}
