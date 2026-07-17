import XCTest
@testable import Palvia

final class OpenAIResponsesAdapterTests: XCTestCase {
    private func makeAdapter() -> OpenAIResponsesAdapter {
        OpenAIResponsesAdapter(context: LLMAdapterContext(baseURL: "https://api.openai.com/v1", apiKey: "sk-test"))
    }

    private func bodyDict(from request: URLRequest) throws -> [String: Any] {
        let data = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
    }

    func testBuildChatRequestUsesResponsesEndpointAndSchema() throws {
        let request = try makeAdapter().buildChatRequest(
            model: "gpt-5.4",
            messages: [.system("Be concise"), .user("Hello")],
            tools: nil,
            maxTokens: 1234,
            temperature: 0.25,
            capabilities: .default,
            thinkingLevel: .high
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        XCTAssertEqual(request.value(forHTTPHeaderField: "Authorization"), "Bearer sk-test")

        let dict = try bodyDict(from: request)
        XCTAssertEqual(dict["model"] as? String, "gpt-5.4")
        XCTAssertEqual(dict["stream"] as? Bool, false)
        XCTAssertEqual(dict["max_output_tokens"] as? Int, 1234)
        XCTAssertNil(dict["messages"], "Responses API requests must not send Chat Completions messages")
        XCTAssertNil(dict["max_tokens"], "Responses API requests use max_output_tokens")

        let input = try XCTUnwrap(dict["input"] as? [[String: Any]])
        XCTAssertEqual(input.count, 2)
        XCTAssertEqual(input[0]["type"] as? String, "message")
        XCTAssertEqual(input[0]["role"] as? String, "system")
        let firstContent = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(firstContent.first?["type"] as? String, "input_text")
        XCTAssertEqual(firstContent.first?["text"] as? String, "Be concise")

        let reasoning = try XCTUnwrap(dict["reasoning"] as? [String: Any])
        XCTAssertEqual(reasoning["effort"] as? String, "high")
    }

    func testBuildStreamRequestMapsToolsImagesAndToolOutputs() throws {
        let tool = ToolDefinitionBuilder.build(
            name: "lookup",
            description: "Look up data",
            properties: ["query": ToolDefinitionBuilder.stringParam("Query")],
            required: ["query"]
        )
        let request = try makeAdapter().buildStreamRequest(
            model: "gpt-5.4",
            messages: [
                LLMChatMessage(role: .user, contentParts: [
                    .text("Describe"),
                    .imageURL(url: "data:image/png;base64,abc", detail: "auto")
                ]),
                .assistant(nil, toolCalls: [LLMToolCall(id: "call_1", name: "lookup", arguments: "{\"query\":\"x\"}")]),
                .tool(content: "result", toolCallId: "call_1")
            ],
            tools: [tool],
            maxTokens: 2000,
            temperature: 0.7,
            capabilities: .default,
            thinkingLevel: .off
        )

        XCTAssertEqual(request.url?.absoluteString, "https://api.openai.com/v1/responses")
        let dict = try bodyDict(from: request)
        XCTAssertEqual(dict["stream"] as? Bool, true)
        XCTAssertNil(dict["reasoning"], "Thinking off should omit Responses reasoning")

        let tools = try XCTUnwrap(dict["tools"] as? [[String: Any]])
        XCTAssertEqual(tools.first?["type"] as? String, "function")
        XCTAssertEqual(tools.first?["name"] as? String, "lookup")

        let input = try XCTUnwrap(dict["input"] as? [[String: Any]])
        let content = try XCTUnwrap(input[0]["content"] as? [[String: Any]])
        XCTAssertEqual(content[0]["type"] as? String, "input_text")
        XCTAssertEqual(content[1]["type"] as? String, "input_image")
        XCTAssertEqual(content[1]["image_url"] as? String, "data:image/png;base64,abc")
        XCTAssertEqual(input[1]["type"] as? String, "function_call")
        XCTAssertEqual(input[1]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[2]["type"] as? String, "function_call_output")
        XCTAssertEqual(input[2]["call_id"] as? String, "call_1")
        XCTAssertEqual(input[2]["output"] as? String, "result")
    }

    func testParseResponsesResponseToChatResponse() throws {
        let json = #"""
        {
          "id": "resp_123",
          "output": [
            {
              "type": "message",
              "content": [
                { "type": "output_text", "text": "Hello" },
                { "type": "output_text", "text": " world" }
              ]
            },
            {
              "type": "function_call",
              "call_id": "call_abc",
              "name": "lookup",
              "arguments": "{\"query\":\"x\"}"
            }
          ],
          "usage": { "input_tokens": 10, "output_tokens": 5, "total_tokens": 15 }
        }
        """#.data(using: .utf8)!

        let response = try makeAdapter().parseChatResponse(data: json)
        XCTAssertEqual(response.id, "resp_123")
        XCTAssertEqual(response.choices.first?.message?.content, "Hello world")
        XCTAssertEqual(response.choices.first?.finishReason, "tool_calls")
        XCTAssertEqual(response.choices.first?.message?.toolCalls?.first?.id, "call_abc")
        XCTAssertEqual(response.usage?.promptTokens, 10)
        XCTAssertEqual(response.usage?.completionTokens, 5)
        XCTAssertEqual(response.usage?.totalTokens, 15)
    }

    func testProcessResponsesStreamEvents() throws {
        let adapter = makeAdapter()

        let textChunks = adapter.processStreamEvent(.message(data: #"{"type":"response.output_text.delta","delta":"Hi"}"#))
        guard case .content(let text) = textChunks.first else {
            return XCTFail("Expected content chunk")
        }
        XCTAssertEqual(text, "Hi")

        let toolChunks = adapter.processStreamEvent(.message(data: #"{"type":"response.output_item.done","item":{"type":"function_call","call_id":"call_1","name":"lookup","arguments":"{}"}}"#))
        guard case .toolCall(let toolCall) = toolChunks.first else {
            return XCTFail("Expected tool call chunk")
        }
        XCTAssertEqual(toolCall.id, "call_1")
        XCTAssertEqual(toolCall.function.name, "lookup")

        let doneChunks = adapter.processStreamEvent(.message(data: #"{"type":"response.completed","response":{"id":"resp_1","output":[],"usage":{"input_tokens":1,"output_tokens":2,"total_tokens":3}}}"#))
        XCTAssertEqual(doneChunks.count, 3)
        guard case .usage(let usage) = doneChunks[0] else {
            return XCTFail("Expected usage chunk")
        }
        XCTAssertEqual(usage.totalTokens, 3)
        guard case .finishReason(.stop) = doneChunks[1] else {
            return XCTFail("Expected stop finish reason")
        }
        guard case .done = doneChunks[2] else {
            return XCTFail("Expected done chunk")
        }
    }

    func testIncompleteMaxOutputTokensBecomesContinuableCompletion() {
        let chunks = makeAdapter().processStreamEvent(.message(data: #"{"type":"response.incomplete","response":{"id":"resp_1","output":[],"usage":{"input_tokens":9,"output_tokens":4,"total_tokens":13},"incomplete_details":{"reason":"max_output_tokens"}}}"#))

        XCTAssertEqual(chunks.count, 3)
        guard case .usage(let usage) = chunks[0] else {
            return XCTFail("Expected usage before termination")
        }
        XCTAssertEqual(usage.totalTokens, 13)
        guard case .finishReason(.outputLimit) = chunks[1] else {
            return XCTFail("Expected output-limit finish reason")
        }
        guard case .done = chunks[2] else {
            return XCTFail("Expected a completed stream so ChatViewModel can continue it")
        }
    }

    func testOpenAICompatibleStillUsesChatCompletions() throws {
        let adapter = OpenAIAdapter(context: LLMAdapterContext(baseURL: "https://openrouter.ai/api/v1", apiKey: "k"))
        let request = try adapter.buildChatRequest(
            model: "openai/gpt-5.4",
            messages: [.user("Hello")],
            tools: nil,
            maxTokens: 100,
            temperature: 0.7,
            capabilities: .default,
            thinkingLevel: .off
        )

        XCTAssertEqual(request.url?.absoluteString, "https://openrouter.ai/api/v1/chat/completions")
        let dict = try bodyDict(from: request)
        XCTAssertNotNil(dict["messages"])
        XCTAssertNil(dict["input"])
    }
}
