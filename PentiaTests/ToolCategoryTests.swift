import XCTest
@testable import iClaw

final class ToolCategoryTests: XCTestCase {

    // MARK: - ToolPermissionLevel

    func testPermissionLevelReadWrite() {
        let level = ToolPermissionLevel.readWrite
        XCTAssertTrue(level.allowsRead)
        XCTAssertTrue(level.allowsWrite)
    }

    func testPermissionLevelReadOnly() {
        let level = ToolPermissionLevel.readOnly
        XCTAssertTrue(level.allowsRead)
        XCTAssertFalse(level.allowsWrite)
    }

    func testPermissionLevelWriteOnly() {
        let level = ToolPermissionLevel.writeOnly
        XCTAssertFalse(level.allowsRead)
        XCTAssertTrue(level.allowsWrite)
    }

    func testPermissionLevelDisabled() {
        let level = ToolPermissionLevel.disabled
        XCTAssertFalse(level.allowsRead)
        XCTAssertFalse(level.allowsWrite)
    }

    func testPermissionLevelCodable() throws {
        for level in ToolPermissionLevel.allCases {
            let data = try JSONEncoder().encode(level)
            let decoded = try JSONDecoder().decode(ToolPermissionLevel.self, from: data)
            XCTAssertEqual(decoded, level)
        }
    }

    func testPermissionLevelRawValues() {
        XCTAssertEqual(ToolPermissionLevel.readWrite.rawValue, "rw")
        XCTAssertEqual(ToolPermissionLevel.readOnly.rawValue, "r")
        XCTAssertEqual(ToolPermissionLevel.writeOnly.rawValue, "w")
        XCTAssertEqual(ToolPermissionLevel.disabled.rawValue, "-")
    }

    func testPermissionLevelDisplayLabels() {
        for level in ToolPermissionLevel.allCases {
            XCTAssertFalse(level.displayLabel.isEmpty)
            XCTAssertFalse(level.iconName.isEmpty)
            XCTAssertFalse(level.iconColor.isEmpty)
        }
    }

    // MARK: - ToolCategory Enumeration

    func testAllCategoriesExist() {
        XCTAssertTrue(ToolCategory.allCases.count > 0)
        XCTAssertTrue(ToolCategory.allCases.contains(.calendar))
        XCTAssertTrue(ToolCategory.allCases.contains(.browser))
        XCTAssertTrue(ToolCategory.allCases.contains(.codeExecution))
        XCTAssertTrue(ToolCategory.allCases.contains(.cron))
        XCTAssertTrue(ToolCategory.allCases.contains(.health))
        XCTAssertTrue(ToolCategory.allCases.contains(.subAgents))
        XCTAssertTrue(ToolCategory.allCases.contains(.files))
    }

    func testAppleCategories() {
        let apple = ToolCategory.appleCategories
        XCTAssertTrue(apple.contains(.calendar))
        XCTAssertTrue(apple.contains(.reminders))
        XCTAssertTrue(apple.contains(.contacts))
        XCTAssertTrue(apple.contains(.clipboard))
        XCTAssertTrue(apple.contains(.notifications))
        XCTAssertTrue(apple.contains(.location))
        XCTAssertTrue(apple.contains(.map))
        XCTAssertTrue(apple.contains(.health))
        XCTAssertFalse(apple.contains(.browser))
        XCTAssertFalse(apple.contains(.codeExecution))
    }

    func testAgentCategories() {
        let agent = ToolCategory.agentCategories
        XCTAssertTrue(agent.contains(.browser))
        XCTAssertTrue(agent.contains(.codeExecution))
        XCTAssertTrue(agent.contains(.subAgents))
        XCTAssertTrue(agent.contains(.cron))
        XCTAssertTrue(agent.contains(.skills))
        XCTAssertTrue(agent.contains(.config))
        XCTAssertTrue(agent.contains(.model))
        XCTAssertTrue(agent.contains(.files))
        XCTAssertFalse(agent.contains(.calendar))
    }

    func testIsAppleCategory() {
        XCTAssertTrue(ToolCategory.calendar.isAppleCategory)
        XCTAssertTrue(ToolCategory.health.isAppleCategory)
        XCTAssertFalse(ToolCategory.browser.isAppleCategory)
        XCTAssertFalse(ToolCategory.codeExecution.isAppleCategory)
    }

    // MARK: - Tool Names

    func testEveryToolNameIsUnique() {
        var allNames = Set<String>()
        for cat in ToolCategory.allCases {
            for name in cat.allToolNames {
                XCTAssertFalse(allNames.contains(name), "Duplicate tool name: \(name)")
                allNames.insert(name)
            }
        }
    }

    func testReadToolNamesAreSubsetOfAll() {
        for cat in ToolCategory.allCases {
            for name in cat.readToolNames {
                XCTAssertTrue(cat.allToolNames.contains(name), "\(name) not in allToolNames for \(cat)")
            }
        }
    }

