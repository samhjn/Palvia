import XCTest
import SwiftData
@testable import iClaw

// MARK: - Shared Test Schema

private let testSchema = Schema([
    Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
    CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
    Message.self, SessionEmbedding.self
])

// MARK: - Session Creation & Deletion Tests

final class SessionListOperationsTests: XCTestCase {

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

    // MARK: - Create Session

    @MainActor
    func testCreateSessionReturnsNewSession() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let session = vm.createSession(agent: agent)

        XCTAssertEqual(session.agent?.name, "TestAgent")
        XCTAssertFalse(session.title.isEmpty)
        XCTAssertFalse(session.isArchived)
        XCTAssertFalse(session.isActive)
        XCTAssertEqual(session.messages.count, 0)
    }

    @MainActor
    func testCreateSessionAppearsInList() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let countBefore = vm.sessions.count
        _ = vm.createSession(agent: agent)

        XCTAssertEqual(vm.sessions.count, countBefore + 1)
    }

    @MainActor
    func testCreateMultipleSessions() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let s1 = vm.createSession(agent: agent)
        let s2 = vm.createSession(agent: agent)

        XCTAssertNotEqual(s1.id, s2.id)
        XCTAssertEqual(vm.sessions.count, 2)
    }

    // MARK: - Delete Session

    @MainActor
    func testDeleteSessionRemovesFromList() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let session = vm.createSession(agent: agent)
        XCTAssertEqual(vm.sessions.count, 1)

        vm.deleteSession(session)
        XCTAssertEqual(vm.sessions.count, 0)
    }

    @MainActor
    func testDeleteSessionCascadesMessages() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "ToDelete")
        context.insert(session)
        session.agent = agent
        for i in 0..<5 {
            let msg = Message(role: .user, content: "msg \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        vm.deleteSession(session)

        let remaining = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        XCTAssertEqual(remaining.count, 0, "Messages should be cascade-deleted with their Session")
    }

    @MainActor
    func testDeleteSessionAtOffsets() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        _ = vm.createSession(agent: agent)
        _ = vm.createSession(agent: agent)
        _ = vm.createSession(agent: agent)
        XCTAssertEqual(vm.sessions.count, 3)

        vm.deleteSessionAtOffsets(IndexSet(integer: 1))
        XCTAssertEqual(vm.sessions.count, 2)
    }

    // MARK: - Archived Sessions Hidden

    @MainActor
    func testArchivedSessionsNotShownInList() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)

        let visible = Session(title: "Visible")
        context.insert(visible)
        visible.agent = agent

        let archived = Session(title: "Archived")
        archived.isArchived = true
        context.insert(archived)
        archived.agent = agent

        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        XCTAssertEqual(vm.sessions.count, 1)
        XCTAssertEqual(vm.sessions.first?.title, "Visible")
    }

    // MARK: - Sort Order

    @MainActor
    func testSessionsListSortedByUpdatedAtDescending() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)

        let old = Session(title: "Old")
        old.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(old)
        old.agent = agent

        let recent = Session(title: "Recent")
        recent.updatedAt = Date(timeIntervalSince1970: 2000)
        context.insert(recent)
        recent.agent = agent

        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        XCTAssertEqual(vm.sessions.first?.title, "Recent")
        XCTAssertEqual(vm.sessions.last?.title, "Old")
    }
}

// MARK: - Session Search / Filter Tests

final class SessionSearchTests: XCTestCase {

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

    @MainActor
    func testSearchByTitle() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)

        let s1 = Session(title: "Swift Programming")
        context.insert(s1)
        s1.agent = agent
        let s2 = Session(title: "Python Tutorial")
        context.insert(s2)
        s2.agent = agent
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        vm.searchText = "swift"
        vm.applySearch()

        XCTAssertEqual(vm.sessions.count, 1)
        XCTAssertEqual(vm.sessions.first?.title, "Swift Programming")
    }

    @MainActor
    func testSearchByMessageContent() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)

        let s1 = Session(title: "Chat A")
        context.insert(s1)
        s1.agent = agent
        let msg = Message(role: .assistant, content: "The answer is 42")
        context.insert(msg)
        s1.messages.append(msg)

        let s2 = Session(title: "Chat B")
        context.insert(s2)
        s2.agent = agent
        let msg2 = Message(role: .assistant, content: "Hello world")
        context.insert(msg2)
        s2.messages.append(msg2)

        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        vm.searchText = "42"
        vm.applySearch()

        XCTAssertEqual(vm.sessions.count, 1)
        XCTAssertEqual(vm.sessions.first?.title, "Chat A")
    }

    @MainActor
    func testSearchByAgentName() {
        let agentA = Agent(name: "CodeHelper")
        context.insert(agentA)
        let agentB = Agent(name: "Writer")
        context.insert(agentB)

        let s1 = Session(title: "Session 1")
        context.insert(s1)
        s1.agent = agentA
        let s2 = Session(title: "Session 2")
        context.insert(s2)
        s2.agent = agentB
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        vm.searchText = "codehelper"
        vm.applySearch()

        XCTAssertEqual(vm.sessions.count, 1)
        XCTAssertEqual(vm.sessions.first?.title, "Session 1")
    }

    @MainActor
    func testEmptySearchShowsAll() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        for i in 0..<3 {
            let s = Session(title: "Session \(i)")
            context.insert(s)
            s.agent = agent
        }
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        vm.searchText = "test"
        vm.applySearch()
        let filtered = vm.sessions.count

        vm.searchText = ""
        vm.applySearch()
        XCTAssertEqual(vm.sessions.count, 3)
        XCTAssertLessThanOrEqual(filtered, 3)
    }

    @MainActor
    func testWhitespaceOnlySearchShowsAll() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let s = Session(title: "Session")
        context.insert(s)
        s.agent = agent
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        vm.searchText = "   "
        vm.applySearch()

        XCTAssertEqual(vm.sessions.count, 1)
    }
}

