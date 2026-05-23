import XCTest
@testable import iClaw

final class ToolDefinitionsTests: XCTestCase {

    // MARK: - Tool Inventory

    func testAllToolsNonEmpty() {
        XCTAssertFalse(ToolDefinitions.allTools.isEmpty)
    }

    func testAllToolsHaveUniqueNames() {
        let names = ToolDefinitions.allTools.map(\.function.name)
        let uniqueNames = Set(names)
        XCTAssertEqual(names.count, uniqueNames.count, "Duplicate tool names found")
    }

    func testAllToolsHaveDescriptions() {
        for tool in ToolDefinitions.allTools {
            XCTAssertFalse(tool.function.description.isEmpty,
                          "Tool \(tool.function.name) has empty description")
        }
    }

    func testAllToolsHaveObjectTypeParameters() {
        for tool in ToolDefinitions.allTools {
            XCTAssertEqual(tool.function.parameters.type, "object",
                          "Tool \(tool.function.name) parameters should be 'object' type")
        }
    }

    func testAllToolsAreTypeFunctions() {
        for tool in ToolDefinitions.allTools {
            XCTAssertEqual(tool.type, "function",
                          "Tool \(tool.function.name) should have type 'function'")
        }
    }

    // MARK: - Required Parameters Consistency

    func testRequiredParametersExistInProperties() {
        for tool in ToolDefinitions.allTools {
            guard let required = tool.function.parameters.required else { continue }
            let propertyKeys = Set(tool.function.parameters.properties?.keys ?? [:].keys)
            for req in required {
                XCTAssertTrue(propertyKeys.contains(req),
                             "Tool \(tool.function.name): required param '\(req)' not in properties")
            }
        }
    }

    // MARK: - Specific Core Tools Exist

    func testCoreToolsExist() {
        let names = Set(ToolDefinitions.allTools.map(\.function.name))

        // Code Execution
        XCTAssertTrue(names.contains("execute_javascript"))
        XCTAssertTrue(names.contains("save_code"))
        XCTAssertTrue(names.contains("load_code"))
        XCTAssertTrue(names.contains("list_code"))
        XCTAssertTrue(names.contains("run_snippet"))
        XCTAssertTrue(names.contains("delete_code"))

        // Browser
        XCTAssertTrue(names.contains("browser_navigate"))
        XCTAssertTrue(names.contains("browser_get_page_info"))
        XCTAssertTrue(names.contains("browser_click"))
        XCTAssertTrue(names.contains("browser_input"))
        XCTAssertTrue(names.contains("browser_select"))
        XCTAssertTrue(names.contains("browser_extract"))
        XCTAssertTrue(names.contains("browser_execute_js"))
        XCTAssertTrue(names.contains("browser_wait"))
        XCTAssertTrue(names.contains("browser_scroll"))

        // Sub-Agents
        XCTAssertTrue(names.contains("create_sub_agent"))
        XCTAssertTrue(names.contains("message_sub_agent"))
        XCTAssertTrue(names.contains("collect_sub_agent_output"))
        XCTAssertTrue(names.contains("list_sub_agents"))
        XCTAssertTrue(names.contains("stop_sub_agent"))
        XCTAssertTrue(names.contains("delete_sub_agent"))

        // Cron
        XCTAssertTrue(names.contains("schedule_cron"))
        XCTAssertTrue(names.contains("unschedule_cron"))
        XCTAssertTrue(names.contains("list_cron"))

        // Config
        XCTAssertTrue(names.contains("read_config"))
        XCTAssertTrue(names.contains("write_config"))

        // Skills (Phase 4d: authoring is via fs.*; these are the agent-binding
        // and validation tools only)
        XCTAssertTrue(names.contains("install_skill"))
        XCTAssertTrue(names.contains("uninstall_skill"))
        XCTAssertTrue(names.contains("list_skills"))
        XCTAssertTrue(names.contains("validate_skill"))
        XCTAssertFalse(names.contains("create_skill"), "create_skill is removed; author via fs.writeFile('skills/<slug>/SKILL.md', ...) instead.")
        XCTAssertFalse(names.contains("edit_skill"), "edit_skill is removed; rewrite via fs.writeFile.")
        XCTAssertFalse(names.contains("delete_skill"), "delete_skill is removed; rm via fs.delete('skills/<slug>', {recursive:true}).")
        XCTAssertFalse(names.contains("read_skill"), "read_skill is removed; read via fs.readFile('skills/<slug>/SKILL.md').")

        // Model
        XCTAssertTrue(names.contains("set_model"))
        XCTAssertTrue(names.contains("get_model"))
        XCTAssertTrue(names.contains("list_models"))

        // Files
        XCTAssertTrue(names.contains("file_list"))
        XCTAssertTrue(names.contains("file_read"))
        XCTAssertTrue(names.contains("file_write"))
        XCTAssertTrue(names.contains("file_delete"))
        XCTAssertTrue(names.contains("file_info"))
        // file_mkdir was moved into the "File Ops" built-in skill; not a default tool.
        XCTAssertFalse(names.contains("file_mkdir"))
    }

