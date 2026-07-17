import Foundation

/// OpenAI Responses API adapter.
///
/// This is intentionally separate from `OpenAIAdapter`: most third-party
/// "OpenAI compatible" providers implement Chat Completions but not the
/// newer `/responses` wire protocol.
final class OpenAIResponsesAdapter: LLMAPIAdapter, @unchecked Sendable {
    let context: LLMAdapterContext

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
        let request = OpenAIResponsesRequest(
            model: model,
            input: OpenAIResponsesInputMapper.inputItems(from: messages),
            tools: OpenAIResponsesInputMapper.tools(from: tools),
            stream: false,
            maxOutputTokens: maxTokens,
            temperature: temperature,
            reasoning: thinkingLevel.openAIReasoningEffort.map { OpenAIResponsesReasoning(effort: $0) }
        )
        let bodyData = try APIRequestBuilder.stableJSONEncoder.encode(request)
        return try APIRequestBuilder.jsonPOST(
            base: context.baseURL,
            path: "/responses",
            apiKey: context.apiKey,
            style: .openAIResponses,
            body: bodyData
        )
    }

    func parseChatResponse(data: Data) throws -> LLMChatResponse {
        let response = try JSONDecoder().decode(OpenAIResponsesResponse.self, from: data)
        return response.asChatResponse()
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
        let request = OpenAIResponsesRequest(
            model: model,
            input: OpenAIResponsesInputMapper.inputItems(from: messages),
            tools: OpenAIResponsesInputMapper.tools(from: tools),
            stream: true,
            maxOutputTokens: maxTokens,
            temperature: temperature,
            reasoning: thinkingLevel.openAIReasoningEffort.map { OpenAIResponsesReasoning(effort: $0) }
        )
        let bodyData = try APIRequestBuilder.stableJSONEncoder.encode(request)
        return try APIRequestBuilder.jsonPOST(
            base: context.baseURL,
            path: "/responses",
            apiKey: context.apiKey,
            style: .openAIResponses,
            body: bodyData
        )
    }

    func processStreamEvent(_ event: SSEEvent) -> [StreamChunk] {
        switch event {
        case .message(let data):
            return processResponsesMessage(data)
        case .done:
            return [.done]
        }
    }

    private func processResponsesMessage(_ data: String) -> [StreamChunk] {
        guard let jsonData = data.data(using: .utf8),
              let event = try? JSONDecoder().decode(OpenAIResponsesStreamEvent.self, from: jsonData)
        else { return [] }

        switch event.type {
        case "response.output_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return [] }
            return [.content(delta)]
        case "response.reasoning_summary_text.delta", "response.reasoning_text.delta":
            guard let delta = event.delta, !delta.isEmpty else { return [] }
            return [.thinking(delta)]
        case "response.output_item.done":
            if let toolCall = event.item?.asToolCall() {
                return [.toolCall(toolCall)]
            }
            return []
        case "response.completed":
            var chunks: [StreamChunk] = []
            if let usage = event.response?.usage?.asLLMUsage {
                chunks.append(.usage(usage))
            }
            chunks.append(.finishReason(.stop))
            chunks.append(.done)
            return chunks
        case "response.incomplete":
            var chunks: [StreamChunk] = []
            if let usage = event.response?.usage?.asLLMUsage {
                chunks.append(.usage(usage))
            }
            let reason = event.response?.incompleteDetails?.reason ?? event.type
            let finishReason = StreamFinishReason(rawValue: reason)
            if finishReason.isOutputLimit {
                chunks.append(.finishReason(finishReason))
                chunks.append(.done)
            } else {
                chunks.append(.error(event.error?.message ?? reason))
            }
            return chunks
        case "response.failed":
            return [.error(event.error?.message ?? event.response?.incompleteDetails?.reason ?? event.type)]
        default:
            // Forward-compatible: ignore event types that do not map to the
            // app's current streaming abstraction.
            return []
        }
    }

    // MARK: - Models

    func buildModelsRequest() throws -> URLRequest {
        try APIRequestBuilder.jsonGET(
            base: context.baseURL,
            path: "/models",
            apiKey: context.apiKey,
            style: .openAIResponses
        )
    }

    func parseModelsResponse(data: Data) throws -> [String] {
        let response = try JSONDecoder().decode(ModelsListResponse.self, from: data)
        return response.data.map(\.id).sorted()
    }
}

// MARK: - Request types

private struct OpenAIResponsesRequest: Encodable {
    let model: String
    let input: [OpenAIResponsesInputItem]
    var tools: [OpenAIResponsesTool]?
    var stream: Bool?
    var maxOutputTokens: Int?
    var temperature: Double?
    var reasoning: OpenAIResponsesReasoning?

    enum CodingKeys: String, CodingKey {
        case model, input, tools, stream, temperature, reasoning
        case maxOutputTokens = "max_output_tokens"
    }
}

private struct OpenAIResponsesReasoning: Encodable {
    let effort: String?
}

private enum OpenAIResponsesInputItem: Encodable {
    case message(role: String, content: [OpenAIResponsesInputContent])
    case functionCall(callID: String, name: String, arguments: String)
    case functionCallOutput(callID: String, output: String)

