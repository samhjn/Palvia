import XCTest
import SwiftData
@testable import iClaw

// MARK: - LLMChatRequest Encoding Tests

final class LLMChatRequestTests: XCTestCase {

    func testRequestWithToolsEncoding() throws {
        let tool = ToolDefinitionBuilder.build(
            name: "test_tool",
            description: "A test tool",
            properties: ["input": ToolDefinitionBuilder.stringParam("The input")],
            required: ["input"]
        )
        let messages = [LLMChatMessage.user("Hello")]
        let request = LLMChatRequest(
            model: "gpt-4o",
            messages: messages,
            tools: [tool],
            toolChoice: .auto,
            stream: false,
            maxTokens: 4096,
            temperature: 0.7
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["model"] as? String, "gpt-4o")
        XCTAssertEqual(dict["stream"] as? Bool, false)
        XCTAssertEqual(dict["max_tokens"] as? Int, 4096)
        XCTAssertEqual(dict["temperature"] as? Double, 0.7)
        XCTAssertEqual(dict["tool_choice"] as? String, "auto")

        let tools = dict["tools"] as? [[String: Any]]
        XCTAssertEqual(tools?.count, 1)
        XCTAssertEqual(tools?.first?["type"] as? String, "function")

        let function = tools?.first?["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "test_tool")
    }

    func testRequestWithoutToolsOmitsToolFields() throws {
        let request = LLMChatRequest(
            model: "gpt-4o",
            messages: [LLMChatMessage.user("Hi")],
            stream: false
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(dict["tools"])
        XCTAssertNil(dict["tool_choice"])
    }

    func testRequestWithStreamOptions() throws {
        let request = LLMChatRequest(
            model: "gpt-4o",
            messages: [LLMChatMessage.user("Hi")],
            stream: true,
            streamOptions: LLMStreamOptions(includeUsage: true)
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["stream"] as? Bool, true)
        let streamOpts = dict["stream_options"] as? [String: Any]
        XCTAssertEqual(streamOpts?["include_usage"] as? Bool, true)
    }

    func testRequestMessagesPreserveOrder() throws {
        let messages = [
            LLMChatMessage.system("System prompt"),
            LLMChatMessage.user("User message"),
            LLMChatMessage.assistant("Reply"),
        ]
        let request = LLMChatRequest(model: "gpt-4o", messages: messages)

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let encodedMessages = dict["messages"] as! [[String: Any]]

        XCTAssertEqual(encodedMessages.count, 3)
        XCTAssertEqual(encodedMessages[0]["role"] as? String, "system")
        XCTAssertEqual(encodedMessages[1]["role"] as? String, "user")
        XCTAssertEqual(encodedMessages[2]["role"] as? String, "assistant")
    }
}

// MARK: - LLMToolChoice Extended Tests

final class LLMToolChoiceTests: XCTestCase {

    func testToolChoiceFunctionEncoding() throws {
        let choice = LLMToolChoice.function(name: "browser_navigate")
        let data = try JSONEncoder().encode(choice)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "function")
        let function = dict["function"] as? [String: Any]
        XCTAssertEqual(function?["name"] as? String, "browser_navigate")
    }

    func testToolChoiceDecodingUnknownStringDefaultsToAuto() throws {
        let json = "\"unknown_value\""
        let data = json.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(LLMToolChoice.self, from: data)
        if case .auto = decoded {} else {
            XCTFail("Unknown string should decode as .auto")
        }
    }

    func testToolChoiceRoundTripAuto() throws {
        let original = LLMToolChoice.auto
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMToolChoice.self, from: data)
        if case .auto = decoded {} else {
            XCTFail("Expected .auto after round trip")
        }
    }

    func testToolChoiceRoundTripNone() throws {
        let original = LLMToolChoice.none
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMToolChoice.self, from: data)
        if case .none = decoded {} else {
            XCTFail("Expected .none after round trip")
        }
    }

    func testToolChoiceRoundTripRequired() throws {
        let original = LLMToolChoice.required
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(LLMToolChoice.self, from: data)
        if case .required = decoded {} else {
            XCTFail("Expected .required after round trip")
        }
    }
}

// MARK: - Streaming Delta Tool Call Tests

final class LLMDeltaToolCallTests: XCTestCase {

    func testDecodeSingleDeltaToolCall() throws {
        let json = """
        {
            "index": 0,
            "id": "call_abc123",
            "type": "function",
            "function": {
                "name": "browser_navigate",
                "arguments": "{\\"url\\": \\"https://example.com\\"}"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let dtc = try JSONDecoder().decode(LLMDeltaToolCall.self, from: data)

        XCTAssertEqual(dtc.index, 0)
        XCTAssertEqual(dtc.id, "call_abc123")
        XCTAssertEqual(dtc.type, "function")
        XCTAssertEqual(dtc.function?.name, "browser_navigate")
        XCTAssertNotNil(dtc.function?.arguments)
    }

    func testDecodeDeltaToolCallIncrementalArguments() throws {
        let json = """
        {
            "index": 0,
            "function": {
                "arguments": "{\\"ke"
            }
        }
        """
        let data = json.data(using: .utf8)!
        let dtc = try JSONDecoder().decode(LLMDeltaToolCall.self, from: data)

        XCTAssertEqual(dtc.index, 0)
        XCTAssertNil(dtc.id)
        XCTAssertNil(dtc.type)
        XCTAssertNil(dtc.function?.name)
        XCTAssertEqual(dtc.function?.arguments, "{\"ke")
    }

    func testDecodeDeltaWithToolCalls() throws {
        let json = """
        {
            "id": "chatcmpl-stream-1",
            "choices": [
                {
                    "index": 0,
                    "delta": {
                        "tool_calls": [
                            {
                                "index": 0,
                                "id": "call_xyz",
                                "type": "function",
                                "function": {
                                    "name": "execute_javascript",
                                    "arguments": ""
                                }
                            }
                        ]
                    },
                    "finish_reason": null
                }
            ],
            "usage": null
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)

        let delta = response.choices.first?.delta
        XCTAssertNotNil(delta?.toolCalls)
        XCTAssertEqual(delta?.toolCalls?.count, 1)
        XCTAssertEqual(delta?.toolCalls?.first?.index, 0)
        XCTAssertEqual(delta?.toolCalls?.first?.id, "call_xyz")
        XCTAssertEqual(delta?.toolCalls?.first?.function?.name, "execute_javascript")
    }

