import XCTest
import SwiftData
@testable import Palvia

final class TokenStatisticsTests: XCTestCase {

    private func message(_ role: MessageRole, estimate: Int,
                         prompt: Int? = nil, completion: Int? = nil,
                         cacheRead: Int? = nil, cacheWrite: Int? = nil) -> Message {
        let msg = Message(role: role, content: "x", tokenEstimate: estimate)
        msg.apiPromptTokens = prompt
        msg.apiCompletionTokens = completion
        msg.apiCacheReadTokens = cacheRead
        msg.apiCacheWriteTokens = cacheWrite
        return msg
    }

    // MARK: - Composition by role

    func testRoleComposition() {
        let messages = [
            message(.system, estimate: 100),
            message(.user, estimate: 50),
            message(.assistant, estimate: 200, prompt: 150, completion: 200),
            message(.tool, estimate: 30),
            message(.user, estimate: 40),
        ]
        let stats = TokenStatistics.compute(from: messages)

        XCTAssertEqual(stats.systemTokens, 100)
        XCTAssertEqual(stats.userTokens, 90)
        XCTAssertEqual(stats.assistantTokens, 200)
        XCTAssertEqual(stats.toolTokens, 30)
        XCTAssertEqual(stats.estimatedTotalTokens, 420)

        XCTAssertEqual(stats.messageCount, 5)
        XCTAssertEqual(stats.userMessageCount, 2)
        XCTAssertEqual(stats.assistantMessageCount, 1)
        XCTAssertEqual(stats.toolMessageCount, 1)
    }

    // MARK: - Billed usage aggregation

    func testBilledUsageAcrossTurns() {
        let messages = [
            message(.user, estimate: 10),
            message(.assistant, estimate: 20, prompt: 100, completion: 50,
                    cacheRead: 40, cacheWrite: 10),
            message(.user, estimate: 10),
            message(.assistant, estimate: 20, prompt: 200, completion: 80,
                    cacheRead: 60),
        ]
        let stats = TokenStatistics.compute(from: messages)

        XCTAssertTrue(stats.hasAPIUsage)
        XCTAssertEqual(stats.turnsWithUsage, 2)
        XCTAssertEqual(stats.billedInputTokens, 300)
        XCTAssertEqual(stats.billedOutputTokens, 130)
        XCTAssertEqual(stats.billedTotalTokens, 430)
        XCTAssertEqual(stats.cacheReadTokens, 100)
        XCTAssertEqual(stats.cacheWriteTokens, 10)
        XCTAssertEqual(stats.averageOutputPerTurn, 65)
    }

    func testHasCacheActivity() {
        let none = TokenStatistics.compute(from: [message(.assistant, estimate: 20, prompt: 100, completion: 50)])
        XCTAssertFalse(none.hasCacheActivity)

        let readOnly = TokenStatistics.compute(from: [message(.assistant, estimate: 20, prompt: 100, completion: 50, cacheRead: 40)])
        XCTAssertTrue(readOnly.hasCacheActivity)

        let writeOnly = TokenStatistics.compute(from: [message(.assistant, estimate: 20, prompt: 100, completion: 50, cacheWrite: 10)])
        XCTAssertTrue(writeOnly.hasCacheActivity)
    }

    // Regression: a multi-round tool-call turn (several assistant messages, each
    // carrying its own usage) must sum input/output/cache across every round,
    // not just reflect the last one.
    func testMultiRoundToolCallAggregation() {
        let messages = [
            message(.user, estimate: 10),
            message(.assistant, estimate: 15, prompt: 500, completion: 30, cacheRead: 450),   // round 1: tool call
            message(.tool, estimate: 800),
            message(.assistant, estimate: 12, prompt: 900, completion: 25, cacheRead: 850),   // round 2: tool call
            message(.tool, estimate: 300),
            message(.assistant, estimate: 40, prompt: 1300, completion: 60, cacheRead: 1200), // round 3: final text
        ]
        let stats = TokenStatistics.compute(from: messages)

        XCTAssertEqual(stats.turnsWithUsage, 3)
        XCTAssertEqual(stats.billedInputTokens, 2700)   // 500 + 900 + 1300
        XCTAssertEqual(stats.billedOutputTokens, 115)   // 30 + 25 + 60
        XCTAssertEqual(stats.cacheReadTokens, 2500)     // 450 + 850 + 1200
        XCTAssertEqual(stats.toolTokens, 1100)          // 800 + 300
        XCTAssertTrue(stats.hasCacheActivity)
    }

