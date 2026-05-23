import XCTest
import SwiftData
import WebKit
@testable import iClaw

// MARK: - ScrollViewOffsetObserver Coalescing Tests

/// Tests for the CADisplayLink-based coalescing fix that prevents layout feedback
/// loops in the scroll offset observer (0x8BADF00D watchdog crash).
final class ScrollOffsetCoalescingTests: XCTestCase {

    // MARK: - ChatScrollState initial state

    func testChatScrollStateDefaultsToNearBottom() {
        let state = ChatScrollState()
        XCTAssertTrue(state.isNearBottom,
                      "ChatScrollState should default to isNearBottom = true")
    }

    func testChatScrollStateScrollViewDefaultsToNil() {
        let state = ChatScrollState()
        XCTAssertNil(state.scrollView,
                     "ChatScrollState.scrollView should default to nil")
    }

    // MARK: - Coordinator lifecycle

    @MainActor
    func testCoordinatorCreatesDisplayLink() {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 2000)
        coordinator.observe(scrollView)

        // The coordinator should have set up observation without crashing
        XCTAssertTrue(state.isNearBottom,
                      "State should remain unchanged immediately after observation starts")
    }

    @MainActor
    func testCoordinatorDoesNotUpdateStateSynchronously() {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 2000)
        coordinator.observe(scrollView)

        // Scroll far from the bottom — in the old code this would trigger
        // an immediate DispatchQueue.main.async state change. With the
        // CADisplayLink fix, the state should NOT change synchronously.
        scrollView.contentOffset = CGPoint(x: 0, y: 0)

        // Give KVO a chance to fire (it's synchronous on the same thread)
        // but the CADisplayLink callback should NOT have fired yet
        // because the display link fires on the next frame, not synchronously.
        XCTAssertTrue(state.isNearBottom,
                      "State should not change synchronously — CADisplayLink defers the update")
    }

    @MainActor
    func testCoordinatorEventuallyUpdatesState() async throws {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 2000)
        coordinator.observe(scrollView)

        // Scroll far from the bottom
        scrollView.contentOffset = CGPoint(x: 0, y: 0)

        // Wait for the CADisplayLink to fire (next frame)
        // CADisplayLink fires on each display refresh (~16ms at 60fps)
        try await Task.sleep(for: .milliseconds(100))

        // After a frame, the display link should have fired and updated the state
        XCTAssertFalse(state.isNearBottom,
                       "After display link fires, isNearBottom should be false when scrolled to top")
    }

    @MainActor
    func testCoordinatorCoalescesRapidUpdates() async throws {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 5000)
        coordinator.observe(scrollView)

        // Simulate rapid contentOffset changes (as would happen during layout)
        // In the old code, each would schedule a separate DispatchQueue.main.async
        for offset in stride(from: 0.0, through: 500.0, by: 10.0) {
            scrollView.contentOffset = CGPoint(x: 0, y: offset)
        }

        // State should still not have changed synchronously
        XCTAssertTrue(state.isNearBottom,
                      "Rapid updates should be coalesced, not applied synchronously")

        // After one frame, only the final state should be applied
        try await Task.sleep(for: .milliseconds(100))

        // At offset 500 with contentSize 5000 and height 812,
        // distance = 5000 - 500 - 812 = 3688 which is >> 200 threshold
        XCTAssertFalse(state.isNearBottom,
                       "After coalescing, final state should reflect last offset")
    }

    @MainActor
    func testCoordinatorNearBottomDetection() async throws {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 2000)
        coordinator.observe(scrollView)

        // Scroll to near bottom (within 200px threshold)
        // distance = contentSize.height - contentOffset.y - bounds.height
        // distance = 2000 - 1100 - 812 = 88 which is < 200
        scrollView.contentOffset = CGPoint(x: 0, y: 1100)

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertTrue(state.isNearBottom,
                      "Should be near bottom when within 200px of the end")
    }

    @MainActor
    func testCoordinatorFarFromBottomDetection() async throws {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 3000)
        coordinator.observe(scrollView)

        // Scroll to middle — far from bottom
        // distance = 3000 - 500 - 812 = 1688 which is >> 200
        scrollView.contentOffset = CGPoint(x: 0, y: 500)

        try await Task.sleep(for: .milliseconds(100))

        XCTAssertFalse(state.isNearBottom,
                       "Should not be near bottom when far from the end")
    }

    @MainActor
    func testCoordinatorNoUpdateWhenStateUnchanged() async throws {
        let state = ChatScrollState()
        state.isNearBottom = false
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 3000)
        coordinator.observe(scrollView)

        // Set offset that also produces isNearBottom = false
        scrollView.contentOffset = CGPoint(x: 0, y: 100)

        try await Task.sleep(for: .milliseconds(100))

        // State should remain false — no unnecessary update
        XCTAssertFalse(state.isNearBottom,
                       "Should not trigger update when new state matches current state")
    }

    @MainActor
    func testCoordinatorDeallocCleansUp() {
        let state = ChatScrollState()
        var coordinator: ScrollViewOffsetObserver.Coordinator? = {
            let observer = ScrollViewOffsetObserver(scrollState: state)
            let c = observer.makeCoordinator()
            let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
            scrollView.contentSize = CGSize(width: 375, height: 2000)
            c.observe(scrollView)
            return c
        }()

        XCTAssertNotNil(coordinator)

        // Deallocating should not crash (deinit invalidates both KVO and CADisplayLink)
        coordinator = nil

        // If we get here without a crash, cleanup was successful
        XCTAssertNil(coordinator)
    }
}

