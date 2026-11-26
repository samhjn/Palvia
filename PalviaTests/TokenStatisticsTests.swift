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

    func testCacheOnlyReportKeepsUnknownTotalSeparateFromReportedZero() {
        let cacheOnly = TokenStatistics.compute(from: [message(.assistant, estimate: 20, cacheRead: 80)])
        XCTAssertEqual(cacheOnly.turnsWithUsage, 1)
        XCTAssertEqual(cacheOnly.cacheReadTokens, 80)
        XCTAssertNil(cacheOnly.knownBilledTotal)
        XCTAssertTrue(cacheOnly.hasEstimatedUsage)

        let free = message(.assistant, estimate: 20)
        free.applyAPIUsage(LLMUsage(promptTokens: nil, completionTokens: nil, totalTokens: 0))
        let zero = TokenStatistics.compute(from: [free])
        XCTAssertEqual(zero.knownBilledTotal, 0)
        XCTAssertFalse(zero.hasEstimatedUsage)
    }

    func testReportedTotalWithoutBreakdownIsBilledOnceAlongsideLegacyMessages() {
        let assistant = message(.assistant, estimate: 20)
        assistant.applyAPIUsage(LLMUsage(promptTokens: nil, completionTokens: nil, totalTokens: 75))
        let stats = TokenStatistics.compute(from: [
            message(.user, estimate: 10), assistant,
            message(.assistant, estimate: 20, prompt: 40, completion: 10),
        ])
        XCTAssertEqual(stats.billedTotalTokens, 125)
        XCTAssertEqual(stats.billedInputTokens, 40)
        XCTAssertEqual(stats.billedOutputTokens, 10)
        XCTAssertEqual(stats.averageOutputPerTurn, 10)
        XCTAssertEqual(stats.turnsWithUsage, 2)
        XCTAssertFalse(stats.hasEstimatedUsage)
    }

    func testResolveBreakdownPerRequestBeforeAddingContinuations() {
        let assistant = message(.assistant, estimate: 20)
        let totalOnly = LLMUsage(promptTokens: nil, completionTokens: nil, totalTokens: 75)
        let inputOnly = LLMUsage(promptTokens: 6, completionTokens: nil, totalTokens: 10)
        let outputOnly = LLMUsage(promptTokens: nil, completionTokens: 0, totalTokens: 12)
        let noTotal = LLMUsage(promptTokens: 50, completionTokens: 10, totalTokens: nil)
        assistant.applyAPIUsage(noTotal, previousRequests: [totalOnly, inputOnly, outputOnly])
        let stats = TokenStatistics.compute(from: [assistant])

        XCTAssertEqual(stats.billedInputTokens, 68)
        XCTAssertEqual(stats.billedOutputTokens, 14)
        XCTAssertEqual(stats.billedTotalTokens, 157)
        XCTAssertEqual(stats.assistantTokens, 20)
        XCTAssertFalse(stats.hasEstimatedUsage)
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

    // MARK: - Bug fixes & edge cases

    func testAverageOutputPerTurnExcludesPromptOnlyTurnsFromDenominator() {
        let messages = [
            message(.user, estimate: 10),
            message(.assistant, estimate: 20, prompt: 100, completion: 80),
            message(.user, estimate: 10),
            message(.assistant, estimate: 30, prompt: 200, completion: nil),
        ]
        let stats = TokenStatistics.compute(from: messages)

        XCTAssertEqual(stats.turnsWithUsage, 2)
        XCTAssertEqual(stats.turnsWithOutputUsage, 1)
        XCTAssertEqual(stats.billedOutputTokens, 80)
        XCTAssertEqual(stats.averageOutputPerTurn, 80,
                       "Turns missing completion usage must not dilute averageOutputPerTurn")
    }

    func testAnthropicUsageIncludesCacheTokensInNormalizedPromptTokens() throws {
        let adapter = AnthropicAdapter(
            context: LLMAdapterContext(baseURL: "https://api.anthropic.com/v1", apiKey: "test")
        )
        let responseJSON = """
        {
            "id": "msg_cache_1",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hello"}],
            "model": "claude-sonnet-4-20250514",
            "stop_reason": "end_turn",
            "usage": {
                "input_tokens": 50,
                "output_tokens": 200,
                "cache_creation_input_tokens": 1000,
                "cache_read_input_tokens": 8000
            }
        }
        """
        let response = try adapter.parseChatResponse(data: Data(responseJSON.utf8))
        let usage = try XCTUnwrap(response.usage)

        XCTAssertEqual(usage.promptTokens, 9050,
                       "Anthropic total input must equal input_tokens + cache_creation + cache_read")
        XCTAssertEqual(usage.completionTokens, 200)
        XCTAssertEqual(usage.totalTokens, 9250)
        XCTAssertEqual(usage.cacheCreationInputTokens, 1000)
        XCTAssertEqual(usage.cacheReadInputTokens, 8000)
    }

    func testAnthropicStreamMergesStartAndDeltaWithoutDroppingCacheFromTotalInput() {
        let adapter = AnthropicAdapter(
            context: LLMAdapterContext(baseURL: "https://api.anthropic.com/v1", apiKey: "test")
        )

        let startChunks = adapter.processStreamEvent(.message(data: """
        {
            "type": "message_start",
            "message": {
                "id": "msg_stream_1",
                "role": "assistant",
                "model": "claude-sonnet-4-20250514",
                "usage": {
                    "input_tokens": 25,
                    "output_tokens": 1,
                    "cache_creation_input_tokens": 500,
                    "cache_read_input_tokens": 4000
                }
            }
        }
        """))
        // Simulate a proxy that repeats input_tokens (or sends 0 for cache) on message_delta.
        let deltaChunks = adapter.processStreamEvent(.message(data: """
        {
            "type": "message_delta",
            "delta": {"type": "message_delta", "stop_reason": "end_turn"},
            "usage": {
                "input_tokens": 25,
                "output_tokens": 350,
                "cache_read_input_tokens": 0
            }
        }
        """))

        var merged: LLMUsage?
        for chunk in startChunks + deltaChunks {
            if case .usage(let usage) = chunk {
                merged = merged?.merging(usage) ?? usage
            }
        }

        XCTAssertEqual(merged?.promptTokens, 4525)
        XCTAssertEqual(merged?.completionTokens, 350)
        XCTAssertEqual(merged?.totalTokens, 4875)
        XCTAssertEqual(merged?.cacheCreationInputTokens, 500)
        XCTAssertEqual(merged?.cacheReadInputTokens, 4000)
    }

    func testAnthropicResponseWithoutUsageReturnsNilUsage() throws {
        let adapter = AnthropicAdapter(
            context: LLMAdapterContext(baseURL: "https://api.anthropic.com/v1", apiKey: "test")
        )
        let responseJSON = """
        {
            "id": "msg_no_usage",
            "type": "message",
            "role": "assistant",
            "content": [{"type": "text", "text": "Hi"}],
            "stop_reason": "end_turn"
        }
        """
        let response = try adapter.parseChatResponse(data: Data(responseJSON.utf8))
        XCTAssertNil(response.usage)
    }

    func testUsageMergeIgnoresZeroPlaceholdersOverExistingPositiveCounts() {
        let initial = LLMUsage(
            promptTokens: 1200,
            completionTokens: 0,
            totalTokens: 1200,
            cacheCreationInputTokens: 200,
            cacheReadInputTokens: 900
        )
        let trailing = LLMUsage(
            promptTokens: 0,
            completionTokens: 180,
            totalTokens: 180,
            cacheCreationInputTokens: 0,
            cacheReadInputTokens: 0
        )

        let merged = initial.merging(trailing)
        XCTAssertEqual(merged.promptTokens, 1200)
        XCTAssertEqual(merged.completionTokens, 180)
        XCTAssertEqual(merged.totalTokens, 1380)
        XCTAssertEqual(merged.cacheCreationInputTokens, 200)
        XCTAssertEqual(merged.cacheReadInputTokens, 900)
    }

    func testUsageDecodingDerivesMissingFieldFromTotalAndParsesInputTokenDetails() throws {
        let missingCompletion = #"{"prompt_tokens": 400, "total_tokens": 520, "input_tokens_details": {"cached_tokens": 300}}"#
        let decoded1 = try JSONDecoder().decode(LLMUsage.self, from: Data(missingCompletion.utf8))
        XCTAssertEqual(decoded1.promptTokens, 400)
        XCTAssertEqual(decoded1.completionTokens, 120)
        XCTAssertEqual(decoded1.cacheReadInputTokens, 300)

        let missingPrompt = #"{"completion_tokens": 80, "total_tokens": 500}"#
        let decoded2 = try JSONDecoder().decode(LLMUsage.self, from: Data(missingPrompt.utf8))
        XCTAssertEqual(decoded2.promptTokens, 420)
        XCTAssertEqual(decoded2.completionTokens, 80)
    }

    func testCompressedSessionFallbackInputUsesSummaryInsteadOfDroppedHistory() {
        let messages = [
            message(.user, estimate: 100),       // idx 0 (pinned first user)
            message(.assistant, estimate: 500, prompt: 100, completion: 500), // idx 1 (compressed)
            message(.user, estimate: 1000),      // idx 2 (compressed)
            message(.assistant, estimate: 1000, prompt: 1600, completion: 1000), // idx 3 (compressed)
            message(.user, estimate: 50),        // idx 4 (uncompressed tail)
            message(.assistant, estimate: 40),   // idx 5 (uncompressed, no API usage)
        ]

        let stats = TokenStatistics.compute(
            from: messages,
            compressedUpToIndex: 4,
            compressedSummaryTokens: 200
        )

        // Post-compression turn sees: summary (200) + pinned first user (100) + tail user (50) = 350
        XCTAssertEqual(stats.fallbackInputTokens, 350)
        XCTAssertEqual(stats.fallbackOutputTokens, 40)
        // Role composition still covers full conversation history.
        XCTAssertEqual(stats.userTokens, 1150)
        XCTAssertEqual(stats.assistantTokens, 1540)
    }

    @MainActor
    func testActiveContextTokensAlignsCompressedIndexWithSystemMessages() throws {
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let container = try ModelContainer(for: schema,
                                           configurations: [ModelConfiguration(isStoredInMemoryOnly: true)])
        let context = ModelContext(container)

        let session = Session(title: "S")
        let t0 = Date(timeIntervalSince1970: 100)
        let m0 = Message(role: .system, content: "sys", tokenEstimate: 100); m0.timestamp = t0
        let m1 = Message(role: .user, content: "u1", tokenEstimate: 50); m1.timestamp = t0.addingTimeInterval(1)
        let m2 = Message(role: .assistant, content: "a1", tokenEstimate: 60); m2.timestamp = t0.addingTimeInterval(2)
        let m3 = Message(role: .user, content: "u2", tokenEstimate: 70); m3.timestamp = t0.addingTimeInterval(3)
        session.messages = [m0, m1, m2, m3]
        session.compressedUpToIndex = 2 // m0 and m1 compressed; m2 and m3 active
        session.compressedContext = "summary"
        context.insert(session)
        try context.save()

        let active = ContextManager().activeContextTokens(session: session)
        let expectedSummary = TokenEstimator.estimate("summary")
        XCTAssertEqual(active, expectedSummary + 60 + 70)
    }

    func testTokenEstimatorIncludesThinkingContent() {
        let msg = Message(role: .assistant, content: "Short answer.")
        let withoutThinking = msg.tokenEstimate
        msg.thinkingContent = String(repeating: "reasoning step ", count: 30)
        msg.recalculateTokenEstimate()

        XCTAssertGreaterThan(msg.tokenEstimate, withoutThinking)
        XCTAssertEqual(msg.tokenEstimate, TokenEstimator.estimateMessage(msg))
    }

    func testCompressionStatsFormatsMillionsConsistently() {
        let stats = CompressionStats(
            activeTokens: 1_250_000,
            threshold: 2_000_000,
            totalMessages: 10,
            compressedCount: 0,
            pendingCount: 7
        )
        XCTAssertEqual(stats.activeFormatted, "1.2M")
        XCTAssertEqual(stats.thresholdFormatted, "2.0M")
    }
}
