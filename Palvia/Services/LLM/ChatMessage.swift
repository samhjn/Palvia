import Foundation

// MARK: - Multimodal content parts

enum ContentPart: Codable {
    case text(String)
    case imageURL(url: String, detail: String?)
    case videoURL(url: String)

    enum CodingKeys: String, CodingKey {
        case type, text
        case imageUrl = "image_url"
        case videoUrl = "video_url"
    }

    struct ImageURLPayload: Codable {
        let url: String
        var detail: String?
    }

    struct VideoURLPayload: Codable {
        let url: String
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .imageURL(let url, let detail):
            try container.encode("image_url", forKey: .type)
            try container.encode(ImageURLPayload(url: url, detail: detail), forKey: .imageUrl)
        case .videoURL(let url):
            try container.encode("video_url", forKey: .type)
            try container.encode(VideoURLPayload(url: url), forKey: .videoUrl)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        let type = try container.decode(String.self, forKey: .type)
        switch type {
        case "image_url":
            let payload = try container.decode(ImageURLPayload.self, forKey: .imageUrl)
            self = .imageURL(url: payload.url, detail: payload.detail)
        case "video_url":
            let payload = try container.decode(VideoURLPayload.self, forKey: .videoUrl)
            self = .videoURL(url: payload.url)
        default:
            let text = try container.decodeIfPresent(String.self, forKey: .text) ?? ""
            self = .text(text)
        }
    }
}

// MARK: - OpenAI-compatible request/response types

struct LLMChatMessage: Codable {
    let role: MessageRole
    var content: String?
    var contentParts: [ContentPart]?
    var toolCalls: [LLMToolCall]?
    var toolCallId: String?
    var name: String?
    /// DeepSeek thinking-mode reasoning trace. Must be echoed back on
    /// subsequent requests for `deepseek-reasoner` / thinking-enabled
    /// `deepseek-chat`; ignored by other OpenAI-compatible providers.
    var reasoningContent: String?
    /// Anthropic-style thinking signature paired with `reasoningContent`.
    /// Captured from `signature` / `signature_delta` events; replayed inside
    /// the assistant's `thinking` content block so the API can verify the
    /// trace on tool-use multi-turn requests. Not part of the OpenAI wire
    /// format — purely an in-memory carrier.
    var thinkingSignature: String?

    enum CodingKeys: String, CodingKey {
        case role, content, name, images
        case toolCalls = "tool_calls"
        case toolCallId = "tool_call_id"
        case reasoningContent = "reasoning_content"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        if let parts = contentParts, !parts.isEmpty {
            try container.encode(parts, forKey: .content)
        } else if role == .assistant && toolCalls != nil {
            try container.encode(content, forKey: .content)
        } else if let content = content {
            try container.encode(content, forKey: .content)
        }

        if let toolCalls = toolCalls, !toolCalls.isEmpty {
            try container.encode(toolCalls, forKey: .toolCalls)
        }
        if let toolCallId = toolCallId {
            try container.encode(toolCallId, forKey: .toolCallId)
        }
        if let name = name {
            try container.encode(name, forKey: .name)
        }
        if let reasoningContent = reasoningContent, !reasoningContent.isEmpty {
            try container.encode(reasoningContent, forKey: .reasoningContent)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        // Decode role: try enum first, fall back to raw string for forward compat
        if let roleEnum = try? container.decode(MessageRole.self, forKey: .role) {
            role = roleEnum
        } else {
            let roleStr = try container.decode(String.self, forKey: .role)
            role = MessageRole(rawValue: roleStr) ?? .user
        }
        toolCalls = try container.decodeIfPresent([LLMToolCall].self, forKey: .toolCalls)
        toolCallId = try container.decodeIfPresent(String.self, forKey: .toolCallId)
        name = try container.decodeIfPresent(String.self, forKey: .name)
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
        thinkingSignature = nil

        var contentStr: String?
        if let str = try? container.decodeIfPresent(String.self, forKey: .content) {
            contentStr = str
            contentParts = nil
        } else if let parts = try? container.decodeIfPresent([ContentPart].self, forKey: .content) {
            contentParts = parts
            contentStr = parts.map { part in
                switch part {
                case .text(let t): return t
                case .imageURL(let url, _): return "\n![image](\(url))\n"
                case .videoURL(let url): return "\n![video](\(url))\n"
                }
            }.joined()
        } else {
            contentStr = nil
            contentParts = nil
        }

        // OpenRouter image generation: images in a separate field
        if let images = try? container.decodeIfPresent([ContentPart].self, forKey: .images) {
            let imageMarkdown = images.compactMap { part -> String? in
                if case .imageURL(let url, _) = part { return "\n![image](\(url))\n" }
                return nil
            }.joined()
            if !imageMarkdown.isEmpty {
                contentStr = (contentStr ?? "") + imageMarkdown
            }
        }

        content = contentStr
    }

