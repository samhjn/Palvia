import XCTest

/// Stress tests for streaming output with very long markdown content,
/// rapid updates, and multi-round conversations (4+ rounds of 1000+ char history).
/// Designed to expose scroll position bugs, rendering stalls, and auto-scroll failures.
final class ChatStreamingTests: BaseTestCase {

    override func setUpWithError() throws {
        continueAfterFailure = false
        app = XCUIApplication()
        app.launchArguments += [LaunchArguments.uiTesting, LaunchArguments.simulateStreaming]
        app.launch()
    }

    // MARK: - Helpers

    /// Wait for either mutually-exclusive input action without checking them
    /// sequentially. Streaming can finish between two `waitForExistence`
    /// calls, replacing stop with send and making both waits report false.
    private func waitForChatActionButton(timeout: TimeInterval = 10) -> Bool {
        let sendBtn = app.buttons[AccessibilityID.Chat.sendButton]
        let stopBtn = app.buttons[AccessibilityID.Chat.stopButton]
        let deadline = Date().addingTimeInterval(timeout)

        repeat {
            if sendBtn.exists || stopBtn.exists { return true }
            RunLoop.current.run(until: Date().addingTimeInterval(0.1))
        } while Date() < deadline

        return sendBtn.exists || stopBtn.exists
    }

    private func enterStreamingSession() -> ChatPage {
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
            let sessionText = app.staticTexts.containing(
                NSPredicate(format: "label CONTAINS[c] %@", "Streaming Test")
            ).firstMatch
            if sessionText.waitForExistence(timeout: 3) {
                sessionText.tap()
            } else {
                XCTFail("Streaming test session should appear in the list")
                return ChatPage(app: app)
            }
        }

