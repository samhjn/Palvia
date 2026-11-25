import XCTest

/// Tests for initial scroll position and scroll-to-bottom button behavior
/// when opening sessions with very long Markdown content across multiple rounds.
///
/// Uses `seedHeavyMarkdown` which creates 4 rounds of 3000-6000+ character
/// Markdown messages. This volume triggers LazyVStack rendering delays that
/// can cause "false bottom" states where the UI thinks it's at the bottom
/// but the actual content hasn't finished layout.
final class ChatHeavyMarkdownTests: BaseTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [LaunchArguments.uiTesting, LaunchArguments.seedHeavyMarkdown]
    }

    // MARK: - Helpers

    private func enterSession(startInHistory: Bool = false) -> ChatPage {
        if startInHistory {
            app.launchArguments += [LaunchArguments.seedHeavyMarkdownInHistory]
        }
        app.launch()
        waitForAppReady()

        let buttonRow = app.buttons.matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
        let cellRow = app.cells.matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
        let anyRow = app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch

        guard let row = XCUIElement.waitForFirstExisting([buttonRow, cellRow, anyRow], timeout: 10) else {
            XCTFail("Heavy markdown session row should appear in the list")
            return ChatPage(app: app)
        }
        row.tap()

        let chat = ChatPage(app: app)
        let sendBtn = app.buttons[AccessibilityID.Chat.sendButton]
        let capsule = app.buttons[AccessibilityID.Chat.displayModeCapsule]
        let loaded = XCUIElement.waitForFirstExisting([sendBtn, capsule], timeout: 15) != nil
        XCTAssertTrue(loaded, "Chat view should be displayed")
        return chat
    }

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

    private func finalParagraphVisibility(in scrollView: XCUIElement) -> NSPredicate {
        let tail = scrollView.staticTexts.matching(
            NSPredicate(format: "label CONTAINS %@", "以上就是完整的 Swift 最佳实践文档的全部内容。")
        ).firstMatch
        return NSPredicate { _, _ in
            guard tail.exists else { return false }
            let frame = tail.frame
            return scrollView.frame.contains(CGPoint(x: frame.midX, y: frame.midY))
        }
    }

    private func tapScrollToBottom(_ button: XCUIElement, expecting tailVisible: NSPredicate) {
        button.tapWhenReady()
        XCTAssertTrue(button.waitForNonExistence(timeout: 5), "Tapping scroll-to-bottom should dismiss the button")

        let visible = XCTNSPredicateExpectation(predicate: tailVisible, object: nil)
        let result = XCTWaiter.wait(for: [visible], timeout: 15)
        if result != .completed {
            let screenshot = XCTAttachment(screenshot: app.screenshot())
            screenshot.name = "Chat after tapping scroll-to-bottom"
            add(screenshot)
        }
        XCTAssertEqual(result, .completed,
                       "Tapping scroll-to-bottom should bring the final paragraph into view")
    }

    // MARK: - Initial Scroll Position & False Bottom (Bug #2 + #3)

    /// The core "false bottom" test. After entering a session with 6 rounds
    /// of very long Markdown (~60K+ chars total, last message ~13K), we wait
    /// for MarkdownContentView to finish rendering, then check:
    ///
    /// 1. Is the view STILL at the actual bottom? (last message tail visible)
    /// 2. Does the scroll state correctly reflect the position?
    ///    - If at bottom: scroll-to-bottom button should be hidden
    ///    - If NOT at bottom: scroll-to-bottom button should be visible & hittable
    ///
    /// The "false bottom" bug: initial scrollTo fires before markdown renders
    /// to full height. The view settles at a partial bottom. As rendering
    /// completes, content grows downward. The view is no longer at bottom,
    /// but the scroll state still thinks it is — button stays hidden, user
    /// is stuck with no way to reach the actual bottom.
    func test_falseBottom_afterRenderSettles() {
        _ = enterSession()

        // Wait for MarkdownContentView to finish rendering.
        // With 6 rounds × ~10K chars of complex markdown (code blocks, tables),
        // this can take 5+ seconds on iOS 26.
        RunLoop.current.run(until: Date().addingTimeInterval(5))

        let scrollBtn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        let lastMsgTailKeywords = ["总结清单", "最佳实践文档"]

        // Check 1: Is the tail of the last message actually visible?
        let tailVisible = waitForAnyKeyword(lastMsgTailKeywords, timeout: 3)

        if tailVisible {
            // Good — we're at the real bottom. Button should be hidden.
            let buttonHidden = !scrollBtn.exists || !scrollBtn.isHittable
            XCTAssertTrue(buttonHidden,
                          "View is at the real bottom but scroll-to-bottom is visible. "
                          + "Scroll state is out of sync.")
            return
        }

        // The tail is NOT visible — we're NOT at the actual bottom.
        // This is the "false bottom" scenario.
        //
        // Now the critical question: does the UI know?
        // If scroll-to-bottom is hidden, that's the bug:
        // the user is NOT at the bottom but has no button to get there.
        if !scrollBtn.exists || !scrollBtn.isHittable {
            // Confirm there IS more content below by scrolling down
            let scrollView = app.scrollViews.firstMatch
            scrollView.swipeUp()
            scrollView.swipeUp()
            let foundAfterScroll = waitForAnyKeyword(lastMsgTailKeywords, timeout: 3)
            if foundAfterScroll {
                XCTFail("FALSE BOTTOM BUG: After markdown rendering settled, the view "
                        + "is NOT at the actual bottom (last message tail was only "
                        + "reachable by scrolling further down), but the scroll-to-bottom "
                        + "button was hidden. The UI thinks it's at the bottom but it isn't. "
                        + "Root cause: initial scrollTo fired before MarkdownContentView "
                        + "rendered to full height; scroll state was never corrected.")
            } else {
                // Tail keywords not found even after scrolling — content may still
                // be rendering, or the keywords aren't in the visible staticTexts.
                // Fall back to checking if we're at the send button level.
                let sendBtn = app.buttons[AccessibilityID.Chat.sendButton]
                XCTAssertTrue(sendBtn.exists,
                              "Neither last message tail nor send button found — "
                              + "the view may be stuck at a completely wrong position.")
            }
        } else {
            // Button IS visible — the UI correctly detected it's not at bottom.
            // This means the scroll state is working, but the initial scrollTo
            // failed to reach the actual bottom. Less severe but still a bug.
            XCTFail("Initial scroll did not reach the actual bottom of the last message. "
                    + "The scroll-to-bottom button appeared (correctly), meaning the UI "
                    + "knows it's not at bottom. But the onAppear scrollTo should have "
                    + "positioned the view at the actual bottom from the start.")
        }
    }

    /// From a saved position in history, tapping scroll-to-bottom should
    /// reveal the last paragraph even as the long Markdown rows lay out.
    func test_scrollToBottom_reachesRealBottom() {
        let chat = enterSession(startInHistory: true)
        let scrollView = app.scrollViews.matching(identifier: AccessibilityID.Chat.messageList).firstMatch
        XCTAssertTrue(scrollView.waitUntilHittable(), "The chat history should be ready to scroll")

        let tailVisible = finalParagraphVisibility(in: scrollView)
        XCTAssertFalse(tailVisible.evaluate(with: nil), "The saved position in history should open above the final paragraph")
        tapScrollToBottom(chat.scrollToBottomButton, expecting: tailVisible)
    }

    // MARK: - Scroll-to-Bottom Button (Bug #3)

    /// After the initial render settles (whether at true or false bottom),
    /// scrolling up should reliably show the scroll-to-bottom button,
    /// and tapping it should return to the actual bottom.
    func test_scrollToBottom_appearsAndReturnsToBotom() {
        _ = enterSession()

        // Wait for initial render to settle
        RunLoop.current.run(until: Date().addingTimeInterval(3))

        let scrollView = app.scrollViews.firstMatch
        guard scrollView.waitForExistence(timeout: 5) else {
            XCTFail("Scroll view should exist")
            return
        }

        // Scroll up significantly — in heavy markdown this means many swipes.
        // Pause between batches so deceleration settles and userDidScrollAway
        // is reliably set before the next gesture.
        for _ in 0..<3 { scrollView.swipeDown() }
        RunLoop.current.run(until: Date().addingTimeInterval(0.5))
        for _ in 0..<2 { scrollView.swipeDown() }

        // Wait for deceleration to fully stop and button animation to complete
        RunLoop.current.run(until: Date().addingTimeInterval(1))

        let scrollBtn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        XCTAssertTrue(scrollBtn.waitForExistence(timeout: 5),
                      "scroll-to-bottom button should appear after scrolling up in heavy markdown")

        // Tap the button directly — waitForExistence confirms it's in the
        // hierarchy, and at this point deceleration has stopped so the frame
        // should be valid. If isHittable is unreliable, the tap itself will
        // fail with a clear error.
        scrollBtn.tap()

        // After tapping, button should disappear (user is back at bottom)
        let gone = NSPredicate(format: "exists == false")
        let exp = XCTNSPredicateExpectation(predicate: gone, object: scrollBtn)
        _ = XCTWaiter().wait(for: [exp], timeout: 5)

        // And we should see last-round content
        let lastRoundKeywords = ["总结清单", "并发", "Actor", "TaskGroup", "性能"]
        XCTAssertTrue(waitForAnyKeyword(lastRoundKeywords, timeout: 10),
                      "After tapping scroll-to-bottom, last round content should be visible")
    }

    /// Rapid scroll up and down should not break the scroll-to-bottom button.
    func test_scrollToBottom_survivesRapidScrolling() {
        let chat = enterSession()

        RunLoop.current.run(until: Date().addingTimeInterval(2))

        let scrollView = app.scrollViews.matching(identifier: AccessibilityID.Chat.messageList).firstMatch
        guard scrollView.waitForExistence(timeout: 5) else {
            XCTFail("Scroll view should exist")
            return
        }

        // Rapid scroll: up, down, up
        for _ in 0..<4 { scrollView.swipeDown() }
        for _ in 0..<2 { scrollView.swipeUp() }
        for _ in 0..<3 { scrollView.swipeDown() }

        let tailVisible = finalParagraphVisibility(in: scrollView)
        XCTAssertFalse(tailVisible.evaluate(with: nil), "Rapid scrolling should leave the final paragraph out of view")
        tapScrollToBottom(chat.scrollToBottomButton, expecting: tailVisible)
    }
}