    init(role: MessageRole, content: String? = nil, contentParts: [ContentPart]? = nil,
         toolCalls: [LLMToolCall]? = nil, toolCallId: String? = nil, name: String? = nil,
         reasoningContent: String? = nil, thinkingSignature: String? = nil) {
        self.role = role
        self.content = content
        self.contentParts = contentParts
        self.toolCalls = toolCalls
        self.toolCallId = toolCallId
        self.name = name
        self.reasoningContent = reasoningContent
        self.thinkingSignature = thinkingSignature
    }

    static func system(_ content: String) -> LLMChatMessage {
        LLMChatMessage(role: .system, content: content)
    }

    static func user(_ content: String) -> LLMChatMessage {
        LLMChatMessage(role: .user, content: content)
    }

    static func userWithImages(_ text: String, images: [ImageAttachment]) -> LLMChatMessage {
        var parts: [ContentPart] = [.text(text)]
        for img in images {
            parts.append(.imageURL(url: img.base64DataURI, detail: "auto"))
        }
        return LLMChatMessage(role: .user, content: text, contentParts: parts)
    }

    /// Create a user message with mixed media (images + videos).
    static func userWithMedia(_ text: String, images: [ImageAttachment], videos: [VideoAttachment]) -> LLMChatMessage {
        var parts: [ContentPart] = [.text(text)]
        for img in images {
            parts.append(.imageURL(url: img.base64DataURI, detail: "auto"))
        }
        for vid in videos {
            if let dataURI = vid.base64DataURI {
                parts.append(.videoURL(url: dataURI))
            }
        }
        return LLMChatMessage(role: .user, content: text, contentParts: parts)
    }

    static func assistant(_ content: String?, toolCalls: [LLMToolCall]? = nil,
                          reasoningContent: String? = nil,
                          thinkingSignature: String? = nil) -> LLMChatMessage {
        LLMChatMessage(role: .assistant, content: content, toolCalls: toolCalls,
                       reasoningContent: reasoningContent,
                       thinkingSignature: thinkingSignature)
    }

    static func tool(content: String, toolCallId: String, name: String? = nil) -> LLMChatMessage {
        LLMChatMessage(role: .tool, content: content, toolCallId: toolCallId, name: name)
    }

}

struct LLMToolCall: Codable, Identifiable {
    let id: String
    var type: String = "function"
    var function: LLMFunctionCall

    struct LLMFunctionCall: Codable {
        var name: String
        var arguments: String
    }

    init(id: String, name: String, arguments: String) {
        self.id = id
        self.type = "function"
        self.function = LLMFunctionCall(name: name, arguments: arguments)
    }
}

struct LLMStreamOptions: Codable {
    var includeUsage: Bool = true