    func testWriteToolNamesAreSubsetOfAll() {
        for cat in ToolCategory.allCases {
            for name in cat.writeToolNames {
                XCTAssertTrue(cat.allToolNames.contains(name), "\(name) not in allToolNames for \(cat)")
            }
        }
    }

    func testAllToolNamesIsUnionOfReadAndWrite() {
        for cat in ToolCategory.allCases {
            let combined = Set(cat.readToolNames + cat.writeToolNames)
            XCTAssertEqual(combined, Set(cat.allToolNames), "allToolNames mismatch for \(cat)")
        }
    }

    func testAllRegisteredToolNamesContainsAllCategories() {
        for cat in ToolCategory.allCases {
            for name in cat.allToolNames {
                XCTAssertTrue(ToolCategory.allRegisteredToolNames.contains(name),
                              "\(name) not in allRegisteredToolNames")
            }
        }
    }

    func testAllAppleToolNamesSubset() {
        for cat in ToolCategory.appleCategories {
            for name in cat.allToolNames {
                XCTAssertTrue(ToolCategory.allAppleToolNames.contains(name),
                              "\(name) not in allAppleToolNames")
            }
        }
        for cat in ToolCategory.agentCategories {
            for name in cat.allToolNames {
                XCTAssertFalse(ToolCategory.allAppleToolNames.contains(name),
                               "\(name) should not be in allAppleToolNames")
            }
        }
    }

    // MARK: - Category Lookup

    func testCategoryForToolName() {
        XCTAssertEqual(ToolCategory.category(for: "browser_navigate"), .browser)
        XCTAssertEqual(ToolCategory.category(for: "execute_javascript"), .codeExecution)
        XCTAssertEqual(ToolCategory.category(for: "schedule_cron"), .cron)
        XCTAssertEqual(ToolCategory.category(for: "calendar_create_event"), .calendar)
        XCTAssertEqual(ToolCategory.category(for: "health_read_steps"), .health)
        XCTAssertEqual(ToolCategory.category(for: "message_sub_agent"), .subAgents)
        XCTAssertEqual(ToolCategory.category(for: "read_config"), .config)
        XCTAssertEqual(ToolCategory.category(for: "set_model"), .model)
        XCTAssertEqual(ToolCategory.category(for: "file_list"), .files)
        XCTAssertEqual(ToolCategory.category(for: "file_read"), .files)
        XCTAssertEqual(ToolCategory.category(for: "file_write"), .files)
        XCTAssertEqual(ToolCategory.category(for: "file_delete"), .files)
        XCTAssertEqual(ToolCategory.category(for: "file_info"), .files)
        // file_mkdir moved into the File Ops skill; no longer a registered default tool.
        XCTAssertNil(ToolCategory.category(for: "file_mkdir"))
        // Long-tail health tools moved into the Health Plus skill; no longer registered defaults.
        XCTAssertNil(ToolCategory.category(for: "health_read_blood_pressure"))
        XCTAssertNil(ToolCategory.category(for: "health_write_blood_pressure"))
        XCTAssertNil(ToolCategory.category(for: "health_write_workout"))
        XCTAssertNil(ToolCategory.category(for: "health_write_dietary_carbohydrates"))
        XCTAssertNil(ToolCategory.category(for: "unknown_tool"))
    }

    func testIsWriteTool() {
        XCTAssertTrue(ToolCategory.isWriteTool("browser_navigate"))
        XCTAssertTrue(ToolCategory.isWriteTool("execute_javascript"))
        XCTAssertTrue(ToolCategory.isWriteTool("calendar_create_event"))
        XCTAssertTrue(ToolCategory.isWriteTool("schedule_cron"))
        XCTAssertTrue(ToolCategory.isWriteTool("file_write"))
        XCTAssertTrue(ToolCategory.isWriteTool("file_delete"))
        XCTAssertFalse(ToolCategory.isWriteTool("browser_get_page_info"))
        XCTAssertFalse(ToolCategory.isWriteTool("list_cron"))
        XCTAssertFalse(ToolCategory.isWriteTool("read_config"))
        XCTAssertFalse(ToolCategory.isWriteTool("file_list"))
        XCTAssertFalse(ToolCategory.isWriteTool("file_read"))
        XCTAssertFalse(ToolCategory.isWriteTool("file_info"))
        // file_mkdir no longer a registered tool after move to File Ops skill.
        XCTAssertFalse(ToolCategory.isWriteTool("file_mkdir"))
        // Long-tail health writes moved to Health Plus skill; no longer registered default writes.
        XCTAssertFalse(ToolCategory.isWriteTool("health_write_blood_pressure"))
        XCTAssertFalse(ToolCategory.isWriteTool("health_write_workout"))
        XCTAssertFalse(ToolCategory.isWriteTool("unknown_tool"))
    }

