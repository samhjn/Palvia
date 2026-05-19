import XCTest

final class SessionListPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    var newSessionButton: XCUIElement {
        app.buttons[AccessibilityID.SessionList.newSessionButton]
    }

    var emptyNewSessionButton: XCUIElement {
        app.buttons[AccessibilityID.SessionList.emptyNewSessionButton]
    }

    var sessionRows: XCUIElementQuery {
        app.cells.matching(identifier: AccessibilityID.SessionList.sessionRow)
    }

    var navigationTitle: XCUIElement {
        app.navigationBars.firstMatch
    }

    // MARK: - Actions

    @discardableResult
    func tapNewSession() -> Self {
        newSessionButton.tapWhenReady()
        return self
    }

    func selectSession(at index: Int) -> ChatPage {
        sessionRows.element(boundBy: index).tapWhenReady()
        return ChatPage(app: app)
    }

    // MARK: - Assertions

    @discardableResult
    func verifyIsDisplayed(timeout: TimeInterval = 5) -> Self {
        XCTAssertTrue(navigationTitle.waitForExistence(timeout: timeout), "Session list should be displayed")
        return self
    }

    @discardableResult
    func verifyEmptyState() -> Self {
        // Wait for the view to load (ProgressView disappears once viewModel initializes)
        sleep(3)
        XCTAssertEqual(sessionRows.count, 0, "Session list should have no rows in empty state")
        XCTAssertTrue(newSessionButton.exists, "New session toolbar button should still be available")
        return self
    }

    @discardableResult
    func verifySessionCount(_ count: Int) -> Self {
        let matchCount = sessionRows.count
        XCTAssertEqual(matchCount, count, "Expected \(count) sessions, found \(matchCount)")
        return self
    }

    @discardableResult
    func verifyNewSessionSheetIsPresented() -> Self {
        let cancelButton = app.buttons[AccessibilityID.NewSessionSheet.cancelButton]
        XCTAssertTrue(cancelButton.waitForExistence(timeout: 5), "New session sheet should be presented")
        return self
    }

    func dismissNewSessionSheet() {
        let cancelButton = app.buttons[AccessibilityID.NewSessionSheet.cancelButton]
        if cancelButton.exists {
            cancelButton.tap()
        }
    }
}
