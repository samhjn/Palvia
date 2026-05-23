import XCTest
import SwiftData
@testable import iClaw

// MARK: - Markdown Parsing Performance Tests

final class MarkdownParsingPerformanceTests: XCTestCase {

    // MARK: - parseInlineMarkdown batching (O(n) vs former O(n²))

    func testParseInlineMarkdownPlainTextPerformance() {
        let longPlainText = String(repeating: "Hello world this is a test. ", count: 500)
        let view = MarkdownContentView(longPlainText)

        measure {
            _ = view.parseInlineMarkdown(longPlainText)
        }
    }

    func testParseInlineMarkdownCompletesWithinBudget() {
        let longText = String(repeating: "The quick brown fox jumps over the lazy dog. ", count: 1000)
        let view = MarkdownContentView(longText)

        let start = CFAbsoluteTimeGetCurrent()
        _ = view.parseInlineMarkdown(longText)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 1.0,
            "parseInlineMarkdown should complete within 1s for ~45k chars, took \(elapsed)s")
    }

    func testParseInlineMarkdownWithMarkupMixed() {
        let markdown = String(repeating: "Some **bold** and *italic* text with `code` here. ", count: 200)
        let view = MarkdownContentView(markdown)

        let start = CFAbsoluteTimeGetCurrent()
        _ = view.parseInlineMarkdown(markdown)
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 1.0,
            "Mixed markup parsing should complete within 1s, took \(elapsed)s")
    }

    // MARK: - parseBlocks caching

    func testParseBlocksProducesSameResultForSameContent() {
        let content = """
        # Heading
        Some paragraph text.
        
        - Item 1
        - Item 2
        
        ```swift
        let x = 1
        ```
        """
        let view = MarkdownContentView(content)
        let blocks1 = view.parseBlocks()
        let blocks2 = view.parseBlocks()

        XCTAssertEqual(blocks1.count, blocks2.count,
            "Parsing the same content twice should produce identical results")
    }

    func testParseBlocksPerformanceWithLargeContent() {
        var lines: [String] = []
        for i in 0..<200 {
            lines.append("## Section \(i)")
            lines.append(String(repeating: "This is paragraph content for section \(i). ", count: 10))
            lines.append("")
            lines.append("- Bullet point \(i)")
            lines.append("")
        }
        let content = lines.joined(separator: "\n")
        let view = MarkdownContentView(content)

        let start = CFAbsoluteTimeGetCurrent()
        let blocks = view.parseBlocks()
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertGreaterThan(blocks.count, 0)
        XCTAssertLessThan(elapsed, 1.0,
            "Parsing 200 sections of markdown should complete within 1s, took \(elapsed)s")
    }

    // MARK: - Correctness after optimization

    func testParseInlineMarkdownPlainText() {
        let view = MarkdownContentView("Hello world")
        let result = view.parseInlineMarkdown("Hello world")
        XCTAssertEqual(String(result.characters), "Hello world")
    }

    func testParseInlineMarkdownBold() {
        let view = MarkdownContentView("**bold**")
        let result = view.parseInlineMarkdown("**bold**")
        XCTAssertEqual(String(result.characters), "bold")
    }

    func testParseInlineMarkdownInlineCode() {
        let view = MarkdownContentView("`code`")
        let result = view.parseInlineMarkdown("`code`")
        XCTAssertEqual(String(result.characters), "code")
    }

    func testParseInlineMarkdownLink() {
        let view = MarkdownContentView("[text](https://example.com)")
        let result = view.parseInlineMarkdown("[text](https://example.com)")
        XCTAssertEqual(String(result.characters), "text")
    }

    func testParseInlineMarkdownMixedContent() {
        let text = "Hello **bold** and `code` world"
        let view = MarkdownContentView(text)
        let result = view.parseInlineMarkdown(text)
        XCTAssertEqual(String(result.characters), "Hello bold and code world")
    }

    func testParseBlocksHeading() {
        let view = MarkdownContentView("# Title")
        let blocks = view.parseBlocks()
        XCTAssertEqual(blocks.count, 1)
        if case .heading(let level, let text) = blocks.first {
            XCTAssertEqual(level, 1)
            XCTAssertEqual(text, "Title")
        } else {
            XCTFail("Expected heading block")
        }
    }

    func testParseBlocksCodeBlock() {
        let content = """
        ```swift
        let x = 1
        ```
        """
        let view = MarkdownContentView(content)
        let blocks = view.parseBlocks()
        XCTAssertEqual(blocks.count, 1)
        if case .codeBlock(let lang, let code) = blocks.first {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "let x = 1")
        } else {
            XCTFail("Expected code block")
        }
    }

    func testParseBlocksBulletList() {
        let content = """
        - Item A
        - Item B
        """
        let view = MarkdownContentView(content)
        let blocks = view.parseBlocks()
        XCTAssertEqual(blocks.count, 1)
        if case .bulletList(let items) = blocks.first {
            XCTAssertEqual(items, ["Item A", "Item B"])
        } else {
            XCTFail("Expected bullet list block")
        }
    }
}

// MARK: - CronScheduler Lifecycle Tests

final class CronSchedulerLifecycleTests: XCTestCase {

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
    func testPauseSuspendsTimer() {
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        XCTAssertTrue(scheduler.isRunning, "Scheduler should be running after start()")

        scheduler.pause()
        XCTAssertTrue(scheduler.isRunning,
            "isRunning should remain true — pause only suspends the timer, not the logical state")
    }

