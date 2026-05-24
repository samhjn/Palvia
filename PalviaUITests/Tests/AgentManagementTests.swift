import XCTest

final class AgentManagementTests: BaseTestCase {

    func test_agentList_showsEmptyStateOnFreshLaunch() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let agentList = tabBar.switchToAgents()

        agentList.verifyIsDisplayed()
        agentList.verifyEmptyState()
    }

    func test_agentList_createButtonExists() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let agentList = tabBar.switchToAgents()

        XCTAssertTrue(
            agentList.createButton.waitForExistence(timeout: 5),
            "Create agent toolbar button should exist"
        )
    }

    func test_agentList_tapCreate_showsAlert() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let agentList = tabBar.switchToAgents()

        agentList.tapCreate()
        agentList.verifyCreateAlertIsPresented()
    }

    func test_agentList_createAgent_appearsInList() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let agentList = tabBar.switchToAgents()

        agentList.createAgent(name: TestData.testAgentName)
        agentList.verifyAgentCount(1)
    }

    func test_agentList_createMultipleAgents() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let agentList = tabBar.switchToAgents()

        agentList.createAgent(name: "Agent A")

        sleep(1)

        agentList.createAgent(name: "Agent B")
        agentList.verifyAgentCount(2)
    }
}
