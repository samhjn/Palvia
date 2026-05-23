import XCTest
@testable import iClaw

/// Verifies that outgoing LLM request bodies are byte-stable across runs.
///
/// Swift `Dictionary` iteration order is randomized per process, so without
/// a sorted-keys encoder, `JSONSchema.properties` and Anthropic
/// `tool_use.input` would serialize with different key orders between
/// requests and defeat prompt caching on Anthropic, DeepSeek, etc.
final class StableJSONEncoderTests: XCTestCase {

    func testStableEncoderUsesSortedKeys() {
        XCTAssertTrue(
            APIRequestBuilder.stableJSONEncoder.outputFormatting.contains(.sortedKeys),
            "Outgoing LLM bodies must use sorted keys for cache stability"
        )
    }

    /// Two encodings of the same logical payload — fed via dictionaries inserted
    /// in opposite key orders — must produce byte-identical output. Without
    /// `.sortedKeys`, Swift would emit dict keys in insertion / hash order.
    func testIdenticalDictsEncodeByteIdentical() throws {
        let schemaA = JSONSchema(type: "object", properties: [
            "alpha": JSONSchemaProperty(type: "string"),
            "bravo": JSONSchemaProperty(type: "string"),
            "charlie": JSONSchemaProperty(type: "string"),
            "delta": JSONSchemaProperty(type: "string"),
        ])
        let schemaB = JSONSchema(type: "object", properties: [
            "delta": JSONSchemaProperty(type: "string"),
            "charlie": JSONSchemaProperty(type: "string"),
            "bravo": JSONSchemaProperty(type: "string"),
            "alpha": JSONSchemaProperty(type: "string"),
        ])

        let dataA = try APIRequestBuilder.stableJSONEncoder.encode(schemaA)
        let dataB = try APIRequestBuilder.stableJSONEncoder.encode(schemaB)
        XCTAssertEqual(dataA, dataB, "Same logical schema must encode to identical bytes")
    }

    /// Verify the output actually has alphabetically sorted keys.
    func testEncodedSchemaPropertiesAreAlphabeticallyOrdered() throws {
        let schema = JSONSchema(type: "object", properties: [
            "zeta": JSONSchemaProperty(type: "string"),
            "alpha": JSONSchemaProperty(type: "string"),
            "mu": JSONSchemaProperty(type: "string"),
        ])
        let data = try APIRequestBuilder.stableJSONEncoder.encode(schema)
        let json = try XCTUnwrap(String(data: data, encoding: .utf8))
        // Each property name appears exactly once; the alpha-key one should come first.
        let alphaIdx = try XCTUnwrap(json.range(of: "\"alpha\"")?.lowerBound)
        let muIdx = try XCTUnwrap(json.range(of: "\"mu\"")?.lowerBound)
        let zetaIdx = try XCTUnwrap(json.range(of: "\"zeta\"")?.lowerBound)
        XCTAssertLessThan(alphaIdx, muIdx)
        XCTAssertLessThan(muIdx, zetaIdx)
    }

    /// AnyCodable wraps arbitrary JSON (used by Anthropic `tool_use.input`).
    /// The same logical input passed in either dict order must produce the
    /// same encoded output.
    func testAnyCodableDictEncodingIsStable() throws {
        let inputA: [String: Any] = ["query": "swift", "limit": 10, "offset": 0]
        let inputB: [String: Any] = ["offset": 0, "limit": 10, "query": "swift"]

        let dataA = try APIRequestBuilder.stableJSONEncoder.encode(AnyCodable(inputA))
        let dataB = try APIRequestBuilder.stableJSONEncoder.encode(AnyCodable(inputB))
        XCTAssertEqual(dataA, dataB)
    }