// MARK: - Session Row Data Tests

final class SessionRowDataTests: XCTestCase {

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

    @MainActor
    func testRowDataReflectsMessageCount() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        for i in 0..<3 {
            let msg = Message(role: .user, content: "msg \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let rowData = vm.rowDataCache[session.id]

        XCTAssertNotNil(rowData)
        XCTAssertEqual(rowData?.messageCount, 3)
    }

    @MainActor
    func testRowDataShowsPreviewFromLastMessage() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let older = Message(role: .user, content: "older message")
        older.timestamp = Date(timeIntervalSince1970: 100)
        context.insert(older)
        session.messages.append(older)

        let newer = Message(role: .assistant, content: "latest reply")
        newer.timestamp = Date(timeIntervalSince1970: 200)
        context.insert(newer)
        session.messages.append(newer)

        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let rowData = vm.rowDataCache[session.id]

        XCTAssertNotNil(rowData?.previewContent)
        XCTAssertTrue(rowData!.previewContent!.contains("latest reply"))
    }

    @MainActor
    func testRowDataDetectsStreamingState() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        session.isActive = true
        session.pendingStreamingContent = "Generating..."
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let rowData = vm.rowDataCache[session.id]

        XCTAssertEqual(rowData?.isStreaming, true)
    }

    @MainActor
    func testRowDataDetectsDraft() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        session.draftText = "unfinished message..."
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let rowData = vm.rowDataCache[session.id]

        XCTAssertEqual(rowData?.hasDraft, true)
    }

    @MainActor
    func testRowDataNoDraftWhenEmpty() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        session.draftText = nil
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let rowData = vm.rowDataCache[session.id]

        XCTAssertEqual(rowData?.hasDraft, false)
    }

    @MainActor
    func testRowDataPreviewTruncatesLongContent() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let longContent = String(repeating: "a", count: 500)
        let msg = Message(role: .assistant, content: longContent)
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let vm = SessionListViewModel(modelContext: context)
        let preview = vm.rowDataCache[session.id]?.previewContent

        XCTAssertNotNil(preview)
        XCTAssertLessThanOrEqual(preview!.count, 200)
    }
}

// MARK: - Session Rename Tests

final class SessionRenameTests: XCTestCase {

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

    @MainActor
    func testRenameUpdatesTitle() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Original")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.setCustomTitle("Renamed")

        XCTAssertEqual(session.title, "Renamed")
    }

    @MainActor
    func testRenameSetsTitleCustomizedFlag() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Auto Title")
        context.insert(session)
        session.agent = agent
        try! context.save()

        XCTAssertFalse(session.isTitleCustomized)

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.setCustomTitle("User Title")

        XCTAssertTrue(session.isTitleCustomized)
    }

    @MainActor
    func testRenameUpdatesTimestamp() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        session.updatedAt = Date(timeIntervalSince1970: 1000)
        context.insert(session)
        session.agent = agent
        try! context.save()

        let before = session.updatedAt

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.setCustomTitle("New Name")

        XCTAssertGreaterThan(session.updatedAt, before)
    }

    @MainActor
    func testRenameDoesNotAffectMessages() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        let msg = Message(role: .user, content: "hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.setCustomTitle("New Name")

        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.content, "hello")
    }

    @MainActor
    func testRenamePerformanceWithManyMessages() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        for i in 0..<100 {
            let msg = Message(role: i % 2 == 0 ? .user : .assistant,
                              content: String(repeating: "x", count: 200))
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        let start = CFAbsoluteTimeGetCurrent()
        vm.setCustomTitle("Renamed")
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.05,
            "Rename should return near-instantly, took \(elapsed)s")
    }

    @MainActor
    func testRenameCachedStatsUnchanged() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        for i in 0..<10 {
            let msg = Message(role: .user, content: "msg \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        let before = vm.compressionStats

        vm.setCustomTitle("New")

        XCTAssertEqual(vm.compressionStats.totalMessages, before.totalMessages)
        XCTAssertEqual(vm.compressionStats.activeTokens, before.activeTokens)
    }
}

