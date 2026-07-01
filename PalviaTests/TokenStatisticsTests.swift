import XCTest
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

    func testCacheHitRate() {
        let messages = [
            message(.assistant, estimate: 20, prompt: 200, completion: 50, cacheRead: 50),
        ]
        let stats = TokenStatistics.compute(from: messages)
        XCTAssertEqual(stats.cacheHitRate, 0.25, accuracy: 0.0001)
    }

    func testCacheHitRateClampedAndZeroSafe() {
        // No input tokens -> no divide-by-zero.
        let empty = TokenStatistics.compute(from: [])
        XCTAssertEqual(empty.cacheHitRate, 0)

        // Cache read exceeding billed input clamps to 1.0.
        let messages = [message(.assistant, estimate: 5, prompt: 10, completion: 5, cacheRead: 999)]
        XCTAssertEqual(TokenStatistics.compute(from: messages).cacheHitRate, 1.0, accuracy: 0.0001)
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
}