    /// End-to-end: a full Anthropic request with mixed-order property dicts
    /// must serialize to byte-identical output across two passes.
    func testAnthropicRequestStableAcrossPasses() throws {
        func makeRequest(reverseProps: Bool) -> AnthropicRequest {
            let propsAsc: [(String, JSONSchemaProperty)] = [
                ("aaa", JSONSchemaProperty(type: "string")),
                ("bbb", JSONSchemaProperty(type: "integer")),
                ("ccc", JSONSchemaProperty(type: "boolean")),
            ]
            let entries = reverseProps ? propsAsc.reversed() : propsAsc
            var properties: [String: JSONSchemaProperty] = [:]
            for (k, v) in entries { properties[k] = v }
            let tool = AnthropicTool(
                name: "search",
                description: "Search the web",
                inputSchema: JSONSchema(type: "object", properties: properties, required: ["aaa"])
            )
            return AnthropicRequest(
                model: "claude-sonnet-4-20250514",
                maxTokens: 1024,
                messages: [AnthropicMessage(role: "user", content: [.text("Hi")])],
                tools: [tool],
                stream: true
            )
        }

        let pass1 = try APIRequestBuilder.stableJSONEncoder.encode(makeRequest(reverseProps: false))
        let pass2 = try APIRequestBuilder.stableJSONEncoder.encode(makeRequest(reverseProps: true))
        XCTAssertEqual(pass1, pass2,
                       "Anthropic request bodies must be byte-stable so prompt caching can hit")
    }
}

// MARK: - Anthropic Thinking Block Round-Trip

/// Anthropic native and DeepSeek's Anthropic-compat mode both require the
/// assistant's `thinking` content blocks to be passed back on subsequent
/// requests. These tests pin the parse + replay path end-to-end.
final class AnthropicThinkingBlockTests: XCTestCase {

    // MARK: - Encoding the .thinking content block

