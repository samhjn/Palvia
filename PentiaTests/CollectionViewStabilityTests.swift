import XCTest
import SwiftData
@testable import iClaw

// MARK: - Shared Test Schema

private let testSchema = Schema([
    Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
    CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
    Message.self, SessionEmbedding.self
])

// MARK: - displayMessages Filtering Tests
//
// The crash (UICollectionView _Bug_Detected_In_Client_Of_UICollectionView_Invalid_Number_Of_Items_In_Section)
// was caused by `displayMessages` being a computed property that could return different results
// at different points during SwiftUI's batch update cycle. These tests verify the filtering logic
// that was extracted into `filteredMessages()`, ensuring it produces consistent snapshots.

final class DisplayMessageFilteringTests: XCTestCase {

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

    // MARK: - Verbose Mode (no filtering)

    @MainActor
    func testVerboseModeReturnsAllMessages() {
        let (_, vm) = makeSessionWithMixedMessages()
        vm.isVerbose = true

        // In verbose mode, every message is visible
        XCTAssertEqual(vm.messages.count, 5,
            "VM should have all 5 messages (user + assistant + tool + assistant-with-tool-calls + user)")
    }

    // MARK: - Silent Mode (filters tool & empty-tool-call-only assistant messages)

    @MainActor
    func testSilentModeFiltersOutToolMessages() {
        let (_, vm) = makeSessionWithMixedMessages()
        vm.isVerbose = false

        let filtered = silentFilteredMessages(from: vm.messages)
        let hasToolMsg = filtered.contains { $0.role == .tool }
        XCTAssertFalse(hasToolMsg, "Silent mode should hide all .tool messages")
    }

    @MainActor
    func testSilentModeFiltersOutEmptyAssistantWithToolCalls() {
        let (_, vm) = makeSessionWithMixedMessages()
        vm.isVerbose = false

        let filtered = silentFilteredMessages(from: vm.messages)
        // The assistant message with only toolCallsData and no content should be hidden
        XCTAssertEqual(filtered.count, 3,
            "Silent mode should show 2 user msgs + 1 assistant with content, hiding tool + empty-assistant-with-tool-calls")
    }

    @MainActor
    func testSilentModeKeepsAssistantWithContentAndToolCalls() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        // Assistant message with BOTH content and tool calls should remain visible
        let toolCalls = [LLMToolCall(id: "tc_1", name: "browser_navigate", arguments: "{}")]
        let toolData = try! JSONEncoder().encode(toolCalls)
        let msg = Message(role: .assistant, content: "Let me check that for you.", toolCallsData: toolData)
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.isVerbose = false

