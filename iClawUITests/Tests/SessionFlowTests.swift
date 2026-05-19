import XCTest

final class SessionFlowTests: BaseTestCase {

    func test_sessionList_showsEmptyStateOnFreshLaunch() {
        waitForAppReady()
        let sessionList = SessionListPage(app: app)
        sessionList.verifyIsDisplayed()
        sessionList.verifyEmptyState()
    }

    func test_sessionList_newSessionButtonExists() {
        waitForAppReady()
        let sessionList = SessionListPage(app: app)
        XCTAssertTrue(
            sessionList.newSessionButton.waitForExistence(timeout: 5),
            "New session toolbar button should exist"
        )
    }

    func test_sessionList_tapNewSession_showsSheet() {
        waitForAppReady()
        let sessionList = SessionListPage(app: app)

        sessionList.tapNewSession()
        sessionList.verifyNewSessionSheetIsPresented()
    }

    func test_sessionList_dismissNewSessionSheet() {
        waitForAppReady()
        let sessionList = SessionListPage(app: app)

        sessionList.tapNewSession()
        sessionList.verifyNewSessionSheetIsPresented()
        sessionList.dismissNewSessionSheet()

        let cancelButton = app.buttons[AccessibilityID.NewSessionSheet.cancelButton]
        XCTAssertFalse(cancelButton.exists, "Sheet should be dismissed")
    }

    func test_sessionList_createSession_withAgent() throws {
        waitForAppReady()

        XCTContext.runActivity(named: "Create an agent first") { _ in
            let tabBar = TabBarPage(app: app)
            let agentList = tabBar.switchToAgents()
            agentList.createAgent(name: TestData.testAgentName)

            _ = agentList.verifyAgentCount(1)

            tabBar.switchToSessions()
        }

        XCTContext.runActivity(named: "Create a new session") { _ in
            let sessionList = SessionListPage(app: app)
            sessionList.tapNewSession()
            sessionList.verifyNewSessionSheetIsPresented()

            let agentRow = app.buttons[AccessibilityID.NewSessionSheet.agentRow].firstMatch
            XCTAssertTrue(agentRow.waitForExistence(timeout: 5), "Agent row should appear in sheet")
            agentRow.tap()
        }

        XCTContext.runActivity(named: "Verify chat view opened") { _ in
            let chat = ChatPage(app: app)
            chat.verifyIsDisplayed()
            chat.verifySendButtonExists()
        }
    }
}