// MARK: - Session Export Tests

final class SessionExportTests: XCTestCase {

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

    @MainActor
    func testExportContainsTitle() {
        let session = Session(title: "My Chat")
        context.insert(session)
        try! context.save()

        let md = SessionExporter.exportToMarkdown(session)
        XCTAssertTrue(md.contains("My Chat"))
    }

    @MainActor
    func testExportContainsAgentName() {
        let agent = Agent(name: "CodeHelper")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let md = SessionExporter.exportToMarkdown(session)
        XCTAssertTrue(md.contains("CodeHelper"))
    }

    @MainActor
    func testExportContainsMessages() {
        let session = Session(title: "Test")
        context.insert(session)

        let userMsg = Message(role: .user, content: "What is Swift?")
        context.insert(userMsg)
        session.messages.append(userMsg)

        let assistantMsg = Message(role: .assistant, content: "Swift is a programming language.")
        context.insert(assistantMsg)
        session.messages.append(assistantMsg)

        try! context.save()

        let md = SessionExporter.exportToMarkdown(session)
        XCTAssertTrue(md.contains("What is Swift?"))
        XCTAssertTrue(md.contains("Swift is a programming language."))
    }

    @MainActor
    func testExportContainsYAMLFrontMatter() {
        let session = Session(title: "Test")
        context.insert(session)
        try! context.save()

        let md = SessionExporter.exportToMarkdown(session)
        XCTAssertTrue(md.hasPrefix("---\n"))
        XCTAssertTrue(md.contains("session_id: \(session.id.uuidString)"))
        XCTAssertTrue(md.contains("message_count:"))
    }

    @MainActor
    func testExportContainsCompressedContext() {
        let session = Session(title: "Test")
        session.compressedContext = "Summary of earlier conversation"
        session.compressedUpToIndex = 5
        context.insert(session)
        try! context.save()

        let md = SessionExporter.exportToMarkdown(session)
        XCTAssertTrue(md.contains("Summary of earlier conversation"))
        XCTAssertTrue(md.contains("compressed_messages: 5"))
    }

    @MainActor
    func testExportContainsThinkingContent() {
        let session = Session(title: "Test")
        context.insert(session)

        let msg = Message(role: .assistant, content: "Result")
        msg.thinkingContent = "Let me think step by step..."
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let md = SessionExporter.exportToMarkdown(session)
        XCTAssertTrue(md.contains("Let me think step by step..."))
    }

    @MainActor
    func testExportFileNameSanitized() {
        let session = Session(title: "Hello, World! @#$%")
        context.insert(session)
        try! context.save()

        let filename = SessionExporter.exportFileName(for: session)
        XCTAssertTrue(filename.hasPrefix("iClaw_"))
        XCTAssertTrue(filename.hasSuffix(".md"))
        XCTAssertFalse(filename.contains("@"))
        XCTAssertFalse(filename.contains("#"))
    }

    @MainActor
    func testExportToFileCreatesReadableFile() {
        let session = Session(title: "Export Test")
        context.insert(session)
        let msg = Message(role: .user, content: "Test content")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let url = SessionExporter.exportToFile(session)
        XCTAssertNotNil(url)

        if let url {
            let content = try? String(contentsOf: url, encoding: .utf8)
            XCTAssertNotNil(content)
            XCTAssertTrue(content!.contains("Export Test"))
            XCTAssertTrue(content!.contains("Test content"))
            try? FileManager.default.removeItem(at: url)
        }
    }

    @MainActor
    func testExportMessagesInChronologicalOrder() {
        let session = Session(title: "Test")
        context.insert(session)

        let first = Message(role: .user, content: "FIRST_MESSAGE")
        first.timestamp = Date(timeIntervalSince1970: 100)
        context.insert(first)
        session.messages.append(first)

        let second = Message(role: .assistant, content: "SECOND_MESSAGE")
        second.timestamp = Date(timeIntervalSince1970: 200)
        context.insert(second)
        session.messages.append(second)

        try! context.save()

        let md = SessionExporter.exportToMarkdown(session)
        let firstIdx = md.range(of: "FIRST_MESSAGE")!.lowerBound
        let secondIdx = md.range(of: "SECOND_MESSAGE")!.lowerBound
        XCTAssertTrue(firstIdx < secondIdx, "Messages should appear in chronological order")
    }