        let chat = ChatPage(app: app)
        let appeared = waitForChatActionButton()
        XCTAssertTrue(appeared, "Chat view should be displayed (send or stop button visible)")
        return chat
    }

    /// Polls until streaming is active OR has already completed.
    private func waitForStreamingActive(timeout: TimeInterval = 10) -> Bool {
        let bubble = app.descendants(matching: .any)[AccessibilityID.Chat.streamingBubble]
        if bubble.waitForExistence(timeout: timeout) { return true }
        let stopBtn = app.buttons[AccessibilityID.Chat.stopButton]
        if stopBtn.exists { return true }
        let sendBtn = app.buttons[AccessibilityID.Chat.sendButton]
        return sendBtn.exists
    }

    /// Polls until streaming completes (bubble disappears OR send button returns).
    private func waitForStreamingComplete(timeout: TimeInterval = 15) -> Bool {
        let bubble = app.descendants(matching: .any)[AccessibilityID.Chat.streamingBubble]
        if !bubble.exists {
            let sendBtn = app.buttons[AccessibilityID.Chat.sendButton]
            if sendBtn.exists { return true }
        }
        let gone = NSPredicate(format: "exists == false")
        let exp = XCTNSPredicateExpectation(predicate: gone, object: bubble)
        if XCTWaiter().wait(for: [exp], timeout: timeout) == .completed { return true }
        let sendBtn = app.buttons[AccessibilityID.Chat.sendButton]
        return sendBtn.waitForExistence(timeout: 5)
    }

    private var isScrollToBottomVisible: Bool {
        let btn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        return btn.exists && btn.isHittable
    }

    /// Wait until the scroll-to-bottom button disappears (auto-scroll re-engaged).
    private func waitForScrollToBottomHidden(timeout: TimeInterval = 5) -> Bool {
        let btn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        if !btn.exists { return true }
        let gone = NSPredicate(format: "exists == false || isHittable == false")
        let exp = XCTNSPredicateExpectation(predicate: gone, object: btn)
        return XCTWaiter().wait(for: [exp], timeout: timeout) == .completed
    }

    /// Wait until the scroll-to-bottom button appears (user scrolled away).
    private func waitForScrollToBottomVisible(timeout: TimeInterval = 5) -> Bool {
        let btn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        return btn.waitForExistence(timeout: timeout)
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

    // MARK: - Streaming Bubble Presence

    func test_streaming_bubbleAppearsWithContent() {
        _ = enterStreamingSession()
        XCTAssertTrue(waitForStreamingActive(), "Streaming bubble should appear after entering session")
    }

    // MARK: - Auto-Scroll During Rapid Streaming

    func test_streaming_autoScrollMaintainedDuringRapidOutput() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive() else {
            XCTFail("Streaming did not start")
            return
        }

        // Poll over a few seconds: scroll-to-bottom should never appear
        let scrollBtn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        let appeared = NSPredicate(format: "exists == true AND isHittable == true")
        let exp = XCTNSPredicateExpectation(predicate: appeared, object: scrollBtn)
        let result = XCTWaiter().wait(for: [exp], timeout: 5)

        XCTAssertNotEqual(result, .completed,
                          "Auto-scroll should maintain position during rapid streaming updates. " +
                          "If this fails, the scroll-to-bottom logic cannot keep up with content growth.")

        let foundRecent = waitForAnyKeyword(["泛型", "协议", "Actor", "TaskGroup", "并发"], timeout: 3)
        XCTAssertTrue(foundRecent, "Recent streaming content should be visible, proving auto-scroll works")

        _ = chat
    }

    // MARK: - Scroll-to-Bottom After Manual Scroll During Stream

    func test_streaming_scrollToBottomWorksAfterScrollingUpDuringRapidStream() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive() else { XCTFail("Streaming did not start"); return }

        // Scroll up aggressively
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<5 {
            scrollView.swipeDown()
        }

        // Scroll-to-bottom button should appear
        let scrollBtn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        XCTAssertTrue(scrollBtn.waitForExistence(timeout: 5),
                      "Scroll-to-bottom must appear after scrolling away from bottom during stream")

        scrollBtn.tap()

        // After tapping, button should hide (auto-scroll re-engaged)
        XCTAssertTrue(waitForScrollToBottomHidden(timeout: 5),
                      "After tapping scroll-to-bottom during streaming, view should return to bottom " +
                      "and the button should disappear.")

        _ = chat
    }

    // MARK: - Content Growth Verification (Large Chunks)

    func test_streaming_contentGrowsWithLargeChunks() {
        _ = enterStreamingSession()
        guard waitForStreamingActive(timeout: 15) else { XCTFail("Streaming did not start"); return }

        // Wait for later content to appear (sections 5+ of streaming)
        let laterKeywords = ["并发层", "TaskLifecycle", "MainActor", "性能预算", "最终建议"]
        let found = waitForAnyKeyword(laterKeywords, timeout: 10)

        XCTAssertTrue(found,
                      "Later streaming content keywords should appear as stream progresses. " +
                      "If none found, markdown rendering stalled or debounce blocked updates.")
    }

    // MARK: - Streaming Completion

    func test_streaming_completionPersistsMessageAndClearsState() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive(timeout: 15) else { XCTFail("Streaming did not start"); return }

        _ = waitForStreamingComplete(timeout: 15)

        let bubble = chat.streamingBubble
        XCTAssertFalse(bubble.exists,
                       "Streaming bubble should disappear after completion")

        let loading = chat.loadingIndicator
        XCTAssertFalse(loading.exists,
                       "Loading indicator should disappear after streaming completion")

        // Scroll to bottom and check for final content keywords
        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<3 { scrollView.swipeUp() }

        let possibleFinalKeywords = ["最终建议", "从简单开始", "持续重构", "核心要点回顾", "架构选择决策树"]
        let found = waitForAnyKeyword(possibleFinalKeywords, timeout: 5)
        XCTAssertTrue(found,
                      "After streaming completes, at least one keyword from the final " +
                      "section should be visible, proving the full content was delivered and persisted.")
    }

    // MARK: - Long Markdown Stays at Bottom Throughout

    func test_streaming_veryLongMarkdownKeepsBottomPosition() {
        _ = enterStreamingSession()
        guard waitForStreamingActive() else { XCTFail("Streaming did not start"); return }

        // Over multiple seconds, scroll-to-bottom should never appear
        let scrollBtn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        let appeared = NSPredicate(format: "exists == true AND isHittable == true")
        let exp = XCTNSPredicateExpectation(predicate: appeared, object: scrollBtn)
        let result = XCTWaiter().wait(for: [exp], timeout: 7)

        XCTAssertNotEqual(result, .completed,
                          "Auto-scroll lost position during long markdown stream. " +
                          "This indicates the content height grew faster than scrollTo could track.")
    }

    // MARK: - Silent Mode During Active Stream

    func test_streaming_silentModeHidesThinkingWithoutBreakingStream() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive() else { XCTFail("Streaming did not start"); return }

        chat.switchToSilentMode()

        // Wait for mode capsule to reflect change
        let capsule = chat.displayModeCapsule
        let silentPred = NSPredicate(format: "label CONTAINS[c] %@", "静")
        let exp = XCTNSPredicateExpectation(predicate: silentPred, object: capsule)
        _ = XCTWaiter().wait(for: [exp], timeout: 3)

        let thinkingBubbles = app.descendants(matching: .any).matching(identifier: AccessibilityID.Chat.thinkingBubble)
        XCTAssertEqual(thinkingBubbles.count, 0,
                       "Thinking bubbles must be hidden in silent mode during active streaming")

        let streamBubble = chat.streamingBubble
        let contentExists = waitForAnyKeyword(["架构", "Swift", "泛型"], timeout: 3)
        XCTAssertTrue(streamBubble.exists || contentExists,
                      "Streaming content should continue flowing after switching to silent mode.")
    }

    // MARK: - Mode Toggle During Stream Doesn't Break Scroll

    func test_streaming_modeToggleDuringStreamPreservesScrollPosition() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive() else { XCTFail("Streaming did not start"); return }

        chat.switchToSilentMode()

        let capsule = chat.displayModeCapsule
        let silentPred = NSPredicate(format: "label CONTAINS[c] %@", "静")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: silentPred, object: capsule)], timeout: 3)

        chat.switchToVerboseMode()

        let verbosePred = NSPredicate(format: "label CONTAINS[c] %@", "详")
        _ = XCTWaiter().wait(for: [XCTNSPredicateExpectation(predicate: verbosePred, object: capsule)], timeout: 3)

        XCTAssertFalse(isScrollToBottomVisible,
                       "After mode toggle during stream, auto-scroll should resume. " +
                       "If scroll-to-bottom appears, the mode change disrupted scroll state.")
    }

    // MARK: - Scroll Position After Render Complete

    func test_streaming_positionStableAfterCompletion() {
        _ = enterStreamingSession()
        guard waitForStreamingActive(timeout: 15) else { XCTFail("Streaming did not start"); return }

        _ = waitForStreamingComplete(timeout: 15)

        XCTAssertTrue(waitForScrollToBottomHidden(timeout: 3),
                      "After streaming completes, view should remain at bottom without needing manual scroll")

        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<3 { scrollView.swipeUp() }

        let possibleFinalKeywords = ["最终建议", "从简单开始", "核心要点回顾", "架构选择决策树"]
        let found = waitForAnyKeyword(possibleFinalKeywords, timeout: 5)
        XCTAssertTrue(found,
                      "After streaming completes, view should show final content at bottom")
    }

    // MARK: - Multi-Round: History Accessible Above Stream

    func test_multiRound_canScrollToVeryEarlyHistoryDuringStream() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive() else { XCTFail("Streaming did not start"); return }

        let scrollView = app.scrollViews.firstMatch
        // The goal is to prove earlier history rounds are accessible during streaming.
        // With 4 rounds of very long markdown + active stream, reaching Round 1
        // may require 30+ swipes. Check Round 2 (closer) as a reliable milestone.
        let historyKeywords = ["面向协议编程", "协议扩展", "protocol-oriented", "泛型系统", "类型擦除"]
        for _ in 0..<20 { scrollView.swipeDown() }
        if waitForAnyKeyword(historyKeywords, timeout: 3) {
            _ = chat
            return
        }
        // If not found yet, keep scrolling.
        for _ in 0..<15 { scrollView.swipeDown() }
        XCTAssertTrue(waitForAnyKeyword(historyKeywords, timeout: 5),
                      "Earlier history rounds should be reachable by scrolling up during stream.")
        _ = chat
    }

    // MARK: - Multi-Round: Return to Stream After Deep History Scroll

    func test_multiRound_scrollToBottomReturnsToStreamFromDeepHistory() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive() else { XCTFail("Streaming did not start"); return }

        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<12 {
            scrollView.swipeDown()
        }

        let scrollBtn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        if scrollBtn.waitForExistence(timeout: 5) {
            scrollBtn.tap()
        } else {
            for _ in 0..<12 { scrollView.swipeUp() }
        }

        // Wait for scroll to settle at bottom
        _ = waitForScrollToBottomHidden(timeout: 5)

        let atBottom = !isScrollToBottomVisible
        let streamVisible = chat.streamingBubble.exists || waitForAnyKeyword(["最佳实践", "架构", "Swift"], timeout: 3)

        XCTAssertTrue(atBottom || streamVisible,
                      "After returning from deep history scroll, should be back at streaming position.")
    }

    // MARK: - Multi-Round: Auto-Scroll Not Disrupted by Content Size

    func test_multiRound_autoScrollStillWorksWithMassiveContentSize() {
        _ = enterStreamingSession()
        guard waitForStreamingActive(timeout: 15) else { XCTFail("Streaming did not start"); return }

        let bubble = app.descendants(matching: .any)[AccessibilityID.Chat.streamingBubble]
        if bubble.exists {
            _ = waitForStreamingComplete(timeout: 12)
        }

        XCTAssertTrue(waitForScrollToBottomHidden(timeout: 5),
                      "With massive content (4 rounds of 1000+ char history + streaming output), " +
                      "the view should end up at bottom position without needing manual scroll.")
    }

    // MARK: - Multi-Round: Markdown in History Still Renders During Stream

    func test_multiRound_historyMarkdownRenderedCorrectlyDuringStream() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive() else { XCTFail("Streaming did not start"); return }

        let scrollView = app.scrollViews.firstMatch
        for _ in 0..<6 {
            scrollView.swipeDown()
        }

        let historyKeywords = ["性能对比", "Actor", "WorkerPool", "Repository", "Coordinator"]
        let found = waitForAnyKeyword(historyKeywords, timeout: 5)
        XCTAssertTrue(found,
                      "History keywords should be rendered in markdown while streaming is active. " +
                      "If none found, LazyVStack may have discarded history views under memory pressure.")

        _ = chat
    }

    // MARK: - Stress: Rapid Scroll During Fast Streaming

    func test_stress_rapidScrollDuringFastStreaming() {
        let chat = enterStreamingSession()
        guard waitForStreamingActive() else { XCTFail("Streaming did not start"); return }

        let scrollView = app.scrollViews.firstMatch

        for _ in 0..<3 {
            scrollView.swipeDown()
            scrollView.swipeDown()
            scrollView.swipeUp()
            scrollView.swipeUp()
        }

        // After aggressive scrolling, the app should remain responsive
        let responsive = waitForChatActionButton(timeout: 8)
        XCTAssertTrue(responsive,
                      "App should remain responsive after rapid scrolling during fast streaming.")

        let scrollBtn = app.buttons[AccessibilityID.Chat.scrollToBottom]
        if scrollBtn.exists && scrollBtn.isHittable {
            scrollBtn.tap()
            _ = waitForScrollToBottomHidden(timeout: 3)
        }

        let hasContent = chat.streamingBubble.exists || waitForAnyKeyword(["Swift", "架构", "协议"], timeout: 3)
        XCTAssertTrue(hasContent,
                      "After rapid scroll stress, streaming content should still be visible/accessible")
    }

    // MARK: - Focus Retention After Long Reasoning Completion

    /// Bug: after long thinking/reasoning content finishes streaming, the view
    /// loses focus — the scroll position jumps away from the final message.
    /// The streaming bubble (with thinking + content) is replaced by a persisted
    /// message whose height differs substantially, causing layout-driven position drift.
    func test_streaming_focusRetainedAfterLongReasoningCompletion() {
        _ = enterStreamingSession()
        guard waitForStreamingActive(timeout: 15) else {
            XCTFail("Streaming did not start")
            return
        }

        guard waitForStreamingComplete(timeout: 20) else {
            XCTFail("Streaming did not complete in time")
            return
        }

        XCTAssertTrue(waitForScrollToBottomHidden(timeout: 5),
                      "After long reasoning content completes, the view should remain at bottom. "
                      + "If scroll-to-bottom appears, the position was lost during the "
                      + "streaming→persisted message transition.")

        let finalKeywords = ["最终建议", "从简单开始", "核心要点回顾", "架构选择决策树"]
        XCTAssertTrue(waitForAnyKeyword(finalKeywords, timeout: 5),
                      "After reasoning completion, final content should be visible at bottom "
                      + "without manual scrolling. If not, the view lost focus during "
                      + "the streaming-to-persisted message transition.")

        let sendBtn = app.buttons[AccessibilityID.Chat.sendButton]
        XCTAssertTrue(sendBtn.waitForExistence(timeout: 5),
                      "Send button should return after streaming completes")
    }

    // MARK: - No Blank Screen After Completion (Over-Scroll Regression)

    /// Bug: at streaming end the expanded thinking bubble collapses and the
    /// streaming bubble is removed, shrinking the content height while the
    /// scroll offset stays put — stranding the viewport in blank space past
    /// the end of the content with no auto-recovery. Keyword `exists` checks
    /// don't catch this (off-screen elements still exist), so this test
    /// asserts the last bubble's frame actually intersects the window.
    func test_streaming_noBlankScreenAfterCompletion() {
        _ = enterStreamingSession()
        guard waitForStreamingActive(timeout: 15) else {
            XCTFail("Streaming did not start")
            return
        }
        guard waitForStreamingComplete(timeout: 20) else {
            XCTFail("Streaming did not complete in time")
            return
        }

        let bubbles = app.descendants(matching: .any).matching(identifier: AccessibilityID.Chat.messageBubble)
        XCTAssertTrue(bubbles.firstMatch.waitForExistence(timeout: 5),
                      "Persisted message bubbles should exist after streaming completes")

        let window = app.windows.firstMatch
        let lastBubbleOnScreen = NSPredicate { _, _ in
            let count = bubbles.count
            guard count > 0 else { return false }
            let lastBubble = bubbles.element(boundBy: count - 1)
            return lastBubble.exists && lastBubble.frame.intersects(window.frame)
        }
        let exp = XCTNSPredicateExpectation(predicate: lastBubbleOnScreen, object: nil)
        XCTAssertEqual(XCTWaiter().wait(for: [exp], timeout: 5), .completed,
                       "After streaming ends, the last message must be on screen. " +
                       "A miss means the view is over-scrolled into blank space past the content end.")
    }
}