    // Regression for the split-usage bug: Anthropic reports input + cache in
    // `message_start` and the final output only in `message_delta`. Merging must
    // preserve the earlier fields instead of overwriting them with nils.
    func testUsageMergePreservesSplitFields() {
        let start = LLMUsage(promptTokens: 1200, completionTokens: 1, totalTokens: nil,
                             cacheCreationInputTokens: 200, cacheReadInputTokens: 1000)
        let delta = LLMUsage(promptTokens: nil, completionTokens: 350, totalTokens: nil,
                             cacheCreationInputTokens: nil, cacheReadInputTokens: nil)

        let merged = start.merging(delta)

        XCTAssertEqual(merged.promptTokens, 1200)
        XCTAssertEqual(merged.completionTokens, 350)
        XCTAssertEqual(merged.cacheCreationInputTokens, 200)
        XCTAssertEqual(merged.cacheReadInputTokens, 1000)
    }

    func testNoAPIUsage() {
        let messages = [
            message(.user, estimate: 10),
            message(.assistant, estimate: 20),
        ]
        let stats = TokenStatistics.compute(from: messages)
        XCTAssertFalse(stats.hasAPIUsage)
        XCTAssertEqual(stats.turnsWithUsage, 0)
        XCTAssertEqual(stats.billedTotalTokens, 0)
        XCTAssertEqual(stats.averageOutputPerTurn, 0)
        XCTAssertTrue(stats.hasEstimatedUsage)
        XCTAssertEqual(stats.turnsWithEstimatedUsage, 1)
        XCTAssertEqual(stats.fallbackInputTokens, 10)
        XCTAssertEqual(stats.fallbackOutputTokens, 20)
        XCTAssertEqual(stats.fallbackTotalTokens, 30)
    }

    func testPartialProviderUsageFallsBackOnlyForMissingField() {
        let messages = [
            message(.user, estimate: 12),
            message(.assistant, estimate: 30, prompt: 120, completion: nil),
        ]
        let stats = TokenStatistics.compute(from: messages)

        XCTAssertTrue(stats.hasAPIUsage)
        XCTAssertEqual(stats.billedInputTokens, 120)
        XCTAssertEqual(stats.fallbackInputTokens, 0,
                       "Reported prompt usage must not be replaced by an estimate")
        XCTAssertEqual(stats.fallbackOutputTokens, 30)
        XCTAssertEqual(stats.turnsWithEstimatedUsage, 1)
    }

    // MARK: - Formatting

    func testFormat() {
        XCTAssertEqual(TokenStatistics.format(0), "0")
        XCTAssertEqual(TokenStatistics.format(999), "999")
        XCTAssertEqual(TokenStatistics.format(1000), "1.0k")
        XCTAssertEqual(TokenStatistics.format(12_345), "12.3k")
        XCTAssertEqual(TokenStatistics.format(1_000_000), "1.0M")
        XCTAssertEqual(TokenStatistics.format(2_500_000), "2.5M")
    }

    // MARK: - Context ratio

    func testContextUsageRatio() {
        var stats = TokenStatistics()
        stats.activeContextTokens = 12_000
        stats.contextThreshold = 24_000
        XCTAssertEqual(stats.contextUsageRatio, 0.5, accuracy: 0.0001)

        stats.contextThreshold = 0
        XCTAssertEqual(stats.contextUsageRatio, 0)
    }

    // MARK: - Per-turn overhead