    @MainActor
    func testExportEmptySession() {
        let session = Session(title: "Empty")
        context.insert(session)
        try! context.save()

        let md = SessionExporter.exportToMarkdown(session)
        XCTAssertTrue(md.contains("Empty"))
        XCTAssertTrue(md.contains("message_count: 0"))
    }
}

// MARK: - ChatViewModel Lifecycle & Draft Tests

final class SessionLifecycleTests: XCTestCase {

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

    // MARK: - Scroll Position Persistence

    @MainActor
    func testSaveScrollPositionPersists() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let msg = Message(role: .user, content: "hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.saveScrollPosition(msg.id)

        XCTAssertEqual(session.lastViewedMessageId, msg.id)
    }

    @MainActor
    func testScrollPositionRestoredOnInit() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let msg = Message(role: .user, content: "hello")
        context.insert(msg)
        session.messages.append(msg)
        session.lastViewedMessageId = msg.id
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertEqual(vm.initialScrollTarget, msg.id)
    }

    @MainActor
    func testClearScrollPosition() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        session.lastViewedMessageId = UUID()
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.saveScrollPosition(nil)

        XCTAssertNil(session.lastViewedMessageId)
    }

    // MARK: - Draft Text Persistence

    @MainActor
    func testDraftTextPersistsToSession() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.inputText = "unfinished thought"

        XCTAssertEqual(session.draftText, "unfinished thought")
    }

    @MainActor
    func testEmptyDraftClearsSessionDraft() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        session.draftText = "old draft"
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.inputText = "   "

        XCTAssertNil(session.draftText)
    }

    @MainActor
    func testDraftTextRestoredOnInit() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        session.draftText = "saved draft"
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertEqual(vm.inputText, "saved draft")
    }

    // MARK: - View Lifecycle

    @MainActor
    func testOnViewAppearLoadsMessages() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        let msg = Message(role: .user, content: "hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.onViewAppear()

        XCTAssertEqual(vm.messages.count, 1)
    }

    @MainActor
    func testOnViewDisappearSavesDraft() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.inputText = "draft in progress"
        vm.onViewDisappear()

        XCTAssertEqual(session.draftText, "draft in progress")
    }

    // MARK: - Verbose / Silent Mode

    @MainActor
    func testVerboseModeDefaultsFromAgent() {
        let agent = Agent(name: "TestAgent")
        agent.isVerbose = false
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertFalse(vm.isVerbose)
    }

    @MainActor
    func testToggleVerboseUpdatesAgent() {
        let agent = Agent(name: "TestAgent")
        agent.isVerbose = true
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.isVerbose = false

        XCTAssertFalse(agent.isVerbose)
    }

    // MARK: - Active Session Lock

    @MainActor
    func testNoBlockWhenNoOtherActive() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.checkActiveSessionLock()

        XCTAssertNil(vm.sendBlockedReason)
        XCTAssertTrue(vm.canSend)
    }

    // MARK: - Dismiss Retry

    @MainActor
    func testDismissRetryClearsError() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.errorMessage = "Something went wrong"
        vm.canRetry = true

        vm.dismissRetry()

        XCTAssertNil(vm.errorMessage)
        XCTAssertFalse(vm.canRetry)
    }

    // MARK: - Cached Agent Properties

    @MainActor
    func testCachedAgentDisplayName() {
        let agent = Agent(name: "SmartAssistant")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertEqual(vm.agentDisplayName, "SmartAssistant")
    }

    @MainActor
    func testCachedImageInputDisabledDefault() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertFalse(vm.isImageInputDisabled)
    }

    @MainActor
    func testNoAgentMeansImageEnabled() {
        let session = Session(title: "Test")
        context.insert(session)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertFalse(vm.isImageInputDisabled)
        XCTAssertNil(vm.agentDisplayName)
    }
}

// MARK: - Session Model Computed Properties Tests

final class SessionModelTests: XCTestCase {

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

    @MainActor
    func testRelatedSessionIdsRoundTrip() {
        let session = Session(title: "Test")
        context.insert(session)

        let ids = [UUID(), UUID(), UUID()]
        session.relatedSessionIds = ids

        XCTAssertEqual(session.relatedSessionIds.count, 3)
        XCTAssertEqual(session.relatedSessionIds, ids)
    }

    @MainActor
    func testRelatedSessionIdsEmptyByDefault() {
        let session = Session(title: "Test")
        context.insert(session)

        XCTAssertTrue(session.relatedSessionIds.isEmpty)
    }