    enum CodingKeys: String, CodingKey {
        case includeUsage = "include_usage"
    }
}

struct LLMChatRequest: Codable {
    let model: String
    let messages: [LLMChatMessage]
    var tools: [LLMToolDefinition]?
    var toolChoice: LLMToolChoice?
    var stream: Bool?
    var streamOptions: LLMStreamOptions?
    var maxTokens: Int?
    var temperature: Double?
    var modalities: [String]?
    /// OpenAI reasoning_effort parameter for o-series / reasoning models.
    var reasoningEffort: String?
    /// DeepSeek extension on the OpenAI dialect: explicit
    /// `{"thinking": {"type": "enabled"|"disabled"}}` switch. We never send
    /// this to plain OpenAI / OpenRouter / Ollama (they 400 on unknown
    /// fields); only DeepSeek v4 routes through here.
    var thinking: OpenAIThinkingSwitch?

    enum CodingKeys: String, CodingKey {
        case model, messages, tools, stream, temperature, modalities, thinking
        case toolChoice = "tool_choice"
        case streamOptions = "stream_options"
        case maxTokens = "max_tokens"
        case reasoningEffort = "reasoning_effort"
    }
}

/// DeepSeek extension on the OpenAI dialect — JSON shape matches Anthropic's
/// `thinking` parameter (just `{"type": "enabled"|"disabled"}`, no
/// `budget_tokens`).
struct OpenAIThinkingSwitch: Codable {
    let type: String

    static let enabled = OpenAIThinkingSwitch(type: "enabled")
    static let disabled = OpenAIThinkingSwitch(type: "disabled")
}

enum LLMToolChoice: Codable {
    case auto
    case none
    case required
    case function(name: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        switch self {
        case .auto: try container.encode("auto")
        case .none: try container.encode("none")
        case .required: try container.encode("required")
        case .function(let name):
            let value = ToolChoiceFunction(type: "function", function: ToolChoiceFunctionName(name: name))
            try container.encode(value)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let str = try? container.decode(String.self) {
            switch str {
            case "auto": self = .auto
            case "none": self = .none
            case "required": self = .required
            default: self = .auto
            }
        } else {
            self = .auto
        }
    }
}

private struct ToolChoiceFunction: Codable {
    let type: String
    let function: ToolChoiceFunctionName
}

private struct ToolChoiceFunctionName: Codable {
    let name: String
}

struct LLMToolDefinition: Codable {
    let type: String
    let function: LLMFunctionDefinition

    init(function: LLMFunctionDefinition) {
        self.type = "function"
        self.function = function
    }
}

struct LLMFunctionDefinition: Codable {
    let name: String
    let description: String
    let parameters: JSONSchema

    init(name: String, description: String, parameters: JSONSchema) {
        self.name = name
        self.description = description
        self.parameters = parameters
    }
}

struct JSONSchema: Codable {
    let type: String
    var properties: [String: JSONSchemaProperty]?
    var required: [String]?
    var additionalProperties: Bool?

    enum CodingKeys: String, CodingKey {
        case type, properties, required
        case additionalProperties = "additionalProperties"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(type, forKey: .type)
        // Always encode properties (as empty {} if nil) for maximum API compatibility
        try container.encode(properties ?? [:], forKey: .properties)
        if let required = required, !required.isEmpty {
            try container.encode(required, forKey: .required)
        }
        if let ap = additionalProperties {
            try container.encode(ap, forKey: .additionalProperties)
        }
    }

    init(
        type: String = "object",
        properties: [String: JSONSchemaProperty]? = nil,
        required: [String]? = nil
    ) {
        self.type = type
        self.properties = properties
        self.required = required
    }
}

final class JSONSchemaProperty: Codable {
    let type: String
    var description: String?
    var enumValues: [String]?
    var items: JSONSchemaProperty?

    enum CodingKeys: String, CodingKey {
        case type, description, items
        case enumValues = "enum"
    }

