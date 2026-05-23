import XCTest

final class SettingsPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    var addProviderButton: XCUIElement {
        app.buttons[AccessibilityID.Settings.addProviderButton]
    }

    var aboutRow: XCUIElement {
        app.buttons[AccessibilityID.Settings.aboutRow]
    }

    var backgroundToggle: XCUIElement {
        app.switches[AccessibilityID.Settings.backgroundToggle]
    }

    var skillDisclosureToggle: XCUIElement {
        app.switches[AccessibilityID.Settings.skillDisclosureToggle]
    }

    var providerRows: XCUIElementQuery {
        app.buttons.matching(identifier: AccessibilityID.Settings.providerRow)
    }

    var navigationTitle: XCUIElement {
        app.navigationBars.firstMatch
    }

    // MARK: - Actions

    @discardableResult
    func tapAddProvider() -> Self {
        addProviderButton.tapWhenReady()
        return self
    }

    @discardableResult
    func tapAbout() -> Self {
        aboutRow.tapWhenReady()
        return self
    }

    // MARK: - Assertions

    @discardableResult
    func verifyIsDisplayed(timeout: TimeInterval = 5) -> Self {
        XCTAssertTrue(navigationTitle.waitForExistence(timeout: timeout), "Settings should be displayed")
        return self
    }

    @discardableResult
    func verifyAddProviderButtonExists() -> Self {
        XCTAssertTrue(addProviderButton.waitForExistence(timeout: 5), "Add provider button should exist")
        return self
    }

    @discardableResult
    func verifyAboutRowExists() -> Self {
        XCTAssertTrue(aboutRow.waitForExistence(timeout: 5), "About row should exist")
        return self
    }

    @discardableResult
    func verifyTogglesExist() -> Self {
        XCTAssertTrue(backgroundToggle.waitForExistence(timeout: 5), "Background toggle should exist")
        XCTAssertTrue(skillDisclosureToggle.exists, "Skill disclosure toggle should exist")
        return self
    }
}
