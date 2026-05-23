import XCTest
@testable import iClaw

// MARK: - CacheControl Encoding

final class CacheControlTests: XCTestCase {

    func testEphemeralEncoding() throws {
        let data = try JSONEncoder().encode(CacheControl.ephemeral)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        XCTAssertEqual(dict?["type"] as? String, "ephemeral")
    }
}

// MARK: - AnthropicSystemBlock Cache Encoding

final class AnthropicSystemBlockCacheTests: XCTestCase {

    func testEncodingWithoutCache() throws {
        let block = AnthropicSystemBlock(type: "text", text: "You are helpful.")
        let data = try JSONEncoder().encode(block)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["type"] as? String, "text")
        XCTAssertEqual(dict?["text"] as? String, "You are helpful.")
        XCTAssertNil(dict?["cache_control"], "cache_control should be absent when not set")
    }

    func testEncodingWithCache() throws {
        var block = AnthropicSystemBlock(type: "text", text: "You are helpful.")
        block.cacheControl = .ephemeral
        let data = try JSONEncoder().encode(block)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["type"] as? String, "text")
        XCTAssertEqual(dict?["text"] as? String, "You are helpful.")
        let cc = dict?["cache_control"] as? [String: Any]
        XCTAssertNotNil(cc, "cache_control should be present")
        XCTAssertEqual(cc?["type"] as? String, "ephemeral")
    }
}

// MARK: - AnthropicTool Cache Encoding

final class AnthropicToolCacheTests: XCTestCase {

    private func makeTool(cached: Bool = false) -> AnthropicTool {
        var tool = AnthropicTool(
            name: "execute_javascript",
            description: "Run JS code",
            inputSchema: JSONSchema(type: "object", properties: [
                "code": JSONSchemaProperty(type: "string", description: "The code")
            ], required: ["code"])
        )
        if cached { tool.cacheControl = .ephemeral }
        return tool
    }

    func testEncodingWithoutCache() throws {
        let data = try JSONEncoder().encode(makeTool())
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["name"] as? String, "execute_javascript")
        XCTAssertNil(dict?["cache_control"])
    }

    func testEncodingWithCache() throws {
        let data = try JSONEncoder().encode(makeTool(cached: true))
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["name"] as? String, "execute_javascript")
        let cc = dict?["cache_control"] as? [String: Any]
        XCTAssertNotNil(cc)
        XCTAssertEqual(cc?["type"] as? String, "ephemeral")
    }
}

// MARK: - AnthropicMessage CacheControlOnLast Encoding

final class AnthropicMessageCacheTests: XCTestCase {

