import XCTest
@testable import iClaw

final class ChatMessageTests: XCTestCase {

    // MARK: - LLMChatMessage Factory Methods

    func testSystemMessage() {
        let msg = LLMChatMessage.system("You are a helpful assistant.")
        XCTAssertEqual(msg.role, .system)
        XCTAssertEqual(msg.content, "You are a helpful assistant.")
        XCTAssertNil(msg.toolCalls)
        XCTAssertNil(msg.toolCallId)
    }

    func testUserMessage() {
        let msg = LLMChatMessage.user("Hello!")
        XCTAssertEqual(msg.role, .user)
        XCTAssertEqual(msg.content, "Hello!")
    }

    func testAssistantMessage() {
        let msg = LLMChatMessage.assistant("Hi there!")
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertEqual(msg.content, "Hi there!")
        XCTAssertNil(msg.toolCalls)
    }

    func testAssistantMessageWithToolCalls() {
        let toolCall = LLMToolCall(id: "call_1", name: "browser_navigate", arguments: "{\"url\":\"https://example.com\"}")
        let msg = LLMChatMessage.assistant(nil, toolCalls: [toolCall])
        XCTAssertEqual(msg.role, .assistant)
        XCTAssertNil(msg.content)
        XCTAssertEqual(msg.toolCalls?.count, 1)
        XCTAssertEqual(msg.toolCalls?.first?.function.name, "browser_navigate")
    }

    func testToolMessage() {
        let msg = LLMChatMessage.tool(content: "Success", toolCallId: "call_1", name: "browser_navigate")
        XCTAssertEqual(msg.role, .tool)
        XCTAssertEqual(msg.content, "Success")
        XCTAssertEqual(msg.toolCallId, "call_1")
        XCTAssertEqual(msg.name, "browser_navigate")
    }

    // MARK: - LLMToolCall

    func testToolCallInit() {
        let tc = LLMToolCall(id: "tc_1", name: "execute_javascript", arguments: "{\"code\":\"1+1\"}")
        XCTAssertEqual(tc.id, "tc_1")
        XCTAssertEqual(tc.type, "function")
        XCTAssertEqual(tc.function.name, "execute_javascript")
        XCTAssertEqual(tc.function.arguments, "{\"code\":\"1+1\"}")
    }

    // MARK: - Codable Round-Trip