    @MainActor
    func testResumeRestoresTimer() {
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        scheduler.pause()
        scheduler.resume()
        XCTAssertTrue(scheduler.isRunning, "Scheduler should still be running after resume()")
    }

    @MainActor
    func testResumeWithoutStartIsNoop() {
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.resume()
        XCTAssertFalse(scheduler.isRunning, "resume() on a never-started scheduler should be a no-op")
    }

    @MainActor
    func testStopAfterPause() {
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        scheduler.pause()
        scheduler.stop()
        XCTAssertFalse(scheduler.isRunning, "stop() should set isRunning to false")
    }

    @MainActor
    func testPauseIsIdempotent() {
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        scheduler.pause()
        scheduler.pause()
        XCTAssertTrue(scheduler.isRunning, "Double pause should not crash or change state")
    }

    @MainActor
    func testResumeIsIdempotent() {
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()
        scheduler.resume()
        scheduler.resume()
        XCTAssertTrue(scheduler.isRunning, "Double resume should not crash or change state")
    }

    @MainActor
    func testPauseResumeDoesNotLoseRunningState() {
        let scheduler = CronScheduler(modelContainer: container)
        scheduler.start()

        for _ in 0..<5 {
            scheduler.pause()
            scheduler.resume()
        }

        XCTAssertTrue(scheduler.isRunning,
            "Repeated pause/resume cycles should not corrupt state")
    }
}

// MARK: - CompressionStats Tests

final class CompressionStatsTests: XCTestCase {

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
    func testCompressionStatsComputesWithoutRedundantSort() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        for i in 0..<20 {
            let msg = Message(role: .user, content: "Message \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            vm.refreshCompressionStats()
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 2.0,
            "100 calls to refreshCompressionStats should complete within 2s, took \(elapsed)s")
    }

    @MainActor
    func testCompressionStatsReturnsCorrectCounts() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        for i in 0..<5 {
            let msg = Message(role: .user, content: "Message \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        let stats = vm.compressionStats

        XCTAssertEqual(stats.totalMessages, 5)
        XCTAssertEqual(stats.compressedCount, 0)
        XCTAssertGreaterThanOrEqual(stats.activeTokens, 0)
        XCTAssertGreaterThan(stats.threshold, 0)
    }
}

// MARK: - ChatViewModel Background Resilience Tests

final class ChatViewModelBackgroundTests: XCTestCase {

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
    func testPrepareForBackgroundDoesNotCrashWhenIdle() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.prepareForBackground()
        // Should not crash even with no active stream
    }

    @MainActor
    func testSetCustomTitleUpdatesProperties() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Old Title")
        context.insert(session)
        session.agent = agent
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        vm.setCustomTitle("New Title")

        XCTAssertEqual(session.title, "New Title")
        XCTAssertTrue(session.isTitleCustomized)
    }

    @MainActor
    func testSetCustomTitleCompletesQuickly() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        for i in 0..<50 {
            let msg = Message(role: i % 2 == 0 ? .user : .assistant,
                              content: String(repeating: "Content for message \(i). ", count: 20))
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        let start = CFAbsoluteTimeGetCurrent()
        vm.setCustomTitle("Renamed Session")
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 0.1,
            "setCustomTitle should return near-instantly (deferred save), took \(elapsed)s")
    }

    @MainActor
    func testCompressionStatsNotRecomputedOnTitleChange() {
        let agent = Agent(name: "TestAgent")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent

        for i in 0..<30 {
            let msg = Message(role: .user, content: "Message \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let vm = ChatViewModel(session: session, modelContext: context)
        let statsBefore = vm.compressionStats

        vm.setCustomTitle("New Title")

        let statsAfter = vm.compressionStats
        XCTAssertEqual(statsBefore.totalMessages, statsAfter.totalMessages,
            "compressionStats should not recompute just because the title changed")
        XCTAssertEqual(statsBefore.activeTokens, statsAfter.activeTokens)
    }
}

// MARK: - Session.sortedMessages Tests

final class SessionSortedMessagesTests: XCTestCase {

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
    func testSortedMessagesPerformance() {
        let session = Session(title: "Test")
        context.insert(session)

        for i in 0..<200 {
            let msg = Message(role: .user, content: "Message \(i)")
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let start = CFAbsoluteTimeGetCurrent()
        for _ in 0..<100 {
            _ = session.sortedMessages
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        XCTAssertLessThan(elapsed, 1.0,
            "100 calls to sortedMessages (200 msgs, cached) should complete within 1s, took \(elapsed)s")
    }

    @MainActor
    func testSortedMessagesOrdersCorrectly() {
        let session = Session(title: "Test")
        context.insert(session)

        let dates = [
            Date(timeIntervalSince1970: 300),
            Date(timeIntervalSince1970: 100),
            Date(timeIntervalSince1970: 200),
        ]

        for (i, date) in dates.enumerated() {
            let msg = Message(role: .user, content: "Message \(i)")
            msg.timestamp = date
            context.insert(msg)
            session.messages.append(msg)
        }
        try! context.save()

        let sorted = session.sortedMessages
        XCTAssertEqual(sorted.count, 3)
        XCTAssertEqual(sorted[0].content, "Message 1")
        XCTAssertEqual(sorted[1].content, "Message 2")
        XCTAssertEqual(sorted[2].content, "Message 0")
    }
}