    // MARK: - Bridge Actions

    func testBridgeActionsExistForAppleCategories() {
        for cat in ToolCategory.appleCategories {
            XCTAssertFalse(cat.allBridgeActions.isEmpty,
                          "Apple category \(cat) should have bridge actions")
        }
    }

    func testAgentCategoriesHaveNoBridgeActions() {
        let exceptionsWithBridgeActions: Set<ToolCategory> = [.files]
        for cat in ToolCategory.agentCategories where !exceptionsWithBridgeActions.contains(cat) {
            XCTAssertTrue(cat.allBridgeActions.isEmpty,
                         "Agent category \(cat) should have no bridge actions")
        }
    }

    func testFilesCategoryHasBridgeActions() {
        XCTAssertFalse(ToolCategory.files.allBridgeActions.isEmpty)
        XCTAssertTrue(ToolCategory.files.bridgeReadActions.contains("files.list"))
        XCTAssertTrue(ToolCategory.files.bridgeReadActions.contains("files.read"))
        XCTAssertTrue(ToolCategory.files.bridgeReadActions.contains("files.readFile"))
        XCTAssertTrue(ToolCategory.files.bridgeReadActions.contains("files.info"))
        XCTAssertTrue(ToolCategory.files.bridgeReadActions.contains("files.stat"))
        XCTAssertTrue(ToolCategory.files.bridgeReadActions.contains("files.exists"))
        XCTAssertTrue(ToolCategory.files.bridgeReadActions.contains("files.seek"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.write"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.writeFile"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.appendFile"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.delete"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.mkdir"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.cp"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.mv"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.open"))
        XCTAssertTrue(ToolCategory.files.bridgeWriteActions.contains("files.truncate"))
    }

    func testAllBridgeActionNamesCoversAll() {
        for cat in ToolCategory.allCases {
            for action in cat.allBridgeActions {
                XCTAssertTrue(ToolCategory.allBridgeActionNames.contains(action))
            }
        }
    }

    func testCategoryForBridgeAction() {
        XCTAssertEqual(ToolCategory.category(forBridgeAction: "calendar.searchEvents"), .calendar)
        XCTAssertEqual(ToolCategory.category(forBridgeAction: "health.readSteps"), .health)
        XCTAssertEqual(ToolCategory.category(forBridgeAction: "clipboard.read"), .clipboard)
        XCTAssertNil(ToolCategory.category(forBridgeAction: "unknown.action"))
    }

    func testIsBridgeWriteAction() {
        XCTAssertTrue(ToolCategory.isBridgeWriteAction("calendar.createEvent"))
        XCTAssertTrue(ToolCategory.isBridgeWriteAction("clipboard.write"))
        XCTAssertFalse(ToolCategory.isBridgeWriteAction("calendar.searchEvents"))
        XCTAssertFalse(ToolCategory.isBridgeWriteAction("clipboard.read"))
    }

    // MARK: - Display Properties

    func testDisplayNameNonEmpty() {
        for cat in ToolCategory.allCases {
            XCTAssertFalse(cat.displayName.isEmpty, "displayName empty for \(cat)")
        }
    }

    func testSystemImageNonEmpty() {
        for cat in ToolCategory.allCases {
            XCTAssertFalse(cat.systemImage.isEmpty, "systemImage empty for \(cat)")
        }
    }

    func testIdEqualsRawValue() {
        for cat in ToolCategory.allCases {
            XCTAssertEqual(cat.id, cat.rawValue)
        }
    }

    // MARK: - HasWriteTools

    func testHasWriteToolsCorrectness() {
        XCTAssertTrue(ToolCategory.calendar.hasWriteTools)
        XCTAssertTrue(ToolCategory.browser.hasWriteTools)
        XCTAssertTrue(ToolCategory.health.hasWriteTools)
        XCTAssertTrue(ToolCategory.files.hasWriteTools)
        XCTAssertFalse(ToolCategory.contacts.hasWriteTools)
        XCTAssertFalse(ToolCategory.location.hasWriteTools)
        XCTAssertFalse(ToolCategory.map.hasWriteTools)
    }

    // MARK: - Available Levels

    func testAvailableLevelsForReadOnlyCategories() {
        for cat in ToolCategory.allCases where !cat.hasWriteTools {
            XCTAssertEqual(cat.availableLevels, [.readWrite, .disabled],
                          "\(cat) should only have readWrite and disabled levels")
        }
    }

    func testAvailableLevelsForReadWriteCategories() {
        for cat in ToolCategory.allCases where cat.hasWriteTools {
            XCTAssertEqual(cat.availableLevels, ToolPermissionLevel.allCases,
                          "\(cat) should have all permission levels")
        }
    }
}