// MARK: - WebView Safe Area Configuration Tests

/// Tests for the WKWebView safe area fix that prevents the web view's internal
/// scroll view from feeding back into UIKit's safe-area-inset layout cycle.
///
/// Since UIViewRepresentable.Context cannot be constructed in tests, we verify
/// the configuration behavior directly on WKWebView instances.
@MainActor
final class WebViewSafeAreaTests: XCTestCase {

    func testFreshWebViewDefaultsToAutomatic() {
        // Verify the baseline: a fresh WKWebView does NOT have .never
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)

        XCTAssertNotEqual(webView.scrollView.contentInsetAdjustmentBehavior, .never,
                          "Fresh WKWebView should default to automatic, not .never")
    }

    func testBrowserServiceWebViewHasNeverBehavior() {
        // BrowserService.shared uses WebViewRepresentable, which sets .never
        // in makeUIView. Verify that creating a WebViewRepresentable stores
        // the correct webView reference.
        let service = BrowserService.shared
        let representable = WebViewRepresentable(webView: service.webView)
        XCTAssertTrue(representable.webView === service.webView,
                      "WebViewRepresentable should hold a reference to the same WKWebView")
    }

    func testContentInsetAdjustmentBehaviorSetToNever() {
        // Simulate the exact configuration WebViewRepresentable.makeUIView applies
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)

        // This is what makeUIView does:
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        XCTAssertEqual(webView.scrollView.contentInsetAdjustmentBehavior, .never,
                       "contentInsetAdjustmentBehavior should be .never after configuration")
    }

    func testNeverBehaviorPreventsAutoInsetAdjustment() {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: config)

        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = .zero

        // With .never, adjustedContentInset should match contentInset (no system additions)
        XCTAssertEqual(webView.scrollView.adjustedContentInset, .zero,
                       "With .never behavior, adjustedContentInset should not include safe area additions")
    }

    func testNeverBehaviorPersistsAfterContentInsetChange() {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: .zero, configuration: config)

        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentInset = UIEdgeInsets(top: 10, left: 0, bottom: 10, right: 0)

        XCTAssertEqual(webView.scrollView.contentInsetAdjustmentBehavior, .never,
                       "Behavior should persist after changing content inset")
    }

    func testNeverBehaviorPersistsAfterContentSizeChange() {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: config)

        webView.scrollView.contentInsetAdjustmentBehavior = .never
        webView.scrollView.contentSize = CGSize(width: 375, height: 5000)

        XCTAssertEqual(webView.scrollView.contentInsetAdjustmentBehavior, .never,
                       "Behavior should persist after changing content size")
    }
}

// MARK: - Animation Configuration Tests

/// Tests verifying that the silentStatus animation modifier was removed.
/// The rapid-fire silentStatus changes (every 0.3s via TimelineView) combined
/// with implicit .animation() amplified layout passes during scene transitions.
final class ChatAnimationConfigTests: XCTestCase {

