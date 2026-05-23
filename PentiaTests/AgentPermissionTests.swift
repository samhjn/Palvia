import XCTest
import SwiftData
@testable import iClaw

final class AgentPermissionTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!
    private var agent: Agent!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self])
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

    // MARK: - Default Permissions

    @MainActor
    func testDefaultPermissionsAllowAll() {
        XCTAssertTrue(agent.toolPermissions.isEmpty)
        for cat in ToolCategory.allCases {
            XCTAssertEqual(agent.permissionLevel(for: cat), .readWrite)
        }
    }

    @MainActor
    func testDefaultIsToolAllowed() {
        XCTAssertTrue(agent.isToolAllowed("browser_navigate"))
        XCTAssertTrue(agent.isToolAllowed("execute_javascript"))
        XCTAssertTrue(agent.isToolAllowed("calendar_create_event"))
        XCTAssertTrue(agent.isToolAllowed("health_read_steps"))
        XCTAssertTrue(agent.isToolAllowed("read_config"))
    }

    @MainActor
    func testUnknownToolAlwaysAllowed() {
        XCTAssertTrue(agent.isToolAllowed("completely_unknown_tool"))
    }

    // MARK: - Setting Permissions

    @MainActor
    func testSetPermissionDisabled() {
        agent.setPermissionLevel(.disabled, for: .browser)
        XCTAssertEqual(agent.permissionLevel(for: .browser), .disabled)
        XCTAssertFalse(agent.isToolAllowed("browser_navigate"))
        XCTAssertFalse(agent.isToolAllowed("browser_get_page_info"))
    }

    @MainActor
    func testSetPermissionReadOnly() {
        agent.setPermissionLevel(.readOnly, for: .calendar)
        XCTAssertEqual(agent.permissionLevel(for: .calendar), .readOnly)
        XCTAssertTrue(agent.isToolAllowed("calendar_search_events"))
        XCTAssertTrue(agent.isToolAllowed("calendar_list_calendars"))
        XCTAssertFalse(agent.isToolAllowed("calendar_create_event"))
        XCTAssertFalse(agent.isToolAllowed("calendar_update_event"))
        XCTAssertFalse(agent.isToolAllowed("calendar_delete_event"))
    }

    @MainActor
    func testSetPermissionWriteOnly() {
        agent.setPermissionLevel(.writeOnly, for: .health)
        XCTAssertEqual(agent.permissionLevel(for: .health), .writeOnly)
        XCTAssertFalse(agent.isToolAllowed("health_read_steps"))
        XCTAssertFalse(agent.isToolAllowed("health_read_heart_rate"))
        XCTAssertTrue(agent.isToolAllowed("health_write_dietary_energy"))
        XCTAssertTrue(agent.isToolAllowed("health_write_body_mass"))
    }

    @MainActor
    func testResetPermissionToReadWrite() {
        agent.setPermissionLevel(.disabled, for: .browser)
        XCTAssertFalse(agent.isToolAllowed("browser_navigate"))

        agent.setPermissionLevel(.readWrite, for: .browser)
        XCTAssertTrue(agent.isToolAllowed("browser_navigate"))
        XCTAssertFalse(agent.toolPermissions.keys.contains("browser"),
                       "readWrite should remove key from storage")
    }

    @MainActor
    func testMultipleCategoryPermissions() {
        agent.setPermissionLevel(.disabled, for: .browser)
        agent.setPermissionLevel(.readOnly, for: .calendar)
        agent.setPermissionLevel(.writeOnly, for: .health)

        XCTAssertFalse(agent.isToolAllowed("browser_navigate"))
        XCTAssertTrue(agent.isToolAllowed("calendar_search_events"))
        XCTAssertFalse(agent.isToolAllowed("calendar_create_event"))
        XCTAssertFalse(agent.isToolAllowed("health_read_steps"))
        XCTAssertTrue(agent.isToolAllowed("health_write_body_mass"))

        XCTAssertTrue(agent.isToolAllowed("execute_javascript"))
        XCTAssertTrue(agent.isToolAllowed("read_config"))
    }

    // MARK: - Blocked Bridge Actions

    @MainActor
    func testBlockedBridgeActionsDefault() {
        let blocked = ToolCategory.blockedBridgeActions(for: agent)
        XCTAssertTrue(blocked.isEmpty, "Default agent should have no blocked bridge actions")
    }

    @MainActor
    func testBlockedBridgeActionsDisabledCategory() {
        agent.setPermissionLevel(.disabled, for: .calendar)
        let blocked = ToolCategory.blockedBridgeActions(for: agent)
        XCTAssertTrue(blocked.contains("calendar.searchEvents"))
        XCTAssertTrue(blocked.contains("calendar.createEvent"))
        XCTAssertTrue(blocked.contains("calendar.listCalendars"))
    }

    @MainActor
    func testBlockedBridgeActionsReadOnly() {
        agent.setPermissionLevel(.readOnly, for: .calendar)
        let blocked = ToolCategory.blockedBridgeActions(for: agent)
        XCTAssertFalse(blocked.contains("calendar.searchEvents"))
        XCTAssertTrue(blocked.contains("calendar.createEvent"))
    }

    @MainActor
    func testBlockedBridgeActionsWriteOnly() {
        agent.setPermissionLevel(.writeOnly, for: .health)
        let blocked = ToolCategory.blockedBridgeActions(for: agent)
        XCTAssertTrue(blocked.contains("health.readSteps"))
        XCTAssertFalse(blocked.contains("health.writeDietaryEnergy"))
    }

    // MARK: - Tool Permissions Persistence

    @MainActor
    func testToolPermissionsCodableRoundTrip() {
        agent.setPermissionLevel(.readOnly, for: .calendar)
        agent.setPermissionLevel(.disabled, for: .browser)

        let raw = agent.appleToolPermissionsRaw
        XCTAssertNotNil(raw)

        let newAgent = Agent(name: "NewAgent")
        newAgent.appleToolPermissionsRaw = raw

        XCTAssertEqual(newAgent.permissionLevel(for: .calendar), .readOnly)
        XCTAssertEqual(newAgent.permissionLevel(for: .browser), .disabled)
        XCTAssertEqual(newAgent.permissionLevel(for: .health), .readWrite)
    }

    // MARK: - Agent Properties

    @MainActor
    func testAgentSubAgentTypes() {
        let main = Agent(name: "Main")
        XCTAssertTrue(main.isMainAgent)
        XCTAssertFalse(main.isSubAgent)
        XCTAssertFalse(main.isTempSubAgent)
        XCTAssertFalse(main.isPersistentSubAgent)

        let temp = Agent(name: "Temp")
        temp.subAgentType = "temp"
        XCTAssertTrue(temp.isTempSubAgent)
        XCTAssertFalse(temp.isPersistentSubAgent)

        let persistent = Agent(name: "Persistent")
        persistent.subAgentType = "persistent"
        XCTAssertFalse(persistent.isTempSubAgent)
        XCTAssertTrue(persistent.isPersistentSubAgent)
    }

    // MARK: - Model Whitelist

    @MainActor
    func testAllowedModelIdsEmptyAllowsAll() {
        let providerId = UUID()
        XCTAssertTrue(agent.isModelAllowed(providerId: providerId, modelName: "gpt-4o"))
    }

    @MainActor
    func testAllowedModelIdsRestricts() {
        let providerId = UUID()
        agent.allowedModelIds = ["\(providerId.uuidString):gpt-4o"]

        XCTAssertTrue(agent.isModelAllowed(providerId: providerId, modelName: "gpt-4o"))
        XCTAssertFalse(agent.isModelAllowed(providerId: providerId, modelName: "gpt-3.5"))
        XCTAssertFalse(agent.isModelAllowed(providerId: UUID(), modelName: "gpt-4o"))
    }

    @MainActor
    func testAllowedModelIdsRoundTrip() {
        let id1 = UUID()
        let id2 = UUID()
        agent.allowedModelIds = ["\(id1.uuidString):model-a", "\(id2.uuidString):model-b"]

        XCTAssertEqual(agent.allowedModelIds.count, 2)
        XCTAssertTrue(agent.allowedModelIds.contains("\(id1.uuidString):model-a"))
    }

    @MainActor
    func testAllowedModelIdsClearResets() {
        agent.allowedModelIds = ["some:model"]
        XCTAssertFalse(agent.allowedModelIds.isEmpty)

        agent.allowedModelIds = []
        XCTAssertTrue(agent.allowedModelIds.isEmpty)
        XCTAssertNil(agent.allowedModelIdsRaw)
    }

    // MARK: - Fallback Provider IDs

    @MainActor
    func testFallbackProviderIdsRoundTrip() {
        let id1 = UUID()
        let id2 = UUID()
        agent.fallbackProviderIds = [id1, id2]

        XCTAssertEqual(agent.fallbackProviderIds.count, 2)
        XCTAssertEqual(agent.fallbackProviderIds[0], id1)
        XCTAssertEqual(agent.fallbackProviderIds[1], id2)
    }

    @MainActor
    func testFallbackProviderIdsEmpty() {
        XCTAssertTrue(agent.fallbackProviderIds.isEmpty)
    }

    @MainActor
    func testFallbackModelNamesRoundTrip() {
        agent.fallbackModelNames = ["gpt-4o", "claude-3-opus"]
        XCTAssertEqual(agent.fallbackModelNames.count, 2)
        XCTAssertEqual(agent.fallbackModelNames[0], "gpt-4o")
        XCTAssertEqual(agent.fallbackModelNames[1], "claude-3-opus")
    }

    // MARK: - Compression Threshold

    @MainActor
    func testEffectiveCompressionThresholdDefault() {
        XCTAssertEqual(agent.compressionThreshold, 0)
        XCTAssertEqual(agent.effectiveCompressionThreshold, ContextManager.compressionThreshold)
    }

    @MainActor
    func testEffectiveCompressionThresholdCustom() {
        agent.compressionThreshold = 10000
        XCTAssertEqual(agent.effectiveCompressionThreshold, 10000)
    }

    // MARK: - Files Permission

    @MainActor
    func testFilesPermissionDisabled() {
        agent.setPermissionLevel(.disabled, for: .files)
        XCTAssertEqual(agent.permissionLevel(for: .files), .disabled)
        XCTAssertFalse(agent.isToolAllowed("file_list"))
        XCTAssertFalse(agent.isToolAllowed("file_read"))
        XCTAssertFalse(agent.isToolAllowed("file_write"))
        XCTAssertFalse(agent.isToolAllowed("file_delete"))
        XCTAssertFalse(agent.isToolAllowed("file_info"))
    }

    @MainActor
    func testFilesPermissionReadOnly() {
        agent.setPermissionLevel(.readOnly, for: .files)
        XCTAssertTrue(agent.isToolAllowed("file_list"))
        XCTAssertTrue(agent.isToolAllowed("file_read"))
        XCTAssertTrue(agent.isToolAllowed("file_info"))
        XCTAssertFalse(agent.isToolAllowed("file_write"))
        XCTAssertFalse(agent.isToolAllowed("file_delete"))
    }

    @MainActor
    func testFilesPermissionWriteOnly() {
        agent.setPermissionLevel(.writeOnly, for: .files)
        XCTAssertFalse(agent.isToolAllowed("file_list"))
        XCTAssertFalse(agent.isToolAllowed("file_read"))
        XCTAssertFalse(agent.isToolAllowed("file_info"))
        XCTAssertTrue(agent.isToolAllowed("file_write"))
        XCTAssertTrue(agent.isToolAllowed("file_delete"))
    }

    @MainActor
    func testFilesBridgeActionsDisabled() {
        agent.setPermissionLevel(.disabled, for: .files)
        let blocked = ToolCategory.blockedBridgeActions(for: agent)
        XCTAssertTrue(blocked.contains("files.list"))
        XCTAssertTrue(blocked.contains("files.read"))
        XCTAssertTrue(blocked.contains("files.write"))
        XCTAssertTrue(blocked.contains("files.delete"))
        XCTAssertTrue(blocked.contains("files.info"))
    }

    @MainActor
    func testFilesBridgeActionsReadOnly() {
        agent.setPermissionLevel(.readOnly, for: .files)
        let blocked = ToolCategory.blockedBridgeActions(for: agent)
        XCTAssertFalse(blocked.contains("files.list"))
        XCTAssertFalse(blocked.contains("files.read"))
        XCTAssertFalse(blocked.contains("files.info"))
        XCTAssertTrue(blocked.contains("files.write"))
        XCTAssertTrue(blocked.contains("files.delete"))
    }
}