    func testEncodingWithoutCache() throws {
        let msg = AnthropicMessage(role: "user", content: [.text("Hello")])
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertEqual(dict?["role"] as? String, "user")
        let content = dict?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 1)
        XCTAssertNil(content?.first?["cache_control"],
                     "No cache_control when cacheControlOnLast is nil")
    }

    func testEncodingWithCacheSingleBlock() throws {
        var msg = AnthropicMessage(role: "user", content: [.text("Hello")])
        msg.cacheControlOnLast = .ephemeral
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let content = dict?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 1)
        let cc = content?.first?["cache_control"] as? [String: Any]
        XCTAssertNotNil(cc, "Last block should have cache_control")
        XCTAssertEqual(cc?["type"] as? String, "ephemeral")
    }

    func testEncodingWithCacheMultipleBlocks() throws {
        var msg = AnthropicMessage(role: "user", content: [
            .text("First"),
            .text("Second"),
            .text("Third")
        ])
        msg.cacheControlOnLast = .ephemeral
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let content = dict?["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 3)

        // Only the last block should have cache_control
        XCTAssertNil(content?[0]["cache_control"], "First block should NOT have cache_control")
        XCTAssertNil(content?[1]["cache_control"], "Second block should NOT have cache_control")
        let cc = content?[2]["cache_control"] as? [String: Any]
        XCTAssertNotNil(cc, "Third (last) block should have cache_control")
        XCTAssertEqual(cc?["type"] as? String, "ephemeral")
    }

    func testEncodingEmptyContentWithCacheIsHarmless() throws {
        var msg = AnthropicMessage(role: "user", content: [])
        msg.cacheControlOnLast = .ephemeral
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // Empty content should still encode without crash
        let content = dict?["content"] as? [Any]
        XCTAssertEqual(content?.count, 0)
    }

    func testEncodingWithCachePreservesBlockContent() throws {
        // Ensure the original block fields are preserved alongside cache_control
        var msg = AnthropicMessage(role: "user", content: [.text("Hello world")])
        msg.cacheControlOnLast = .ephemeral
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let block = (dict?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(block?["type"] as? String, "text")
        XCTAssertEqual(block?["text"] as? String, "Hello world")
        XCTAssertNotNil(block?["cache_control"])
    }

    func testEncodingToolResultWithCache() throws {
        // Tool result blocks (encoded as "user" role) should also support cache
        var msg = AnthropicMessage(role: "user", content: [
            .toolResult(toolUseId: "toolu_01", content: "Success")
        ])
        msg.cacheControlOnLast = .ephemeral
        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let block = (dict?["content"] as? [[String: Any]])?.first
        XCTAssertEqual(block?["type"] as? String, "tool_result")
        XCTAssertEqual(block?["tool_use_id"] as? String, "toolu_01")
        let cc = block?["cache_control"] as? [String: Any]
        XCTAssertNotNil(cc, "Tool result block should also get cache_control")
    }
}

// MARK: - LLMUsage Cache Token Decoding

final class LLMUsageCacheTests: XCTestCase {

    // MARK: Anthropic format

    func testDecodingAnthropicCacheTokens() throws {
        let json = """
        {
            "prompt_tokens": 1000,
            "completion_tokens": 200,
            "total_tokens": 1200,
            "cache_creation_input_tokens": 800,
            "cache_read_input_tokens": 600
        }
        """
        let usage = try JSONDecoder().decode(LLMUsage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(usage.promptTokens, 1000)
        XCTAssertEqual(usage.completionTokens, 200)
        XCTAssertEqual(usage.cacheCreationInputTokens, 800)
        XCTAssertEqual(usage.cacheReadInputTokens, 600)
    }

    func testDecodingAnthropicCacheCreationOnly() throws {
        let json = """
        {
            "prompt_tokens": 500,
            "completion_tokens": 100,
            "cache_creation_input_tokens": 400
        }
        """
        let usage = try JSONDecoder().decode(LLMUsage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(usage.cacheCreationInputTokens, 400)
        XCTAssertNil(usage.cacheReadInputTokens, "No cache read on first request")
    }

    // MARK: OpenAI format

    func testDecodingOpenAICachedTokens() throws {
        let json = """
        {
            "prompt_tokens": 1000,
            "completion_tokens": 200,
            "total_tokens": 1200,
            "prompt_tokens_details": {
                "cached_tokens": 750
            }
        }
        """
        let usage = try JSONDecoder().decode(LLMUsage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(usage.promptTokens, 1000)
        XCTAssertEqual(usage.cacheReadInputTokens, 750,
                       "OpenAI cached_tokens should map to cacheReadInputTokens")
        XCTAssertNil(usage.cacheCreationInputTokens,
                     "OpenAI does not report cache creation tokens")
    }

    func testDecodingOpenAIZeroCachedTokens() throws {
        let json = """
        {
            "prompt_tokens": 500,
            "completion_tokens": 100,
            "total_tokens": 600,
            "prompt_tokens_details": {
                "cached_tokens": 0
            }
        }
        """
        let usage = try JSONDecoder().decode(LLMUsage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(usage.cacheReadInputTokens, 0, "Zero cached tokens should decode as 0")
    }

    func testDecodingOpenAIEmptyDetails() throws {
        let json = """
        {
            "prompt_tokens": 500,
            "completion_tokens": 100,
            "total_tokens": 600,
            "prompt_tokens_details": {}
        }
        """
        let usage = try JSONDecoder().decode(LLMUsage.self, from: json.data(using: .utf8)!)

        XCTAssertNil(usage.cacheReadInputTokens,
                     "Empty details with no cached_tokens should leave field nil")
    }

    // MARK: Anthropic takes precedence

    func testAnthropicFieldTakesPrecedenceOverOpenAI() throws {
        // Hypothetical edge case: both fields present
        let json = """
        {
            "prompt_tokens": 500,
            "completion_tokens": 100,
            "cache_read_input_tokens": 300,
            "prompt_tokens_details": {
                "cached_tokens": 999
            }
        }
        """
        let usage = try JSONDecoder().decode(LLMUsage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(usage.cacheReadInputTokens, 300,
                       "Anthropic cache_read_input_tokens should take precedence")
    }

    // MARK: Backward compatibility

    func testDecodingWithoutAnyCacheFields() throws {
        let json = """
        {
            "prompt_tokens": 256,
            "completion_tokens": 128,
            "total_tokens": 384
        }
        """
        let usage = try JSONDecoder().decode(LLMUsage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(usage.promptTokens, 256)
        XCTAssertEqual(usage.completionTokens, 128)
        XCTAssertEqual(usage.totalTokens, 384)
        XCTAssertNil(usage.cacheCreationInputTokens)
        XCTAssertNil(usage.cacheReadInputTokens)
    }

    func testDecodingEmptyJSON() throws {
        let json = "{}"
        let usage = try JSONDecoder().decode(LLMUsage.self, from: json.data(using: .utf8)!)

        XCTAssertNil(usage.promptTokens)
        XCTAssertNil(usage.completionTokens)
        XCTAssertNil(usage.totalTokens)
        XCTAssertNil(usage.cacheCreationInputTokens)
        XCTAssertNil(usage.cacheReadInputTokens)
    }

    // MARK: Memberwise init

    func testMemberwiseInitDefaults() {
        let usage = LLMUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150)

        XCTAssertEqual(usage.promptTokens, 100)
        XCTAssertEqual(usage.completionTokens, 50)
        XCTAssertEqual(usage.totalTokens, 150)
        XCTAssertNil(usage.cacheCreationInputTokens, "Default should be nil")
        XCTAssertNil(usage.cacheReadInputTokens, "Default should be nil")
    }

    func testMemberwiseInitWithCacheFields() {
        let usage = LLMUsage(
            promptTokens: 1000, completionTokens: 200, totalTokens: 1200,
            cacheCreationInputTokens: 800, cacheReadInputTokens: 600
        )

        XCTAssertEqual(usage.cacheCreationInputTokens, 800)
        XCTAssertEqual(usage.cacheReadInputTokens, 600)
    }

    // MARK: Codable round-trip

    func testCodableRoundTripWithCacheFields() throws {
        let original = LLMUsage(
            promptTokens: 500, completionTokens: 100, totalTokens: 600,
            cacheCreationInputTokens: 400, cacheReadInputTokens: 300
        )
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMUsage.self, from: data)

        XCTAssertEqual(decoded.promptTokens, original.promptTokens)
        XCTAssertEqual(decoded.completionTokens, original.completionTokens)
        XCTAssertEqual(decoded.totalTokens, original.totalTokens)
        XCTAssertEqual(decoded.cacheCreationInputTokens, original.cacheCreationInputTokens)
        XCTAssertEqual(decoded.cacheReadInputTokens, original.cacheReadInputTokens)
    }

    func testEncodeDoesNotEmitPromptTokensDetails() throws {
        // Ensure the encoder writes flat Anthropic keys, not OpenAI nested format
        let usage = LLMUsage(
            promptTokens: 100, completionTokens: 50, totalTokens: 150,
            cacheReadInputTokens: 80
        )
        let data = try JSONEncoder().encode(usage)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(dict?["prompt_tokens_details"],
                     "Encoding should not emit prompt_tokens_details (OpenAI read-only field)")
        XCTAssertEqual(dict?["cache_read_input_tokens"] as? Int, 80)
    }
}

// MARK: - AnthropicUsage Cache Token Decoding

final class AnthropicUsageCacheTests: XCTestCase {

    func testDecodingWithCacheFields() throws {
        let json = """
        {
            "input_tokens": 1000,
            "output_tokens": 200,
            "cache_creation_input_tokens": 800,
            "cache_read_input_tokens": 600
        }
        """
        let usage = try JSONDecoder().decode(AnthropicUsage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(usage.inputTokens, 1000)
        XCTAssertEqual(usage.outputTokens, 200)
        XCTAssertEqual(usage.cacheCreationInputTokens, 800)
        XCTAssertEqual(usage.cacheReadInputTokens, 600)
    }

    func testDecodingWithoutCacheFields() throws {
        let json = """
        {
            "input_tokens": 500,
            "output_tokens": 100
        }
        """
        let usage = try JSONDecoder().decode(AnthropicUsage.self, from: json.data(using: .utf8)!)

        XCTAssertEqual(usage.inputTokens, 500)
        XCTAssertEqual(usage.outputTokens, 100)
        XCTAssertNil(usage.cacheCreationInputTokens)
        XCTAssertNil(usage.cacheReadInputTokens)
    }
}

// MARK: - AnthropicRequest Encoding with Cache Breakpoints

final class AnthropicRequestCacheTests: XCTestCase {

    /// Verify that when system blocks have cache_control, the encoded request
    /// includes the cache_control field in the system array.
    func testRequestEncodingWithSystemCache() throws {
        var block = AnthropicSystemBlock(type: "text", text: "System prompt")
        block.cacheControl = .ephemeral

        let request = AnthropicRequest(
            model: "claude-sonnet-4-20250514",
            maxTokens: 1024,
            system: [block],
            messages: [AnthropicMessage(role: "user", content: [.text("Hi")])],
            stream: true
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let system = dict?["system"] as? [[String: Any]]
        XCTAssertEqual(system?.count, 1)
        let cc = system?.first?["cache_control"] as? [String: Any]
        XCTAssertNotNil(cc)
        XCTAssertEqual(cc?["type"] as? String, "ephemeral")
    }

    /// Verify that when tools have cache_control, the encoded request
    /// includes cache_control on the tool definitions.
    func testRequestEncodingWithToolCache() throws {
        var tool = AnthropicTool(
            name: "test_tool",
            description: "A test",
            inputSchema: JSONSchema(type: "object")
        )
        tool.cacheControl = .ephemeral

        let request = AnthropicRequest(
            model: "claude-sonnet-4-20250514",
            maxTokens: 1024,
            messages: [AnthropicMessage(role: "user", content: [.text("Hi")])],
            tools: [tool],
            stream: true
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        let tools = dict?["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        let cc = tools?.first?["cache_control"] as? [String: Any]
        XCTAssertNotNil(cc)
        XCTAssertEqual(cc?["type"] as? String, "ephemeral")
    }

    /// End-to-end: simulate what buildAnthropicBody produces —
    /// 2 system blocks, 3 tools, 3 user turns. Verify breakpoints land correctly.
    func testCacheBreakpointPlacement() throws {
        // Simulate buildAnthropicBody's cache breakpoint logic
        var systemBlocks = [
            AnthropicSystemBlock(type: "text", text: "Capabilities..."),
            AnthropicSystemBlock(type: "text", text: "Soul...")
        ]
        var tools: [AnthropicTool]? = [
            AnthropicTool(name: "tool_a", description: "A", inputSchema: JSONSchema(type: "object")),
            AnthropicTool(name: "tool_b", description: "B", inputSchema: JSONSchema(type: "object")),
            AnthropicTool(name: "tool_c", description: "C", inputSchema: JSONSchema(type: "object"))
        ]
        var messages = [
            AnthropicMessage(role: "user", content: [.text("Turn 1")]),
            AnthropicMessage(role: "assistant", content: [.text("Response 1")]),
            AnthropicMessage(role: "user", content: [.text("Turn 2")]),
            AnthropicMessage(role: "assistant", content: [.text("Response 2")]),
            AnthropicMessage(role: "user", content: [.text("Turn 3")])
        ]

        // Apply the same logic as buildAnthropicBody
        // Breakpoint 1: last system block
        systemBlocks[systemBlocks.count - 1].cacheControl = .ephemeral

        // Breakpoint 2: last tool
        if var t = tools, !t.isEmpty {
            t[t.count - 1].cacheControl = .ephemeral
            tools = t
        }

        // Breakpoint 3: penultimate user turn
        let userIndices = messages.indices.filter { messages[$0].role == "user" }
        if userIndices.count >= 2 {
            let penultimateIdx = userIndices[userIndices.count - 2]
            messages[penultimateIdx].cacheControlOnLast = .ephemeral
        }

        // Verify system breakpoints
        XCTAssertNil(systemBlocks[0].cacheControl, "First system block should NOT be cached")
        XCTAssertNotNil(systemBlocks[1].cacheControl, "Last system block SHOULD be cached")

        // Verify tool breakpoints
        XCTAssertNil(tools?[0].cacheControl, "First tool should NOT be cached")
        XCTAssertNil(tools?[1].cacheControl, "Second tool should NOT be cached")
        XCTAssertNotNil(tools?[2].cacheControl, "Last tool SHOULD be cached")

        // Verify message breakpoints
        // User turns are at indices 0, 2, 4. Penultimate user = index 2 (Turn 2).
        XCTAssertNil(messages[0].cacheControlOnLast, "First user turn should NOT be cached")
        XCTAssertNil(messages[1].cacheControlOnLast, "Assistant message should NOT be cached")
        XCTAssertNotNil(messages[2].cacheControlOnLast, "Penultimate user turn SHOULD be cached")
        XCTAssertNil(messages[3].cacheControlOnLast, "Assistant message should NOT be cached")
        XCTAssertNil(messages[4].cacheControlOnLast, "Last user turn should NOT be cached")

        // Verify the full request encodes correctly
        let request = AnthropicRequest(
            model: "claude-sonnet-4-20250514",
            maxTokens: 1024,
            system: systemBlocks,
            messages: messages,
            tools: tools,
            stream: true
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        // System: only last has cache_control
        let sys = dict?["system"] as? [[String: Any]]
        XCTAssertNil(sys?[0]["cache_control"])
        XCTAssertNotNil(sys?[1]["cache_control"])

        // Tools: only last has cache_control
        let tls = dict?["tools"] as? [[String: Any]]
        XCTAssertNil(tls?[0]["cache_control"])
        XCTAssertNil(tls?[1]["cache_control"])
        XCTAssertNotNil(tls?[2]["cache_control"])

        // Messages: only the penultimate user (index 2) has cache_control on its last block
        let msgs = dict?["messages"] as? [[String: Any]]
        let msg2Content = msgs?[2]["content"] as? [[String: Any]]
        XCTAssertNotNil(msg2Content?.last?["cache_control"],
                        "Penultimate user turn's last content block should have cache_control")

        // Other messages should NOT have cache_control
        for i in [0, 1, 3, 4] {
            let blocks = msgs?[i]["content"] as? [[String: Any]]
            for block in blocks ?? [] {
                XCTAssertNil(block["cache_control"],
                             "Message at index \(i) should NOT have cache_control")
            }
        }
    }

    /// Edge case: only one user turn — no penultimate user, so no message breakpoint.
    func testCacheBreakpointSingleUserTurn() {
        var messages = [
            AnthropicMessage(role: "user", content: [.text("Only turn")])
        ]

        let userIndices = messages.indices.filter { messages[$0].role == "user" }
        if userIndices.count >= 2 {
            let penultimateIdx = userIndices[userIndices.count - 2]
            messages[penultimateIdx].cacheControlOnLast = .ephemeral
        }

        // With only 1 user turn, no message should get cache_control
        XCTAssertNil(messages[0].cacheControlOnLast,
                     "Single user turn should NOT get message-level cache breakpoint")
    }

    /// Edge case: exactly two user turns — first user gets the breakpoint.
    func testCacheBreakpointTwoUserTurns() {
        var messages = [
            AnthropicMessage(role: "user", content: [.text("Turn 1")]),
            AnthropicMessage(role: "assistant", content: [.text("Response")]),
            AnthropicMessage(role: "user", content: [.text("Turn 2")])
        ]

        let userIndices = messages.indices.filter { messages[$0].role == "user" }
        if userIndices.count >= 2 {
            let penultimateIdx = userIndices[userIndices.count - 2]
            messages[penultimateIdx].cacheControlOnLast = .ephemeral
        }

        XCTAssertNotNil(messages[0].cacheControlOnLast,
                        "First user turn should be cached as penultimate")
        XCTAssertNil(messages[2].cacheControlOnLast,
                     "Last user turn should NOT be cached")
    }

    /// Edge case: no tools and no system blocks — only message breakpoint.
    func testCacheBreakpointNoToolsNoSystem() throws {
        let request = AnthropicRequest(
            model: "claude-sonnet-4-20250514",
            maxTokens: 1024,
            system: nil,
            messages: [AnthropicMessage(role: "user", content: [.text("Hi")])],
            tools: nil,
            stream: true
        )
        // Should encode without crash even with no system/tools
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as? [String: Any]

        XCTAssertNil(dict?["system"])
        XCTAssertNil(dict?["tools"])
    }
}

// MARK: - Anthropic Streaming Usage with Cache Tokens

final class AnthropicStreamCacheUsageTests: XCTestCase {

    func testMessageStartWithCacheUsage() throws {
        let json = """
        {
            "type": "message_start",
            "message": {
                "id": "msg_01",
                "role": "assistant",
                "model": "claude-sonnet-4-20250514",
                "usage": {
                    "input_tokens": 1000,
                    "output_tokens": 0,
                    "cache_creation_input_tokens": 800,
                    "cache_read_input_tokens": 0
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

        XCTAssertEqual(event.type, "message_start")
        XCTAssertEqual(event.message?.usage?.inputTokens, 1000)
        XCTAssertEqual(event.message?.usage?.cacheCreationInputTokens, 800)
        XCTAssertEqual(event.message?.usage?.cacheReadInputTokens, 0)
    }

    func testMessageStartWithCacheHit() throws {
        let json = """
        {
            "type": "message_start",
            "message": {
                "id": "msg_02",
                "role": "assistant",
                "model": "claude-sonnet-4-20250514",
                "usage": {
                    "input_tokens": 200,
                    "output_tokens": 0,
                    "cache_creation_input_tokens": 0,
                    "cache_read_input_tokens": 800
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

        XCTAssertEqual(event.message?.usage?.cacheCreationInputTokens, 0,
                       "No creation on cache hit")
        XCTAssertEqual(event.message?.usage?.cacheReadInputTokens, 800,
                       "Should report 800 tokens read from cache")
    }

    func testMessageDeltaWithCacheUsage() throws {
        let json = """
        {
            "type": "message_delta",
            "usage": {
                "input_tokens": null,
                "output_tokens": 150,
                "cache_creation_input_tokens": null,
                "cache_read_input_tokens": null
            }
        }
        """
        let data = json.data(using: .utf8)!
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

        XCTAssertEqual(event.type, "message_delta")
        XCTAssertEqual(event.usage?.outputTokens, 150)
        XCTAssertNil(event.usage?.cacheCreationInputTokens)
        XCTAssertNil(event.usage?.cacheReadInputTokens)
    }
}

// MARK: - OpenAI Response with Cache Details

final class OpenAICacheResponseTests: XCTestCase {

    func testFullResponseWithCachedTokens() throws {
        let json = """
        {
            "id": "chatcmpl-abc",
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
                "prompt_tokens": 1000,
                "completion_tokens": 50,
                "total_tokens": 1050,
                "prompt_tokens_details": {
                    "cached_tokens": 900
                }
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)

        XCTAssertEqual(response.usage?.promptTokens, 1000)
        XCTAssertEqual(response.usage?.completionTokens, 50)
        XCTAssertEqual(response.usage?.cacheReadInputTokens, 900,
                       "OpenAI cached_tokens should map to cacheReadInputTokens")
    }

    func testFullResponseWithoutCachedTokens() throws {
        let json = """
        {
            "id": "chatcmpl-xyz",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": "Hi"
                    },
                    "finish_reason": "stop"
                }
            ],
            "usage": {
                "prompt_tokens": 500,
                "completion_tokens": 10,
                "total_tokens": 510
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)

        XCTAssertEqual(response.usage?.promptTokens, 500)
        XCTAssertNil(response.usage?.cacheReadInputTokens,
                     "Without prompt_tokens_details, cache fields should be nil")
    }
}