    func testPerTurnOverheadDefaultsEmpty() {
        let stats = TokenStatistics.compute(from: [message(.user, estimate: 10)])
        XCTAssertEqual(stats.systemPromptTokens, 0)
        XCTAssertEqual(stats.toolSchemaTokens, 0)
        XCTAssertEqual(stats.perTurnOverheadTokens, 0)
        XCTAssertFalse(stats.hasPerTurnOverhead)
    }

    // compute(for:) reads the overhead captured on the session at send time,
    // without rebuilding the prompt, and keeps it out of the message composition.
    @MainActor
    func testPerTurnOverheadReadFromSession() throws {
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)

        let session = Session(title: "S")
        session.lastSystemPromptTokens = 1500
        session.lastToolSchemaTokens = 800
        session.lastConfigMarkdownTokens = 400
        session.lastSkillsTokens = 250
        session.messages = [Message(role: .user, content: "Hi", tokenEstimate: 10)]
        context.insert(session)
        try context.save()

        let stats = TokenStatistics.compute(for: session)

        XCTAssertEqual(stats.systemPromptTokens, 1500)
        XCTAssertEqual(stats.toolSchemaTokens, 800)
        XCTAssertEqual(stats.configMarkdownTokens, 400)
        XCTAssertEqual(stats.skillsTokens, 250)
        XCTAssertEqual(stats.perTurnOverheadTokens, 2300)
        XCTAssertTrue(stats.hasPerTurnOverhead)
        // Overhead must not leak into the conversation composition.
        XCTAssertEqual(stats.systemTokens, 0)
        XCTAssertEqual(stats.userTokens, 10)
    }

    @MainActor
    func testEstimatedUsageIncludesPerTurnOverhead() throws {
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let session = Session(title: "S")
        session.lastSystemPromptTokens = 100
        session.lastToolSchemaTokens = 50
        session.messages = [
            Message(role: .user, content: "Hi", tokenEstimate: 10),
            Message(role: .assistant, content: "Hello", tokenEstimate: 20),
        ]
        let context = ModelContext(container)
        context.insert(session)
        try context.save()

        let stats = TokenStatistics.compute(for: session)

        XCTAssertEqual(stats.fallbackInputTokens, 160,
                       "10 conversation tokens + 150 fixed request overhead")
        XCTAssertEqual(stats.fallbackOutputTokens, 20)
    }

    @MainActor
    func testEstimatedOverheadIsNotAddedWhenOnlyCompletionUsageIsMissing() throws {
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let session = Session(title: "S")
        session.lastSystemPromptTokens = 100
        session.lastToolSchemaTokens = 50
        let user = Message(role: .user, content: "Hi", tokenEstimate: 10)
        let assistant = Message(role: .assistant, content: "Hello", tokenEstimate: 20)
        assistant.apiPromptTokens = 500
        session.messages = [user, assistant]
        let context = ModelContext(container)
        context.insert(session)
        try context.save()

        let stats = TokenStatistics.compute(for: session)

        XCTAssertEqual(stats.billedInputTokens, 500)
        XCTAssertEqual(stats.fallbackInputTokens, 0)
        XCTAssertEqual(stats.fallbackOutputTokens, 20)
    }

    // Compression must be visible: the summary size and how many messages it replaced.
    @MainActor
    func testCompressionSurfaced() throws {
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)

        let session = Session(title: "S")
        session.compressedUpToIndex = 12
        session.compressedContext = String(repeating: "summary text ", count: 40)
        session.messages = [Message(role: .user, content: "latest", tokenEstimate: 10)]
        context.insert(session)
        try context.save()

        let stats = TokenStatistics.compute(for: session)

        XCTAssertTrue(stats.isCompressed)
        XCTAssertEqual(stats.compressedMessageCount, 12)
        XCTAssertGreaterThan(stats.compressedSummaryTokens, 0)
    }

    func testNotCompressedByDefault() {
        let stats = TokenStatistics.compute(from: [message(.user, estimate: 10)])
        XCTAssertFalse(stats.isCompressed)
        XCTAssertEqual(stats.compressedMessageCount, 0)
        XCTAssertEqual(stats.compressedSummaryTokens, 0)
    }
}