    func testAppleEcosystemToolsExist() {
        let names = Set(ToolDefinitions.allTools.map(\.function.name))

        XCTAssertTrue(names.contains("calendar_list_calendars"))
        XCTAssertTrue(names.contains("calendar_create_event"))
        XCTAssertTrue(names.contains("calendar_search_events"))
        XCTAssertTrue(names.contains("reminder_list"))
        XCTAssertTrue(names.contains("reminder_create"))
        XCTAssertTrue(names.contains("contacts_search"))
        XCTAssertTrue(names.contains("clipboard_read"))
        XCTAssertTrue(names.contains("clipboard_write"))
        XCTAssertTrue(names.contains("notification_schedule"))
        XCTAssertTrue(names.contains("location_get_current"))
        XCTAssertTrue(names.contains("map_search_places"))
        // Default Health menu: steps/heart rate/sleep/body mass reads + body mass/dietary
        // energy/dietary water writes. Long-tail tools live in the "Health Plus" skill.
        XCTAssertTrue(names.contains("health_read_steps"))
        XCTAssertTrue(names.contains("health_read_heart_rate"))
        XCTAssertTrue(names.contains("health_read_sleep"))
        XCTAssertTrue(names.contains("health_read_body_mass"))
        XCTAssertTrue(names.contains("health_write_dietary_energy"))
        XCTAssertTrue(names.contains("health_write_body_mass"))
        XCTAssertTrue(names.contains("health_write_dietary_water"))
        XCTAssertFalse(names.contains("health_read_blood_pressure"))
        XCTAssertFalse(names.contains("health_write_blood_pressure"))
        XCTAssertFalse(names.contains("health_write_workout"))
        XCTAssertFalse(names.contains("health_write_dietary_carbohydrates"))
    }

    // MARK: - Specific Tool Parameters

    func testExecuteJavaScriptToolParameters() {
        let tool = ToolDefinitions.executeJavaScriptTool
        XCTAssertEqual(tool.function.name, "execute_javascript")
        let props = tool.function.parameters.properties!
        XCTAssertNotNil(props["code"])
        XCTAssertNotNil(props["mode"])
        XCTAssertNotNil(props["timeout"])
        XCTAssertEqual(props["mode"]?.enumValues, ["repl", "script"])
        XCTAssertEqual(tool.function.parameters.required, ["code"])
    }

    func testBrowserNavigateToolParameters() {
        let tool = ToolDefinitions.browserNavigateTool
        XCTAssertEqual(tool.function.name, "browser_navigate")
        let props = tool.function.parameters.properties!
        XCTAssertNotNil(props["url"])
        XCTAssertNotNil(props["action"])
        XCTAssertEqual(props["action"]?.enumValues, ["back", "forward", "reload"])
    }

    func testScheduleCronToolParameters() {
        let tool = ToolDefinitions.scheduleCronTool
        XCTAssertEqual(tool.function.name, "schedule_cron")
        XCTAssertEqual(tool.function.parameters.required, ["name", "cron_expression", "job_hint"])
        let props = tool.function.parameters.properties!
        XCTAssertNotNil(props["name"])
        XCTAssertNotNil(props["cron_expression"])
        XCTAssertNotNil(props["job_hint"])
        XCTAssertNotNil(props["enabled"])
    }