    init(type: String, description: String? = nil, enumValues: [String]? = nil, items: JSONSchemaProperty? = nil) {
        self.type = type
        self.description = description
        self.enumValues = enumValues
        self.items = items
    }
}

// MARK: - Response types

struct LLMChatResponse: Codable {
    let id: String?
    let choices: [LLMChoice]
    let usage: LLMUsage?
}

struct LLMChoice: Codable {
    let index: Int
    let message: LLMChatMessage?
    let delta: LLMDelta?
    let finishReason: String?

    enum CodingKeys: String, CodingKey {
        case index, message, delta
        case finishReason = "finish_reason"
    }
}

struct LLMDelta: Codable {
    var role: String?
    var content: String?
    var reasoningContent: String?
    var toolCalls: [LLMDeltaToolCall]?

    enum CodingKeys: String, CodingKey {
        case role, content, images, reasoning
        case reasoningContent = "reasoning_content"
        case toolCalls = "tool_calls"
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encodeIfPresent(role, forKey: .role)
        try container.encodeIfPresent(content, forKey: .content)
        try container.encodeIfPresent(reasoningContent, forKey: .reasoningContent)
        try container.encodeIfPresent(toolCalls, forKey: .toolCalls)
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        role = try container.decodeIfPresent(String.self, forKey: .role)
        toolCalls = try container.decodeIfPresent([LLMDeltaToolCall].self, forKey: .toolCalls)

        // Parse reasoning from multiple possible fields
        reasoningContent = try container.decodeIfPresent(String.self, forKey: .reasoningContent)
            ?? container.decodeIfPresent(String.self, forKey: .reasoning)

        var contentStr: String?
        if let str = try? container.decodeIfPresent(String.self, forKey: .content) {
            contentStr = str
        } else if let parts = try? container.decodeIfPresent([ContentPart].self, forKey: .content) {
            contentStr = parts.map { part in
                switch part {
                case .text(let t): return t
                case .imageURL(let url, _): return "\n![image](\(url))\n"
                case .videoURL(let url): return "\n![video](\(url))\n"
                }
            }.joined()
        }

        if let images = try? container.decodeIfPresent([ContentPart].self, forKey: .images) {
            let imageMarkdown = images.compactMap { part -> String? in
                if case .imageURL(let url, _) = part { return "\n![image](\(url))\n" }
                return nil
            }.joined()
            if !imageMarkdown.isEmpty {
                contentStr = (contentStr ?? "") + imageMarkdown
            }
        }

        content = contentStr
    }
}

struct LLMDeltaToolCall: Codable {
    let index: Int
    var id: String?
    var type: String?
    var function: LLMDeltaFunction?
}

struct LLMDeltaFunction: Codable {
    var name: String?
    var arguments: String?
}

struct LLMUsage: Codable {
    let promptTokens: Int?
    let completionTokens: Int?
    let totalTokens: Int?
    /// Tokens written to the cache (Anthropic: `cache_creation_input_tokens`).
    var cacheCreationInputTokens: Int?
    /// Tokens read from cache (Anthropic: `cache_read_input_tokens`,
    /// OpenAI: `prompt_tokens_details.cached_tokens`).
    var cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case promptTokens = "prompt_tokens"
        case completionTokens = "completion_tokens"
        case totalTokens = "total_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
        case promptTokensDetails = "prompt_tokens_details"
    }

    // Custom decoder: merge Anthropic (`cache_read_input_tokens`) and
    // OpenAI (`prompt_tokens_details.cached_tokens`) into one field.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        promptTokens = try c.decodeIfPresent(Int.self, forKey: .promptTokens)
        completionTokens = try c.decodeIfPresent(Int.self, forKey: .completionTokens)
        totalTokens = try c.decodeIfPresent(Int.self, forKey: .totalTokens)
        cacheCreationInputTokens = try c.decodeIfPresent(Int.self, forKey: .cacheCreationInputTokens)

        // Anthropic puts it at `cache_read_input_tokens`
        var cacheRead = try c.decodeIfPresent(Int.self, forKey: .cacheReadInputTokens)

