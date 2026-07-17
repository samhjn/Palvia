import Foundation

enum StreamChunk {
    case content(String)
    case thinking(String)
    /// Anthropic-style thinking signature delivered after the thinking trace.
    /// Carried separately so the consumer can persist it alongside the text
    /// and replay both on the next request.
    case thinkingSignature(String)
    case toolCall(LLMToolCall)
    case usage(LLMUsage)
    /// Why the provider stopped generating. Kept separate from `.done` so
    /// callers can distinguish a natural completion from an output-token cap.
    case finishReason(StreamFinishReason)
    case done
    case error(String)
}

/// Provider-neutral stream termination reason.
enum StreamFinishReason: Equatable, Sendable {
    case stop
    case toolCalls
    case outputLimit
    case other(String)

    init(rawValue: String) {
        switch rawValue.lowercased() {
        case "stop", "end_turn", "completed":
            self = .stop
        case "tool_calls", "tool_call", "function_call", "tool_use":
            self = .toolCalls
        case "length", "max_tokens", "max_output_tokens":
            self = .outputLimit
        default:
            self = .other(rawValue)
        }
    }

    var isOutputLimit: Bool { self == .outputLimit }
}

/// Retry policy for HTTP 429 responses. Retries stay on the same provider;
/// router-level failover is attempted only after this policy is exhausted.
struct LLMRateLimitRetryPolicy: Sendable, Equatable {
    static let `default` = LLMRateLimitRetryPolicy()

    let maxRetries: Int
    let baseDelay: TimeInterval
    let maximumDelay: TimeInterval

    init(maxRetries: Int = 3, baseDelay: TimeInterval = 1, maximumDelay: TimeInterval = 30) {
        self.maxRetries = max(0, maxRetries)
        self.baseDelay = max(0, baseDelay)
        self.maximumDelay = max(0, maximumDelay)
    }

    func delay(retryAfter: String?, retryNumber: Int, now: Date = Date()) -> TimeInterval {
        if let retryAfter {
            let trimmed = retryAfter.trimmingCharacters(in: .whitespacesAndNewlines)
            if let seconds = TimeInterval(trimmed) {
                // Respect an explicit server hint even when it is longer than
                // our locally-capped exponential backoff.
                return max(0, seconds)
            }

            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "en_US_POSIX")
            formatter.timeZone = TimeZone(secondsFromGMT: 0)
            formatter.dateFormat = "EEE',' dd MMM yyyy HH':'mm':'ss zzz"
            if let date = formatter.date(from: trimmed) {
                return max(0, date.timeIntervalSince(now))
            }
        }

        let exponent = max(0, retryNumber)
        return min(baseDelay * pow(2, Double(exponent)), maximumDelay)
    }
}

/// Thread-safe holder for the inner SSE-reading Task, allowing external cancellation
/// that bypasses AsyncStream's cooperative cancellation.
final class StreamCancelState: @unchecked Sendable {
    private let lock = NSLock()
    private var _innerTask: Task<Void, Never>?
    private var _cancelled = false

    var innerTask: Task<Void, Never>? {
        get { lock.withLock { _innerTask } }
        set {
            lock.withLock {
                _innerTask = newValue
                if _cancelled { newValue?.cancel() }
            }
        }
    }

    func cancel() {
        lock.withLock {
            _cancelled = true
            _innerTask?.cancel()
        }
    }
}

final class LLMService: @unchecked Sendable {
    let provider: LLMProvider
    private let modelNameOverride: String?
    private let thinkingLevelOverride: ThinkingLevel?
    private let urlSession: URLSession
    private let rateLimitRetryPolicy: LLMRateLimitRetryPolicy
    private let retrySleeper: @Sendable (TimeInterval) async throws -> Void

    private var baseURL: String { provider.endpoint }
    private var apiKey: String { provider.apiKey }
    private var model: String { modelNameOverride ?? provider.modelName }
    private var apiStyle: APIStyle { provider.apiStyle }

    /// Model capabilities resolved for the effective model.
    var effectiveCapabilities: ModelCapabilities {
        provider.capabilities(for: model)
    }

    /// Effective thinking level: agent override > model default from capabilities.
    var effectiveThinkingLevel: ThinkingLevel {
        thinkingLevelOverride ?? effectiveCapabilities.thinkingLevel
    }

    /// Effective max tokens: per-model override > provider default.
    var effectiveMaxTokens: Int {
        effectiveCapabilities.maxTokens ?? provider.maxTokens
    }

    /// Effective temperature: per-model override > provider default.
    var effectiveTemperature: Double {
        effectiveCapabilities.temperature ?? provider.temperature
    }

    /// Create the appropriate API adapter for this provider's API style.
    private func createAdapter() -> LLMAPIAdapter {
        let ctx = LLMAdapterContext(provider: provider)
        switch apiStyle {
        case .anthropic:
            return AnthropicAdapter(context: ctx)
        case .openAIResponses:
            return OpenAIResponsesAdapter(context: ctx)
        case .openAI, .googleVeo, .dashScope, .kling, .seedance:
            // Video-specific protocols use OpenAI-compatible chat for any LLM operations
            return OpenAIAdapter(context: ctx)
        }
    }