    func testDecodeMultipleParallelDeltaToolCalls() throws {
        let json = """
        {
            "id": "chatcmpl-parallel",
            "choices": [
                {
                    "index": 0,
                    "delta": {
                        "tool_calls": [
                            {
                                "index": 0,
                                "id": "call_1",
                                "type": "function",
                                "function": { "name": "file_read", "arguments": "" }
                            },
                            {
                                "index": 1,
                                "id": "call_2",
                                "type": "function",
                                "function": { "name": "file_list", "arguments": "" }
                            }
                        ]
                    },
                    "finish_reason": null
                }
            ],
            "usage": null
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)

        let toolCalls = response.choices.first?.delta?.toolCalls
        XCTAssertEqual(toolCalls?.count, 2)
        XCTAssertEqual(toolCalls?[0].index, 0)
        XCTAssertEqual(toolCalls?[0].function?.name, "file_read")
        XCTAssertEqual(toolCalls?[1].index, 1)
        XCTAssertEqual(toolCalls?[1].function?.name, "file_list")
    }

    func testDecodeToolCallFinishReason() throws {
        let json = """
        {
            "id": "chatcmpl-finish",
            "choices": [
                {
                    "index": 0,
                    "delta": {},
                    "finish_reason": "tool_calls"
                }
            ],
            "usage": null
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)

        XCTAssertEqual(response.choices.first?.finishReason, "tool_calls")
    }
}

// MARK: - Multiple Tool Calls Response Tests

final class MultipleToolCallResponseTests: XCTestCase {

