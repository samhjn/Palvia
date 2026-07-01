import Foundation

/// Aggregated token usage for a chat session, combining vendor-reported (billed)
/// counts with local estimates broken down by message role.
///
/// Two complementary views are provided:
/// - **Billed** totals come from the API `usage` payload persisted on each
///   assistant `Message` (`apiPromptTokens` / `apiCompletionTokens` / cache
///   fields). Because every turn re-sends the running context, summing the
///   per-turn prompt tokens yields the cumulative *billed* input across the
///   whole conversation — i.e. what the user actually paid for.
/// - **Estimated composition** buckets each message's local `tokenEstimate` by
///   role, so the user can see where the context weight sits (their own
///   prompts, assistant replies, tool output, etc.) even for turns that never
///   reported API usage.
struct TokenStatistics: Equatable {
    // MARK: Billed (API-reported)

    /// Sum of per-turn prompt tokens across all assistant turns that reported
    /// usage (cumulative billed input).
    var billedInputTokens: Int = 0
    /// Sum of per-turn completion tokens (billed output).
    var billedOutputTokens: Int = 0
    /// Sum of tokens served from the prompt cache (a subset of billed input,
    /// typically discounted by the vendor).
    var cacheReadTokens: Int = 0
    /// Sum of tokens written to the prompt cache.
    var cacheWriteTokens: Int = 0
    /// Number of assistant turns that carried API usage.
    var turnsWithUsage: Int = 0

    // MARK: Estimated composition (by role)

    var systemTokens: Int = 0
    var userTokens: Int = 0
    var assistantTokens: Int = 0
    var toolTokens: Int = 0

    /// Estimated size of the dynamically-assembled system prompt (SOUL / USER /
    /// MEMORY / capabilities / skills). It is never stored as a `Message`, so it
    /// is captured separately and folded into `systemTokens`. Zero when computed
    /// from messages alone (no agent context available).
    var systemPromptTokens: Int = 0

    // MARK: Counts

    var messageCount: Int = 0
    var userMessageCount: Int = 0
    var assistantMessageCount: Int = 0
    var toolMessageCount: Int = 0

    /// Tokens currently in the active context window (compressed summary +
    /// uncompressed tail). Populated by the caller via `ContextManager`.
    var activeContextTokens: Int = 0
    /// The agent's compression threshold, for context-window sizing.
    var contextThreshold: Int = 0

    // MARK: Derived

    var billedTotalTokens: Int { billedInputTokens + billedOutputTokens }

    var estimatedTotalTokens: Int {
        systemTokens + userTokens + assistantTokens + toolTokens
    }

    /// True when at least one turn reported real API usage.
    var hasAPIUsage: Bool { turnsWithUsage > 0 }

    /// Average billed output tokens per assistant turn.
    var averageOutputPerTurn: Int {
        turnsWithUsage > 0 ? billedOutputTokens / turnsWithUsage : 0
    }

    /// True when the provider reported any prompt-cache activity.
    var hasCacheActivity: Bool { cacheReadTokens > 0 || cacheWriteTokens > 0 }

    /// Active context usage as a fraction of the compression threshold (0...1+).
    var contextUsageRatio: Double {
        guard contextThreshold > 0 else { return 0 }
        return Double(activeContextTokens) / Double(contextThreshold)
    }

    // MARK: Computation

    /// Aggregate statistics from a set of messages. Pure and SwiftData-agnostic
    /// so it is trivially unit-testable.
    static func compute(from messages: [Message]) -> TokenStatistics {
        var stats = TokenStatistics()
        stats.messageCount = messages.count

        for message in messages {
            let estimate = message.tokenEstimate > 0
                ? message.tokenEstimate
                : TokenEstimator.estimateMessage(message)

            switch message.role {
            case .system:
                stats.systemTokens += estimate
            case .user:
                stats.userTokens += estimate
                stats.userMessageCount += 1
            case .assistant:
                stats.assistantTokens += estimate
                stats.assistantMessageCount += 1
            case .tool:
                stats.toolTokens += estimate
                stats.toolMessageCount += 1
            }

            // Billed usage is recorded on the assistant turn.
            if let prompt = message.apiPromptTokens {
                stats.billedInputTokens += prompt
            }
            if let completion = message.apiCompletionTokens {
                stats.billedOutputTokens += completion
            }
            if let cacheRead = message.apiCacheReadTokens {
                stats.cacheReadTokens += cacheRead
            }
            if let cacheWrite = message.apiCacheWriteTokens {
                stats.cacheWriteTokens += cacheWrite
            }
            if message.apiPromptTokens != nil || message.apiCompletionTokens != nil {
                stats.turnsWithUsage += 1
            }
        }

        return stats
    }

    /// Convenience that also fills in the active-context figures from a session
    /// and the system prompt, which is assembled per request and never stored
    /// as a `Message`.
    static func compute(
        for session: Session,
        contextManager: ContextManager = ContextManager(),
        promptBuilder: PromptBuilder = PromptBuilder()
    ) -> TokenStatistics {
        var stats = compute(from: session.messages)
        stats.activeContextTokens = contextManager.activeContextTokens(session: session)
        stats.contextThreshold = session.agent?.effectiveCompressionThreshold ?? ContextManager.compressionThreshold

        // The system prompt is billed on every turn but lives outside
        // `session.messages`, so estimate it for the session's current
        // configuration and fold it into the system bucket. Otherwise the
        // composition understates the largest fixed cost of the conversation.
        if let agent = session.agent {
            let systemPrompt = promptBuilder.buildSystemPrompt(
                for: agent,
                activatedSkillSlugs: session.activatedSkillSlugs
            )
            stats.systemPromptTokens = TokenEstimator.estimate(systemPrompt)
            stats.systemTokens += stats.systemPromptTokens
        }
        return stats
    }

    // MARK: Formatting

    /// Compact human-readable count, e.g. `12.3k` or `1.2M`.
    static func format(_ n: Int) -> String {
        let value = Double(n)
        if n >= 1_000_000 {
            return String(format: "%.1fM", value / 1_000_000)
        } else if n >= 1_000 {
            return String(format: "%.1fk", value / 1_000)
        }
        return "\(n)"
    }
}