    enum CodingKeys: String, CodingKey {
        case type, role, content, name, arguments, output
        case callID = "call_id"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .message(let role, let content):
            try container.encode("message", forKey: .type)
            try container.encode(role, forKey: .role)
            try container.encode(content, forKey: .content)
        case .functionCall(let callID, let name, let arguments):
            try container.encode("function_call", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(name, forKey: .name)
            try container.encode(arguments, forKey: .arguments)
        case .functionCallOutput(let callID, let output):
            try container.encode("function_call_output", forKey: .type)
            try container.encode(callID, forKey: .callID)
            try container.encode(output, forKey: .output)
        }
    }
}

private enum OpenAIResponsesInputContent: Encodable {
    case inputText(String)
    case inputImage(url: String, detail: String?)

    enum CodingKeys: String, CodingKey {
        case type, text, detail
        case imageURL = "image_url"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .inputText(let text):
            try container.encode("input_text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .inputImage(let url, let detail):
            try container.encode("input_image", forKey: .type)
            try container.encode(url, forKey: .imageURL)
            try container.encodeIfPresent(detail, forKey: .detail)
        }
    }
}

private struct OpenAIResponsesTool: Encodable {
    let type: String
    let name: String
    let description: String
    let parameters: JSONSchema
}

private enum OpenAIResponsesInputMapper {
    static func inputItems(from messages: [LLMChatMessage]) -> [OpenAIResponsesInputItem] {
        messages.flatMap { message -> [OpenAIResponsesInputItem] in
            if message.role == .tool, let toolCallID = message.toolCallId {
                return [.functionCallOutput(callID: toolCallID, output: message.content ?? "")]
            }

            if let toolCalls = message.toolCalls, !toolCalls.isEmpty {
                return toolCalls.map { toolCall in
                    .functionCall(
                        callID: toolCall.id,
                        name: toolCall.function.name,
                        arguments: toolCall.function.arguments
                    )
                }
            }

            var content: [OpenAIResponsesInputContent] = []
            if let parts = message.contentParts, !parts.isEmpty {
                for part in parts {
                    switch part {
                    case .text(let text):
                        content.append(.inputText(text))
                    case .imageURL(let url, let detail):
                        content.append(.inputImage(url: url, detail: detail))
                    case .videoURL(let url):
                        // Responses supports rich input items; keep current app
                        // behavior conservative by sending the media URI as text
                        // until a dedicated video input mapping is added.
                        content.append(.inputText(url))
                    }
                }
            } else if let text = message.content {
                content.append(.inputText(text))
            }

            guard !content.isEmpty else { return [] }
            return [.message(role: message.role.rawValue, content: content)]
        }
    }

    static func tools(from tools: [LLMToolDefinition]?) -> [OpenAIResponsesTool]? {
        guard let tools, !tools.isEmpty else { return nil }
        return tools.map { tool in
            OpenAIResponsesTool(
                type: tool.type,
                name: tool.function.name,
                description: tool.function.description,
                parameters: tool.function.parameters
            )
        }
    }
}

// MARK: - Response types

private struct OpenAIResponsesResponse: Decodable {
    let id: String?
    let output: [OpenAIResponsesOutputItem]?
    let usage: OpenAIResponsesUsage?
    let incompleteDetails: OpenAIResponsesIncompleteDetails?

    enum CodingKeys: String, CodingKey {
        case id, output, usage
        case incompleteDetails = "incomplete_details"
    }

    func asChatResponse() -> LLMChatResponse {
        var textParts: [String] = []
        var toolCalls: [LLMToolCall] = []

        for item in output ?? [] {
            if let text = item.outputText, !text.isEmpty {
                textParts.append(text)
            }
            if let toolCall = item.asToolCall() {
                toolCalls.append(toolCall)
            }
        }

        let message = LLMChatMessage.assistant(
            textParts.joined(),
            toolCalls: toolCalls.isEmpty ? nil : toolCalls
        )
        let finishReason = toolCalls.isEmpty ? "stop" : "tool_calls"
        let choice = LLMChoice(index: 0, message: message, delta: nil, finishReason: finishReason)
        return LLMChatResponse(id: id, choices: [choice], usage: usage?.asLLMUsage)
    }
}

private struct OpenAIResponsesOutputItem: Decodable {
    let type: String?
    let id: String?
    let callID: String?
    let name: String?
    let arguments: String?
    let content: [OpenAIResponsesOutputContent]?

    enum CodingKeys: String, CodingKey {
        case type, id, name, arguments, content
        case callID = "call_id"
    }

    var outputText: String? {
        guard type == "message" else { return nil }
        return content?.compactMap(\.text).joined()
    }

    func asToolCall() -> LLMToolCall? {
        guard type == "function_call", let name, let arguments else { return nil }
        return LLMToolCall(id: callID ?? id ?? UUID().uuidString, name: name, arguments: arguments)
    }
}

private struct OpenAIResponsesOutputContent: Decodable {
    let type: String?
    let text: String?
}

private struct OpenAIResponsesUsage: Decodable {
    let inputTokens: Int?
    let outputTokens: Int?
    let totalTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case totalTokens = "total_tokens"
    }

    var asLLMUsage: LLMUsage {
        LLMUsage(promptTokens: inputTokens, completionTokens: outputTokens, totalTokens: totalTokens)
    }
}

private struct OpenAIResponsesIncompleteDetails: Decodable {
    let reason: String?
}

private struct OpenAIResponsesStreamEvent: Decodable {
    let type: String
    let delta: String?
    let item: OpenAIResponsesOutputItem?
    let response: OpenAIResponsesResponse?
    let error: OpenAIResponsesError?
}

private struct OpenAIResponsesError: Decodable {
    let message: String?
}
