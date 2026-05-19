import XCTest

final class ChatPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    var inputField: XCUIElement {
        app.otherElements[AccessibilityID.Chat.inputField]
    }

    var sendButton: XCUIElement {
        app.buttons[AccessibilityID.Chat.sendButton]
    }

    var stopButton: XCUIElement {
        app.buttons[AccessibilityID.Chat.stopButton]
    }

    var menuButton: XCUIElement {
        app.buttons[AccessibilityID.Chat.menuButton]
    }

    var messageBubbles: XCUIElementQuery {
        app.otherElements.matching(identifier: AccessibilityID.Chat.messageBubble)
    }

    var scrollToBottomButton: XCUIElement {
        app.buttons[AccessibilityID.Chat.scrollToBottom]
    }

    var navigationTitle: XCUIElement {
        app.navigationBars.firstMatch
    }

    // MARK: - Actions

    @discardableResult
    func typeMessage(_ text: String) -> Self {
        inputField.tapWhenReady()
        inputField.typeText(text)
        return self
    }

    @discardableResult
    func tapSend() -> Self {
        sendButton.tapWhenReady()
        return self
    }

    @discardableResult
    func tapStop() -> Self {
        stopButton.tapWhenReady()
        return self
    }

    @discardableResult
    func tapMenu() -> Self {
        menuButton.tapWhenReady()
        return self
    }

    // MARK: - Assertions

    @discardableResult
    func verifyIsDisplayed(timeout: TimeInterval = 5) -> Self {
        XCTAssertTrue(sendButton.waitForExistence(timeout: timeout), "Chat view should be displayed")
        return self
    }

    @discardableResult
    func verifySendButtonExists() -> Self {
        XCTAssertTrue(sendButton.exists, "Send button should exist")
        return self
    }

    @discardableResult
    func verifySendButtonDisabled() -> Self {
        XCTAssertFalse(sendButton.isEnabled, "Send button should be disabled when input is empty")
        return self
    }

    @discardableResult
    func verifyMenuButtonExists() -> Self {
        XCTAssertTrue(menuButton.waitForExistence(timeout: 5), "Menu button should exist")
        return self
    }
}