    @MainActor
    func testParentSessionIdRoundTrip() {
        let session = Session(title: "Test")
        context.insert(session)

        let parentId = UUID()
        session.parentSessionId = parentId

        XCTAssertEqual(session.parentSessionId, parentId)
    }

    @MainActor
    func testLastViewedMessageIdRoundTrip() {
        let session = Session(title: "Test")
        context.insert(session)

        let msgId = UUID()
        session.lastViewedMessageId = msgId

        XCTAssertEqual(session.lastViewedMessageId, msgId)
    }

    @MainActor
    func testLastViewedMessageIdNilByDefault() {
        let session = Session(title: "Test")
        context.insert(session)

        XCTAssertNil(session.lastViewedMessageId)
    }

    @MainActor
    func testInitialState() {
        let session = Session(title: "New Chat")
        context.insert(session)

        XCTAssertEqual(session.title, "New Chat")
        XCTAssertFalse(session.isArchived)
        XCTAssertFalse(session.isActive)
        XCTAssertFalse(session.isTitleCustomized)
        XCTAssertFalse(session.isCompressingContext)
        XCTAssertEqual(session.messages.count, 0)
        XCTAssertEqual(session.compressedUpToIndex, 0)
        XCTAssertNil(session.compressedContext)
        XCTAssertNil(session.draftText)
        XCTAssertNil(session.pendingStreamingContent)
    }

    @MainActor
    func testSortedMessagesEmpty() {
        let session = Session(title: "Test")
        context.insert(session)

        XCTAssertTrue(session.sortedMessages.isEmpty)
    }

    @MainActor
    func testSortedMessagesByTimestamp() {
        let session = Session(title: "Test")
        context.insert(session)

        let msg1 = Message(role: .user, content: "First")
        msg1.timestamp = Date(timeIntervalSince1970: 300)
        context.insert(msg1)
        session.messages.append(msg1)

        let msg2 = Message(role: .assistant, content: "Second")
        msg2.timestamp = Date(timeIntervalSince1970: 100)
        context.insert(msg2)
        session.messages.append(msg2)

        let msg3 = Message(role: .user, content: "Third")
        msg3.timestamp = Date(timeIntervalSince1970: 200)
        context.insert(msg3)
        session.messages.append(msg3)

        try! context.save()

        let sorted = session.sortedMessages
        XCTAssertEqual(sorted[0].content, "Second")
        XCTAssertEqual(sorted[1].content, "Third")
        XCTAssertEqual(sorted[2].content, "First")
    }
}

// MARK: - Message-Session Relationship Safety Tests

final class MessageSessionRelationshipTests: XCTestCase {

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