    init(
        provider: LLMProvider,
        modelNameOverride: String? = nil,
        thinkingLevelOverride: ThinkingLevel? = nil,
        urlSession: URLSession = .shared,
        rateLimitRetryPolicy: LLMRateLimitRetryPolicy = .default,
        retrySleeper: (@Sendable (TimeInterval) async throws -> Void)? = nil
    ) {
        self.provider = provider
        self.modelNameOverride = modelNameOverride
        self.thinkingLevelOverride = thinkingLevelOverride
        self.urlSession = urlSession
        self.rateLimitRetryPolicy = rateLimitRetryPolicy
        self.retrySleeper = retrySleeper ?? { seconds in
            try Task.checkCancellation()
            guard seconds > 0 else { return }
            try await Task.sleep(for: .seconds(seconds))
        }
    }

    // MARK: - Fetch available models

    static func fetchModels(endpoint: String, apiKey: String, apiStyle: APIStyle = .openAI) async throws -> [String] {
        let ctx = LLMAdapterContext(provider: LLMProvider(name: "_temp", endpoint: endpoint, apiKey: apiKey))
        let adapter: LLMAPIAdapter
        switch apiStyle {
        case .anthropic: adapter = AnthropicAdapter(context: ctx)
        case .openAIResponses: adapter = OpenAIResponsesAdapter(context: ctx)
        case .openAI, .googleVeo, .dashScope, .kling, .seedance:
            adapter = OpenAIAdapter(context: ctx)
        }

        var request = try adapter.buildModelsRequest()
        request.timeoutInterval = 15

        let (data, response) = try await URLSession.shared.data(for: request)

        do {
            try APIRequestBuilder.validate(data: data, response: response)
        } catch let error as APIRequestError {
            throw LLMError.apiError(
                statusCode: error.statusCode ?? 0,
                message: error.messageBody ?? "Unknown error"
            )
        }

        return try adapter.parseModelsResponse(data: data)
    }

    // MARK: - Non-streaming

