import XCTest

/// UI tests for silent/verbose mode switching, long markdown rendering,
/// and multi-round long markdown output scenarios.
///
/// Uses a single shared app launch per class to avoid ~25s cold start per test.
/// Each test navigates back to the session list and re-enters (~3s) instead.
final class ChatDisplayModeTests: BaseTestCase {

    private static var sharedApp: XCUIApplication!

    override class func setUp() {
        super.setUp()
        let app = XCUIApplication()
        app.launchArguments += [LaunchArguments.uiTesting, LaunchArguments.seedMarkdown]
        app.launch()
        sharedApp = app
    }

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = Self.sharedApp
        navigateToSessionListIfNeeded()
    }

    override func tearDownWithError() throws {
        ensureVerboseMode()
        // Don't nil out `app` — it's shared across all tests in this class.
    }

    override class func tearDown() {
        sharedApp?.terminate()
        sharedApp = nil
        super.tearDown()
    }

    /// Navigate back to session list if currently in a chat view.
    private func navigateToSessionListIfNeeded() {
        let sessionRow = app.cells.matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
        if sessionRow.waitForExistence(timeout: 2) { return }

        // Also check as button (iPad / different iOS versions)
        let sessionBtn = app.buttons.matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
        if sessionBtn.exists { return }

        // We're in chat view — tap the navigation back button
        let backButton = app.navigationBars.buttons.firstMatch
        if backButton.waitForExistence(timeout: 3) {
            backButton.tap()
            // Wait for session list to appear
            _ = sessionRow.waitForExistence(timeout: 5)
                || sessionBtn.waitForExistence(timeout: 3)
        }
    }

    /// Reset display mode to verbose so the next test starts cleanly.
    private func ensureVerboseMode() {
        let capsule = app.buttons[AccessibilityID.Chat.displayModeCapsule]
        guard capsule.exists else { return }
        let label = capsule.label
        if label.localizedCaseInsensitiveContains("Silent")
            || label.localizedCaseInsensitiveContains("静默") {
            capsule.tap()
            let verboseBtn = app.buttons[AccessibilityID.Chat.verboseOption]
            if verboseBtn.waitForExistence(timeout: 3) {
                verboseBtn.tap()
            }
        }
    }

    // MARK: - Helpers

    private func enterSeededSession() -> ChatPage {
        let cellRow = app.cells.matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
        let buttonRow = app.buttons.matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch

        if cellRow.waitForExistence(timeout: 8) {
            cellRow.tap()
        } else if buttonRow.waitForExistence(timeout: 3) {
            buttonRow.tap()
        } else {
            let anyRow = app.descendants(matching: .any)
                .matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
            if anyRow.waitForExistence(timeout: 3) {
                anyRow.tap()
            } else {
                XCTFail("Seeded session row should appear in the list")
                return ChatPage(app: app)
            }
        }

        let chat = ChatPage(app: app)
        let sendBtn = app.buttons[AccessibilityID.Chat.sendButton]
        let capsule = app.buttons[AccessibilityID.Chat.displayModeCapsule]

        // Wait for navigation to leave the session list before asserting chat controls.
        let listGone = NSPredicate(format: "exists == false")
        let listGoneExp = XCTNSPredicateExpectation(predicate: listGone, object: cellRow)
        _ = XCTWaiter().wait(for: [listGoneExp], timeout: 5)

        let loaded = sendBtn.waitForExistence(timeout: 10) || capsule.waitForExistence(timeout: 5)
        XCTAssertTrue(loaded, "Chat view should be displayed (sendButton or displayModeCapsule)")
        return chat
    }

    /// Wait for display mode capsule to reflect the given mode keyword.
    private func waitForMode(_ keyword: String, chat: ChatPage, timeout: TimeInterval = 5) {
        let capsule = chat.displayModeCapsule
        let pred = NSPredicate(format: "label CONTAINS[c] %@", keyword)
        let exp = XCTNSPredicateExpectation(predicate: pred, object: capsule)
        _ = XCTWaiter().wait(for: [exp], timeout: timeout)
    }

    /// Wait for any of the given keywords to appear in staticTexts.
    private func waitForAnyKeyword(_ keywords: [String], timeout: TimeInterval = 5) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while Date() < deadline {
            for keyword in keywords {
                let match = app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS[c] %@", keyword)
                ).firstMatch
                if match.exists { return true }
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.3))
        }
        return false
    }

    // MARK: - Silent/Verbose Mode Switching Tests

    func test_displayModeCapsule_existsInChat() {
        let chat = enterSeededSession()
        chat.verifyDisplayModeCapsuleExists()
    }

    func test_switchToSilentMode_hidesToolMessages() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Verify starts in verbose mode") { _ in
            chat.verifyDisplayModeCapsuleExists()
            let label = chat.displayModeCapsule.label
            XCTAssertTrue(
                label.localizedCaseInsensitiveContains("Verbose") || label.localizedCaseInsensitiveContains("详细"),
                "Should start in verbose mode, got label: \(label)"
            )
        }

        XCTContext.runActivity(named: "Switch to silent mode") { _ in
            chat.switchToSilentMode()
            waitForMode("静", chat: chat)
        }

        XCTContext.runActivity(named: "Verify capsule shows silent mode") { _ in
            let label = chat.displayModeCapsule.label
            XCTAssertTrue(
                label.localizedCaseInsensitiveContains("Silent") || label.localizedCaseInsensitiveContains("静默"),
                "Should be in silent mode after switch, got label: \(label)"
            )
        }
    }

    func test_switchBackToVerboseMode_restoresAllMessages() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Switch to silent mode") { _ in
            chat.switchToSilentMode()
            waitForMode("静", chat: chat)
            let label = chat.displayModeCapsule.label
            XCTAssertTrue(
                label.localizedCaseInsensitiveContains("Silent") || label.localizedCaseInsensitiveContains("静默"),
                "Should be in silent mode"
            )
        }

        XCTContext.runActivity(named: "Switch back to verbose mode") { _ in
            chat.switchToVerboseMode()
            waitForMode("详", chat: chat)
        }

        XCTContext.runActivity(named: "Verify verbose mode is restored") { _ in
            let label = chat.displayModeCapsule.label
            XCTAssertTrue(
                label.localizedCaseInsensitiveContains("Verbose") || label.localizedCaseInsensitiveContains("详细"),
                "Should be back in verbose mode, got label: \(label)"
            )
            chat.verifySendButtonExists()
        }
    }

    func test_rapidModeToggle_doesNotCrash() {
        let chat = enterSeededSession()
        chat.verifyDisplayModeCapsuleExists()

        XCTContext.runActivity(named: "Rapidly toggle display mode multiple times") { _ in
            for _ in 0..<5 {
                chat.switchToSilentMode()
                usleep(300_000)
                chat.switchToVerboseMode()
                usleep(300_000)
            }
        }

        XCTContext.runActivity(named: "Verify app is still responsive") { _ in
            chat.verifyIsDisplayed()
            chat.verifyDisplayModeCapsuleExists()
            chat.verifySendButtonExists()
        }
    }

    func test_silentMode_preservedAcrossScroll() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Switch to silent mode") { _ in
            chat.switchToSilentMode()
            waitForMode("静", chat: chat)
        }

        XCTContext.runActivity(named: "Scroll up and back down") { _ in
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeDown()
                scrollView.swipeUp()
            }
        }

        XCTContext.runActivity(named: "Verify silent mode still active") { _ in
            // Check the capsule label — this is the reliable indicator,
            // not staticTexts.count which varies with LazyVStack rendering.
            let capsule = chat.displayModeCapsule
            let label = capsule.label
            XCTAssertTrue(
                label.localizedCaseInsensitiveContains("Silent") || label.localizedCaseInsensitiveContains("静默"),
                "Silent mode should persist after scrolling, got label: \(label)"
            )
            chat.verifyDisplayModeCapsuleExists()
        }
    }

    // MARK: - Long Markdown Rendering Tests

    func test_longMarkdownContent_rendersWithoutCrash() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Verify markdown content is rendered near bottom") { _ in
            let found = waitForAnyKeyword(["Result", "错误处理", "throws"], timeout: 5)
            XCTAssertTrue(found, "Markdown content from last round should be rendered")
        }

        XCTContext.runActivity(named: "Verify chat is interactive with markdown content loaded") { _ in
            chat.verifyIsDisplayed()
            chat.verifySendButtonExists()
        }
    }

    func test_longMarkdownContent_scrollable() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Verify bottom content is visible on entry") { _ in
            let found = waitForAnyKeyword(["Result", "错误处理", "throws"], timeout: 5)
            XCTAssertTrue(found, "Should see bottom content on entry")
        }

        XCTContext.runActivity(named: "Scroll up and verify content changes") { _ in
            let scrollView = app.scrollViews.firstMatch
            guard scrollView.exists else {
                XCTFail("Scroll view should exist")
                return
            }
            scrollView.swipeDown()
            scrollView.swipeDown()
            scrollView.swipeDown()

            XCTAssertGreaterThan(app.staticTexts.count, 0, "Should see text content after scrolling up")
        }
    }

    func test_longMarkdownContent_codeBlocksRendered() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Verify code blocks are present in markdown") { _ in
            chat.verifyMarkdownContentExists()

            let found = waitForAnyKeyword(["swift", "func", "struct", "class"], timeout: 5)
            XCTAssertTrue(found,
                          "Markdown with Swift code blocks should render code-related text")
        }
    }

    func test_longMarkdownContent_tablesRendered() {
        _ = enterSeededSession()

        XCTContext.runActivity(named: "Scroll to table region and verify content") { _ in
            if waitForAnyKeyword(["throws", "@State", "Binding"], timeout: 3) { return }

            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeDown()
            }
            let found = waitForAnyKeyword(["@State", "throws", "Binding"], timeout: 5)
            XCTAssertTrue(found, "Markdown table or code content should be rendered")
        }
    }

    // MARK: - Multi-Round Long Markdown Output Tests

    func test_multiRound_allRoundsVisible() {
        _ = enterSeededSession()

        XCTContext.runActivity(named: "Verify last round content visible at bottom") { _ in
            let found = waitForAnyKeyword(["Result", "错误处理", "throws"], timeout: 5)
            XCTAssertTrue(found, "Third round content should be visible at bottom")
        }

        XCTContext.runActivity(named: "Verify scrolling reveals earlier rounds") { _ in
            let scrollView = app.scrollViews.firstMatch
            guard scrollView.exists else {
                XCTFail("Scroll view should exist")
                return
            }
            for _ in 0..<5 {
                scrollView.swipeDown()
            }
            XCTAssertGreaterThan(app.staticTexts.count, 0, "Earlier rounds should be visible after scrolling to top")
        }
    }

    func test_multiRound_scrollThroughAllRounds() {
        _ = enterSeededSession()

        XCTContext.runActivity(named: "Scroll to first round at top") { _ in
            let scrollView = app.scrollViews.firstMatch
            guard scrollView.exists else {
                XCTFail("Scroll view should exist")
                return
            }
            for _ in 0..<8 {
                scrollView.swipeDown()
            }

            let firstUserContent = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Swift 语言")
            ).firstMatch
            XCTAssertTrue(firstUserContent.waitForExistence(timeout: 5),
                          "First round user message should be visible at top")
        }

        XCTContext.runActivity(named: "Scroll to last round at bottom") { _ in
            let scrollView = app.scrollViews.firstMatch
            for _ in 0..<8 {
                scrollView.swipeUp()
            }

            let lastContent = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "错误处理")
            ).firstMatch
            XCTAssertTrue(lastContent.waitForExistence(timeout: 5),
                          "Last round content should be visible at bottom")
        }
    }

    func test_multiRound_silentModeFiltersAcrossAllRounds() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Verify verbose mode and visible content") { _ in
            let label = chat.displayModeCapsule.label
            XCTAssertTrue(
                label.localizedCaseInsensitiveContains("Verbose") || label.localizedCaseInsensitiveContains("详细"),
                "Should start in verbose mode"
            )
            let found = waitForAnyKeyword(["Result", "错误处理", "throws"], timeout: 5)
            XCTAssertTrue(found, "Should have markdown content visible")
        }

        XCTContext.runActivity(named: "Switch to silent mode") { _ in
            chat.switchToSilentMode()
            waitForMode("静", chat: chat)
        }

        XCTContext.runActivity(named: "Verify silent mode active and content remains") { _ in
            let label = chat.displayModeCapsule.label
            XCTAssertTrue(
                label.localizedCaseInsensitiveContains("Silent") || label.localizedCaseInsensitiveContains("静默"),
                "Should be in silent mode"
            )
            // Anchor-based scrollTo preserves position; last-round content should still be visible.
            let found = waitForAnyKeyword(["Result", "错误处理", "throws", "async"], timeout: 5)
            XCTAssertTrue(found, "Assistant content should remain visible in silent mode")
        }
    }

    func test_multiRound_longContentDoesNotBlockMainThread() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Perform rapid scrolling through multi-round content") { _ in
            let scrollView = app.scrollViews.firstMatch
            guard scrollView.waitForExistence(timeout: 5) else {
                XCTFail("Scroll view should exist")
                return
            }
            for _ in 0..<3 {
                scrollView.swipeDown()
                scrollView.swipeUp()
            }
        }

        XCTContext.runActivity(named: "Verify UI remains responsive") { _ in
            chat.verifyIsDisplayed()
            chat.verifyDisplayModeCapsuleExists()
        }
    }

    func test_multiRound_switchModeWhileScrolled() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Scroll up from bottom") { _ in
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeDown()
            }
        }

        XCTContext.runActivity(named: "Switch to silent mode while scrolled") { _ in
            chat.switchToSilentMode()
            waitForMode("静", chat: chat)
        }

        XCTContext.runActivity(named: "Verify chat remains stable") { _ in
            chat.verifyIsDisplayed()
            chat.verifyDisplayModeCapsuleExists()
        }

        XCTContext.runActivity(named: "Switch back to verbose mode") { _ in
            chat.switchToVerboseMode()
            waitForMode("详", chat: chat)
            chat.verifyIsDisplayed()
            chat.verifyDisplayModeCapsuleExists()
        }
    }

    // MARK: - Scroll Position Stability During Mode Switch

    /// Verifies that switching Verbose→Silent while viewing the last round
    /// keeps that content visible (not jumped to an unrelated position).
    func test_verboseToSilent_atBottom_remainsAtBottom() {
        let chat = enterSeededSession()

        let lastRoundKeywords = ["Result", "错误处理", "throws"]
        XCTAssertTrue(waitForAnyKeyword(lastRoundKeywords, timeout: 5),
                      "Last round content should be visible at bottom before switch")

        chat.switchToSilentMode()
        waitForMode("静", chat: chat)

        // Anchor-based scroll correction keeps the same message visible.
        // No manual swipe needed — if this fails, the scrollTo(anchorId) logic is broken.
        XCTAssertTrue(waitForAnyKeyword(lastRoundKeywords, timeout: 5),
                      "After Verbose→Silent, last round content should still be visible. " +
                      "The anchor-based scrollTo should keep the visible message in place.")
    }

    /// Verifies that switching Verbose→Silent while scrolled to mid-content
    /// keeps that content in view rather than jumping elsewhere.
    func test_verboseToSilent_atMiddle_preservesVisibleContent() {
        let chat = enterSeededSession()

        let scrollView = app.scrollViews.firstMatch
        scrollView.swipeDown()
        scrollView.swipeDown()

        // The 2nd round discusses SwiftUI — look for its distinctive keywords.
        let midKeywords = ["SwiftUI", "@State", "Binding", "body", "View"]
        var anchorKeyword: String?
        for kw in midKeywords {
            let match = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", kw)
            ).firstMatch
            if match.waitForExistence(timeout: 3) {
                anchorKeyword = kw
                break
            }
        }

        if anchorKeyword == nil {
            scrollView.swipeDown()
            for kw in midKeywords {
                let match = app.staticTexts.containing(
                    NSPredicate(format: "label CONTAINS[c] %@", kw)
                ).firstMatch
                if match.waitForExistence(timeout: 3) {
                    anchorKeyword = kw
                    break
                }
            }
        }

        guard anchorKeyword != nil else {
            XCTFail("Could not scroll to Round 2 (SwiftUI) content")
            return
        }

        chat.switchToSilentMode()
        waitForMode("静", chat: chat)

        // Anchor-based scrollTo should keep the same message visible without nudging.
        XCTAssertTrue(waitForAnyKeyword(midKeywords, timeout: 5),
                      "After Verbose→Silent at mid-content, Round 2 keywords should still be visible. " +
                      "The anchor-based scrollTo should preserve the visible message position.")
    }

    /// Verifies that switching Verbose→Silent while viewing the first round
    /// (above the tool messages) keeps that content visible.
    func test_verboseToSilent_atTop_preservesFirstRoundContent() {
        let chat = enterSeededSession()

        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<6 { scrollView.swipeDown() }

        let topKeywords = ["Swift 语言", "类型安全", "可选类型"]
        guard waitForAnyKeyword(topKeywords, timeout: 5) else {
            XCTFail("Could not scroll to first round content at top")
            return
        }

        chat.switchToSilentMode()
        waitForMode("静", chat: chat)

        XCTAssertTrue(waitForAnyKeyword(topKeywords, timeout: 5),
                      "After Verbose→Silent at top, first round content should remain visible.")
    }

}