    func testMessageSubAgentToolParameters() {
        let tool = ToolDefinitions.messageSubAgentTool
        XCTAssertEqual(tool.function.name, "message_sub_agent")
        XCTAssertEqual(tool.function.parameters.required, ["agent_id", "message"])
    }

    func testFileToolsParameters() {
        let readTool = ToolDefinitions.fileReadTool
        XCTAssertEqual(readTool.function.name, "file_read")
        XCTAssertEqual(readTool.function.parameters.required, ["path"])
        XCTAssertNotNil(readTool.function.parameters.properties?["path"])
        XCTAssertNotNil(readTool.function.parameters.properties?["mode"])
        XCTAssertNotNil(readTool.function.parameters.properties?["size"])
        XCTAssertNotNil(readTool.function.parameters.properties?["offset"])
        XCTAssertEqual(readTool.function.parameters.properties?["mode"]?.enumValues, ["text", "base64", "hex"])

        let writeTool = ToolDefinitions.fileWriteTool
        XCTAssertEqual(writeTool.function.name, "file_write")
        XCTAssertEqual(writeTool.function.parameters.required, ["path", "content"])

        let listTool = ToolDefinitions.fileListTool
        XCTAssertEqual(listTool.function.name, "file_list")
        XCTAssertNil(listTool.function.parameters.required)
        XCTAssertNotNil(listTool.function.parameters.properties?["path"])
    }

    // MARK: - ToolDefinitionBuilder

    func testBuilderStringParam() {
        let prop = ToolDefinitionBuilder.stringParam("A description")
        XCTAssertEqual(prop.type, "string")
        XCTAssertEqual(prop.description, "A description")
        XCTAssertNil(prop.enumValues)
    }

    func testBuilderEnumParam() {
        let prop = ToolDefinitionBuilder.enumParam("Choose one", values: ["a", "b", "c"])
        XCTAssertEqual(prop.type, "string")
        XCTAssertEqual(prop.enumValues, ["a", "b", "c"])
    }

    func testBuilderIntParam() {
        let prop = ToolDefinitionBuilder.intParam("An integer")
        XCTAssertEqual(prop.type, "integer")
    }

    func testBuilderBoolParam() {
        let prop = ToolDefinitionBuilder.boolParam("A boolean")
        XCTAssertEqual(prop.type, "boolean")
    }

    func testBuilderNumberParam() {
        let prop = ToolDefinitionBuilder.numberParam("A number")
        XCTAssertEqual(prop.type, "number")
    }

    func testBuilderBuildTool() {
        let tool = ToolDefinitionBuilder.build(
            name: "test_tool",
            description: "A test tool",
            properties: [
                "param1": ToolDefinitionBuilder.stringParam("First param"),
                "param2": ToolDefinitionBuilder.intParam("Second param")
            ],
            required: ["param1"]
        )
        XCTAssertEqual(tool.type, "function")
        XCTAssertEqual(tool.function.name, "test_tool")
        XCTAssertEqual(tool.function.description, "A test tool")
        XCTAssertEqual(tool.function.parameters.type, "object")
        XCTAssertEqual(tool.function.parameters.properties?.count, 2)
        XCTAssertEqual(tool.function.parameters.required, ["param1"])
    }

    func testBuilderBuildToolNoProperties() {
        let tool = ToolDefinitionBuilder.build(
            name: "empty_tool",
            description: "No params"
        )
        XCTAssertNil(tool.function.parameters.properties)
        XCTAssertNil(tool.function.parameters.required)
    }

    // MARK: - Tool Count Consistency

    func testAllToolsMatchRegisteredNames() {
        let definedNames = Set(ToolDefinitions.allTools.map(\.function.name))
        let registeredNames = ToolCategory.allRegisteredToolNames
        XCTAssertEqual(definedNames, registeredNames,
                      "ToolDefinitions.allTools and ToolCategory.allRegisteredToolNames should match")
    }

    // MARK: - Tool Serialization

    func testToolDefinitionsAreSerializable() throws {
        let encoder = JSONEncoder()
        for tool in ToolDefinitions.allTools {
            let data = try encoder.encode(tool)
            XCTAssertTrue(data.count > 0, "Tool \(tool.function.name) should serialize to non-empty data")
        }
    }
}
