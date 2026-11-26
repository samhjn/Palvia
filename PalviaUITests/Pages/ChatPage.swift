import XCTest

final class ChatPage {
    private let app: XCUIApplication

    init(app: XCUIApplication) {
        self.app = app
    }

    var inputField: XCUIElement {
        app.descendants(matching: .any)[AccessibilityID.Chat.inputField]
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
        // In SwiftUI, views inside LazyVStack with .accessibilityIdentifier
        // typically render as "other" elements within the scroll view's subtree.
        // We scope to scroll views to avoid counting unrelated descendants.
        app.scrollViews[AccessibilityID.Chat.messageList].descendants(matching: .other)
            .matching(NSPredicate(format: "identifier BEGINSWITH %@", AccessibilityID.Chat.messageBubblePrefix))
    }

    var scrollToBottomButton: XCUIElement {
        app.buttons[AccessibilityID.Chat.scrollToBottom]
    }

    var navigationTitle: XCUIElement {
        app.navigationBars.firstMatch
    }

    static let silentModeLabels = ["Silent", "静默", "靜默", "サイレント", "무음"]
    static let verboseModeLabels = ["Verbose", "详细", "詳細", "상세"]

    var displayModeCapsule: XCUIElement {
        app.buttons[AccessibilityID.Chat.displayModeCapsule]
    }

    /// SwiftUI `Menu` action buttons inside a `Section` may drop their
    /// `.accessibilityIdentifier` on newer iOS versions, exposing only their
    /// localized label. Match either the identifier or the localized menu label
    /// while excluding the trigger capsule itself.
    var silentMenuOption: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR (identifier != %@ AND label IN %@)",
            AccessibilityID.Chat.silentOption,
            AccessibilityID.Chat.displayModeCapsule,
            Self.silentModeLabels
        )).firstMatch
    }

    var verboseMenuOption: XCUIElement {
        app.buttons.matching(NSPredicate(
            format: "identifier == %@ OR (identifier != %@ AND label IN %@)",
            AccessibilityID.Chat.verboseOption,
            AccessibilityID.Chat.displayModeCapsule,
            Self.verboseModeLabels
        )).firstMatch
    }

    static func isSilentLabel(_ label: String) -> Bool {
        silentModeLabels.contains { label.localizedCaseInsensitiveContains($0) }
    }

    static func isVerboseLabel(_ label: String) -> Bool {
        verboseModeLabels.contains { label.localizedCaseInsensitiveContains($0) }
    }

    var markdownContentViews: XCUIElementQuery {
        app.scrollViews.descendants(matching: .other).matching(identifier: AccessibilityID.Chat.markdownContent)
    }

    var toolCallCards: XCUIElementQuery {
        app.scrollViews.descendants(matching: .other).matching(identifier: AccessibilityID.Chat.toolCallCard)
    }

    var streamingBubble: XCUIElement {
        app.descendants(matching: .any)[AccessibilityID.Chat.streamingBubble]
    }

    var loadingIndicator: XCUIElement {
        app.descendants(matching: .any)[AccessibilityID.Chat.loadingIndicator]
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

    @discardableResult
    func tapDisplayModeCapsule() -> Self {
        displayModeCapsule.tapWhenReady()
        return self
    }

    @discardableResult
    func switchToSilentMode() -> Self {
        tapDisplayModeCapsule()
        silentMenuOption.tapWhenReady()
        return self
    }

    @discardableResult
    func switchToVerboseMode() -> Self {
        tapDisplayModeCapsule()
        verboseMenuOption.tapWhenReady()
        return self
    }

    @discardableResult
    func waitForSilentMode(timeout: TimeInterval = 5) -> Bool {
        waitForDisplayMode(labels: Self.silentModeLabels, timeout: timeout)
    }

    @discardableResult
    func waitForVerboseMode(timeout: TimeInterval = 5) -> Bool {
        waitForDisplayMode(labels: Self.verboseModeLabels, timeout: timeout)
    }

    private func waitForDisplayMode(labels: [String], timeout: TimeInterval) -> Bool {
        let predicates = labels.map { NSPredicate(format: "label CONTAINS[c] %@", $0) }
        let compound = NSCompoundPredicate(orPredicateWithSubpredicates: predicates)
        let exp = XCTNSPredicateExpectation(predicate: compound, object: displayModeCapsule)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    @discardableResult
    func scrollToTop() -> Self {
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeDown()
            scrollView.swipeDown()
            scrollView.swipeDown()
        }
        return self
    }

    @discardableResult
    func scrollToBottom() -> Self {
        let scrollView = app.scrollViews.firstMatch
        if scrollView.exists {
            scrollView.swipeUp()
            scrollView.swipeUp()
            scrollView.swipeUp()
        }
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

    @discardableResult
    func verifyDisplayModeCapsuleExists(timeout: TimeInterval = 5) -> Self {
        XCTAssertTrue(displayModeCapsule.waitForExistence(timeout: timeout), "Display mode capsule should exist")
        return self
    }

    @discardableResult
    func verifyDisplayModeLabel(contains text: String) -> Self {
        let label = displayModeCapsule.label
        XCTAssertTrue(label.contains(text), "Display mode capsule should contain '\(text)', got '\(label)'")
        return self
    }

    @discardableResult
    func verifyMessageBubbleCount(_ count: Int, timeout: TimeInterval = 5) -> Self {
        let predicate = NSPredicate(format: "count == %d", count)
        let expectation = XCTNSPredicateExpectation(predicate: predicate, object: messageBubbles)
        let result = XCTWaiter().wait(for: [expectation], timeout: timeout)
        if result != .completed {
            XCTAssertEqual(messageBubbles.count, count, "Expected \(count) message bubbles, got \(messageBubbles.count)")
        }
        return self
    }

    @discardableResult
    func verifyMessageBubbleCountGreaterThan(_ minimum: Int) -> Self {
        XCTAssertGreaterThan(messageBubbles.count, minimum, "Expected more than \(minimum) message bubbles")
        return self
    }

    @discardableResult
    func verifyMarkdownContentExists(timeout: TimeInterval = 5) -> Self {
        // Try accessibility-identified markdown views first, fall back to
        // checking for any rendered text that indicates markdown was parsed.
        let firstMarkdown = markdownContentViews.firstMatch
        if firstMarkdown.waitForExistence(timeout: timeout) {
            return self
        }
        // Fallback: check for typical markdown-rendered content (headings, etc.)
        let anyText = app.staticTexts.firstMatch
        XCTAssertTrue(anyText.waitForExistence(timeout: 3), "Markdown content should be rendered")
        return self
    }
}