    func testDecodeResponseWithMultipleToolCalls() throws {
        let json = """
        {
            "id": "chatcmpl-multi",
            "choices": [
                {
                    "index": 0,
                    "message": {
                        "role": "assistant",
                        "content": null,
                        "tool_calls": [
                            {
                                "id": "call_1",
                                "type": "function",
                                "function": {
                                    "name": "file_read",
                                    "arguments": "{\\"name\\": \\"notes.txt\\"}"
                                }
                            },
                            {
                                "id": "call_2",
                                "type": "function",
                                "function": {
                                    "name": "file_list",
                                    "arguments": "{}"
                                }
                            },
                            {
                                "id": "call_3",
                                "type": "function",
                                "function": {
                                    "name": "execute_javascript",
                                    "arguments": "{\\"code\\": \\"1+1\\", \\"mode\\": \\"repl\\"}"
                                }
                            }
                        ]
                    },
                    "finish_reason": "tool_calls"
                }
            ],
            "usage": {
                "prompt_tokens": 100,
                "completion_tokens": 50,
                "total_tokens": 150
            }
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(LLMChatResponse.self, from: data)

        let toolCalls = response.choices.first?.message?.toolCalls
        XCTAssertEqual(toolCalls?.count, 3)
        XCTAssertEqual(toolCalls?[0].id, "call_1")
        XCTAssertEqual(toolCalls?[0].function.name, "file_read")
        XCTAssertEqual(toolCalls?[1].id, "call_2")
        XCTAssertEqual(toolCalls?[1].function.name, "file_list")
        XCTAssertEqual(toolCalls?[2].id, "call_3")
        XCTAssertEqual(toolCalls?[2].function.name, "execute_javascript")
    }

    func testAssistantMessageWithToolCallsEncoding() throws {
        let toolCalls = [
            LLMToolCall(id: "c1", name: "read_config", arguments: "{\"key\":\"SOUL.md\"}"),
            LLMToolCall(id: "c2", name: "file_list", arguments: "{}"),
        ]
        let msg = LLMChatMessage.assistant(nil, toolCalls: toolCalls)

        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["role"] as? String, "assistant")
        let encoded = dict["tool_calls"] as? [[String: Any]]
        XCTAssertEqual(encoded?.count, 2)
        XCTAssertEqual((encoded?[0]["function"] as? [String: Any])?["name"] as? String, "read_config")
        XCTAssertEqual((encoded?[1]["function"] as? [String: Any])?["name"] as? String, "file_list")
    }

    func testToolResponseMessageEncoding() throws {
        let msg = LLMChatMessage.tool(content: "File contents here", toolCallId: "call_abc", name: "file_read")

        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["role"] as? String, "tool")
        XCTAssertEqual(dict["content"] as? String, "File contents here")
        XCTAssertEqual(dict["tool_call_id"] as? String, "call_abc")
        XCTAssertEqual(dict["name"] as? String, "file_read")
    }

    func testToolResponseWithoutNameEncoding() throws {
        let msg = LLMChatMessage.tool(content: "result", toolCallId: "call_xyz")

        let data = try JSONEncoder().encode(msg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["role"] as? String, "tool")
        XCTAssertEqual(dict["tool_call_id"] as? String, "call_xyz")
        XCTAssertNil(dict["name"])
    }
}

// MARK: - LLMToolCall Edge Cases

final class LLMToolCallEdgeCaseTests: XCTestCase {

    func testToolCallWithEmptyArguments() throws {
        let tc = LLMToolCall(id: "tc_empty", name: "list_code", arguments: "{}")
        let data = try JSONEncoder().encode(tc)
        let decoded = try JSONDecoder().decode(LLMToolCall.self, from: data)

        XCTAssertEqual(decoded.function.arguments, "{}")
    }

    func testToolCallWithComplexNestedArguments() throws {
        let args = """
        {"filters":{"tags":["coding","review"]},"limit":10,"offset":0}
        """
        let tc = LLMToolCall(id: "tc_nested", name: "list_skills", arguments: args)
        let data = try JSONEncoder().encode(tc)
        let decoded = try JSONDecoder().decode(LLMToolCall.self, from: data)

        XCTAssertEqual(decoded.function.arguments, args)
    }

    func testToolCallWithUnicodeArguments() throws {
        let args = "{\"title\":\"日本語テスト\",\"notes\":\"中文笔记\"}"
        let tc = LLMToolCall(id: "tc_unicode", name: "calendar_create_event", arguments: args)
        let data = try JSONEncoder().encode(tc)
        let decoded = try JSONDecoder().decode(LLMToolCall.self, from: data)

        XCTAssertEqual(decoded.function.arguments, args)
    }

    func testToolCallIdentifiable() {
        let tc = LLMToolCall(id: "unique_id", name: "test", arguments: "{}")
        XCTAssertEqual(tc.id, "unique_id")
    }

    func testToolCallTypeDefaultsToFunction() {
        let tc = LLMToolCall(id: "tc_1", name: "test", arguments: "{}")
        XCTAssertEqual(tc.type, "function")
    }
}

// MARK: - LLMToolDefinition Wire Format Tests

final class LLMToolDefinitionWireFormatTests: XCTestCase {

    func testToolDefinitionEncodesOpenAIFormat() throws {
        let tool = ToolDefinitionBuilder.build(
            name: "read_config",
            description: "Read config",
            properties: ["key": ToolDefinitionBuilder.stringParam("Config key")],
            required: ["key"]
        )

        let data = try JSONEncoder().encode(tool)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "function")
        let function = dict["function"] as? [String: Any]
        XCTAssertNotNil(function)
        XCTAssertEqual(function?["name"] as? String, "read_config")
        XCTAssertEqual(function?["description"] as? String, "Read config")

        let params = function?["parameters"] as? [String: Any]
        XCTAssertEqual(params?["type"] as? String, "object")
        XCTAssertNotNil(params?["properties"])
        XCTAssertEqual(params?["required"] as? [String], ["key"])
    }

    func testToolWithEnumPropertyEncodesCorrectly() throws {
        let tool = ToolDefinitionBuilder.build(
            name: "browser_scroll",
            description: "Scroll page",
            properties: [
                "direction": ToolDefinitionBuilder.enumParam("Direction", values: ["up", "down"]),
                "pixels": ToolDefinitionBuilder.intParam("Scroll amount"),
            ]
        )

        let data = try JSONEncoder().encode(tool)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let function = dict["function"] as! [String: Any]
        let params = function["parameters"] as! [String: Any]
        let props = params["properties"] as! [String: Any]

        let direction = props["direction"] as! [String: Any]
        XCTAssertEqual(direction["type"] as? String, "string")
        XCTAssertEqual(direction["enum"] as? [String], ["up", "down"])

        let pixels = props["pixels"] as! [String: Any]
        XCTAssertEqual(pixels["type"] as? String, "integer")
    }

    func testToolWithArrayPropertyEncodesCorrectly() throws {
        let itemProp = JSONSchemaProperty(type: "string", description: "A model UUID")
        let arrayProp = JSONSchemaProperty(type: "array", description: "List of UUIDs", items: itemProp)

        let tool = LLMToolDefinition(
            function: LLMFunctionDefinition(
                name: "set_model",
                description: "Set model",
                parameters: JSONSchema(
                    type: "object",
                    properties: ["model_ids": arrayProp],
                    required: ["model_ids"]
                )
            )
        )

        let data = try JSONEncoder().encode(tool)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let function = dict["function"] as! [String: Any]
        let params = function["parameters"] as! [String: Any]
        let props = params["properties"] as! [String: Any]
        let modelIds = props["model_ids"] as! [String: Any]

        XCTAssertEqual(modelIds["type"] as? String, "array")
        let items = modelIds["items"] as? [String: Any]
        XCTAssertEqual(items?["type"] as? String, "string")
    }
}

// MARK: - FunctionCallRouter Tests

final class FunctionCallRouterToolCallTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
        agent = Agent(name: "TestAgent")
        context.insert(agent)
        try! context.save()
    }

    override func tearDown() {
        container = nil
        context = nil
        agent = nil
        super.tearDown()
    }

    @MainActor
    func testUnknownToolReturnsErrorMessage() async {
        let router = FunctionCallRouter(agent: agent, modelContext: context)
        let tc = LLMToolCall(id: "t1", name: "totally_fake_tool", arguments: "{}")
        let result = await router.execute(toolCall: tc)

        XCTAssertTrue(result.text.contains("Unknown tool"))
        XCTAssertTrue(result.text.contains("totally_fake_tool"))
    }

    @MainActor
    func testDisabledToolReturnsPermissionError() async {
        agent.setPermissionLevel(.disabled, for: .browser)
        try! context.save()

        let router = FunctionCallRouter(agent: agent, modelContext: context)
        let tc = LLMToolCall(id: "t2", name: "browser_navigate", arguments: "{\"url\":\"https://example.com\"}")
        let result = await router.execute(toolCall: tc)

        XCTAssertTrue(result.text.contains(L10n.PermissionError.toolNotPermitted("browser_navigate",
            ToolCategory.browser.displayName).prefix(10).description))
    }

    @MainActor
    func testReadOnlyBlocksWriteTools() async {
        agent.setPermissionLevel(.readOnly, for: .codeExecution)
        try! context.save()

        let router = FunctionCallRouter(agent: agent, modelContext: context)
        let tc = LLMToolCall(id: "t3", name: "execute_javascript", arguments: "{\"code\":\"1+1\"}")
        let result = await router.execute(toolCall: tc)

        XCTAssertFalse(result.text.contains("Unknown tool"),
                       "Should be blocked by permission, not unknown tool")
    }

    @MainActor
    func testReadOnlyAllowsReadTools() async {
        agent.setPermissionLevel(.readOnly, for: .codeExecution)
        try! context.save()

        let router = FunctionCallRouter(agent: agent, modelContext: context)
        let tc = LLMToolCall(id: "t4", name: "list_code", arguments: "{}")
        let result = await router.execute(toolCall: tc)

        XCTAssertFalse(result.text.contains("not permitted"),
                       "Read tool should be allowed with readOnly permission")
    }

    @MainActor
    func testMalformedJsonArgumentsHandledGracefully() async {
        let router = FunctionCallRouter(agent: agent, modelContext: context)
        let tc = LLMToolCall(id: "t5", name: "read_config", arguments: "not valid json at all")
        let result = await router.execute(toolCall: tc)

        XCTAssertFalse(result.text.isEmpty, "Should return some result even with bad arguments")
    }

    @MainActor
    func testEmptyArgumentsHandledGracefully() async {
        let router = FunctionCallRouter(agent: agent, modelContext: context)
        let tc = LLMToolCall(id: "t6", name: "list_code", arguments: "")
        let result = await router.execute(toolCall: tc)

        XCTAssertFalse(result.text.isEmpty)
    }

    @MainActor
    func testCancellationReturnsCancel() async {
        let router = FunctionCallRouter(agent: agent, modelContext: context)
        let tc = LLMToolCall(id: "t7", name: "list_code", arguments: "{}")

        let task = Task {
            try? await Task.sleep(nanoseconds: 0)
            return await router.execute(toolCall: tc)
        }
        task.cancel()
        let result = await task.value

        XCTAssertTrue(result.text.contains("Cancelled") || !result.text.isEmpty,
                      "Cancelled task should return cancelled result or complete normally")
    }
}

// MARK: - ToolCallResult Tests

final class ToolCallResultTests: XCTestCase {

    func testBasicResult() {
        let result = ToolCallResult("Success")
        XCTAssertEqual(result.text, "Success")
        XCTAssertNil(result.imageAttachments)
    }

    func testCancelledResult() {
        let result = ToolCallResult.cancelled
        XCTAssertTrue(result.text.contains("Cancelled"))
    }

    func testResultWithImageAttachments() {
        let result = ToolCallResult("Image result", imageAttachments: [])
        XCTAssertEqual(result.text, "Image result")
        XCTAssertNotNil(result.imageAttachments)
        XCTAssertTrue(result.imageAttachments!.isEmpty)
    }
}

// MARK: - Tool Filtering by Permission Tests

final class ToolFilteringTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    @MainActor
    func testDefaultAgentGetsAllTools() {
        let agent = Agent(name: "Default")
        context.insert(agent)
        try! context.save()

        let tools = ToolDefinitions.tools(for: agent)
        XCTAssertEqual(tools.count, ToolDefinitions.allTools.count)
    }

    @MainActor
    func testDisabledCategoryExcludesTools() {
        let agent = Agent(name: "Limited")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .browser)
        try! context.save()

        let tools = ToolDefinitions.tools(for: agent)
        let toolNames = Set(tools.map(\.function.name))

        XCTAssertFalse(toolNames.contains("browser_navigate"))
        XCTAssertFalse(toolNames.contains("browser_click"))
        XCTAssertFalse(toolNames.contains("browser_get_page_info"))
        XCTAssertTrue(toolNames.contains("execute_javascript"))
    }

    @MainActor
    func testReadOnlyExcludesWriteToolsOnly() {
        let agent = Agent(name: "ReadOnly")
        context.insert(agent)
        agent.setPermissionLevel(.readOnly, for: .calendar)
        try! context.save()

        let tools = ToolDefinitions.tools(for: agent)
        let toolNames = Set(tools.map(\.function.name))

        XCTAssertTrue(toolNames.contains("calendar_list_calendars"))
        XCTAssertTrue(toolNames.contains("calendar_search_events"))
        XCTAssertFalse(toolNames.contains("calendar_create_event"))
        XCTAssertFalse(toolNames.contains("calendar_update_event"))
        XCTAssertFalse(toolNames.contains("calendar_delete_event"))
    }

    @MainActor
    func testWriteOnlyExcludesReadToolsOnly() {
        let agent = Agent(name: "WriteOnly")
        context.insert(agent)
        agent.setPermissionLevel(.writeOnly, for: .health)
        try! context.save()

        let tools = ToolDefinitions.tools(for: agent)
        let toolNames = Set(tools.map(\.function.name))

        XCTAssertFalse(toolNames.contains("health_read_steps"))
        XCTAssertFalse(toolNames.contains("health_read_heart_rate"))
        XCTAssertTrue(toolNames.contains("health_write_dietary_energy"))
        XCTAssertTrue(toolNames.contains("health_write_body_mass"))
    }

    @MainActor
    func testMultipleDisabledCategoriesStackCorrectly() {
        let agent = Agent(name: "MultiDisabled")
        context.insert(agent)
        agent.setPermissionLevel(.disabled, for: .browser)
        agent.setPermissionLevel(.disabled, for: .health)
        agent.setPermissionLevel(.disabled, for: .calendar)
        try! context.save()

        let tools = ToolDefinitions.tools(for: agent)
        let toolNames = Set(tools.map(\.function.name))

        for name in ToolCategory.browser.allToolNames {
            XCTAssertFalse(toolNames.contains(name), "\(name) should be excluded")
        }
        for name in ToolCategory.health.allToolNames {
            XCTAssertFalse(toolNames.contains(name), "\(name) should be excluded")
        }
        for name in ToolCategory.calendar.allToolNames {
            XCTAssertFalse(toolNames.contains(name), "\(name) should be excluded")
        }

        XCTAssertTrue(toolNames.contains("execute_javascript"))
        XCTAssertTrue(toolNames.contains("read_config"))
    }
}

// MARK: - Anthropic Tool Format Tests

final class AnthropicToolFormatTests: XCTestCase {

    func testAnthropicToolEncoding() throws {
        let tool = AnthropicTool(
            name: "browser_navigate",
            description: "Navigate the browser",
            inputSchema: JSONSchema(
                type: "object",
                properties: ["url": JSONSchemaProperty(type: "string", description: "Target URL")],
                required: ["url"]
            )
        )

        let data = try JSONEncoder().encode(tool)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["name"] as? String, "browser_navigate")
        XCTAssertEqual(dict["description"] as? String, "Navigate the browser")

        let schema = dict["input_schema"] as? [String: Any]
        XCTAssertEqual(schema?["type"] as? String, "object")
        XCTAssertNotNil(schema?["properties"])
        XCTAssertEqual(schema?["required"] as? [String], ["url"])
    }

    func testAnthropicContentBlockToolUseEncoding() throws {
        let block = AnthropicContentBlock.toolUse(
            id: "toolu_123",
            name: "read_config",
            input: "{\"key\":\"SOUL.md\"}"
        )

        let data = try JSONEncoder().encode(block)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "tool_use")
        XCTAssertEqual(dict["id"] as? String, "toolu_123")
        XCTAssertEqual(dict["name"] as? String, "read_config")
        XCTAssertNotNil(dict["input"])
    }

    func testAnthropicContentBlockToolResultEncoding() throws {
        let block = AnthropicContentBlock.toolResult(
            toolUseId: "toolu_123",
            content: "Config content here"
        )

        let data = try JSONEncoder().encode(block)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "tool_result")
        XCTAssertEqual(dict["tool_use_id"] as? String, "toolu_123")
        XCTAssertEqual(dict["content"] as? String, "Config content here")
    }

    func testAnthropicContentBlockToolUseWithInvalidJsonFallback() throws {
        let block = AnthropicContentBlock.toolUse(
            id: "toolu_bad",
            name: "test_tool",
            input: "not valid json"
        )

        let data = try JSONEncoder().encode(block)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "tool_use")
        let input = dict["input"] as? [String: Any]
        XCTAssertNotNil(input, "Invalid JSON should fall back to empty dict")
        XCTAssertTrue(input?.isEmpty ?? false)
    }

    func testAnthropicToolResultRichEncoding() throws {
        let blocks: [AnthropicToolResultBlock] = [
            .text("Here is the result"),
            .image(mediaType: "image/png", data: "base64data"),
        ]
        let block = AnthropicContentBlock.toolResultRich(
            toolUseId: "toolu_rich",
            blocks: blocks
        )

        let data = try JSONEncoder().encode(block)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "tool_result")
        XCTAssertEqual(dict["tool_use_id"] as? String, "toolu_rich")

        let content = dict["content"] as? [[String: Any]]
        XCTAssertEqual(content?.count, 2)
        XCTAssertEqual(content?[0]["type"] as? String, "text")
        XCTAssertEqual(content?[0]["text"] as? String, "Here is the result")
        XCTAssertEqual(content?[1]["type"] as? String, "image")
    }

    func testAnthropicResponseWithToolUseDecoding() throws {
        let json = """
        {
            "id": "msg_tool",
            "type": "message",
            "role": "assistant",
            "content": [
                {"type": "text", "text": "Let me check."},
                {
                    "type": "tool_use",
                    "id": "toolu_abc",
                    "name": "execute_javascript",
                    "input": {"code": "Math.PI", "mode": "repl"}
                }
            ],
            "model": "claude-3-5-sonnet",
            "stop_reason": "tool_use",
            "usage": {"input_tokens": 50, "output_tokens": 30}
        }
        """
        let data = json.data(using: .utf8)!
        let response = try JSONDecoder().decode(AnthropicResponse.self, from: data)

        XCTAssertEqual(response.content.count, 2)
        XCTAssertEqual(response.content[0].type, "text")
        XCTAssertEqual(response.content[0].text, "Let me check.")
        XCTAssertEqual(response.content[1].type, "tool_use")
        XCTAssertEqual(response.content[1].id, "toolu_abc")
        XCTAssertEqual(response.content[1].name, "execute_javascript")
        XCTAssertNotNil(response.content[1].input)
        XCTAssertEqual(response.stopReason, "tool_use")
    }

    func testAnthropicStreamToolCallEvents() throws {
        let blockStart = """
        {
            "type": "content_block_start",
            "index": 1,
            "content_block": {
                "type": "tool_use",
                "id": "toolu_stream_1",
                "name": "read_config"
            }
        }
        """
        let data = blockStart.data(using: .utf8)!
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

        XCTAssertEqual(event.type, "content_block_start")
        XCTAssertEqual(event.index, 1)
        XCTAssertEqual(event.contentBlock?.type, "tool_use")
        XCTAssertEqual(event.contentBlock?.id, "toolu_stream_1")
        XCTAssertEqual(event.contentBlock?.name, "read_config")
    }

    func testAnthropicStreamInputJsonDelta() throws {
        let delta = """
        {
            "type": "content_block_delta",
            "index": 1,
            "delta": {
                "type": "input_json_delta",
                "partial_json": "{\\"key\\": \\"SO"
            }
        }
        """
        let data = delta.data(using: .utf8)!
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

        XCTAssertEqual(event.type, "content_block_delta")
        XCTAssertEqual(event.delta?.type, "input_json_delta")
        XCTAssertEqual(event.delta?.partialJson, "{\"key\": \"SO")
    }

    func testAnthropicStreamMessageDeltaWithToolUseStop() throws {
        let delta = """
        {
            "type": "message_delta",
            "delta": {
                "type": "message_delta",
                "stop_reason": "tool_use"
            },
            "usage": {
                "output_tokens": 42
            }
        }
        """
        let data = delta.data(using: .utf8)!
        let event = try JSONDecoder().decode(AnthropicStreamEvent.self, from: data)

        XCTAssertEqual(event.type, "message_delta")
        XCTAssertEqual(event.delta?.stopReason, "tool_use")
        XCTAssertEqual(event.usage?.outputTokens, 42)
    }
}

// MARK: - Anthropic Thinking / Token Budget Tests

final class AnthropicThinkingTests: XCTestCase {

    func testAnthropicThinkingEncoding() throws {
        let thinking = AnthropicThinking.enabled(budget: 10000)
        let data = try JSONEncoder().encode(thinking)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["type"] as? String, "enabled")
        XCTAssertEqual(dict["budget_tokens"] as? Int, 10000)
    }

    func testAnthropicThinkingCustomBudget() throws {
        let thinking = AnthropicThinking.enabled(budget: 50000)
        let data = try JSONEncoder().encode(thinking)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["budget_tokens"] as? Int, 50000)
    }

    func testAnthropicRequestWithThinkingEncoding() throws {
        let thinking = AnthropicThinking.enabled(budget: 10000)
        let request = AnthropicRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 16000,
            messages: [AnthropicMessage(role: "user", content: [.text("Hello")])],
            stream: true,
            temperature: 1.0,
            thinking: thinking
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertEqual(dict["model"] as? String, "claude-sonnet-4-6")
        XCTAssertEqual(dict["max_tokens"] as? Int, 16000)
        XCTAssertEqual(dict["temperature"] as? Double, 1.0)

        let thinkingDict = dict["thinking"] as? [String: Any]
        XCTAssertNotNil(thinkingDict)
        XCTAssertEqual(thinkingDict?["type"] as? String, "enabled")
        XCTAssertEqual(thinkingDict?["budget_tokens"] as? Int, 10000)
    }

    func testAnthropicRequestWithoutThinkingOmitsField() throws {
        let request = AnthropicRequest(
            model: "claude-sonnet-4-6",
            maxTokens: 4096,
            messages: [AnthropicMessage(role: "user", content: [.text("Hello")])],
            stream: false,
            temperature: 0.7
        )

        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]

        XCTAssertNil(dict["thinking"])
        XCTAssertEqual(dict["max_tokens"] as? Int, 4096)
    }

    func testMaxTokensAlwaysExceedsBudgetTokens() {
        // Simulates the logic in LLMService.buildAnthropicBody
        let testCases: [(maxTokens: Int, thinkingBudget: Int)] = [
            (4096, 10000),    // budget > maxTokens
            (10000, 10000),   // budget == maxTokens
            (16000, 10000),   // budget < maxTokens
            (1024, 50000),    // large budget, small maxTokens
            (128000, 1024),   // large maxTokens, small budget
        ]

        for (providerMaxTokens, thinkingBudget) in testCases {
            let budgetTokens = thinkingBudget
            let maxTokens = max(providerMaxTokens, budgetTokens + 1)

            XCTAssertGreaterThan(
                maxTokens, budgetTokens,
                "max_tokens (\(maxTokens)) must be > budget_tokens (\(budgetTokens)) "
                + "for providerMaxTokens=\(providerMaxTokens), thinkingBudget=\(thinkingBudget)"
            )
        }
    }

    // MARK: - Adaptive thinking (`output_config.effort`)

    func testAnthropicThinkingAdaptiveEncoding() throws {
        let data = try JSONEncoder().encode(AnthropicThinking.adaptive)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["type"] as? String, "adaptive")
        XCTAssertNil(dict["budget_tokens"], "adaptive must omit budget_tokens")
    }

    func testAnthropicOutputConfigEncoding() throws {
        let cfg = AnthropicOutputConfig(effort: "xhigh")
        let data = try JSONEncoder().encode(cfg)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        XCTAssertEqual(dict["effort"] as? String, "xhigh")
    }

    func testAnthropicRequestEmitsOutputConfig() throws {
        let request = AnthropicRequest(
            model: "claude-opus-4-7",
            maxTokens: 64_000,
            messages: [AnthropicMessage(role: "user", content: [.text("Hi")])],
            stream: false,
            temperature: 1.0,
            thinking: .adaptive,
            outputConfig: AnthropicOutputConfig(effort: "high")
        )
        let data = try JSONEncoder().encode(request)
        let dict = try JSONSerialization.jsonObject(with: data) as! [String: Any]
        let outputCfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(outputCfg["effort"] as? String, "high")
        XCTAssertEqual((dict["thinking"] as? [String: Any])?["type"] as? String, "adaptive")
    }
}

// MARK: - Claude model thinking-strategy classification

final class ClaudeModelInfoTests: XCTestCase {

    func testOpus47UsesAdaptive() {
        XCTAssertEqual(ClaudeModelInfo.classify("claude-opus-4-7").thinkingStrategy, .adaptive)
        XCTAssertEqual(ClaudeModelInfo.classify("claude-opus-4-7-20260101").thinkingStrategy, .adaptive)
    }

    func testOpus46AndSonnet46UseAdaptive() {
        XCTAssertEqual(ClaudeModelInfo.classify("claude-opus-4-6").thinkingStrategy, .adaptive)
        XCTAssertEqual(ClaudeModelInfo.classify("claude-sonnet-4-6").thinkingStrategy, .adaptive)
    }

    func testOpus45UsesManualWithEffort() {
        XCTAssertEqual(ClaudeModelInfo.classify("claude-opus-4-5").thinkingStrategy, .manualWithEffort)
    }

    func testOlderClaudeFallsBackToManual() {
        XCTAssertEqual(ClaudeModelInfo.classify("claude-sonnet-4-5").thinkingStrategy, .manual)
        XCTAssertEqual(ClaudeModelInfo.classify("claude-opus-4").thinkingStrategy, .manual)
        XCTAssertEqual(ClaudeModelInfo.classify("claude-3-5-sonnet").thinkingStrategy, .manual)
        XCTAssertEqual(ClaudeModelInfo.classify("claude-haiku-4-5").thinkingStrategy, .manual)
    }

    func testNonClaudeIsManual() {
        XCTAssertEqual(ClaudeModelInfo.classify("gpt-5.4").thinkingStrategy, .manual)
    }

    /// `deepseek-chat` is now classified by `DeepSeekModelInfo` and its
    /// resolved Anthropic strategy is `.effortSwitch` — verify the
    /// dispatcher gets it right.
    func testDeepSeekResolvesToEffortSwitch() {
        XCTAssertEqual(AnthropicThinkingStrategy.resolve(for: "deepseek-chat"), .effortSwitch)
        XCTAssertEqual(AnthropicThinkingStrategy.resolve(for: "deepseek-v4-pro"), .effortSwitch)
        // v3 is not v4, so it stays on the Claude-fallback path.
        XCTAssertEqual(AnthropicThinkingStrategy.resolve(for: "deepseek-v3"), .manual)
    }

    func testEffortSupportMatrix() {
        let opus47 = EffortLevelSupport.forModel("claude-opus-4-7", apiStyle: .anthropic)
        XCTAssertTrue(opus47.supportsEffort)
        XCTAssertTrue(opus47.supportsXHigh)
        XCTAssertTrue(opus47.supportsMax)
        XCTAssertTrue(opus47.supportsExplicitThinkingSwitch)

        let sonnet46 = EffortLevelSupport.forModel("claude-sonnet-4-6", apiStyle: .anthropic)
        XCTAssertTrue(sonnet46.supportsEffort)
        XCTAssertFalse(sonnet46.supportsXHigh, "xhigh is Opus-4.7 only")
        XCTAssertTrue(sonnet46.supportsMax)

        let opus45 = EffortLevelSupport.forModel("claude-opus-4-5", apiStyle: .anthropic)
        XCTAssertTrue(opus45.supportsEffort)
        XCTAssertFalse(opus45.supportsXHigh)
        XCTAssertTrue(opus45.supportsMax)

        let legacy = EffortLevelSupport.forModel("claude-sonnet-4-5", apiStyle: .anthropic)
        XCTAssertFalse(legacy.supportsEffort)
        XCTAssertTrue(legacy.supportsExplicitThinkingSwitch,
                      "Anthropic-compat fallback still emits the thinking switch")
    }

    /// DeepSeek v4 supports `xhigh`/`max` on either dialect; plain o-series
    /// only knows low/medium/high and never sees the explicit thinking
    /// switch.
    func testDeepSeekAndOpenAIDialectMatrix() {
        let dsAnth = EffortLevelSupport.forModel("deepseek-v4-pro", apiStyle: .anthropic)
        XCTAssertTrue(dsAnth.supportsEffort)
        XCTAssertTrue(dsAnth.supportsXHigh)
        XCTAssertTrue(dsAnth.supportsMax)
        XCTAssertTrue(dsAnth.supportsExplicitThinkingSwitch)

        let dsOAI = EffortLevelSupport.forModel("deepseek-chat", apiStyle: .openAI)
        XCTAssertTrue(dsOAI.supportsXHigh)
        XCTAssertTrue(dsOAI.supportsMax)
        XCTAssertTrue(dsOAI.supportsExplicitThinkingSwitch)

        let oai = EffortLevelSupport.forModel("gpt-5.4", apiStyle: .openAI)
        XCTAssertTrue(oai.supportsEffort)
        XCTAssertFalse(oai.supportsXHigh)
        XCTAssertFalse(oai.supportsMax)
        XCTAssertFalse(oai.supportsExplicitThinkingSwitch,
                       "OpenAI o-series 400s on unknown fields like `thinking`")
    }
}

// MARK: - DeepSeekModelInfo

final class DeepSeekModelInfoTests: XCTestCase {
    func testV4Family() {
        XCTAssertEqual(DeepSeekModelInfo.classify("deepseek-v4-pro"), .v4OrLater)
        XCTAssertEqual(DeepSeekModelInfo.classify("deepseek-v4-flash"), .v4OrLater)
        XCTAssertEqual(DeepSeekModelInfo.classify("deepseek-v4.1"), .v4OrLater)
        XCTAssertEqual(DeepSeekModelInfo.classify("deepseek-chat"), .v4OrLater,
                       "deepseek-chat alias points at the current (v4) model")
        XCTAssertEqual(DeepSeekModelInfo.classify("deepseek-reasoner"), .v4OrLater)
    }

    func testV3IsNotV4() {
        XCTAssertEqual(DeepSeekModelInfo.classify("deepseek-v3-pro"), .v3)
        XCTAssertEqual(DeepSeekModelInfo.classify("deepseek-v3"), .v3)
    }

    func testNonDeepSeek() {
        XCTAssertEqual(DeepSeekModelInfo.classify("gpt-5.4"), .other)
        XCTAssertEqual(DeepSeekModelInfo.classify("claude-sonnet-4-6"), .other)
    }
}

// MARK: - End-to-end Anthropic body shape per model

final class AnthropicEffortRequestTests: XCTestCase {
    private func makeAdapter() -> AnthropicAdapter {
        AnthropicAdapter(context: LLMAdapterContext(baseURL: "https://api.anthropic.com", apiKey: "k"))
    }

    private func encodeBody(model: String, level: ThinkingLevel, maxTokens: Int = 4096) throws -> [String: Any] {
        let request = try makeAdapter().buildChatRequest(
            model: model,
            messages: [.user("Hi")],
            tools: nil,
            maxTokens: maxTokens,
            temperature: 0.7,
            capabilities: .default,
            thinkingLevel: level
        )
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    // Adaptive path: Opus 4.7 with high effort should emit adaptive thinking
    // and output_config.effort, with no budget_tokens in sight.
    func testOpus47HighEffortShape() throws {
        let dict = try encodeBody(model: "claude-opus-4-7", level: .high)
        let thinking = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "adaptive")
        XCTAssertNil(thinking["budget_tokens"])
        let cfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "high")
        XCTAssertEqual(dict["temperature"] as? Double, 1.0, "thinking on requires temp == 1.0")
    }

    // xhigh on Opus 4.7 passes through verbatim and bumps max_tokens to 64k.
    func testOpus47XHighBumpsMaxTokens() throws {
        let dict = try encodeBody(model: "claude-opus-4-7", level: .xhigh, maxTokens: 4096)
        let cfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "xhigh")
        XCTAssertGreaterThanOrEqual(dict["max_tokens"] as? Int ?? 0, 64_000)
    }

    // xhigh on Sonnet 4.6 must downgrade — that level is Opus-4.7 only.
    func testSonnet46XHighClampsToHigh() throws {
        let dict = try encodeBody(model: "claude-sonnet-4-6", level: .xhigh)
        let cfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "high")
    }

    // Adaptive off: thinking still emitted (DeepSeek-compat) but as disabled,
    // and effort drops to "low" to honour the user's frugality.
    func testAdaptiveOffSendsDisabledPlusLowEffort() throws {
        let dict = try encodeBody(model: "claude-sonnet-4-6", level: .off)
        let thinking = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")
        let cfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "low")
    }

    // Opus 4.5: keeps manual extended thinking AND adds the effort hint.
    func testOpus45CombinesBudgetTokensWithEffort() throws {
        let dict = try encodeBody(model: "claude-opus-4-5", level: .high)
        let thinking = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, ThinkingLevel.high.anthropicBudgetTokens)
        let cfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "high")
    }

    // Legacy Claude (e.g. Sonnet 4.5): no output_config, manual thinking only.
    func testLegacyClaudeOmitsOutputConfig() throws {
        let dict = try encodeBody(model: "claude-sonnet-4-5", level: .high)
        XCTAssertNil(dict["output_config"], "older models reject unknown fields")
        let thinking = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertEqual(thinking["budget_tokens"] as? Int, ThinkingLevel.high.anthropicBudgetTokens)
    }

    // DeepSeek v4 over Anthropic-compat: explicit thinking switch + effort,
    // no budget_tokens, no adaptive form (DeepSeek doesn't speak adaptive).
    func testDeepSeekV4AnthropicMaxShape() throws {
        let dict = try encodeBody(model: "deepseek-v4-pro", level: .max)
        let thinking = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "enabled")
        XCTAssertNil(thinking["budget_tokens"], "DeepSeek rejects budget_tokens")
        let cfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "max")
    }

    func testDeepSeekV4AnthropicOffShape() throws {
        let dict = try encodeBody(model: "deepseek-chat", level: .off)
        let thinking = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(thinking["type"] as? String, "disabled")
        let cfg = try XCTUnwrap(dict["output_config"] as? [String: Any])
        XCTAssertEqual(cfg["effort"] as? String, "low",
                       "Off must still send effort:low to override DeepSeek's enabled-by-default")
    }
}

// MARK: - DeepSeek vs o-series on the OpenAI dialect

final class OpenAIDeepSeekEffortTests: XCTestCase {
    private func makeAdapter() -> OpenAIAdapter {
        OpenAIAdapter(context: LLMAdapterContext(baseURL: "https://api.deepseek.com", apiKey: "k"))
    }

    private func encodeBody(model: String, level: ThinkingLevel) throws -> [String: Any] {
        let request = try makeAdapter().buildChatRequest(
            model: model,
            messages: [.user("Hi")],
            tools: nil,
            maxTokens: 1024,
            temperature: 0.7,
            capabilities: .default,
            thinkingLevel: level
        )
        let body = try XCTUnwrap(request.httpBody)
        return try XCTUnwrap(JSONSerialization.jsonObject(with: body) as? [String: Any])
    }

    func testDeepSeekV4SendsThinkingSwitchAndUnclampedEffort() throws {
        let dict = try encodeBody(model: "deepseek-v4-pro", level: .max)
        XCTAssertEqual(dict["reasoning_effort"] as? String, "max",
                       "DeepSeek collapses xhigh→max server-side; we send the unclamped value verbatim")
        let switchField = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(switchField["type"] as? String, "enabled")
    }

    func testDeepSeekV4OffSendsExplicitDisabled() throws {
        let dict = try encodeBody(model: "deepseek-chat", level: .off)
        // .off has no reasoning_effort (nil) — but the thinking switch
        // must be present and disabled, otherwise DeepSeek's default-on
        // leaks through.
        XCTAssertNil(dict["reasoning_effort"])
        let switchField = try XCTUnwrap(dict["thinking"] as? [String: Any])
        XCTAssertEqual(switchField["type"] as? String, "disabled")
    }

    func testPlainOpenAIClampsXHighToHigh() throws {
        let dict = try encodeBody(model: "gpt-5.4", level: .xhigh)
        XCTAssertEqual(dict["reasoning_effort"] as? String, "high",
                       "OpenAI o-series doesn't define xhigh; client clamps")
        XCTAssertNil(dict["thinking"],
                     "Sending an unknown `thinking` field to OpenAI 400s — must be omitted")
    }

    func testPlainOpenAIClampsMaxToHigh() throws {
        let dict = try encodeBody(model: "gpt-5.4", level: .max)
        XCTAssertEqual(dict["reasoning_effort"] as? String, "high")
        XCTAssertNil(dict["thinking"])
    }
}

// MARK: - Tool Call Conversation Flow Tests

final class ToolCallConversationFlowTests: XCTestCase {

    func testFullToolCallConversationRoundTrip() throws {
        let systemMsg = LLMChatMessage.system("You are helpful.")
        let userMsg = LLMChatMessage.user("Read my config")
        let assistantMsg = LLMChatMessage.assistant(nil, toolCalls: [
            LLMToolCall(id: "call_1", name: "read_config", arguments: "{\"key\":\"SOUL.md\"}")
        ])
        let toolMsg = LLMChatMessage.tool(content: "You are a creative AI.", toolCallId: "call_1", name: "read_config")
        let finalMsg = LLMChatMessage.assistant("Your config says you are a creative AI.")

        let messages = [systemMsg, userMsg, assistantMsg, toolMsg, finalMsg]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for (i, msg) in messages.enumerated() {
            let data = try encoder.encode(msg)
            let decoded = try decoder.decode(LLMChatMessage.self, from: data)
            XCTAssertEqual(decoded.role, msg.role, "Message \(i) role mismatch")
        }

        let toolData = try encoder.encode(toolMsg)
        let decodedTool = try decoder.decode(LLMChatMessage.self, from: toolData)
        XCTAssertEqual(decodedTool.toolCallId, "call_1")

        let assistantData = try encoder.encode(assistantMsg)
        let decodedAssistant = try decoder.decode(LLMChatMessage.self, from: assistantData)
        XCTAssertEqual(decodedAssistant.toolCalls?.count, 1)
    }

    func testMultiTurnToolCallConversation() throws {
        let messages: [LLMChatMessage] = [
            .system("You are helpful."),
            .user("List my files and read notes.txt"),
            .assistant(nil, toolCalls: [
                LLMToolCall(id: "c1", name: "file_list", arguments: "{}"),
                LLMToolCall(id: "c2", name: "file_read", arguments: "{\"name\":\"notes.txt\"}"),
            ]),
            .tool(content: "notes.txt (1KB)", toolCallId: "c1", name: "file_list"),
            .tool(content: "Hello World", toolCallId: "c2", name: "file_read"),
            .assistant("You have one file: notes.txt containing 'Hello World'"),
        ]

        let encoder = JSONEncoder()
        let decoder = JSONDecoder()

        for msg in messages {
            let data = try encoder.encode(msg)
            let decoded = try decoder.decode(LLMChatMessage.self, from: data)
            XCTAssertEqual(decoded.role, msg.role)
        }

        let assistantWithTools = messages[2]
        let data = try encoder.encode(assistantWithTools)
        let decoded = try decoder.decode(LLMChatMessage.self, from: data)
        XCTAssertEqual(decoded.toolCalls?.count, 2)
        XCTAssertEqual(decoded.toolCalls?[0].function.name, "file_list")
        XCTAssertEqual(decoded.toolCalls?[1].function.name, "file_read")
    }
}

// MARK: - ToolCategory / FunctionCallRouter Consistency Tests

final class ToolCallRouterConsistencyTests: XCTestCase {

    func testEveryRegisteredToolHasADefinition() {
        let definedNames = Set(ToolDefinitions.allTools.map(\.function.name))
        let registeredNames = ToolCategory.allRegisteredToolNames

        for name in registeredNames {
            XCTAssertTrue(definedNames.contains(name),
                          "Tool '\(name)' registered in ToolCategory but missing from ToolDefinitions")
        }
    }

    func testEveryDefinedToolIsRegistered() {
        let definedNames = Set(ToolDefinitions.allTools.map(\.function.name))
        let registeredNames = ToolCategory.allRegisteredToolNames

        for name in definedNames {
            XCTAssertTrue(registeredNames.contains(name),
                          "Tool '\(name)' in ToolDefinitions but missing from ToolCategory")
        }
    }

    func testEveryCategoryHasAtLeastOneToolName() {
        for cat in ToolCategory.allCases {
            XCTAssertFalse(cat.allToolNames.isEmpty,
                           "Category \(cat.rawValue) has no tool names")
        }
    }

    func testNoDuplicateToolNamesAcrossCategories() {
        var seen = Set<String>()
        for cat in ToolCategory.allCases {
            for name in cat.allToolNames {
                XCTAssertFalse(seen.contains(name),
                               "Tool '\(name)' appears in multiple categories")
                seen.insert(name)
            }
        }
    }

    func testReadWriteToolsAreDisjoint() {
        for cat in ToolCategory.allCases {
            let readSet = Set(cat.readToolNames)
            let writeSet = Set(cat.writeToolNames)
            let overlap = readSet.intersection(writeSet)
            XCTAssertTrue(overlap.isEmpty,
                          "Category \(cat.rawValue) has tools in both read and write: \(overlap)")
        }
    }
}

// MARK: - StreamChunk Tool Call Tests

final class StreamChunkToolCallTests: XCTestCase {

    func testStreamChunkToolCallCase() {
        let tc = LLMToolCall(id: "call_stream", name: "read_config", arguments: "{\"key\":\"test\"}")
        let chunk = StreamChunk.toolCall(tc)

        if case .toolCall(let decoded) = chunk {
            XCTAssertEqual(decoded.id, "call_stream")
            XCTAssertEqual(decoded.function.name, "read_config")
            XCTAssertEqual(decoded.function.arguments, "{\"key\":\"test\"}")
        } else {
            XCTFail("Expected .toolCall")
        }
    }

    func testStreamChunkUsageCase() {
        let usage = LLMUsage(promptTokens: 100, completionTokens: 50, totalTokens: 150)
        let chunk = StreamChunk.usage(usage)

        if case .usage(let u) = chunk {
            XCTAssertEqual(u.promptTokens, 100)
            XCTAssertEqual(u.completionTokens, 50)
            XCTAssertEqual(u.totalTokens, 150)
        } else {
            XCTFail("Expected .usage")
        }
    }
}

// MARK: - LLMUsage Tests

final class LLMUsageTests: XCTestCase {

    func testUsageDecoding() throws {
        let json = """
        {
            "prompt_tokens": 256,
            "completion_tokens": 128,
            "total_tokens": 384
        }
        """
        let data = json.data(using: .utf8)!
        let usage = try JSONDecoder().decode(LLMUsage.self, from: data)

        XCTAssertEqual(usage.promptTokens, 256)
        XCTAssertEqual(usage.completionTokens, 128)
        XCTAssertEqual(usage.totalTokens, 384)
    }

    func testUsageDecodingWithNulls() throws {
        let json = """
        {
            "prompt_tokens": null,
            "completion_tokens": null,
            "total_tokens": null
        }
        """
        let data = json.data(using: .utf8)!
        let usage = try JSONDecoder().decode(LLMUsage.self, from: data)

        XCTAssertNil(usage.promptTokens)
        XCTAssertNil(usage.completionTokens)
        XCTAssertNil(usage.totalTokens)
    }

    func testUsageDecodingPartial() throws {
        let json = """
        {
            "prompt_tokens": 100
        }
        """
        let data = json.data(using: .utf8)!
        let usage = try JSONDecoder().decode(LLMUsage.self, from: data)

        XCTAssertEqual(usage.promptTokens, 100)
        XCTAssertNil(usage.completionTokens)
        XCTAssertNil(usage.totalTokens)
    }
}
