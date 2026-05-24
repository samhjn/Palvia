import XCTest

final class TabBarPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    private var tabBar: XCUIElement { app.tabBars.firstMatch }

    var sessionsTab: XCUIElement { tabBar.buttons.element(boundBy: 0) }
    var agentsTab: XCUIElement { tabBar.buttons.element(boundBy: 1) }
    var browserTab: XCUIElement { tabBar.buttons.element(boundBy: 2) }
    var skillsTab: XCUIElement { tabBar.buttons.element(boundBy: 3) }
    var settingsTab: XCUIElement { tabBar.buttons.element(boundBy: 4) }

    var isVisible: Bool { tabBar.exists }

    @discardableResult
    func switchToSessions() -> SessionListPage {
        sessionsTab.tap()
        return SessionListPage(app: app)
    }

    @discardableResult
    func switchToAgents() -> AgentListPage {
        agentsTab.tap()
        return AgentListPage(app: app)
    }

    func switchToBrowser() {
        browserTab.tap()
    }

    func switchToSkills() {
        skillsTab.tap()
    }

    @discardableResult
    func switchToSettings() -> SettingsPage {
        settingsTab.tap()
        return SettingsPage(app: app)
    }

    func verifyAllTabsExist() {
        XCTAssertTrue(tabBar.exists, "Tab bar should exist")
        XCTAssertEqual(tabBar.buttons.count, 5, "Should have exactly 5 tabs")
    }

    func verifyTabIsSelected(_ index: Int) {
        let tab = tabBar.buttons.element(boundBy: index)
        XCTAssertTrue(tab.isSelected, "Tab at index \(index) should be selected")
    }
}
