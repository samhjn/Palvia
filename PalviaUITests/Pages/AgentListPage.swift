import XCTest

final class AgentListPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    var createButton: XCUIElement {
        app.buttons[AccessibilityID.AgentList.createButton]
    }

    var emptyCreateButton: XCUIElement {
        app.buttons[AccessibilityID.AgentList.emptyCreateButton]
    }

    var agentRows: XCUIElementQuery {
        app.collectionViews.cells.matching(identifier: AccessibilityID.AgentList.agentRow)
    }

    /// Broader fallback query that searches all element types for the agent row identifier.
    var agentRowButtons: XCUIElementQuery {
        app.buttons.matching(identifier: AccessibilityID.AgentList.agentRow)
    }

    var navigationTitle: XCUIElement {
        app.navigationBars.firstMatch
    }

    // MARK: - Actions

    @discardableResult
    func tapCreate() -> Self {
        createButton.tapWhenReady()
        return self
    }

    /// Type an agent name in the alert text field and confirm creation.
    @discardableResult
    func createAgent(name: String) -> Self {
        tapCreate()
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 10), "Agent creation alert should appear")
        // Tap the field before typing: typing into an alert text field that
        // doesn't yet hold keyboard focus drops characters intermittently.
        let textField = alert.textFields.firstMatch
        XCTAssertTrue(textField.waitForExistence(timeout: 5), "Alert text field should appear")
        textField.tap()
        textField.typeText(name)
        // Tap the non-cancel action button (last button in the alert), waiting
        // for it to be hittable so the tap isn't dropped mid-presentation.
        let confirmButton = alert.buttons.element(boundBy: alert.buttons.count - 1)
        _ = confirmButton.waitUntilHittable(timeout: 5)
        confirmButton.tap()
        // Wait for the alert to dismiss rather than sleeping a fixed interval.
        let dismissed = XCTNSPredicateExpectation(
            predicate: NSPredicate(format: "exists == false"),
            object: alert
        )
        _ = XCTWaiter().wait(for: [dismissed], timeout: 5)
        return self
    }

    func selectAgent(at index: Int) {
        agentRows.element(boundBy: index).tapWhenReady()
    }

    // MARK: - Assertions

    @discardableResult
    func verifyIsDisplayed(timeout: TimeInterval = 5) -> Self {
        XCTAssertTrue(navigationTitle.waitForExistence(timeout: timeout), "Agent list should be displayed")
        return self
    }

    @discardableResult
    func verifyEmptyState() -> Self {
        // Wait for the view to load (ProgressView disappears once viewModel initializes)
        sleep(3)
        let cellCount = agentRows.count
        let buttonCount = agentRowButtons.count
        let total = max(cellCount, buttonCount)
        XCTAssertEqual(total, 0, "Agent list should have no rows in empty state")
        XCTAssertTrue(createButton.exists, "Create agent toolbar button should still be available")
        return self
    }

    @discardableResult
    func verifyAgentCount(_ count: Int) -> Self {
        if count > 0 {
            let firstRow = agentRows.firstMatch
            if !firstRow.waitForExistence(timeout: 5) {
                _ = agentRowButtons.firstMatch.waitForExistence(timeout: 3)
            }
        }
        let cellCount = agentRows.count
        let buttonCount = agentRowButtons.count
        let matchCount = max(cellCount, buttonCount)
        XCTAssertEqual(matchCount, count, "Expected \(count) agents, found \(matchCount) (cells=\(cellCount), buttons=\(buttonCount))")
        return self
    }

    @discardableResult
    func verifyCreateAlertIsPresented() -> Self {
        let alert = app.alerts.firstMatch
        XCTAssertTrue(alert.waitForExistence(timeout: 5), "Create agent alert should be presented")
        return self
    }
}