    func testChatMessageCodableRoundTrip() throws {
        let original = LLMChatMessage.user("Test message")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, original.role)
        XCTAssertEqual(decoded.content, original.content)
    }

    func testChatMessageWithToolCallsCodable() throws {
        let toolCall = LLMToolCall(id: "call_abc", name: "read_config", arguments: "{\"key\":\"SOUL.md\"}")
        let original = LLMChatMessage.assistant("Let me read that.", toolCalls: [toolCall])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMChatMessage.self, from: data)
        XCTAssertEqual(decoded.role, .assistant)
        XCTAssertEqual(decoded.content, "Let me read that.")
        XCTAssertEqual(decoded.toolCalls?.count, 1)
        XCTAssertEqual(decoded.toolCalls?.first?.id, "call_abc")
        XCTAssertEqual(decoded.toolCalls?.first?.function.name, "read_config")
    }

    func testToolCallCodableRoundTrip() throws {
        let original = LLMToolCall(id: "id_1", name: "browser_click", arguments: "{\"selector\":\"#btn\"}")
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMToolCall.self, from: data)
        XCTAssertEqual(decoded.id, original.id)
        XCTAssertEqual(decoded.function.name, original.function.name)
        XCTAssertEqual(decoded.function.arguments, original.function.arguments)
    }

    // MARK: - ContentPart

    func testContentPartTextCodable() throws {
        let part = ContentPart.text("Hello")
        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(ContentPart.self, from: data)
        if case .text(let text) = decoded {
            XCTAssertEqual(text, "Hello")
        } else {
            XCTFail("Expected .text")
        }
    }

    func testContentPartImageURLCodable() throws {
        let part = ContentPart.imageURL(url: "data:image/jpeg;base64,abc123", detail: "auto")
        let data = try JSONEncoder().encode(part)
        let decoded = try JSONDecoder().decode(ContentPart.self, from: data)
        if case .imageURL(let url, let detail) = decoded {
            XCTAssertEqual(url, "data:image/jpeg;base64,abc123")
            XCTAssertEqual(detail, "auto")
        } else {
            XCTFail("Expected .imageURL")
        }
    }

    // MARK: - LLMChatResponse Decoding

    func testDecodeChatResponse() throws {
        let json = """
        {
            "id": "chatcmpl-123",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Hello!"
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": 10,
                "completion_tokens": 5,
                "total_tokens": 15
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)
        XCTAssertEqual(response.id, "chatcmpl-123")
        XCTAssertEqual(response.choices.count, 1)
        XCTAssertEqual(response.choices.first?.message?.content, "Hello!")
        XCTAssertEqual(response.choices.first?.finishReason, "stop")
        XCTAssertEqual(response.usage?.promptTokens, 10)
        XCTAssertEqual(response.usage?.completionTokens, 5)
        XCTAssertEqual(response.usage?.totalTokens, 15)
    }

    func testDecodeChatResponseWithToolCalls() throws {
        let json = """
        {
            "id": "chatcmpl-456",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [
                            {
                                "id": "call_abc",
                                "type": "function",
                                "function": {
                                    "name": "browser_navigate",
                                    "arguments": "{\\"url\\":\\"https://example.com\\"}"
                                }
                            }
                        ]
                    },
                    "finish_reason": "tool_calls"
                }
            ],
            "usage": null
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)
        XCTAssertEqual(response.choices.first?.message?.toolCalls?.count, 1)
        XCTAssertEqual(response.choices.first?.message?.toolCalls?.first?.function.name, "browser_navigate")
        XCTAssertEqual(response.choices.first?.finishReason, "tool_calls")
    }

    // MARK: - LLMDelta Decoding

    func testAssistantMessageEncodesReasoningContent() throws {
        let msg = LLMChatMessage.assistant("answer", reasoningContent: "thought process")
        let data = try JSONEncoder().encode(msg)
        let json = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(json["reasoning_content"] as? String, "thought process")
        XCTAssertEqual(json["content"] as? String, "answer")
        XCTAssertEqual(json["role"] as? String, "assistant")
    }

    func testAssistantMessageOmitsEmptyReasoningContent() throws {
        let nilMsg = LLMChatMessage.assistant("answer", reasoningContent: nil)
        let nilData = try JSONEncoder().encode(nilMsg)
        let nilJson = try XCTUnwrap(JSONSerialization.jsonObject(with: nilData) as? [String: Any])
        XCTAssertNil(nilJson["reasoning_content"])

        let emptyMsg = LLMChatMessage.assistant("answer", reasoningContent: "")
        let emptyData = try JSONEncoder().encode(emptyMsg)
        let emptyJson = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        XCTAssertNil(emptyJson["reasoning_content"])
    }

    func testDecodeDeltaWithReasoningContent() throws {
        let json = """
        {
            "id": "chatcmpl-789",
            "choices": [
                {
                    "index": 0,
                    "delta": {
                        "role": "assistant",
                        "content": "Hello",
                        "reasoning_content": "Let me think..."
                    },
                    "finish_reason": null
                }
            ],
            "usage": null
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)
        XCTAssertEqual(response.choices.first?.delta?.content, "Hello")
        XCTAssertEqual(response.choices.first?.delta?.reasoningContent, "Let me think...")
    }

    // MARK: - LLMToolChoice

    func testToolChoiceAutoCodable() throws {
        let choice = LLMToolChoice.auto
        let data = try JSONEncoder().encode(choice)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"auto\"")
    }

    func testToolChoiceNoneCodable() throws {
        let choice = LLMToolChoice.none
        let data = try JSONEncoder().encode(choice)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"none\"")
    }

    func testToolChoiceRequiredCodable() throws {
        let choice = LLMToolChoice.required
        let data = try JSONEncoder().encode(choice)
        let str = String(data: data, encoding: .utf8)
        XCTAssertEqual(str, "\"required\"")
    }

    // MARK: - JSONSchema

    func testJSONSchemaEncoding() throws {
        let schema = JSONSchema(
            type: "object",
            properties: [
                "name": JSONSchemaProperty(type: "string", description: "The name"),
                "age": JSONSchemaProperty(type: "integer", description: "The age")
            ],
            required: ["name"]
        )
        let data = try JSONEncoder().encode(schema)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["type"] as? String, "object")
        XCTAssertNotNil(dict?["properties"])
        XCTAssertEqual(dict?["required"] as? [String], ["name"])
    }

    func testJSONSchemaEncodesEmptyProperties() throws {
        let schema = JSONSchema(type: "object")
        let data = try JSONEncoder().encode(schema)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertNotNil(dict?["properties"], "Should encode empty properties dict")
    }

    // MARK: - LLMError

    func testLLMErrorDescriptions() {
        XCTAssertNotNil(LLMError.invalidURL("bad").errorDescription)
        XCTAssertNotNil(LLMError.invalidResponse.errorDescription)
        XCTAssertNotNil(LLMError.apiError(statusCode: 401, message: "Unauthorized").errorDescription)
        XCTAssertNotNil(LLMError.decodingError("bad json").errorDescription)

        XCTAssertTrue(LLMError.apiError(statusCode: 401, message: "Unauthorized").errorDescription!.contains("401"))
    }

    // MARK: - StreamChunk

    func testStreamChunkEnum() {
        let content = StreamChunk.content("Hello")
        let thinking = StreamChunk.thinking("Hmm...")
        let done = StreamChunk.done
        let error = StreamChunk.error("Failed")

        if case .content(let text) = content { XCTAssertEqual(text, "Hello") }
        if case .thinking(let text) = thinking { XCTAssertEqual(text, "Hmm...") }
        if case .done = done {} else { XCTFail("Expected .done") }
        if case .error(let msg) = error { XCTAssertEqual(msg, "Failed") }
    }

    // MARK: - Anthropic Types

    func testAnthropicStreamEventDecoding() throws {
        let json = """
        {
            "type": "content_block_start",
            "index": 0,
            "content_block": {
                "type": "text",
                "text": "Hello"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)
        XCTAssertEqual(event.type, "content_block_start")
        XCTAssertEqual(event.index, 0)
        XCTAssertEqual(event.contentBlock?.type, "text")
    }

    func testAnthropicResponseDecoding() throws {
        let json = """
        {
            "id": "msg_01",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Hello!"}
            ],
            "model": "claude-3-opus",
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 10, "output_tokens": 5}
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        XCTAssertEqual(response.id, "msg_01")
        XCTAssertEqual(response.role, "assistant")
        XCTAssertEqual(response.content.count, 1)
        XCTAssertEqual(response.content.first?.type, "text")
        XCTAssertEqual(response.content.first?.text, "Hello!")
        XCTAssertEqual(response.usage?.inputTokens, 10)
        XCTAssertEqual(response.usage?.outputTokens, 5)
    }

    func testAnthropicResponseWithToolUseDecoding() throws {
        let json = """
        {
            "id": "msg_02",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "I will search."},
                {"type": "tool_use", "id": "toolu_01", "name": "browser_navigate", "input": {"url": "https://example.com"}}
            ],
            "model": "claude-3-opus",
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 20, "output_tokens": 15}
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)
        XCTAssertEqual(response.content.count, 2)
        XCTAssertEqual(response.content[1].type, "tool_use")
        XCTAssertEqual(response.content[1].name, "browser_navigate")
        XCTAssertEqual(response.content[1].id, "toolu_01")
        XCTAssertNotNil(response.content[1].input)
    }
}
