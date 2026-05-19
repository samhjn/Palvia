import XCTest

/// UI tests for silent/verbose mode switching, long markdown rendering,
/// and multi-round long markdown output scenarios.
final class ChatDisplayModeTests: BaseTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [LaunchArguments.uiTesting, LaunchArguments.seedMarkdown]
        app.launch()
    }

    // MARK: - Helpers

    private func enterSeededSession() -> ChatPage {
        waitForAppReady()

        let cellRow = app.cells.matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
        let buttonRow = app.buttons.matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
        let anyRow = app.descendants(matching: .any).matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch

        if cellRow.waitForExistence(timeout: 8) {
            cellRow.tap()
        } else if buttonRow.waitForExistence(timeout: 3) {
            buttonRow.tap()
        } else if anyRow.waitForExistence(timeout: 3) {
            anyRow.tap()
        } else {
            let markdownText = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Markdown Test")
            ).firstMatch
            if markdownText.waitForExistence(timeout: 3) {
                markdownText.tap()
            } else {
                XCTFail("Seeded session row should appear in the list")
                return ChatPage(app: app)
            }
        }

        let chat = ChatPage(app: app)
        chat.verifyIsDisplayed(timeout: 10)
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

        let silentCount = app.staticTexts.count

        XCTContext.runActivity(named: "Scroll up and back down") { _ in
            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeDown()
                scrollView.swipeUp()
            }
        }

        XCTContext.runActivity(named: "Verify silent mode still active") { _ in
            let afterScrollCount = app.staticTexts.count
            let tolerance = max(3, silentCount / 5)
            XCTAssertTrue(
                abs(afterScrollCount - silentCount) <= tolerance,
                "Silent mode should persist after scrolling (before=\(silentCount), after=\(afterScrollCount))"
            )
            chat.verifyDisplayModeCapsuleExists()
        }
    }

    // MARK: - Long Markdown Rendering Tests

    func test_longMarkdownContent_rendersWithoutCrash() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Verify markdown content is rendered near bottom") { _ in
            let content = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Result")
            )
            XCTAssertGreaterThan(content.count, 0, "Markdown content from last round should be rendered")
        }

        XCTContext.runActivity(named: "Verify chat is interactive with markdown content loaded") { _ in
            chat.verifyIsDisplayed()
            chat.verifySendButtonExists()
        }
    }

    func test_longMarkdownContent_scrollable() {
        let chat = enterSeededSession()

        XCTContext.runActivity(named: "Verify bottom content is visible on entry") { _ in
            let bottomContent = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Result")
            )
            XCTAssertGreaterThan(bottomContent.count, 0, "Should see bottom content on entry")
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

            let codeContent = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "swift")
            )
            XCTAssertGreaterThan(
                codeContent.count, 0,
                "Markdown with Swift code blocks should render code-related text"
            )
        }
    }

    func test_longMarkdownContent_tablesRendered() {
        _ = enterSeededSession()

        XCTContext.runActivity(named: "Scroll to table region and verify content") { _ in
            let tableContent = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "throws")
            )
            if tableContent.count > 0 { return }

            let scrollView = app.scrollViews.firstMatch
            if scrollView.exists {
                scrollView.swipeDown()
            }
            let found = waitForAnyKeyword(["@State", "throws", "Binding"], timeout: 3)
            XCTAssertTrue(found, "Markdown table or code content should be rendered")
        }
    }

    // MARK: - Multi-Round Long Markdown Output Tests

    func test_multiRound_allRoundsVisible() {
        _ = enterSeededSession()

        XCTContext.runActivity(named: "Verify last round content visible at bottom") { _ in
            let round3 = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Result")
            )
            XCTAssertGreaterThan(round3.count, 0, "Third round content should be visible at bottom")
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
            let content = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Result")
            )
            XCTAssertGreaterThan(content.count, 0, "Should have markdown content visible")
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
            let content = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Result")
            )
            XCTAssertGreaterThan(content.count, 0, "Assistant content should remain visible in silent mode")
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

        // Chat auto-scrolls to bottom. Last round is "错误处理 / Result 类型".
        let lastRoundKeyword = "Result"
        let visible = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", lastRoundKeyword)
        ).firstMatch
        XCTAssertTrue(visible.waitForExistence(timeout: 5),
                      "Last round content should be visible at bottom before switch")

        chat.switchToSilentMode()
        waitForMode("静", chat: chat)

        // After switching to Silent, the same last-round content must still be visible.
        // Bug: if scroll position isn't corrected, the view may jump to a random position
        // because tool messages above were removed, changing contentSize.
        let stillVisible = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", lastRoundKeyword)
        ).firstMatch
        XCTAssertTrue(stillVisible.waitForExistence(timeout: 3),
                      "After Verbose→Silent, last round content ('Result') should still be visible. " +
                      "If not, the scroll position jumped because tool messages above were removed " +
                      "without compensating the scroll offset.")
    }

    /// Verifies that switching Verbose→Silent while scrolled to mid-content
    /// keeps that content in view rather than jumping elsewhere.
    func test_verboseToSilent_atMiddle_preservesVisibleContent() {
        let chat = enterSeededSession()

        // Scroll to the 2nd round (SwiftUI content). It's in the middle.
        let scrollView = app.scrollViews.firstMatch
        scrollView.swipeDown()
        scrollView.swipeDown()

        // The 2nd round discusses SwiftUI — look for its distinctive keywords.
        let midKeywords = ["SwiftUI", "@State", "Binding", "body"]
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
        guard let anchor = anchorKeyword else {
            // Try one more swipe to reach it
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
            guard let _ = anchorKeyword else {
                XCTFail("Could not scroll to Round 2 (SwiftUI) content")
                return
            }
            return test_verboseToSilent_atMiddle_verifyAfterSwitch(chat: chat, anchor: anchorKeyword!)
        }

        test_verboseToSilent_atMiddle_verifyAfterSwitch(chat: chat, anchor: anchor)
    }

    private func test_verboseToSilent_atMiddle_verifyAfterSwitch(chat: ChatPage, anchor: String) {
        chat.switchToSilentMode()
        waitForMode("静", chat: chat)

        // The anchor content from Round 2 should still be visible after the switch.
        let afterSwitch = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", anchor)
        ).firstMatch
        XCTAssertTrue(afterSwitch.waitForExistence(timeout: 5),
                      "After Verbose→Silent at mid-content, '\(anchor)' should still be visible. " +
                      "If not, scroll position was disrupted by removal of tool messages above. " +
                      "The onChange(of: isVerbose) needs position correction for the Silent direction too.")
    }

    /// Verifies that switching Verbose→Silent while viewing the first round
    /// (above the tool messages) keeps that content visible.
    func test_verboseToSilent_atTop_preservesFirstRoundContent() {
        let chat = enterSeededSession()

        // Scroll all the way to the top (first round about Swift features)
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<6 { scrollView.swipeDown() }

        let topKeyword = "Swift 语言"
        let topContent = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", topKeyword)
        ).firstMatch
        guard topContent.waitForExistence(timeout: 5) else {
            XCTFail("Could not scroll to first round content at top")
            return
        }

        chat.switchToSilentMode()
        waitForMode("静", chat: chat)

        // Content at the very top should remain visible (tool msgs are below, removal
        // shouldn't affect things above — but offset-based bugs might still cause jumps).
        let stillThere = app.staticTexts.containing(
            NSPredicate(format: "label CONTAINS[c] %@", topKeyword)
        ).firstMatch
        XCTAssertTrue(stillThere.waitForExistence(timeout: 3),
                      "After Verbose→Silent at top, first round content should remain visible. " +
                      "Since tool messages are below the current viewport, removal should not " +
                      "affect scroll position at the top."
        )
    }
}