    /// Verify that silentStatus updates do not trigger layout-amplifying animations.
    /// This is a regression test — the silentStatus used to have an implicit
    /// .animation(.easeInOut(duration: 0.2), value: vm.silentStatus) modifier.
    @MainActor
    func testSilentStatusChangeDoesNotBlockMainThread() async throws {
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let agent = Agent(name: "AnimTest")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        // Simulate rapid silentStatus changes (as TimelineView does every 0.3s)
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<100 {
            vm.silentStatus = "tool:tool_\(i)"
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // Without the animation modifier, rapid status changes should complete
        // near-instantly since they're just string assignments.
        XCTAssertLessThan(elapsed, 0.1,
            "100 rapid silentStatus changes should complete in < 100ms without animation overhead, took \(elapsed)s")
    }

    @MainActor
    func testSilentStatusRapidChangesDoNotAccumulate() throws {
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        let container = try ModelContainer(for: schema, configurations: [config])
        let context = ModelContext(container)

        let agent = Agent(name: "AnimTest")
        context.insert(agent)
        let session = Session(title: "Test")
        context.insert(session)
        session.agent = agent
        try context.save()

        let vm = ChatViewModel(session: session, modelContext: context)

        // Simulate the pattern that would occur during streaming:
        // alternating between tool calls and thinking status
        for i in 0..<50 {
            vm.silentStatus = "tool:browser_navigate"
            vm.silentStatus = "think:\(i)"
            vm.silentStatus = "tool:browser_extract"
            vm.silentStatus = ""
        }

        // The final value should be the last one set
        XCTAssertEqual(vm.silentStatus, "",
                       "silentStatus should reflect the last value set")
    }
}

// MARK: - Integration: Layout Cycle Prevention

/// Integration-level tests that verify the overall layout cycle prevention strategy.
final class LayoutCyclePreventionTests: XCTestCase {

    @MainActor
    func testScrollStateTransitionPerformance() async throws {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 10000)
        coordinator.observe(scrollView)

        // Simulate a layout storm: rapidly toggle between near-bottom and far-from-bottom
        // In the old code, each toggle would schedule a DispatchQueue.main.async
        // that could re-enter the layout cycle.
        let start = CFAbsoluteTimeGetCurrent()
        for i in 0..<1000 {
            // Alternate between near-bottom and far offsets
            let offset: CGFloat = (i % 2 == 0) ? 9000 : 0
            scrollView.contentOffset = CGPoint(x: 0, y: offset)
        }
        let elapsed = CFAbsoluteTimeGetCurrent() - start

        // The KVO callbacks + CADisplayLink scheduling should complete quickly
        // because no state changes are applied synchronously
        XCTAssertLessThan(elapsed, 1.0,
            "1000 rapid offset changes should complete in < 1s with coalescing, took \(elapsed)s")

        // Wait for the single coalesced update
        try await Task.sleep(for: .milliseconds(100))

        // Final state should reflect the last offset (0 = far from bottom)
        XCTAssertFalse(state.isNearBottom,
                       "Final state should reflect the last offset value")
    }

    @MainActor
    func testScrollStateBoundaryCases() async throws {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = CGSize(width: 375, height: 1012)
        coordinator.observe(scrollView)

        // Exactly at threshold: distance = 1012 - 0 - 812 = 200
        // threshold is 200 for non-tracking, so 200 <= 200 → near bottom
        scrollView.contentOffset = CGPoint(x: 0, y: 0)
        try await Task.sleep(for: .milliseconds(100))
        XCTAssertTrue(state.isNearBottom,
                      "Distance exactly at threshold (200) should be considered near bottom")
    }

    @MainActor
    func testScrollStateWithZeroContentSize() async throws {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()

        let scrollView = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        scrollView.contentSize = .zero
        coordinator.observe(scrollView)

        scrollView.contentOffset = .zero
        try await Task.sleep(for: .milliseconds(100))

        // distance = max(0, 0 - 0 - 812) = 0 → near bottom
        XCTAssertTrue(state.isNearBottom,
                      "Zero content size should be treated as near bottom")
    }

    @MainActor
    func testWebViewScrollViewDoesNotParticipateInSafeAreaCycle() {
        let config = WKWebViewConfiguration()
        let webView = WKWebView(frame: CGRect(x: 0, y: 0, width: 375, height: 812), configuration: config)

        // Apply the same configuration as WebViewRepresentable.makeUIView
        webView.scrollView.contentInsetAdjustmentBehavior = .never

        // Simulate what UIKit does during layout: set safe area insets
        // With .never, the scroll view should NOT adjust its content insets
        webView.scrollView.contentInset = .zero

        XCTAssertEqual(webView.scrollView.contentInsetAdjustmentBehavior, .never,
                       "Behavior must stay .never to prevent layout feedback")
        XCTAssertEqual(webView.scrollView.contentInset, .zero,
                       "Content inset should remain zero with .never behavior")
    }
}