        // OpenAI nests it inside `prompt_tokens_details.cached_tokens`
        if cacheRead == nil,
           let details = try c.decodeIfPresent(PromptTokensDetails.self, forKey: .promptTokensDetails) {
            cacheRead = details.cachedTokens
        }
        cacheReadInputTokens = cacheRead
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encodeIfPresent(promptTokens, forKey: .promptTokens)
        try c.encodeIfPresent(completionTokens, forKey: .completionTokens)
        try c.encodeIfPresent(totalTokens, forKey: .totalTokens)
        try c.encodeIfPresent(cacheCreationInputTokens, forKey: .cacheCreationInputTokens)
        try c.encodeIfPresent(cacheReadInputTokens, forKey: .cacheReadInputTokens)
    }

    /// Memberwise init for manual construction.
    init(promptTokens: Int?, completionTokens: Int?, totalTokens: Int?,
         cacheCreationInputTokens: Int? = nil, cacheReadInputTokens: Int? = nil) {
        self.promptTokens = promptTokens
        self.completionTokens = completionTokens
        self.totalTokens = totalTokens
        self.cacheCreationInputTokens = cacheCreationInputTokens
        self.cacheReadInputTokens = cacheReadInputTokens
    }

    /// OpenAI `prompt_tokens_details` nested object.
    private struct PromptTokensDetails: Decodable {
        let cachedTokens: Int?
        enum CodingKeys: String, CodingKey {
            case cachedTokens = "cached_tokens"
        }
    }
}

// MARK: - Anthropic API types

/// Anthropic prompt-caching control. Attach to a system block, tool, or
/// the last content block in a message to mark a cache breakpoint.
struct CacheControl: Encodable {
    let type: String

    static let ephemeral = CacheControl(type: "ephemeral")
}

struct AnthropicRequest: Encodable {
    let model: String
    let maxTokens: Int
    var system: [AnthropicSystemBlock]?
    let messages: [AnthropicMessage]
    var tools: [AnthropicTool]?
    var stream: Bool?
    var temperature: Double?
    var thinking: AnthropicThinking?
    var outputConfig: AnthropicOutputConfig?

    enum CodingKeys: String, CodingKey {
        case model, system, messages, tools, stream, temperature, thinking
        case maxTokens = "max_tokens"
        case outputConfig = "output_config"
    }
}

/// Anthropic `output_config` — controls overall token effort across text,
/// tool calls, and (when adaptive thinking is on) thinking depth.
///
/// Supported on Claude Opus 4.5+, Opus 4.6+, Opus 4.7+, Sonnet 4.6+, and
/// Mythos Preview. Sending it to older models would cause `400 unknown field`
/// errors, so the adapter only emits it for those endpoints.
struct AnthropicOutputConfig: Encodable {
    let effort: String

    enum CodingKeys: String, CodingKey {
        case effort
    }
}

struct AnthropicSystemBlock: Encodable {
    let type: String
    let text: String
    var cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case type, text
        case cacheControl = "cache_control"
    }
}

struct AnthropicThinking: Encodable {
    let type: String
    let budgetTokens: Int?

    enum CodingKeys: String, CodingKey {
        case type
        case budgetTokens = "budget_tokens"
    }

    func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(type, forKey: .type)
        // `budget_tokens` is only valid (and required) on the `enabled` variant.
        if let budgetTokens, type == "enabled" {
            try c.encode(budgetTokens, forKey: .budgetTokens)
        }
    }

    static func enabled(budget: Int) -> AnthropicThinking {
        AnthropicThinking(type: "enabled", budgetTokens: budget)
    }

    /// Adaptive extended thinking — Claude decides how much to think based on
    /// the request and the `output_config.effort` signal. Required on Claude
    /// Opus 4.7 (manual `enabled` is rejected) and recommended on Opus 4.6 /
    /// Sonnet 4.6.
    static let adaptive = AnthropicThinking(type: "adaptive", budgetTokens: nil)

    /// Explicit "thinking off" — sent on every request so providers can't
    /// silently default to enabled. DeepSeek's Anthropic-compat mode does
    /// exactly that when the field is omitted, which causes the model to
    /// emit thinking content even when our local config has it `.off`.
    static let disabled = AnthropicThinking(type: "disabled", budgetTokens: nil)
}

