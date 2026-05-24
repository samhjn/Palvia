import Foundation

/// Anthropic API adapter.
///
/// Handles the Anthropic-specific message format, extended thinking,
/// and streaming protocol differences.
final class AnthropicAdapter: LLMAPIAdapter, @unchecked Sendable {
    let context: LLMAdapterContext
    /// Accumulator for streaming tool calls. Reset per stream session.
    private var toolAccum = ToolCallAccumulator()
    /// Tracks block types during streaming for thinking vs text disambiguation.
    private var activeBlockTypes: [Int: String] = [:]

    init(context: LLMAdapterContext) {
        self.context = context
    }

    // MARK: - Non-streaming

    func buildChatRequest(
        model: String,
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]?,
        maxTokens: Int,
        temperature: Double,
        capabilities: ModelCapabilities,
        thinkingLevel: ThinkingLevel
    ) throws -> URLRequest {
        let anthropicReq = buildAnthropicBody(
            model: model, messages: messages, tools: tools,
            maxTokens: maxTokens, temperature: temperature,
            thinkingLevel: thinkingLevel, stream: false
        )
        return try buildAnthropicURLRequest(body: anthropicReq)
    }

    func parseChatResponse(data: Data) throws -> LLMChatResponse {
        let anthropicResp = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        return convertAnthropicResponse(anthropicResp)
    }

    // MARK: - Streaming

    func buildStreamRequest(
        model: String,
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]?,
        maxTokens: Int,
        temperature: Double,
        capabilities: ModelCapabilities,
        thinkingLevel: ThinkingLevel
    ) throws -> URLRequest {
        // Reset per-stream state
        toolAccum = ToolCallAccumulator()
        activeBlockTypes = [:]

        let anthropicReq = buildAnthropicBody(
            model: model, messages: messages, tools: tools,
            maxTokens: maxTokens, temperature: temperature,
            thinkingLevel: thinkingLevel, stream: true
        )
        return try buildAnthropicURLRequest(body: anthropicReq)
    }

    func processStreamEvent(_ event: SSEEvent) -> [StreamChunk] {
        switch event {
        case .message(let data):
            return processAnthropicMessage(data)
        case .done:
            var chunks: [StreamChunk] = []
            for toolCall in toolAccum.flush() {
                chunks.append(.toolCall(toolCall))
            }
            chunks.append(.done)
            return chunks
        }
    }

    // MARK: - Models

    func buildModelsRequest() throws -> URLRequest {
        try APIRequestBuilder.jsonGET(
            base: context.baseURL,
            path: "/models",
            apiKey: context.apiKey,
            style: .anthropic
        )
    }

    func parseModelsResponse(data: Data) throws -> [String] {
        if let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let models = json["data"] as? [[String: Any]] {
            return models.compactMap { $0["id"] as? String }.sorted()
        }
        return []
    }

    // MARK: - Stream Event Processing

    private func processAnthropicMessage(_ data: String) -> [StreamChunk] {
        guard let jsonData = data.data(using: .utf8),
              let streamEvent = try? JSONDecoder().decode(AnthropicStreamEvent.self, from: jsonData)
        else { return [] }

        var chunks: [StreamChunk] = []

        switch streamEvent.type {
        case "message_start":
            if let msgUsage = streamEvent.message?.usage,
               (msgUsage.inputTokens != nil || msgUsage.outputTokens != nil) {
                chunks.append(.usage(LLMUsage(
                    promptTokens: msgUsage.inputTokens,
                    completionTokens: msgUsage.outputTokens,
                    totalTokens: nil,
                    cacheCreationInputTokens: msgUsage.cacheCreationInputTokens,
                    cacheReadInputTokens: msgUsage.cacheReadInputTokens
                )))
            }

        case "content_block_start":
            if let idx = streamEvent.index, let block = streamEvent.contentBlock {
                activeBlockTypes[idx] = block.type
                if block.type == "tool_use" {
                    toolAccum.accumulate(
                        index: idx,
                        id: block.id ?? "call_\(UUID().uuidString.prefix(8))",
                        name: block.name,
                        arguments: nil
                    )
                }
            }

        case "content_block_delta":
            if let idx = streamEvent.index, let delta = streamEvent.delta {
                let blockType = activeBlockTypes[idx] ?? delta.type
                switch delta.type {
                case "text_delta":
                    if blockType == "thinking" {
                        if let text = delta.text { chunks.append(.thinking(text)) }
                    } else {
                        if let text = delta.text { chunks.append(.content(text)) }
                    }
                case "thinking_delta":
                    if let text = delta.thinking { chunks.append(.thinking(text)) }
                case "signature_delta":
                    if let sig = delta.signature, !sig.isEmpty {
                        chunks.append(.thinkingSignature(sig))
                    }
                case "input_json_delta":
                    if let json = delta.partialJson {
                        toolAccum.accumulate(index: idx, id: nil, name: nil, arguments: json)
                    }
                default:
                    break
                }
            }

        case "content_block_stop":
            break

        case "message_delta":
            if let usage = streamEvent.usage,
               (usage.inputTokens != nil || usage.outputTokens != nil) {
                chunks.append(.usage(LLMUsage(
                    promptTokens: usage.inputTokens,
                    completionTokens: usage.outputTokens,
                    totalTokens: nil,
                    cacheCreationInputTokens: usage.cacheCreationInputTokens,
                    cacheReadInputTokens: usage.cacheReadInputTokens
                )))
            }
            if let stopReason = streamEvent.delta?.stopReason,
               (stopReason == "tool_use" || stopReason == "tool_calls"),
               toolAccum.hasPending {
                for toolCall in toolAccum.flush() {
                    chunks.append(.toolCall(toolCall))
                }
            }

        case "message_stop":
            for toolCall in toolAccum.flush() {
                chunks.append(.toolCall(toolCall))
            }
            chunks.append(.done)

        case "error":
            chunks.append(.error(data))

        default:
            break
        }

        return chunks
    }

    // MARK: - Anthropic Body Building

    private func buildAnthropicBody(
        model: String,
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]?,
        maxTokens: Int,
        temperature: Double,
        thinkingLevel: ThinkingLevel,
        stream: Bool
    ) -> AnthropicRequest {
        var systemBlocks: [AnthropicSystemBlock] = []
        var anthropicMessages: [AnthropicMessage] = []

        for msg in messages {
            switch msg.role {
            case .system:
                if let content = msg.content, !content.isEmpty {
                    systemBlocks.append(AnthropicSystemBlock(type: "text", text: content))
                }
            case .user:
                var blocks: [AnthropicContentBlock] = []
                if let parts = msg.contentParts, !parts.isEmpty {
                    for part in parts {
                        switch part {
                        case .text(let text):
                            if !text.isEmpty { blocks.append(.text(text)) }
                        case .imageURL(let url, _):
                            if let parsed = parseBase64DataURI(url) {
                                blocks.append(.image(mediaType: parsed.mediaType, data: parsed.data))
                            }
                        case .videoURL:
                            break
                        }
                    }
                } else if let content = msg.content, !content.isEmpty {
                    blocks.append(.text(content))
                }
                if !blocks.isEmpty {
                    anthropicMessages.append(AnthropicMessage(role: "user", content: blocks))
                }
            case .assistant:
                var blocks: [AnthropicContentBlock] = []
                // Echo any prior thinking trace back. Sending it broadly is
                // harmless (Anthropic & DeepSeek both tolerate it on non-tool
                // turns) and matches the OpenAI-compat path's behavior for
                // `reasoning_content` (cb1ec24). Per spec the thinking block
                // must precede text/tool_use.
                if let reasoning = msg.reasoningContent, !reasoning.isEmpty {
                    blocks.append(.thinking(text: reasoning, signature: msg.thinkingSignature))
                }
                if let content = msg.content, !content.isEmpty {
                    blocks.append(.text(content))
                }
                if let toolCalls = msg.toolCalls {
                    for tc in toolCalls {
                        blocks.append(.toolUse(id: tc.id, name: tc.function.name, input: tc.function.arguments))
                    }
                }
                if !blocks.isEmpty {
                    anthropicMessages.append(AnthropicMessage(role: "assistant", content: blocks))
                }
            case .tool:
                let toolUseId = msg.toolCallId ?? ""
                let block: AnthropicContentBlock

                if let parts = msg.contentParts,
                   parts.contains(where: { if case .imageURL = $0 { return true }; return false }) {
                    var blocks: [AnthropicToolResultBlock] = []
                    for part in parts {
                        switch part {
                        case .text(let text):
                            if !text.isEmpty { blocks.append(.text(text)) }
                        case .imageURL(let url, _):
                            if let parsed = parseBase64DataURI(url) {
                                blocks.append(.image(mediaType: parsed.mediaType, data: parsed.data))
                            }
                        case .videoURL:
                            break
                        }
                    }
                    block = .toolResultRich(toolUseId: toolUseId, blocks: blocks)
                } else {
                    let content = msg.content ?? ""
                    block = .toolResult(toolUseId: toolUseId, content: content)
                }

                let isToolResultBlock: (AnthropicContentBlock) -> Bool = {
                    switch $0 {
                    case .toolResult, .toolResultRich: return true
                    default: return false
                    }
                }
                if let last = anthropicMessages.last, last.role == "user",
                   last.content.allSatisfy(isToolResultBlock) {
                    var merged = last.content
                    merged.append(block)
                    anthropicMessages[anthropicMessages.count - 1] = AnthropicMessage(role: "user", content: merged)
                } else {
                    anthropicMessages.append(AnthropicMessage(role: "user", content: [block]))
                }
            }
        }

        anthropicMessages = mergeConsecutiveRoles(anthropicMessages)

        var anthropicTools: [AnthropicTool]? = nil
        if let tools = tools, !tools.isEmpty {
            anthropicTools = tools.map {
                AnthropicTool(name: $0.function.name, description: $0.function.description, inputSchema: $0.function.parameters)
            }
        }

        // Pick the correct thinking-parameter shape for this model. Newer
        // Claude variants prefer `output_config.effort` (Opus 4.7 mandates it
        // — manual `thinking.enabled` is rejected), Opus 4.5 still takes
        // `budget_tokens` but layers `effort` on top, DeepSeek v4 uses an
        // effort-plus-switch shape with no `budget_tokens`, and older models
        // only know about manual extended thinking.
        //
        // DeepSeek's Anthropic-compat silently enables thinking when the
        // field is omitted, so we keep emitting an explicit `thinking`
        // payload on every request. For Mythos Preview (which rejects
        // `type:"disabled"`) the resolution lives in the strategy table.
        let strategy = AnthropicThinkingStrategy.resolve(for: model)
        let effortSupport = EffortLevelSupport.forModel(model, apiStyle: .anthropic)
        let resolvedThinking = resolveThinkingPayload(
            level: thinkingLevel,
            strategy: strategy,
            effortSupport: effortSupport
        )
        let thinking = resolvedThinking.thinking
        let outputConfig = resolvedThinking.outputConfig

        var effectiveMaxTokens = maxTokens
        let effectiveTemperature: Double
        if thinkingLevel.isEnabled {
            // Anthropic requires temperature == 1.0 whenever extended
            // thinking (manual or adaptive) is on.
            effectiveTemperature = 1.0
            // Manual thinking still needs `max_tokens > budget_tokens`.
            // Adaptive thinking has no explicit budget — we leave the
            // user-provided cap alone, with one nudge on `xhigh`/`max` so
            // the model actually has room to reason. Anthropic's guidance
            // for Opus 4.7 at `xhigh`/`max` is "start at 64k".
            if let budget = resolvedThinking.budgetTokens {
                effectiveMaxTokens = max(effectiveMaxTokens, budget + 1)
            } else if thinkingLevel == .xhigh || thinkingLevel == .max {
                effectiveMaxTokens = max(effectiveMaxTokens, 64_000)
            }
        } else {
            effectiveTemperature = temperature
        }

        // -- Apply prompt-caching breakpoints --
        // Breakpoint 1: last system block (caches the full system prompt)
        if !systemBlocks.isEmpty {
            systemBlocks[systemBlocks.count - 1].cacheControl = .ephemeral
        }

        // Breakpoint 2: last tool definition (caches system + tools)
        if var tools = anthropicTools, !tools.isEmpty {
            tools[tools.count - 1].cacheControl = .ephemeral
            anthropicTools = tools
        }

        // Breakpoint 3: penultimate user turn (caches conversation prefix)
        // Find the second-to-last user message so that only the final
        // user turn is uncached — maximising cache hits across turns.
        let userIndices = anthropicMessages.indices.filter { anthropicMessages[$0].role == "user" }
        if userIndices.count >= 2 {
            let penultimateIdx = userIndices[userIndices.count - 2]
            anthropicMessages[penultimateIdx].cacheControlOnLast = .ephemeral
        }

        return AnthropicRequest(
            model: model,
            maxTokens: effectiveMaxTokens,
            system: systemBlocks.isEmpty ? nil : systemBlocks,
            messages: anthropicMessages,
            tools: anthropicTools,
            stream: stream,
            temperature: effectiveTemperature,
            thinking: thinking,
            outputConfig: outputConfig
        )
    }

    // MARK: - Thinking payload resolution

    /// Outcome of resolving a `ThinkingLevel` against a model's thinking
    /// strategy. `budgetTokens` is non-nil only for manual extended thinking
    /// and informs the `max_tokens` floor.
    private struct ResolvedThinking {
        let thinking: AnthropicThinking?
        let outputConfig: AnthropicOutputConfig?
        let budgetTokens: Int?
    }

    private func resolveThinkingPayload(
        level: ThinkingLevel,
        strategy: AnthropicThinkingStrategy,
        effortSupport: EffortLevelSupport
    ) -> ResolvedThinking {
        let effortValue: String? = effortSupport.supportsEffort
            ? clampEffort(level: level, effortSupport: effortSupport)
            : nil
        let outputConfig = effortValue.map(AnthropicOutputConfig.init(effort:))

        switch strategy {
        case .manual:
            // Legacy Claude: budget_tokens only. No effort param.
            if level.isEnabled {
                let budget = level.anthropicBudgetTokens
                return ResolvedThinking(
                    thinking: .enabled(budget: budget),
                    outputConfig: nil,
                    budgetTokens: budget
                )
            }
            return ResolvedThinking(thinking: .disabled, outputConfig: nil, budgetTokens: nil)

        case .manualWithEffort:
            // Opus 4.5: manual extended thinking + effort.
            if level.isEnabled {
                let budget = level.anthropicBudgetTokens
                return ResolvedThinking(
                    thinking: .enabled(budget: budget),
                    outputConfig: outputConfig,
                    budgetTokens: budget
                )
            }
            // Off: keep effort low so this model still respects the
            // user's intent to minimise spend, but disable thinking.
            return ResolvedThinking(
                thinking: .disabled,
                outputConfig: AnthropicOutputConfig(effort: "low"),
                budgetTokens: nil
            )

        case .adaptive:
            // Opus 4.6 / Sonnet 4.6 / Opus 4.7+: adaptive thinking + effort.
            // Manual `enabled` would be rejected on Opus 4.7, so we never
            // emit it for this strategy.
            if level.isEnabled {
                return ResolvedThinking(
                    thinking: .adaptive,
                    outputConfig: outputConfig,
                    budgetTokens: nil
                )
            }
            return ResolvedThinking(
                thinking: .disabled,
                outputConfig: AnthropicOutputConfig(effort: "low"),
                budgetTokens: nil
            )

        case .effortSwitch:
            // DeepSeek v4 in Anthropic-compat: explicit thinking switch +
            // effort. Crucially: no `budget_tokens` (DeepSeek rejects it).
            if level.isEnabled {
                return ResolvedThinking(
                    thinking: AnthropicThinking(type: "enabled", budgetTokens: nil),
                    outputConfig: outputConfig,
                    budgetTokens: nil
                )
            }
            return ResolvedThinking(
                thinking: .disabled,
                outputConfig: AnthropicOutputConfig(effort: "low"),
                budgetTokens: nil
            )
        }
    }

    /// Map a `ThinkingLevel` to the literal `effort` string accepted by the
    /// model, downgrading `xhigh`/`max` when the model does not advertise
    /// support. Returns nil for `.off`.
    private func clampEffort(level: ThinkingLevel, effortSupport: EffortLevelSupport) -> String? {
        guard let raw = level.anthropicEffort else { return nil }
        switch level {
        case .xhigh:
            return effortSupport.supportsXHigh ? raw : "high"
        case .max:
            return effortSupport.supportsMax ? raw : "high"
        default:
            return raw
        }
    }

    // MARK: - Helpers

    private func mergeConsecutiveRoles(_ messages: [AnthropicMessage]) -> [AnthropicMessage] {
        var result: [AnthropicMessage] = []
        for msg in messages {
            if let last = result.last, last.role == msg.role {
                var merged = last.content
                merged.append(contentsOf: msg.content)
                result[result.count - 1] = AnthropicMessage(role: msg.role, content: merged)
            } else {
                result.append(msg)
            }
        }
        return result
    }

    private func convertAnthropicResponse(_ resp: AnthropicResponse) -> LLMChatResponse {
        var content = ""
        var toolCalls: [LLMToolCall] = []
        var thinkingText = ""
        var thinkingSignature: String?

        for block in resp.content {
            switch block.type {
            case "text":
                content += block.text ?? ""
            case "thinking":
                thinkingText += block.thinking ?? ""
                if let sig = block.signature, !sig.isEmpty {
                    thinkingSignature = sig
                }
            case "tool_use":
                let args = block.input?.jsonString ?? "{}"
                toolCalls.append(LLMToolCall(
                    id: block.id ?? "call_\(UUID().uuidString.prefix(8))",
                    name: block.name ?? "",
                    arguments: args
                ))
            default:
                break
            }
        }

        let message = LLMChatMessage(
            role: .assistant,
            content: content.isEmpty ? nil : content,
            toolCalls: toolCalls.isEmpty ? nil : toolCalls,
            reasoningContent: thinkingText.isEmpty ? nil : thinkingText,
            thinkingSignature: thinkingSignature
        )
        let choice = LLMChoice(index: 0, message: message, delta: nil, finishReason: resp.stopReason)
        let usage = LLMUsage(
            promptTokens: resp.usage?.inputTokens,
            completionTokens: resp.usage?.outputTokens,
            totalTokens: nil,
            cacheCreationInputTokens: resp.usage?.cacheCreationInputTokens,
            cacheReadInputTokens: resp.usage?.cacheReadInputTokens
        )
        return LLMChatResponse(id: resp.id, choices: [choice], usage: usage)
    }

    private func parseBase64DataURI(_ uri: String) -> (mediaType: String, data: String)? {
        guard uri.hasPrefix("data:") else { return nil }
        let withoutPrefix = String(uri.dropFirst(5))
        guard let semicolonIdx = withoutPrefix.firstIndex(of: ";") else { return nil }
        let mediaType = String(withoutPrefix[withoutPrefix.startIndex..<semicolonIdx])
        let afterSemicolon = String(withoutPrefix[withoutPrefix.index(after: semicolonIdx)...])
        guard afterSemicolon.hasPrefix("base64,") else { return nil }
        let data = String(afterSemicolon.dropFirst(7))
        return (mediaType, data)
    }

    private func buildAnthropicURLRequest<T: Encodable>(body: T) throws -> URLRequest {
        let bodyData = try APIRequestBuilder.stableJSONEncoder.encode(body)
        return try APIRequestBuilder.jsonPOST(
            base: context.baseURL,
            path: "/messages",
            apiKey: context.apiKey,
            style: .anthropic,
            body: bodyData
        )
    }
}
