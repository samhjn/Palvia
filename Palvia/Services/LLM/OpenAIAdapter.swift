import Foundation

/// OpenAI-compatible API adapter.
///
/// Handles request/response formatting for OpenAI, OpenRouter,
/// and other OpenAI-compatible endpoints.
final class OpenAIAdapter: LLMAPIAdapter, @unchecked Sendable {
    let context: LLMAdapterContext
    /// Accumulator for streaming tool calls. Reset per stream session.
    private var toolAccum = ToolCallAccumulator()

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
        let modalities: [String]? = capabilities.imageGenerationMode == .chatInline ? ["image", "text"] : nil
        let (effortValue, thinkingSwitch) = openAIEffortFields(model: model, level: thinkingLevel)
        let request = LLMChatRequest(
            model: model,
            messages: messages,
            tools: tools?.isEmpty == true ? nil : tools,
            toolChoice: (tools != nil && tools?.isEmpty == false) ? .auto : nil,
            stream: false,
            maxTokens: maxTokens,
            temperature: temperature,
            modalities: modalities,
            reasoningEffort: effortValue,
            thinking: thinkingSwitch
        )

        let bodyData = try APIRequestBuilder.stableJSONEncoder.encode(request)
        return try APIRequestBuilder.jsonPOST(
            base: context.baseURL,
            path: "/chat/completions",
            apiKey: context.apiKey,
            style: .openAI,
            body: bodyData
        )
    }

    /// Pick the right `reasoning_effort` value and optional `thinking`
    /// switch for this model. DeepSeek v4 takes the unclamped `xhigh`/`max`
    /// levels and an explicit thinking switch (default-on otherwise leaks);
    /// plain o-series collapses xhigh/max to `"high"` and never sends the
    /// switch (unknown fields = 400 on most other endpoints).
    private func openAIEffortFields(model: String, level: ThinkingLevel)
        -> (effort: String?, thinking: OpenAIThinkingSwitch?)
    {
        let support = EffortLevelSupport.forModel(model, apiStyle: .openAI)
        if support.supportsExplicitThinkingSwitch {
            let switchField: OpenAIThinkingSwitch = level.isEnabled ? .enabled : .disabled
            return (level.anthropicEffort, switchField)
        }
        return (level.openAIReasoningEffort, nil)
    }

    func parseChatResponse(data: Data) throws -> LLMChatResponse {
        try JSONDecoder().decode(LLMChatResponse.self, from: data)
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
        let modalities: [String]? = capabilities.imageGenerationMode == .chatInline ? ["image", "text"] : nil
        let (effortValue, thinkingSwitch) = openAIEffortFields(model: model, level: thinkingLevel)
        let request = LLMChatRequest(
            model: model,
            messages: messages,
            tools: tools?.isEmpty == true ? nil : tools,
            toolChoice: (tools != nil && tools?.isEmpty == false) ? .auto : nil,
            stream: true,
            streamOptions: LLMStreamOptions(includeUsage: true),
            maxTokens: maxTokens,
            temperature: temperature,
            modalities: modalities,
            reasoningEffort: effortValue,
            thinking: thinkingSwitch
        )

        let bodyData = try APIRequestBuilder.stableJSONEncoder.encode(request)
        return try APIRequestBuilder.jsonPOST(
            base: context.baseURL,
            path: "/chat/completions",
            apiKey: context.apiKey,
            style: .openAI,
            body: bodyData
        )
    }

    func processStreamEvent(_ event: SSEEvent) -> [StreamChunk] {
        switch event {
        case .message(let data):
            return processOpenAIMessage(data)
        case .done:
            var chunks: [StreamChunk] = []
            for toolCall in toolAccum.flush() {
                chunks.append(.toolCall(toolCall))
            }
            chunks.append(.done)
            return chunks
        }
    }

    private func processOpenAIMessage(_ data: String) -> [StreamChunk] {
        guard let jsonData = data.data(using: .utf8),
              let chunk = try? JSONDecoder().decode(LLMChatResponse.self, from: jsonData)
        else { return [] }

        var chunks: [StreamChunk] = []

        if let delta = chunk.choices.first?.delta {
            if let reasoning = delta.reasoningContent {
                chunks.append(.thinking(reasoning))
            }
            if let content = delta.content {
                chunks.append(.content(content))
            }
            if let deltaToolCalls = delta.toolCalls {
                for dtc in deltaToolCalls {
                    toolAccum.accumulate(
                        index: dtc.index,
                        id: dtc.id,
                        name: dtc.function?.name,
                        arguments: dtc.function?.arguments
                    )
                }
            }
        }

        if let usage = chunk.usage,
           (usage.promptTokens != nil || usage.completionTokens != nil || usage.totalTokens != nil) {
            chunks.append(.usage(usage))
        }

        if let reason = chunk.choices.first?.finishReason,
           isToolCallFinishReason(reason),
           toolAccum.hasPending {
            for toolCall in toolAccum.flush() {
                chunks.append(.toolCall(toolCall))
            }
        }

        return chunks
    }

    private func isToolCallFinishReason(_ reason: String) -> Bool {
        reason == "tool_calls" || reason == "tool_call" || reason == "function_call"
    }

    // MARK: - Models

    func buildModelsRequest() throws -> URLRequest {
        try APIRequestBuilder.jsonGET(
            base: context.baseURL,
            path: "/models",
            apiKey: context.apiKey,
            style: .openAI
        )
    }

    func parseModelsResponse(data: Data) throws -> [String] {
        let response = try JSONDecoder().decode(ModelsListResponse.self, from: data)
        return response.data.map(\.id).sorted()
    }
}