struct AnthropicMessage: Encodable {
    let role: String
    let content: [AnthropicContentBlock]
    /// When set, `cache_control` is appended to the last content block during encoding.
    var cacheControlOnLast: CacheControl?

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(role, forKey: .role)

        if let cc = cacheControlOnLast, !content.isEmpty {
            var arr = container.nestedUnkeyedContainer(forKey: .content)
            for (i, block) in content.enumerated() {
                if i == content.count - 1 {
                    try arr.encode(CachedBlock(block: block, cacheControl: cc))
                } else {
                    try arr.encode(block)
                }
            }
        } else {
            try container.encode(content, forKey: .content)
        }
    }

    enum CodingKeys: String, CodingKey {
        case role, content
    }

    /// Wrapper that encodes a content block with an additional `cache_control` key.
    private struct CachedBlock: Encodable {
        let block: AnthropicContentBlock
        let cacheControl: CacheControl

        func encode(to encoder: Encoder) throws {
            try block.encode(to: encoder)
            var container = encoder.container(keyedBy: CodingKeys.self)
            try container.encode(cacheControl, forKey: .cacheControl)
        }

        enum CodingKeys: String, CodingKey {
            case cacheControl = "cache_control"
        }
    }
}

enum AnthropicContentBlock: Encodable {
    case text(String)
    case image(mediaType: String, data: String)
    case thinking(text: String, signature: String?)
    case toolUse(id: String, name: String, input: String)
    case toolResult(toolUseId: String, content: String)
    case toolResultRich(toolUseId: String, blocks: [AnthropicToolResultBlock])

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mediaType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(
                ImageSource(type: "base64", mediaType: mediaType, data: data),
                forKey: .source
            )
        case .thinking(let text, let signature):
            try container.encode("thinking", forKey: .type)
            try container.encode(text, forKey: .thinking)
            if let signature, !signature.isEmpty {
                try container.encode(signature, forKey: .signature)
            }
        case .toolUse(let id, let name, let input):
            try container.encode("tool_use", forKey: .type)
            try container.encode(id, forKey: .id)
            try container.encode(name, forKey: .name)
            if let data = input.data(using: .utf8),
               let obj = try? JSONSerialization.jsonObject(with: data) {
                try container.encode(AnyCodable(obj), forKey: .input)
            } else {
                try container.encode([String: String](), forKey: .input)
            }
        case .toolResult(let toolUseId, let content):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(content, forKey: .content)
        case .toolResultRich(let toolUseId, let blocks):
            try container.encode("tool_result", forKey: .type)
            try container.encode(toolUseId, forKey: .toolUseId)
            try container.encode(blocks, forKey: .content)
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, text, source, id, name, input, content, thinking, signature
        case toolUseId = "tool_use_id"
    }

    struct ImageSource: Encodable {
        let type: String
        let mediaType: String
        let data: String

        enum CodingKeys: String, CodingKey {
            case type, data
            case mediaType = "media_type"
        }
    }
}

/// Content blocks inside an Anthropic `tool_result` (text or image).
enum AnthropicToolResultBlock: Encodable {
    case text(String)
    case image(mediaType: String, data: String)

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .text(let text):
            try container.encode("text", forKey: .type)
            try container.encode(text, forKey: .text)
        case .image(let mediaType, let data):
            try container.encode("image", forKey: .type)
            try container.encode(
                AnthropicContentBlock.ImageSource(type: "base64", mediaType: mediaType, data: data),
                forKey: .source
            )
        }
    }

    enum CodingKeys: String, CodingKey {
        case type, text, source
    }
}

struct AnthropicTool: Encodable {
    let name: String
    let description: String
    let inputSchema: JSONSchema
    var cacheControl: CacheControl?

