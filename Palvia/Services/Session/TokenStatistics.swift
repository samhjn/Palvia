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
    private(set) var knownBilledTotal: Int?
    var turnsWithInputUsage: Int = 0
    /// Sum of tokens served from the prompt cache (a subset of billed input,
    /// typically discounted by the vendor).
    var cacheReadTokens: Int = 0
    /// Sum of tokens written to the prompt cache.
    var cacheWriteTokens: Int = 0
    /// Number of assistant turns that carried API usage.
    var turnsWithUsage: Int = 0
    /// Number of assistant turns that carried API output (`completion`) usage.
    /// Used as the denominator for `averageOutputPerTurn` so prompt-only
    /// usage records do not dilute the average.
    var turnsWithOutputUsage: Int = 0

    /// Local fallback for calls where the provider omitted all or part of the
    /// usage payload. Kept separate so estimates are never presented as billed.
    var fallbackInputTokens: Int = 0
    var fallbackOutputTokens: Int = 0
    var turnsWithEstimatedUsage: Int = 0
    /// Subset of estimated turns whose prompt/input count specifically was
    /// absent. This keeps prompt overhead out of output-only estimates.
    var turnsWithEstimatedInputUsage: Int = 0

    // MARK: Estimated composition (by role)

    var systemTokens: Int = 0
    var userTokens: Int = 0
    var assistantTokens: Int = 0
    var toolTokens: Int = 0

    // MARK: Per-turn fixed overhead

    /// Estimated size of the system prompt sent on the most recent request
    /// (SOUL / USER / MEMORY / capabilities / skills). Assembled per request and
    /// never stored as a `Message`, so it is captured at send time and read back
    /// here. Sent — and billed — on every turn. Zero if never sent.
    var systemPromptTokens: Int = 0
    /// Estimated size of the tool/function JSON schemas sent on the most recent
    /// request (also sent and billed every turn). Zero if none / never sent.
    var toolSchemaTokens: Int = 0

    /// Subset of `systemPromptTokens`: user-authored injected config markdown
    /// (SOUL / MEMORY / USER + custom configs).
    var configMarkdownTokens: Int = 0
    /// Subset of `systemPromptTokens`: the installed-skills section.
    var skillsTokens: Int = 0

    // MARK: Compression

    /// Number of leading messages folded into the compressed summary (i.e. no
    /// longer sent verbatim). Zero when the session has never been compressed.
    var compressedMessageCount: Int = 0
    /// Estimated token size of the compressed-history summary that replaces
    /// those messages in the context window.
    var compressedSummaryTokens: Int = 0

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

    var billedTotalTokens: Int { knownBilledTotal ?? 0 }

    var fallbackTotalTokens: Int { fallbackInputTokens + fallbackOutputTokens }

    var estimatedTotalTokens: Int {
        systemTokens + userTokens + assistantTokens + toolTokens
    }

    /// True when at least one turn reported real API usage.
    var hasAPIUsage: Bool { turnsWithUsage > 0 }

    /// True when at least one assistant request needed a local usage estimate.
    var hasEstimatedUsage: Bool { turnsWithEstimatedUsage > 0 }

    /// Average billed output tokens per assistant turn with reported output usage.
    var averageOutputPerTurn: Int {
        turnsWithOutputUsage > 0 ? billedOutputTokens / turnsWithOutputUsage : 0
    }

    /// True when the provider reported any prompt-cache activity.
    var hasCacheActivity: Bool { cacheReadTokens > 0 || cacheWriteTokens > 0 }

    /// Fixed input sent on every turn on top of the conversation: system prompt
    /// plus tool schemas.
    var perTurnOverheadTokens: Int { systemPromptTokens + toolSchemaTokens }

    /// True once a request has been sent and the overhead was captured.
    var hasPerTurnOverhead: Bool { perTurnOverheadTokens > 0 }

    /// True when earlier messages have been compressed into a summary.
    var isCompressed: Bool { compressedMessageCount > 0 }

    /// Active context usage as a fraction of the compression threshold (0...1+).
    var contextUsageRatio: Double {
        guard contextThreshold > 0 else { return 0 }
        return Double(activeContextTokens) / Double(contextThreshold)
    }

    // MARK: Computation

    /// Aggregate statistics from a set of messages. Pure and SwiftData-agnostic
    /// so it is trivially unit-testable.
    ///
    /// When `compressedUpToIndex > 0`, locally-estimated input counts for turns
    /// after the compression boundary reflect the compressed summary (plus the
    /// pinned initial user message, if any) instead of re-counting messages that
    /// were already folded away.
    static func compute(
        from messages: [Message],
        compressedUpToIndex: Int = 0,
        compressedSummaryTokens: Int = 0
    ) -> TokenStatistics {
        var stats = TokenStatistics()
        stats.messageCount = messages.count

        let effectiveCompressedCount = min(max(compressedUpToIndex, 0), messages.count)
        var pinnedFirstUserTokens = 0
        var hasCapturedFirstUser = false
        var runningContextTokens = 0

        for (index, message) in messages.enumerated() {
            if effectiveCompressedCount > 0 && index == effectiveCompressedCount {
                runningContextTokens = compressedSummaryTokens + pinnedFirstUserTokens
            }

            let estimate = message.tokenEstimate > 0
                ? message.tokenEstimate
                : TokenEstimator.estimateMessage(message)

            switch message.role {
            case .system:
                stats.systemTokens += estimate
            case .user:
                stats.userTokens += estimate
                stats.userMessageCount += 1
                if !hasCapturedFirstUser {
                    hasCapturedFirstUser = true
                    if index < effectiveCompressedCount {
                        pinnedFirstUserTokens = estimate
                    }
                }
            case .assistant:
                stats.assistantTokens += estimate
                stats.assistantMessageCount += 1
                stats.addUsage(from: message, estimatedInput: runningContextTokens, estimatedOutput: estimate)
            case .tool:
                stats.toolTokens += estimate
                stats.toolMessageCount += 1
            }

            // Stored `.system` messages are not replayed in `ContextManager`
            // (system prompt overhead is accounted for via `perTurnOverheadTokens`).
            if message.role != .system {
                runningContextTokens += estimate
            }
        }

        return stats
    }

    private mutating func addUsage(from message: Message, estimatedInput: Int, estimatedOutput: Int) {
        let input = message.apiPromptTokens
        let output = message.apiCompletionTokens
        let total = message.apiTotalTokens
        if let input {
            billedInputTokens += input
            turnsWithInputUsage += 1
        }
        if let output {
            billedOutputTokens += output
            turnsWithOutputUsage += 1
        }
        let hasCounts = total != nil || input != nil || output != nil
        if hasCounts {
            let tokens = total ?? ((input ?? 0) + (output ?? 0))
            knownBilledTotal = (knownBilledTotal ?? 0) + tokens
        }
        if hasCounts || message.apiCacheReadTokens != nil || message.apiCacheWriteTokens != nil {
            turnsWithUsage += 1
        }
        cacheReadTokens += message.apiCacheReadTokens ?? 0
        cacheWriteTokens += message.apiCacheWriteTokens ?? 0

        // A provider total already accounts for the request even if neither
        // side was reported. Only estimate usage missing from the total.
        if total != nil, input == nil, output == nil { return }
        guard input == nil || output == nil else { return }
        turnsWithEstimatedUsage += 1
        if input == nil {
            turnsWithEstimatedInputUsage += 1
            fallbackInputTokens += estimatedInput
        }
        if output == nil {
            fallbackOutputTokens += estimatedOutput
        }
    }

    /// Convenience that also fills in the active-context figures and the
    /// per-turn fixed overhead (system prompt + tool schemas) captured on the
    /// session at send time.
    ///
    /// The overhead is read from stored fields rather than rebuilt here on
    /// purpose: reconstructing the system prompt would mean faulting the agent's
    /// relationships off the send path — expensive, and unsafe with a
    /// generation possibly mutating the context.
    static func compute(for session: Session, contextManager: ContextManager = ContextManager()) -> TokenStatistics {
        let compressedMessageCount = max(session.compressedUpToIndex, 0)
        let compressedSummaryTokens: Int
        if compressedMessageCount > 0, let compressed = session.compressedContext, !compressed.isEmpty {
            compressedSummaryTokens = TokenEstimator.estimate(compressed)
        } else {
            compressedSummaryTokens = 0
        }

        var stats = compute(
            from: session.sortedMessages,
            compressedUpToIndex: compressedMessageCount,
            compressedSummaryTokens: compressedSummaryTokens
        )
        stats.activeContextTokens = contextManager.activeContextTokens(session: session)
        stats.contextThreshold = session.agent?.effectiveCompressionThreshold ?? ContextManager.compressionThreshold
        stats.systemPromptTokens = session.lastSystemPromptTokens ?? 0
        stats.toolSchemaTokens = session.lastToolSchemaTokens ?? 0
        stats.configMarkdownTokens = session.lastConfigMarkdownTokens ?? 0
        stats.skillsTokens = session.lastSkillsTokens ?? 0
        // The fixed system/tool overhead is part of every prompt. Add it only
        // to locally-estimated calls; provider-reported input already includes it.
        stats.fallbackInputTokens += stats.perTurnOverheadTokens * stats.turnsWithEstimatedInputUsage

        stats.compressedMessageCount = compressedMessageCount
        stats.compressedSummaryTokens = compressedSummaryTokens
        return stats
    }

    /// Estimate the token cost of the tool/function JSON schemas sent with a
    /// request. Serializes the definitions the way they go over the wire and
    /// runs the same tokenizer used elsewhere; returns 0 when there are none.
    static func estimateToolSchemaTokens(_ tools: [LLMToolDefinition]) -> Int {
        guard !tools.isEmpty else { return 0 }
        guard let data = try? JSONEncoder().encode(tools),
              let json = String(data: data, encoding: .utf8) else { return 0 }
        return TokenEstimator.estimate(json)
    }

    /// Capture the per-turn fixed overhead (system prompt + config/skills
    /// attribution + tool schemas) on the session at send time. Shared by
    /// interactive chat, sub-agents, and cron executions.
    static func recordPerTurnOverhead(
        on session: Session,
        promptSections: [PromptBuilder.SystemPromptSection],
        systemPrompt: String,
        tools: [LLMToolDefinition]
    ) {
        session.lastSystemPromptTokens = TokenEstimator.estimate(systemPrompt)
        session.lastToolSchemaTokens = estimateToolSchemaTokens(tools)
        session.lastConfigMarkdownTokens = promptSections
            .filter { $0.kind == .config }
            .reduce(0) { $0 + TokenEstimator.estimate($1.text) }
        session.lastSkillsTokens = promptSections
            .filter { $0.kind == .skills }
            .reduce(0) { $0 + TokenEstimator.estimate($1.text) }
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