    /// Verify that creating a Message, inserting it, and appending to session
    /// correctly establishes the inverse relationship without crashing.
    @MainActor
    func testInsertThenAppendSetsInverseRelationship() {
        let session = Session(title: "Test")
        context.insert(session)
        try! context.save()

        let msg = Message(role: .user, content: "hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        XCTAssertEqual(msg.session?.id, session.id)
        XCTAssertEqual(session.messages.count, 1)
    }

    /// Ensure all message roles (user, assistant, tool) work with post-insert relationship binding.
    @MainActor
    func testAllRolesBindToSessionAfterInsert() {
        let session = Session(title: "Test")
        context.insert(session)

        let roles: [(MessageRole, String?, String?, String?)] = [
            (.user, "question", nil, nil),
            (.assistant, "answer", nil, nil),
            (.tool, "result", "call_123", "my_tool"),
            (.system, "system prompt", nil, nil),
        ]

        for (role, content, toolCallId, name) in roles {
            let msg = Message(role: role, content: content, toolCallId: toolCallId, name: name)
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        XCTAssertEqual(session.messages.count, 4)
        for msg in session.messages {
            XCTAssertEqual(msg.session?.id, session.id,
                           "Message with role \(msg.roleRaw) should have session set via inverse")
        }
    }

    /// Verify that multiple messages can be added to a session sequentially
    /// and all maintain correct relationships after save.
    @MainActor
    func testMultipleMessagesSequentialInsert() {
        let session = Session(title: "Chat")
        context.insert(session)
        try! context.save()

        for i in 0..<20 {
            let role: MessageRole = i % 2 == 0 ? .user : .assistant
            let msg = Message(role: role, content: "Message \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        XCTAssertEqual(session.messages.count, 20)
        for (i, msg) in session.sortedMessages.enumerated() {
            XCTAssertEqual(msg.session?.id, session.id, "Message \(i) should belong to session")
        }
    }

    /// Verify that a Message with toolCallsData correctly binds to session.
    @MainActor
    func testToolCallMessageBindsToSession() {
        let session = Session(title: "Tool Test")
        context.insert(session)

        let toolCalls = [LLMToolCall(id: "tc1", name: "test_fn", arguments: "{}")]
        let toolData = try! JSONEncoder().encode(toolCalls)

        let assistantMsg = Message(role: .assistant, content: "Calling tool", toolCallsData: toolData)
        context.insert(assistantMsg)
        session.messages.append(assistantMsg)

        let toolMsg = Message(role: .tool, content: "Tool result", toolCallId: "tc1", name: "test_fn")
        context.insert(toolMsg)
        session.messages.append(toolMsg)

        try! context.save()

        XCTAssertEqual(session.messages.count, 2)
        XCTAssertEqual(assistantMsg.session?.id, session.id)
        XCTAssertEqual(toolMsg.session?.id, session.id)
        XCTAssertNotNil(assistantMsg.toolCallsData)
    }

    /// Verify that two sessions don't cross-contaminate messages.
    @MainActor
    func testMessagesDoNotCrossSessionBoundaries() {
        let s1 = Session(title: "Session 1")
        let s2 = Session(title: "Session 2")
        context.insert(s1)
        context.insert(s2)

        let m1 = Message(role: .user, content: "msg for s1")
        context.insert(m1)
        s1.messages.append(m1)

        let m2 = Message(role: .user, content: "msg for s2")
        context.insert(m2)
        s2.messages.append(m2)

        try! context.save()

        XCTAssertEqual(s1.messages.count, 1)
        XCTAssertEqual(s2.messages.count, 1)
        XCTAssertEqual(m1.session?.id, s1.id)
        XCTAssertEqual(m2.session?.id, s2.id)
    }

    /// Verify cascade delete still works with post-insert relationship binding.
    @MainActor
    func testCascadeDeleteAfterPostInsertBinding() {
        let session = Session(title: "To Delete")
        context.insert(session)

        for i in 0..<5 {
            let msg = Message(role: .user, content: "msg \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        XCTAssertEqual(session.messages.count, 5)

        context.delete(session)
        try! context.save()

        let remaining = (try? context.fetch(FetchDescriptor<Message>())) ?? []
        XCTAssertEqual(remaining.count, 0, "Messages should be cascade-deleted with their Session")
    }
}

// MARK: - Retry Deduplication Tests

final class RetryDeduplicationTests: XCTestCase {

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
                ChatViewModel._clearActiveGeneration(for: s.id)
            }
        }
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - Guard: isLoading

    @MainActor
    func testRetryBlockedWhenAlreadyLoading() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.isLoading = true
        vm.canRetry = true
        vm.errorMessage = "some error"

        vm.retryGeneration()

        XCTAssertTrue(vm.canRetry, "canRetry must stay true — retryGeneration was a no-op")
        XCTAssertEqual(vm.errorMessage, "some error", "errorMessage must stay — retryGeneration was a no-op")
    }

    // MARK: - Guard: activeGenerations (cross-VM)

    @MainActor
    func testRetryBlockedByActiveGenerationStaticGuard() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.canRetry = true
        vm.errorMessage = "API error"

        vm.retryGeneration()

        XCTAssertTrue(vm.canRetry, "retryGeneration must be a no-op — generation already active")
        XCTAssertEqual(vm.errorMessage, "API error", "Error must stay — retryGeneration was blocked")
        XCTAssertFalse(vm.isLoading, "isLoading must stay false — retryGeneration was blocked")
    }

    @MainActor
    func testSendBlockedByActiveGenerationStaticGuard() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.inputText = "hello"

        vm.sendMessage()

        XCTAssertFalse(vm.isLoading, "isLoading must stay false — send was blocked")
        XCTAssertEqual(vm.inputText, "hello", "Input must stay — send was blocked")
    }

    @MainActor
    func testRetryPopulatesActiveGenerations() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        XCTAssertFalse(ChatViewModel._hasActiveGeneration(for: session.id))

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.retryGeneration()

        XCTAssertTrue(ChatViewModel._hasActiveGeneration(for: session.id),
                       "retryGeneration must register the task in activeGenerations")
    }

    // MARK: - Double-tap on same VM