    enum CodingKeys: String, CodingKey {
        case name, description
        case inputSchema = "input_schema"
        case cacheControl = "cache_control"
    }
}

/// Type-erased Codable wrapper for arbitrary JSON values.
struct AnyCodable: Encodable {
    let value: Any

    init(_ value: Any) {
        self.value = value
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.singleValueContainer()
        if let dict = value as? [String: Any] {
            try container.encode(dict.mapValues { AnyCodable($0) })
        } else if let array = value as? [Any] {
            try container.encode(array.map { AnyCodable($0) })
        } else if let str = value as? String {
            try container.encode(str)
        } else if let num = value as? Double {
            try container.encode(num)
        } else if let num = value as? Int {
            try container.encode(num)
        } else if let bool = value as? Bool {
            try container.encode(bool)
        } else if value is NSNull {
            try container.encodeNil()
        } else {
            try container.encodeNil()
        }
    }
}

// MARK: - Anthropic stream response types

struct AnthropicStreamEvent: Decodable {
    let type: String
    var message: AnthropicStreamMessage?
    var index: Int?
    var contentBlock: AnthropicStreamContentBlock?
    var delta: AnthropicStreamDelta?
    var usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case type, message, index, delta, usage
        case contentBlock = "content_block"
    }
}

struct AnthropicStreamMessage: Decodable {
    let id: String?
    let role: String?
    let model: String?
    let usage: AnthropicUsage?
}

struct AnthropicStreamContentBlock: Decodable {
    let type: String
    var text: String?
    var thinking: String?
    var id: String?
    var name: String?
}

struct AnthropicStreamDelta: Decodable {
    let type: String
    var text: String?
    var thinking: String?
    var signature: String?
    var partialJson: String?
    var stopReason: String?

    enum CodingKeys: String, CodingKey {
        case type, text, thinking, signature
        case partialJson = "partial_json"
        case stopReason = "stop_reason"
    }
}

struct AnthropicUsage: Decodable {
    var inputTokens: Int?
    var outputTokens: Int?
    var cacheCreationInputTokens: Int?
    var cacheReadInputTokens: Int?

    enum CodingKeys: String, CodingKey {
        case inputTokens = "input_tokens"
        case outputTokens = "output_tokens"
        case cacheCreationInputTokens = "cache_creation_input_tokens"
        case cacheReadInputTokens = "cache_read_input_tokens"
    }
}

/// Non-streaming Anthropic response.
struct AnthropicResponse: Decodable {
    let id: String?
    let type: String?
    let role: String?
    let content: [AnthropicResponseBlock]
    let model: String?
    let stopReason: String?
    let usage: AnthropicUsage?

    enum CodingKeys: String, CodingKey {
        case id, type, role, content, model, usage
        case stopReason = "stop_reason"
    }
}

struct AnthropicResponseBlock: Decodable {
    let type: String
    var text: String?
    var thinking: String?
    var signature: String?
    var id: String?
    var name: String?
    var input: AnyCodableDecoder?
}

/// Type-erased Decodable wrapper.
struct AnyCodableDecoder: Decodable {
    let value: Any

    init(from decoder: Decoder) throws {
        let container = try decoder.singleValueContainer()
        if let dict = try? container.decode([String: AnyCodableDecoder].self) {
            value = dict.mapValues(\.value)
        } else if let array = try? container.decode([AnyCodableDecoder].self) {
            value = array.map(\.value)
        } else if let str = try? container.decode(String.self) {
            value = str
        } else if let num = try? container.decode(Double.self) {
            value = num
        } else if let bool = try? container.decode(Bool.self) {
            value = bool
        } else {
            value = NSNull()
        }
    }

    var jsonString: String {
        if let data = try? JSONSerialization.data(withJSONObject: value),
           let str = String(data: data, encoding: .utf8) {
            return str
        }
        return "{}"
    }
}