    func chatCompletion(
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]? = nil
    ) async throws -> LLMChatResponse {
        try await chatCompletion(messages: messages, tools: tools, rateLimitRetry: 0)
    }

    private func chatCompletion(
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]?,
        rateLimitRetry: Int
    ) async throws -> LLMChatResponse {
        let adapter = createAdapter()
        let caps = effectiveCapabilities
        let repairedMessages = ContextManager.repairDanglingToolCalls(in: messages)
        let adaptedMessages = adaptVideoContentParts(in: repairedMessages)

        let urlRequest = try adapter.buildChatRequest(
            model: model,
            messages: adaptedMessages,
            tools: tools,
            maxTokens: effectiveMaxTokens,
            temperature: effectiveTemperature,
            capabilities: caps,
            thinkingLevel: effectiveThinkingLevel
        )

        let (data, response) = try await urlSession.data(for: urlRequest)

        if let httpResponse = response as? HTTPURLResponse,
           httpResponse.statusCode == 429,
           rateLimitRetry < rateLimitRetryPolicy.maxRetries {
            let delay = rateLimitRetryPolicy.delay(
                retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                retryNumber: rateLimitRetry
            )
            try await retrySleeper(delay)
            return try await chatCompletion(
                messages: messages,
                tools: tools,
                rateLimitRetry: rateLimitRetry + 1
            )
        }

        do {
            try APIRequestBuilder.validate(data: data, response: response)
        } catch let error as APIRequestError {
            throw LLMError.apiError(
                statusCode: error.statusCode ?? 0,
                message: error.messageBody ?? "Unknown error"
            )
        }

        return try adapter.parseChatResponse(data: data)
    }

    // MARK: - Streaming

    func chatCompletionStream(
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]? = nil
    ) async throws -> (stream: AsyncStream<StreamChunk>, cancel: @Sendable () -> Void) {
        try await chatCompletionStream(messages: messages, tools: tools, rateLimitRetry: 0)
    }

    private func chatCompletionStream(
        messages: [LLMChatMessage],
        tools: [LLMToolDefinition]?,
        rateLimitRetry: Int
    ) async throws -> (stream: AsyncStream<StreamChunk>, cancel: @Sendable () -> Void) {
        let adapter = createAdapter()
        let caps = effectiveCapabilities
        let repairedMessages = ContextManager.repairDanglingToolCalls(in: messages)
        let adaptedMessages = adaptVideoContentParts(in: repairedMessages)

        let urlRequest = try adapter.buildStreamRequest(
            model: model,
            messages: adaptedMessages,
            tools: tools,
            maxTokens: effectiveMaxTokens,
            temperature: effectiveTemperature,
            capabilities: caps,
            thinkingLevel: effectiveThinkingLevel
        )

        let (bytes, response) = try await urlSession.bytes(for: urlRequest)

        guard let httpResponse = response as? HTTPURLResponse else {
            throw LLMError.invalidResponse
        }
        guard (200...299).contains(httpResponse.statusCode) else {
            var body = ""
            for try await line in bytes.lines { body += line }
            if httpResponse.statusCode == 429,
               rateLimitRetry < rateLimitRetryPolicy.maxRetries {
                let delay = rateLimitRetryPolicy.delay(
                    retryAfter: httpResponse.value(forHTTPHeaderField: "Retry-After"),
                    retryNumber: rateLimitRetry
                )
                try await retrySleeper(delay)
                return try await chatCompletionStream(
                    messages: messages,
                    tools: tools,
                    rateLimitRetry: rateLimitRetry + 1
                )
            }
            print("[LLMService] Stream error \(httpResponse.statusCode): \(body.prefix(300))")
            throw LLMError.apiError(statusCode: httpResponse.statusCode, message: body)
        }

        // Shared streaming infrastructure: SSE parsing + adapter dispatch
        let cancelState = StreamCancelState()
        let stream = AsyncStream<StreamChunk> { continuation in
            let innerTask = Task {
                var sseParser = SSEParser()

                do {
                    for try await line in bytes.lines {
                        guard !Task.isCancelled else { break }
                        let events = sseParser.parse(chunk: line + "\n\n")

                        for event in events {
                            let chunks = adapter.processStreamEvent(event)
                            for chunk in chunks {
                                continuation.yield(chunk)
                                if case .done = chunk {
                                    continuation.finish()
                                    return
                                }
                            }
                        }
                    }

                    // Stream ended without explicit [DONE]
                    let finalChunks = adapter.processStreamEvent(.done)
                    for chunk in finalChunks {
                        continuation.yield(chunk)
                    }
                    continuation.finish()
                } catch {
                    if !Task.isCancelled {
                        continuation.yield(.error(error.localizedDescription))
                    }
                    continuation.finish()
                }
            }
            cancelState.innerTask = innerTask
            continuation.onTermination = { @Sendable _ in
                innerTask.cancel()
            }
        }
        return (stream, { cancelState.cancel() })
    }

    // MARK: - Video Content Adaptation

    /// Adapts video content parts for the target provider/model before serialization.
    /// - Gemini (supportsVideoInput): converts `.videoURL` to `.imageURL` (Gemini accepts video
    ///   data URIs through the `image_url` content type in OpenAI-compatible mode).
    /// - Models without video support: strips `.videoURL` parts as a safety net.
    private func adaptVideoContentParts(in messages: [LLMChatMessage]) -> [LLMChatMessage] {
        let caps = effectiveCapabilities
        return messages.map { msg in
            guard let parts = msg.contentParts, parts.contains(where: { if case .videoURL = $0 { return true }; return false }) else {
                return msg
            }
            let adaptedParts: [ContentPart] = parts.compactMap { part in
                guard case .videoURL(let url) = part else { return part }
                if caps.supportsVideoInput {
                    return .imageURL(url: url, detail: nil)
                } else {
                    return nil
                }
            }
            return LLMChatMessage(
                role: msg.role,
                content: msg.content,
                contentParts: adaptedParts.isEmpty ? nil : adaptedParts,
                toolCalls: msg.toolCalls,
                toolCallId: msg.toolCallId,
                name: msg.name,
                reasoningContent: msg.reasoningContent,
                thinkingSignature: msg.thinkingSignature
            )
        }
    }
}

// MARK: - Models API response types

struct ModelsListResponse: Codable {
    let data: [ModelInfo]

    struct ModelInfo: Codable {
        let id: String
        let created: Int?
        let ownedBy: String?

        enum CodingKeys: String, CodingKey {
            case id, created
            case ownedBy = "owned_by"
        }
    }
}

enum LLMError: LocalizedError {
    case invalidURL(String)
    case invalidResponse
    case apiError(statusCode: Int, message: String)
    case decodingError(String)
    case videoTooLarge(message: String)
    case videoFormatUnsupported(message: String)

    var errorDescription: String? {
        switch self {
        case .invalidURL(let url): return "Invalid URL: \(url)"
        case .invalidResponse: return "Invalid response from server"
        case .apiError(let code, let msg): return "API Error (\(code)): \(msg)"
        case .decodingError(let msg): return "Decoding error: \(msg)"
        case .videoTooLarge(let msg): return "Video too large: \(msg)"
        case .videoFormatUnsupported(let msg): return "Unsupported video format: \(msg)"
        }
    }

    /// Detect if an API error is video-related based on the error message.
    var isVideoRelated: Bool {
        switch self {
        case .videoTooLarge, .videoFormatUnsupported:
            return true
        case .apiError(_, let msg):
            let lower = msg.lowercased()
            return lower.contains("video") || lower.contains("file size") || lower.contains("too large")
                || lower.contains("payload") || lower.contains("media")
        default:
            return false
        }
    }
}