    @MainActor
    func testDoubleRetryOnSameVMBlocked() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.retryGeneration()

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.canRetry)

        vm.canRetry = true
        vm.retryGeneration()

        XCTAssertTrue(vm.canRetry, "Guard short-circuits — canRetry stays true, no state mutation")
        XCTAssertTrue(vm.isLoading, "isLoading unchanged from first call")
    }

    // MARK: - Flags set correctly

    @MainActor
    func testRetrySetsFlagsCorrectly() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.canRetry = true
        vm.errorMessage = "API error"

        vm.retryGeneration()

        XCTAssertTrue(vm.isLoading)
        XCTAssertFalse(vm.canRetry)
        XCTAssertNil(vm.errorMessage)
    }

    // MARK: - Eager session.isActive

    @MainActor
    func testRetryEagerlySetsSessionActive() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        XCTAssertFalse(session.isActive)

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.retryGeneration()

        XCTAssertTrue(session.isActive, "session.isActive must be set eagerly before the Task runs")
    }

    @MainActor
    func testSendEagerlySetsSessionActive() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        XCTAssertFalse(session.isActive)

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.inputText = "hello"
        vm.sendMessage()

        XCTAssertTrue(session.isActive, "session.isActive must be set eagerly before the Task runs")
    }

    // MARK: - Recovery blocked for active session

    @MainActor
    func testRecoverRetryStateBlockedWhenSessionActive() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let msg = Message(role: .user, content: "hello")
        context.insert(msg)
        session.messages.append(msg)
        session.isActive = true
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        XCTAssertFalse(vm.canRetry, "canRetry must not be set when session is active")
    }

    // MARK: - Dismiss prevents recovery across VM recreation

    @MainActor
    func testDismissRetryPreventsRecoveryAcrossVMs() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let msg = Message(role: .user, content: "hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let vm1 = ChatViewModel(session: session, modelContext: context)
        vm1.canRetry = true
        vm1.dismissRetry()

        let vm2 = ChatViewModel(session: session, modelContext: context)

        XCTAssertFalse(vm2.canRetry, "canRetry must not recover after explicit dismiss")
    }
}

// MARK: - Session State Recovery Tests (cross-VM orphaned generation)