/// End-to-end regression for opening a large source file returned by an agent.
final class LargeLuaFilePreviewUITests: BaseTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [LaunchArguments.uiTesting, LaunchArguments.seedLargeLuaPreview]
        app.launch()
    }

    func testOpeningEightThousandLineLuaAttachmentRemainsResponsive() {
        openLargeLuaPreview()

        let lineCount = app.staticTexts.matching(identifier: AccessibilityID.TextFilePreview.lineCount).firstMatch
        XCTAssertTrue(lineCount.waitForExistence(timeout: 5))
        XCTAssertEqual(lineCount.label, "8000 lines")

        closeButton.tap()
        XCTAssertTrue(closeButton.waitForNonExistence(timeout: 5), "Large Lua preview should close promptly")
    }

    func testTextPreviewOffersOriginalFileForExport() {
        openLargeLuaPreview()
        app.buttons.matching(identifier: AccessibilityID.TextFilePreview.shareButton).firstMatch.tapWhenReady()

        let shareSheet = app.otherElements.matching(identifier: "ActivityListView").firstMatch
        XCTAssertTrue(shareSheet.waitForExistence(timeout: 8))
        // The system share extension uses the simulator's language and exposes
        // actions as cells, independently of the app's language override.
        let saveToFiles = shareSheet.cells.matching(NSPredicate(
            format: "label IN %@", [
                "Save to Files",
                "存储到“文件”",
                "保存到“文件”",
                "儲存到「檔案」",
                "“ファイル”に保存",
                "파일에 저장",
            ]
        )).firstMatch
        XCTAssertTrue(saveToFiles.waitForExistence(timeout: 8), "Text files must offer file export in the system share sheet")
        // iOS hides the extension in its share-sheet title.
        XCTAssertTrue(
            shareSheet.otherElements["modified-script"].waitForExistence(timeout: 5),
            "The share sheet should identify the original file"
        )
    }

    private var closeButton: XCUIElement {
        app.buttons.matching(identifier: AccessibilityID.TextFilePreview.closeButton).firstMatch
    }

    private func openLargeLuaPreview() {
        waitForAppReady()

        let row = app.descendants(matching: .any)
            .matching(identifier: AccessibilityID.SessionList.sessionRow).firstMatch
        row.tapWhenReady()

        let attachment = app.buttons.matching(
            NSPredicate(format: "label CONTAINS %@", "modified-script.lua")
        ).firstMatch
        attachment.tapWhenReady()

        XCTAssertTrue(closeButton.waitUntilHittable(), "Large Lua preview should become interactive promptly")
    }
}