    func testThinkingBlockEncodesTextAndSignature() throws {
        let block = AnthropicContentBlock.thinking(text: "Let me reason...", signature: "sig_abc")
        let data = try APIRequestBuilder.stableJSONEncoder.encode(block)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])

        XCTAssertEqual(dict["type"] as? String, "thinking")
        XCTAssertEqual(dict["thinking"] as? String, "Let me reason...")
        XCTAssertEqual(dict["signature"] as? String, "sig_abc")
    }

    func testThinkingBlockOmitsEmptySignature() throws {
        let nilSig = AnthropicContentBlock.thinking(text: "Reasoning.", signature: nil)
        let nilData = try APIRequestBuilder.stableJSONEncoder.encode(nilSig)
        let nilDict = try XCTUnwrap(JSONSerialization.jsonObject(with: nilData) as? [String: Any])
        XCTAssertNil(nilDict["signature"], "nil signature must not emit the field")

        let emptySig = AnthropicContentBlock.thinking(text: "Reasoning.", signature: "")
        let emptyData = try APIRequestBuilder.stableJSONEncoder.encode(emptySig)
        let emptyDict = try XCTUnwrap(JSONSerialization.jsonObject(with: emptyData) as? [String: Any])
        XCTAssertNil(emptyDict["signature"], "empty signature must not emit the field")
    }

    // MARK: - Decoding the response signature

    func testAnthropicResponseDecodesThinkingSignature() throws {
        let json = """
        {
            "id": "msg_01",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "thinking", "thinking": "I should search.", "signature": "sig_xyz"},
                {"type": "text", "text": "Let me look that up."}
            ],
            "model": "deepseek-reasoner",
            "stop_reason": "end_turn",
            "usage": {"input_tokens": 5, "output_tokens": 3}
        }
        """
        let resp = try JSONDecoder().decode(AnthropicResponse.self, from: json.data(using: .utf8)!)
        let thinking = try XCTUnwrap(resp.content.first(where: { $0.type == "thinking" }))
        XCTAssertEqual(thinking.thinking, "I should search.")
        XCTAssertEqual(thinking.signature, "sig_xyz")
    }

    func testStreamSignatureDeltaDecodes() throws {
        let json = """
        {
            "type": "content_block_delta",
            "index": 0,
            "delta": {"type": "signature_delta", "signature": "sig_streamed"}
        }
        """
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: json.data(using: .utf8)!)
        XCTAssertEqual(event.delta?.type, "signature_delta")
        XCTAssertEqual(event.delta?.signature, "sig_streamed")
    }

    // MARK: - Replay in outgoing request

    /// Verifies the assistant message round-trip: thinking block parsed from
    /// a response, carried as `reasoningContent` + `thinkingSignature`, and
    /// replayed first in the next request body. Without this, DeepSeek's
    /// Anthropic-compat mode rejects the request with
    /// "content[].thinking ... must be passed back".
    func testAssistantThinkingIsReplayedAsContentBlock() throws {
        let assistantMsg = AnthropicMessage(role: "assistant", content: [
            .thinking(text: "Plan the search.", signature: "sig_replay"),
            .text("Sure, let me search."),
            .toolUse(id: "toolu_01", name: "search", input: "{\"q\":\"swift\"}"),
        ])

        let request = AnthropicRequest(
            model: "deepseek-chat",
            maxTokens: 1024,
            messages: [
                AnthropicMessage(role: "user", content: [.text("Find Swift docs")]),
                assistantMsg,
            ],
            stream: false
        )
        let data = try APIRequestBuilder.stableJSONEncoder.encode(request)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let messages = try XCTUnwrap(dict["messages"] as? [[String: Any]])
        XCTAssertEqual(messages.count, 2)

        let assistantBlocks = try XCTUnwrap(messages[1]["content"] as? [[String: Any]])
        XCTAssertEqual(assistantBlocks.count, 3)

        // Per Anthropic spec, thinking must come first in the content array.
        XCTAssertEqual(assistantBlocks[0]["type"] as? String, "thinking")
        XCTAssertEqual(assistantBlocks[0]["thinking"] as? String, "Plan the search.")
        XCTAssertEqual(assistantBlocks[0]["signature"] as? String, "sig_replay")
        XCTAssertEqual(assistantBlocks[1]["type"] as? String, "text")
        XCTAssertEqual(assistantBlocks[2]["type"] as? String, "tool_use")
    }

    // MARK: - LLMChatMessage carries the signature

    func testLLMChatMessageCarriesThinkingSignature() {
        let msg = LLMChatMessage.assistant(
            "answer",
            reasoningContent: "thoughts",
            thinkingSignature: "sig_42"
        )
        XCTAssertEqual(msg.reasoningContent, "thoughts")
        XCTAssertEqual(msg.thinkingSignature, "sig_42")
    }

    // MARK: - End-to-end replay through AnthropicAdapter

    private func makeAdapter() -> AnthropicAdapter {
        AnthropicAdapter(
            context: LLMAdapterContext(baseURL: "https://api.deepseek.com", apiKey: "k")
        )
    }

    private func encodedBody(messages: [LLMChatMessage], thinkingLevel: ThinkingLevel = .off) throws -> [String: Any] {
        let request = try makeAdapter().buildChatRequest(
            model: "deepseek-chat",
            messages: messages,
            tools: nil,
            maxTokens: 512,
            temperature: 0.7,
            capabilities: .default,
            thinkingLevel: thinkingLevel
        )
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    private func encodedAssistant(messages: [LLMChatMessage], thinkingLevel: ThinkingLevel = .off) throws -> [[String: Any]] {
        let dict = try encodedBody(messages: messages, thinkingLevel: thinkingLevel)
        let msgs = try XCTUnwrap(dict["messages"] as? [[String: Any]])
        let assistantMsg = try XCTUnwrap(msgs.first(where: { $0["role"] as? String == "assistant" }))
        return try XCTUnwrap(assistantMsg["content"] as? [[String: Any]])
    }

    // MARK: thinking parameter is always present

    /// Root-cause fix: omitting the `thinking` parameter lets DeepSeek's
    /// Anthropic-compat default to enabled, which causes the model to emit
    /// thinking content even when our local config has it `.off` and then
    /// trips the "thinking must be passed back" check on subsequent turns.
    /// Always emit `{"type":"disabled"}` when off so providers stay in sync.
    func testThinkingParameterAlwaysEmittedWhenOff() throws {
        let dict = try encodedBody(messages: [.user("Hi")], thinkingLevel: .off)
        let thinking = try XCTUnwrap(dict["thinking"] as? [String: Any],
                                     "`thinking` field must be present even when off")
        XCTAssertEqual(thinking["type"] as? String, "disabled")
        XCTAssertNil(thinking["budget_tokens"], "disabled variant must omit budget_tokens")
    }

    /// DeepSeek v4 (Anthropic-compat) uses the `effortSwitch` strategy:
    /// enabled thinking, no `budget_tokens`, plus `output_config.effort`.
    /// (Pre-effort code paths emitted `budget_tokens`; that wire shape is
    /// rejected by DeepSeek v4 and not used anywhere.)
    func testThinkingParameterEmitsEnabledWithEffort() throws {
        let dict = try encodedBody(messages: [.user("Hi")], thinkingLevel: .high)
        let thinking = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertNil(thinking["budget_tokens"], "DeepSeek v4 rejects budget_tokens")
        let cfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "high")
    }

    func testTemperatureNotForcedWhenThinkingDisabled() throws {
        let dict = try encodedBody(messages: [.user("Hi")], thinkingLevel: .off)
        // Forcing 1.0 only applies when thinking is *actually* enabled — with
        // disabled we must pass through the caller's temperature.
        XCTAssertEqual(dict["temperature"] as? Double, 0.7)
    }

    // MARK: thinking-block replay

    /// Replay happens broadly: any prior assistant turn that carries
    /// `reasoningContent` echoes a thinking block, regardless of the current
    /// thinkingLevel or whether tool_calls are present. Cheap insurance for
    /// providers that demand it; Anthropic & DeepSeek both tolerate the
    /// extra context on turns where it isn't strictly required.
    func testThinkingReplayedOnToolUseTurn() throws {
        let toolCall = LLMToolCall(id: "toolu_1", name: "search", arguments: "{\"q\":\"x\"}")
        let assistant = LLMChatMessage.assistant(
            nil,
            toolCalls: [toolCall],
            reasoningContent: "Considered the options.",
            thinkingSignature: "sig_replay"
        )
        let blocks = try encodedAssistant(
            messages: [
                .user("Hi"),
                assistant,
                .tool(content: "result", toolCallId: "toolu_1"),
            ],
            thinkingLevel: .off
        )
        XCTAssertEqual(blocks.first?["type"] as? String, "thinking",
                       "Tool-use turn must replay thinking even when thinkingLevel is .off")
        XCTAssertEqual(blocks.first?["thinking"] as? String, "Considered the options.")
        XCTAssertEqual(blocks.first?["signature"] as? String, "sig_replay")
        XCTAssertTrue(blocks.contains(where: { $0["type"] as? String == "tool_use" }))
    }

    func testThinkingReplayedOnPlainTextAssistantTurn() throws {
        let assistant = LLMChatMessage.assistant(
            "Here's the answer.",
            reasoningContent: "Some prior reasoning.",
            thinkingSignature: "sig_old"
        )
        let blocks = try encodedAssistant(
            messages: [.user("Hi"), assistant, .user("Continue")],
            thinkingLevel: .off
        )
        XCTAssertEqual(blocks.first?["type"] as? String, "thinking",
                       "Replay broadly — text-only turns also echo thinking when present")
        XCTAssertEqual(blocks.first?["thinking"] as? String, "Some prior reasoning.")
    }

    /// When reasoningContent is absent, no thinking block is added.
    func testNoThinkingBlockEmittedWhenReasoningEmpty() throws {
        let toolCall = LLMToolCall(id: "toolu_2", name: "search", arguments: "{}")
        let assistant = LLMChatMessage.assistant(nil, toolCalls: [toolCall])
        let blocks = try encodedAssistant(
            messages: [.user("Hi"), assistant, .tool(content: "ok", toolCallId: "toolu_2")],
            thinkingLevel: .off
        )
        XCTAssertFalse(blocks.contains(where: { $0["type"] as? String == "thinking" }),
                       "No thinking block when reasoningContent is absent")
        XCTAssertEqual(blocks.first?["type"] as? String, "tool_use")
    }
}

// MARK: - AnthropicThinking encoding

final class AnthropicThinkingDisabledTests: XCTestCase {

    func testDisabledEncodesWithoutBudget() throws {
        let data = try JSONEncoder().encode(AnthropicThinking.disabled)
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["type"] as? String, "disabled")
        XCTAssertNil(dict["budget_tokens"],
                     "disabled variant must not include budget_tokens (would be invalid)")
    }

    func testEnabledStillEncodesBudget() throws {
        let data = try JSONEncoder().encode(AnthropicThinking.enabled(budget: 8192))
        let dict = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(dict["type"] as? String, "enabled")
        XCTAssertEqual(dict["budget_tokens"] as? Int, 8192)
    }
}
