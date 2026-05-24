import Foundation

/// Protocol defining the API-specific operations for an LLM provider.
///
/// Each API style (OpenAI, Anthropic, Gemini, etc.) implements this protocol
/// to handle its specific request/response formats while sharing common
/// infrastructure (streaming, tool call accumulation, etc.) via `LLMService`.
protocol LLMAPIAdapter: Sendable {

    /// Build a non-streaming chat completion request.
    func buildChatRequest(
        model: String,
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]?,
        maxTokens: Int,
        temperature: Double,
        capabilities: ModelCapabilities,
        thinkingLevel: ThinkingLevel
    ) throws -> URLRequest

    /// Parse a non-streaming chat completion response.
    func parseChatResponse(data: Data) throws -> LLMChatResponse

    /// Build a streaming chat completion request.
    func buildStreamRequest(
        model: String,
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]?,
        maxTokens: Int,
        temperature: Double,
        capabilities: ModelCapabilities,
        thinkingLevel: ThinkingLevel
    ) throws -> URLRequest

    /// Process a single SSE event into stream chunks.
    func processStreamEvent(_ event: SSEEvent) -> [StreamChunk]

    /// Build a request to fetch available models.
    func buildModelsRequest() throws -> URLRequest

    /// Parse the models list response.
    func parseModelsResponse(data: Data) throws -> [String]
}

/// Context passed to adapters for request building.
struct LLMAdapterContext: Sendable {
    let baseURL: String
    let apiKey: String

    init(provider: LLMProvider) {
        self.baseURL = provider.endpoint
        self.apiKey = provider.apiKey
    }

    /// Memberwise init — usable from tests without spinning up a SwiftData
    /// `LLMProvider` instance.
    init(baseURL: String, apiKey: String) {
        self.baseURL = baseURL
        self.apiKey = apiKey
    }
}