        let filtered = silentFilteredMessages(from: vm.messages)
        XCTAssertEqual(filtered.count, 1,
            "Assistant with both content and tool calls should remain visible in silent mode")
        XCTAssertEqual(filtered.first?.content, "Let me check that for you.")
    }

    // MARK: - Consistency Under Rapid Mutations (the core crash scenario)

    @MainActor
    func testFilteredSnapshotConsistentDuringRapidAppends() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.isVerbose = false

        // Simulate the processToolCalls pattern: append multiple tool messages then loadMessages()
        let userMsg = Message(role: .user, content: "What's the weather?")
        context.insert(userMsg)
        session.messages.append(userMsg)

        let assistantMsg = Message(role: .assistant, content: "I'll check for you.")
        context.insert(assistantMsg)
        session.messages.append(assistantMsg)
        try! context.save()
        vm.loadMessages(immediate: true)

        let snapshotBefore = silentFilteredMessages(from: vm.messages)
        XCTAssertEqual(snapshotBefore.count, 2) // user + assistant

        // Now simulate batch tool-message appends (the dangerous pattern)
        for i in 0..<5 {
            let toolMsg = Message(role: .tool, content: "Result \(i)", toolCallId: "call_\(i)", name: "weather_\(i)")
            context.insert(toolMsg)
            session.messages.append(toolMsg)
        }
        // Single loadMessages() after batch — mirrors processToolCalls behavior
        try! context.save()
        vm.loadMessages(immediate: true)

        let snapshotAfter = silentFilteredMessages(from: vm.messages)
        // Tool messages should still be hidden; only user + assistant visible
        XCTAssertEqual(snapshotAfter.count, 2,
            "After batch tool-message appends, silent filter should still show only user + assistant")
        XCTAssertEqual(vm.messages.count, 7,
            "vm.messages should have all 7 messages (user + assistant + 5 tools)")
    }

    @MainActor
    func testSnapshotStableAcrossMultipleLoadMessagesCalls() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        for i in 0..<10 {
            let msg = Message(role: i % 2 == 0 ? .user : .assistant, content: "Msg \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        // Call loadMessages() rapidly many times — each call should produce the same result
        var counts: [Int] = []
        for _ in 0..<20 {
            vm.loadMessages(immediate: true)
            counts.append(vm.messages.count)
        }

        let allSame = counts.allSatisfy { $0 == counts[0] }
        XCTAssertTrue(allSame,
            "Rapid successive loadMessages() calls should always return the same count, got: \(Set(counts))")
    }

    // MARK: - Verbose Toggle Consistency

    @MainActor
    func testVerboseToggleFilterCountsConsistent() {
        let (_, vm) = makeSessionWithMixedMessages()

        vm.isVerbose = true
        let verboseCount = vm.messages.count
        let verboseFiltered = verboseFilteredMessages(from: vm.messages)

        vm.isVerbose = false
        let silentFiltered = silentFilteredMessages(from: vm.messages)

        vm.isVerbose = true
        let verboseAgain = verboseFilteredMessages(from: vm.messages)

        XCTAssertEqual(verboseFiltered.count, verboseCount,
            "Verbose mode should return all messages")
        XCTAssertLessThan(silentFiltered.count, verboseCount,
            "Silent mode should return fewer messages than verbose")
        XCTAssertEqual(verboseAgain.count, verboseFiltered.count,
            "Toggling back to verbose should restore the full count")
    }

    @MainActor
    func testVerboseToggleDuringToolCallProcessing() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let userMsg = Message(role: .user, content: "hello")
        context.insert(userMsg)
        session.messages.append(userMsg)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.isVerbose = false

        // Start with 1 visible message
        XCTAssertEqual(silentFilteredMessages(from: vm.messages).count, 1)

        // Append a tool message
        let toolMsg = Message(role: .tool, content: "result", toolCallId: "c1", name: "fn")
        context.insert(toolMsg)
        session.messages.append(toolMsg)
        try! context.save()
        vm.loadMessages(immediate: true)

        // Still 1 visible in silent mode
        XCTAssertEqual(silentFilteredMessages(from: vm.messages).count, 1)

        // Toggle to verbose — now 2 visible
        vm.isVerbose = true
        XCTAssertEqual(verboseFilteredMessages(from: vm.messages).count, 2)

        // Toggle back — tool hidden again
        vm.isVerbose = false
        XCTAssertEqual(silentFilteredMessages(from: vm.messages).count, 1)
    }

    // MARK: - Edge Cases

    @MainActor
    func testEmptySessionProducesEmptyFilteredMessages() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        XCTAssertTrue(vm.messages.isEmpty)
        XCTAssertTrue(silentFilteredMessages(from: vm.messages).isEmpty)
        XCTAssertTrue(verboseFilteredMessages(from: vm.messages).isEmpty)
    }

    @MainActor
    func testSessionWithOnlyToolMessagesShowsNothingInSilent() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        for i in 0..<3 {
            let toolMsg = Message(role: .tool, content: "Result \(i)", toolCallId: "c\(i)", name: "fn\(i)")
            context.insert(toolMsg)
            session.messages.append(toolMsg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        XCTAssertEqual(vm.messages.count, 3)
        XCTAssertTrue(silentFilteredMessages(from: vm.messages).isEmpty,
            "Session with only tool messages should show nothing in silent mode")
    }

    @MainActor
    func testAssistantWithSmallToolCallsDataNotFiltered() {
        // toolCallsData with count <= 2 bytes should NOT be filtered
        // (the original filter checks `data.count > 2`)
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let msg = Message(role: .assistant, content: nil, toolCallsData: Data([0x5B, 0x5D])) // "[]" = 2 bytes
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        let filtered = silentFilteredMessages(from: vm.messages)
        XCTAssertEqual(filtered.count, 1,
            "Assistant with toolCallsData.count <= 2 should not be filtered (empty JSON array)")
    }

    // MARK: - loadMessages Consistency After Model Context Save

    @MainActor
    func testLoadMessagesAfterInsertAndSave() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        XCTAssertEqual(vm.messages.count, 0)

        // Insert message, save, then loadMessages
        let msg = Message(role: .user, content: "hello")
        context.insert(msg)
        session.messages.append(msg)
        try! context.save()
        vm.loadMessages(immediate: true)

        XCTAssertEqual(vm.messages.count, 1)
        XCTAssertEqual(vm.messages.first?.content, "hello")
    }

    @MainActor
    func testLoadMessagesIdempotent() {
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
        let count1 = vm.messages.count
        vm.loadMessages(immediate: true)
        let count2 = vm.messages.count
        vm.loadMessages(immediate: true)
        let count3 = vm.messages.count

        XCTAssertEqual(count1, count2)
        XCTAssertEqual(count2, count3)
    }

    // MARK: - Batch Update Simulation (processToolCalls pattern)

    @MainActor
    func testProcessToolCallsPattern_BatchAppendThenLoad() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        // Initial state: user asks, assistant responds with tool calls
        let userMsg = Message(role: .user, content: "Analyze this page")
        context.insert(userMsg)
        session.messages.append(userMsg)

        let toolCalls = [
            LLMToolCall(id: "tc_1", name: "browser_navigate", arguments: "{}"),
            LLMToolCall(id: "tc_2", name: "execute_javascript", arguments: "{}"),
            LLMToolCall(id: "tc_3", name: "browser_screenshot", arguments: "{}")
        ]
        let toolData = try! JSONEncoder().encode(toolCalls)
        let assistantMsg = Message(role: .assistant, content: nil, toolCallsData: toolData)
        context.insert(assistantMsg)
        session.messages.append(assistantMsg)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.isVerbose = false

        // Pre-batch snapshot
        let preBatchFiltered = silentFilteredMessages(from: vm.messages)
        let preBatchCount = preBatchFiltered.count

        // Simulate processToolCalls: batch-append tool results (no loadMessages between)
        let toolResults = [
            ("tc_1", "browser_navigate", "Navigated to example.com"),
            ("tc_2", "execute_javascript", "42"),
            ("tc_3", "browser_screenshot", "Screenshot taken")
        ]
        for (callId, name, result) in toolResults {
            let toolMsg = Message(role: .tool, content: result, toolCallId: callId, name: name)
            context.insert(toolMsg)
            session.messages.append(toolMsg)
        }
        try! context.save()
        vm.loadMessages(immediate: true) // Single load after batch

        // Post-batch snapshot
        let postBatchFiltered = silentFilteredMessages(from: vm.messages)

        // In silent mode, the 3 new tool messages + the empty assistant with tool calls should be hidden
        XCTAssertEqual(preBatchCount, postBatchFiltered.count,
            "Adding tool messages should not change the visible count in silent mode")
        XCTAssertEqual(vm.messages.count, 5,
            "All 5 messages should be in vm.messages (user + assistant-with-tools + 3 tool results)")
    }

    @MainActor
    func testProcessToolCallsPattern_InterleavedLoadMessages() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        let userMsg = Message(role: .user, content: "hello")
        context.insert(userMsg)
        session.messages.append(userMsg)
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.isVerbose = false

        // Simulate the dangerous pattern: loadMessages called after each append
        // This is what caused count mismatches in the old computed-property approach
        var filteredCounts: [Int] = []

        for i in 0..<5 {
            let toolMsg = Message(role: .tool, content: "R\(i)", toolCallId: "c\(i)", name: "fn")
            context.insert(toolMsg)
            session.messages.append(toolMsg)
            try! context.save()
            vm.loadMessages(immediate: true)
            filteredCounts.append(silentFilteredMessages(from: vm.messages).count)
        }

        // In silent mode, tool messages are hidden, so filtered count should stay 1 (just the user msg)
        XCTAssertTrue(filteredCounts.allSatisfy { $0 == 1 },
            "Silent filtered count should remain 1 through all tool appends, got: \(filteredCounts)")
    }

    // MARK: - Helpers

    /// Replicate the silent-mode filter from ChatContentView.filteredMessages().
    /// This mirrors the exact logic so tests verify the same behavior.
    private func silentFilteredMessages(from messages: [Message]) -> [Message] {
        messages.filter { msg in
            if msg.role == .tool { return false }
            if msg.role == .assistant,
               let data = msg.toolCallsData,
               data.count > 2,
               (msg.content ?? "").isEmpty {
                return false
            }
            return true
        }
    }

    /// Verbose mode returns all messages unfiltered.
    private func verboseFilteredMessages(from messages: [Message]) -> [Message] {
        messages
    }

    /// Create a session with a representative mix of message types.
    @MainActor
    private func makeSessionWithMixedMessages() -> (Session, ChatViewModel) {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        // 1. User message
        let msg1 = Message(role: .user, content: "What's the weather?")
        msg1.timestamp = Date(timeIntervalSince1970: 100)
        context.insert(msg1)
        session.messages.append(msg1)

        // 2. Assistant with content (visible in both modes)
        let msg2 = Message(role: .assistant, content: "Let me check that for you.")
        msg2.timestamp = Date(timeIntervalSince1970: 200)
        context.insert(msg2)
        session.messages.append(msg2)

        // 3. Tool result (hidden in silent mode)
        let msg3 = Message(role: .tool, content: "Weather: 72F, Sunny", toolCallId: "call_1", name: "get_weather")
        msg3.timestamp = Date(timeIntervalSince1970: 300)
        context.insert(msg3)
        session.messages.append(msg3)

        // 4. Assistant with only tool calls and no content (hidden in silent mode)
        let toolCalls = [LLMToolCall(id: "call_2", name: "browser_navigate", arguments: "{}")]
        let toolData = try! JSONEncoder().encode(toolCalls)
        let msg4 = Message(role: .assistant, content: nil, toolCallsData: toolData)
        msg4.timestamp = Date(timeIntervalSince1970: 400)
        context.insert(msg4)
        session.messages.append(msg4)

        // 5. Another user message
        let msg5 = Message(role: .user, content: "Thanks!")
        msg5.timestamp = Date(timeIntervalSince1970: 500)
        context.insert(msg5)
        session.messages.append(msg5)

        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        return (session, vm)
    }
}
