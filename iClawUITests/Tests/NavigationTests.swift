import XCTest

final class NavigationTests: BaseTestCase {

    func test_tabBar_allTabsExist() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        tabBar.verifyAllTabsExist()
    }

    func test_tabBar_defaultTabIsSessions() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        tabBar.verifyTabIsSelected(0)
    }

    func test_tabBar_switchToAgents() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let agentList = tabBar.switchToAgents()

        agentList.verifyIsDisplayed()
        tabBar.verifyTabIsSelected(1)
    }

    func test_tabBar_switchToBrowser() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        tabBar.switchToBrowser()
        tabBar.verifyTabIsSelected(2)
    }

    func test_tabBar_switchToSkills() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        tabBar.switchToSkills()
        tabBar.verifyTabIsSelected(3)
    }

    func test_tabBar_switchToSettings() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)
        let settings = tabBar.switchToSettings()

        settings.verifyIsDisplayed()
        tabBar.verifyTabIsSelected(4)
    }

    func test_tabBar_roundTrip_sessionsToAgentsAndBack() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)

        tabBar.switchToAgents()
        tabBar.verifyTabIsSelected(1)

        tabBar.switchToSessions()
        tabBar.verifyTabIsSelected(0)
    }

    func test_tabBar_cycleAllTabs() {
        waitForAppReady()
        let tabBar = TabBarPage(app: app)

        XCTContext.runActivity(named: "Switch to Agents") { _ in
            tabBar.switchToAgents()
            tabBar.verifyTabIsSelected(1)
        }

        XCTContext.runActivity(named: "Switch to Browser") { _ in
            tabBar.switchToBrowser()
            tabBar.verifyTabIsSelected(2)
        }

        XCTContext.runActivity(named: "Switch to Skills") { _ in
            tabBar.switchToSkills()
            tabBar.verifyTabIsSelected(3)
        }

        XCTContext.runActivity(named: "Switch to Settings") { _ in
            tabBar.switchToSettings()
            tabBar.verifyTabIsSelected(4)
        }

        XCTContext.runActivity(named: "Return to Sessions") { _ in
            tabBar.switchToSessions()
            tabBar.verifyTabIsSelected(0)
        }
    }
}