/// Tests that session running state is preserved when the user navigates away
/// (destroying the owning ChatViewModel) while a generation is still running.
/// The generation Task survives in the static `activeGenerations` dictionary.
final class SessionStateRecoveryTests: XCTestCase {

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
                ChatViewModel._clearActiveGeneration(for: s.id)
            }
        }
        container = nil
        context = nil
        super.tearDown()
    }

    // MARK: - recoverStaleActiveState skips reset when activeGenerations is live

    @MainActor
    func testStaleRecoverySkippedWhenActiveGenerationExists() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "Running")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        // Push updatedAt far back so it exceeds the 120s stale threshold.
        session.updatedAt = Date().addingTimeInterval(-300)
        try! context.save()

        // Simulate a generation started by a previous ViewModel instance.
        ChatViewModel._simulateActiveGeneration(for: session.id)

        // Create a fresh ViewModel (as if the user navigated back).
        let vm = ChatViewModel(session: session, modelContext: context)
        _ = vm // suppress unused warning

        XCTAssertTrue(session.isActive,
                      "isActive must NOT be reset when a live generation exists in activeGenerations")
    }

    @MainActor
    func testStaleRecoveryResetsWhenNoActiveGeneration() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "Stale")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.updatedAt = Date().addingTimeInterval(-300)
        try! context.save()

        // No activeGenerations entry — truly stale.
        let vm = ChatViewModel(session: session, modelContext: context)
        _ = vm

        XCTAssertFalse(session.isActive,
                       "isActive must be reset when no live generation and stale threshold exceeded")
    }

    // MARK: - onViewAppear preserves loading state for orphaned generation

    @MainActor
    func testViewAppearKeepsLoadingWhenActiveGenerationExists() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "Running")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.pendingStreamingContent = "partial response..."
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.onViewAppear()

        XCTAssertTrue(vm.isLoading,
                      "isLoading must remain true when orphaned generation is running")
    }

    @MainActor
    func testViewAppearClearsLoadingWhenNoActiveGeneration() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "Idle")
        context.insert(session)
        session.agent = agent
        session.isActive = false
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.onViewAppear()

        XCTAssertFalse(vm.isLoading,
                       "isLoading must be false when session is inactive and no generation running")
        XCTAssertEqual(vm.streamingContent, "",
                       "streamingContent must be cleared when session is inactive")
    }

    // MARK: - Cross-agent session isolation

    @MainActor
    func testAgentBSessionDoesNotAffectAgentAState() {
        // Set up Agent A with an active session.
        let agentA = Agent(name: "AgentA")
        context.insert(agentA)
        let sessionA = Session(title: "A Running")
        context.insert(sessionA)
        sessionA.agent = agentA
        sessionA.isActive = true
        sessionA.pendingStreamingContent = "working..."
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: sessionA.id)

        // Set up Agent B with a new session (simulates user opening Agent B).
        let agentB = Agent(name: "AgentB")
        context.insert(agentB)
        let sessionB = Session(title: "B New")
        context.insert(sessionB)
        sessionB.agent = agentB
        try! context.save()

        // Creating Agent B's ViewModel must not disturb Agent A's session state.
        let vmB = ChatViewModel(session: sessionB, modelContext: context)
        _ = vmB

        XCTAssertTrue(sessionA.isActive,
                      "Agent A session must remain active when Agent B opens a new session")
        XCTAssertEqual(sessionA.pendingStreamingContent, "working...",
                       "Agent A pending content must be preserved")
        XCTAssertTrue(ChatViewModel._hasActiveGeneration(for: sessionA.id),
                      "Agent A generation must still be registered")
    }

    // MARK: - New ViewModel recovers streaming content from orphaned generation

    @MainActor
    func testNewViewModelRecoversPendingStreamingContent() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "Streaming")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.pendingStreamingContent = "Hello, I am responding to your..."
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)

        // startMonitoringIfNeeded should pick up the pending content.
        XCTAssertTrue(vm.isLoading,
                      "ViewModel must show loading for orphaned active session")
        XCTAssertEqual(vm.streamingContent, "Hello, I am responding to your...",
                       "ViewModel must recover pendingStreamingContent from session")
    }

    // MARK: - Session isActive preserved across multiple ViewModel recreations

    @MainActor
    func testIsActivePreservedAcrossMultipleViewModelRecreations() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "Long Running")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.updatedAt = Date().addingTimeInterval(-200) // > 120s stale threshold
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        // Simulate navigating away and back multiple times.
        for i in 1...3 {
            let vm = ChatViewModel(session: session, modelContext: context)
            vm.onViewAppear()

            XCTAssertTrue(session.isActive,
                          "isActive must stay true on recreation #\(i)")
            XCTAssertTrue(vm.isLoading,
                          "isLoading must be true on recreation #\(i)")

            vm.onViewDisappear()
        }
    }

    // MARK: - Monitoring clears streamingContent when pendingStreamingContent becomes nil

    @MainActor
    func testMonitoringClearsStreamingContentWhenPendingBecomesNil() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "ToolLoop")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.pendingStreamingContent = "First API reply..."
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)

        // Monitoring picks up the pending content initially.
        XCTAssertEqual(vm.streamingContent, "First API reply...",
                       "ViewModel must recover pendingStreamingContent on init")

        // Simulate the generation clearing pendingStreamingContent (e.g. stream
        // ended and entered a tool-call cycle where no new content is produced).
        session.pendingStreamingContent = nil

        // Recreate the ViewModel as if SwiftUI rebuilt the view.
        let vm2 = ChatViewModel(session: session, modelContext: context)

        XCTAssertEqual(vm2.streamingContent, "",
                       "streamingContent must be empty when pendingStreamingContent is nil")
        XCTAssertTrue(vm2.isLoading,
                      "isLoading must remain true while session is still active")
    }

    // MARK: - Monitoring does not show stale content from previous generation

    @MainActor
    func testMonitoringDoesNotShowStalePreviousContent() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "Stale")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        // pendingStreamingContent is nil — the previous generation already
        // finished and a new one just started but hasn't produced content yet.
        session.pendingStreamingContent = nil
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)

        XCTAssertEqual(vm.streamingContent, "",
                       "streamingContent must be empty when no pending content exists")
        XCTAssertTrue(vm.isLoading,
                      "isLoading must be true for active session")
    }

    // MARK: - Monitoring transitions from content to empty correctly

    @MainActor
    func testMonitoringTransitionsFromContentToEmpty() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "Transition")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.pendingStreamingContent = "Hello from first call"
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        // First VM sees the pending content.
        let vm1 = ChatViewModel(session: session, modelContext: context)
        XCTAssertEqual(vm1.streamingContent, "Hello from first call")

        // Generation moves to tool-call phase: content cleared.
        session.pendingStreamingContent = nil
        // Second API call produces new content.
        session.pendingStreamingContent = "New response"

        let vm2 = ChatViewModel(session: session, modelContext: context)
        XCTAssertEqual(vm2.streamingContent, "New response",
                       "streamingContent must reflect the latest pendingStreamingContent")
    }

    // MARK: - Empty string pendingStreamingContent treated as no content

    @MainActor
    func testEmptyStringPendingTreatedAsNoContent() {
        let agent = Agent(name: "AgentA")
        context.insert(agent)
        let session = Session(title: "EmptyString")
        context.insert(session)
        session.agent = agent
        session.isActive = true
        session.pendingStreamingContent = ""
        try! context.save()

        ChatViewModel._simulateActiveGeneration(for: session.id)

        let vm = ChatViewModel(session: session, modelContext: context)

        XCTAssertEqual(vm.streamingContent, "",
                       "Empty pendingStreamingContent must result in empty streamingContent")
    }
}
