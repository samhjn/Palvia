import XCTest
import SwiftData
@testable import Palvia

// MARK: - Shared Test Schema

private let testSchema = Schema([
    Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
    CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
    Message.self, SessionEmbedding.self
])

// MARK: - ChatScrollGeometry Tests

/// Pure-function tests for the bottom-anchoring math that the whole chat
/// scroll pipeline (near-bottom detection, over-scroll clamp, settle loop)
/// is built on.
final class ChatScrollGeometryTests: XCTestCase {

    func testMaxOffsetYWithContentTallerThanViewport() {
        let maxY = ChatScrollGeometry.maxOffsetY(
            contentHeight: 2000, boundsHeight: 800,
            adjustedTopInset: 0, adjustedBottomInset: 34)
        XCTAssertEqual(maxY, 1234, "maxOffsetY = content + bottomInset - bounds")
    }

    func testMaxOffsetYWithContentShorterThanViewportClampsToTopInset() {
        let maxY = ChatScrollGeometry.maxOffsetY(
            contentHeight: 300, boundsHeight: 812,
            adjustedTopInset: 100, adjustedBottomInset: 0)
        XCTAssertEqual(maxY, -100,
            "Short content must clamp to -topInset, never a negative overshoot beyond it")
    }

    func testDistanceToBottomIsZeroAtExactBottom() {
        let distance = ChatScrollGeometry.distanceToBottom(
            contentHeight: 2000, boundsHeight: 812,
            adjustedTopInset: 0, adjustedBottomInset: 0,
            offsetY: 1188)
        XCTAssertEqual(distance, 0)
    }

    func testDistanceToBottomNegativeWhenOverScrolled() {
        let distance = ChatScrollGeometry.distanceToBottom(
            contentHeight: 1000, boundsHeight: 812,
            adjustedTopInset: 0, adjustedBottomInset: 0,
            offsetY: 500)
        XCTAssertEqual(distance, -312,
            "Offset past the end of content must yield a negative distance (blank space visible)")
    }

    func testIsNearBottomUserThresholdBoundary() {
        XCTAssertTrue(ChatScrollGeometry.isNearBottom(distance: 50, isUserScrolling: true))
        XCTAssertFalse(ChatScrollGeometry.isNearBottom(distance: 51, isUserScrolling: true))
    }

    func testIsNearBottomIdleThresholdBoundary() {
        XCTAssertTrue(ChatScrollGeometry.isNearBottom(distance: 200, isUserScrolling: false))
        XCTAssertFalse(ChatScrollGeometry.isNearBottom(distance: 201, isUserScrolling: false))
    }

    @MainActor
    func testScrollViewOverloadsMatchPureFunctions() {
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        sv.contentSize = CGSize(width: 375, height: 3000)
        sv.contentOffset = CGPoint(x: 0, y: 1000)

        XCTAssertEqual(ChatScrollGeometry.maxOffsetY(sv),
                       ChatScrollGeometry.maxOffsetY(
                           contentHeight: 3000, boundsHeight: 812,
                           adjustedTopInset: sv.adjustedContentInset.top,
                           adjustedBottomInset: sv.adjustedContentInset.bottom))
        XCTAssertEqual(ChatScrollGeometry.distanceToBottom(sv),
                       ChatScrollGeometry.maxOffsetY(sv) - 1000)
    }

    @MainActor
    func testIsUserDrivenFalseForIdleScrollView() {
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        XCTAssertFalse(ChatScrollGeometry.isUserDriven(sv))
    }
}

// MARK: - ChatMessageFilter Tests

/// Tests for the production message filter that `ChatContentView` renders
/// from. Unlike the older stability tests (which replicated the logic), these
/// call the exact function the view uses.
final class ChatMessageFilterTests: XCTestCase {

    private var container: ModelContainer!
    private var context: ModelContext!

    @MainActor
    override func setUp() {
        super.setUp()
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: testSchema, configurations: [config])
        context = ModelContext(container)
    }

    override func tearDown() {
        container = nil
        context = nil
        super.tearDown()
    }

    @MainActor
    private func makeMixedMessages() -> [Message] {
        let user1 = Message(role: .user, content: "What's the weather?")
        let assistant2 = Message(role: .assistant, content: "Let me check.")
        let tool3 = Message(role: .tool, content: "72F", toolCallId: "c1", name: "get_weather")
        let calls = [LLMToolCall(id: "c2", name: "browser_navigate", arguments: "{}")]
        let assistant4 = Message(role: .assistant, content: nil,
                                 toolCallsData: try! JSONEncoder().encode(calls))
        let assistant5 = Message(role: .assistant, content: "The forecast is 72F.")
        let user6 = Message(role: .user, content: "Thanks!")
        let all = [user1, assistant2, tool3, assistant4, assistant5, user6]
        for msg in all { context.insert(msg) }
        return all
    }

    @MainActor
    func testVerboseModeReturnsAllMessages() {
        let all = makeMixedMessages()
        let visible = ChatMessageFilter.visibleMessages(all, isVerbose: true)
        XCTAssertEqual(visible.map(\.id), all.map(\.id))
    }

    @MainActor
    func testSilentModeHidesToolAndEmptyToolCallAssistant() {
        let all = makeMixedMessages()
        let visible = ChatMessageFilter.visibleMessages(all, isVerbose: false)
        XCTAssertEqual(visible.count, 4)
        XCTAssertFalse(visible.contains { $0.role == .tool })
        XCTAssertEqual(visible.map(\.id), [all[0].id, all[1].id, all[4].id, all[5].id])
    }

    @MainActor
    func testSilentModeKeepsAssistantWithContentAndToolCalls() {
        let calls = [LLMToolCall(id: "c1", name: "browser_navigate", arguments: "{}")]
        let msg = Message(role: .assistant, content: "Checking now.",
                          toolCallsData: try! JSONEncoder().encode(calls))
        context.insert(msg)
        XCTAssertTrue(ChatMessageFilter.isVisibleInSilentMode(msg))
    }

    @MainActor
    func testSilentModeKeepsAssistantWithEmptyJSONArrayToolCalls() {
        // "[]" = 2 bytes: the data.count > 2 guard must keep this visible.
        let msg = Message(role: .assistant, content: nil, toolCallsData: Data([0x5B, 0x5D]))
        context.insert(msg)
        XCTAssertTrue(ChatMessageFilter.isVisibleInSilentMode(msg))
    }

    // MARK: nearestVisibleId — the anchor used when the verbose/silent
    // toggle removes the row the viewport was resting on.

    @MainActor
    func testNearestVisibleIdReturnsTargetWhenVisible() {
        let all = makeMixedMessages()
        let displayed = ChatMessageFilter.visibleMessages(all, isVerbose: false)
        XCTAssertEqual(
            ChatMessageFilter.nearestVisibleId(to: all[0].id, all: all, displayed: displayed),
            all[0].id)
    }

    @MainActor
    func testNearestVisibleIdUsesClosestSurvivingNeighbor() {
        let all = makeMixedMessages()
        let displayed = ChatMessageFilter.visibleMessages(all, isVerbose: false)
        // tool3 (idx 2) is filtered; the next assistant answer is the semantic
        // continuation of the hidden tool plumbing.
        XCTAssertEqual(
            ChatMessageFilter.nearestVisibleId(to: all[2].id, all: all, displayed: displayed),
            all[4].id)
        // assistant4 (idx 3) is filtered; restoring should likewise move to
        // the assistant answer instead of jumping back to earlier content.
        XCTAssertEqual(
            ChatMessageFilter.nearestVisibleId(to: all[3].id, all: all, displayed: displayed),
            all[4].id)
    }

    @MainActor
    func testNearestVisibleIdFallsBackToFirstWhenNoVisiblePredecessor() {
        let tool = Message(role: .tool, content: "r", toolCallId: "c1", name: "fn")
        let user = Message(role: .user, content: "hi")
        context.insert(tool)
        context.insert(user)
        let all = [tool, user]
        let displayed = ChatMessageFilter.visibleMessages(all, isVerbose: false)
        XCTAssertEqual(
            ChatMessageFilter.nearestVisibleId(to: tool.id, all: all, displayed: displayed),
            user.id)
    }

    @MainActor
    func testNearestVisibleIdFallsBackToLastForUnknownTarget() {
        let all = makeMixedMessages()
        let displayed = ChatMessageFilter.visibleMessages(all, isVerbose: false)
        XCTAssertEqual(
            ChatMessageFilter.nearestVisibleId(to: UUID(), all: all, displayed: displayed),
            displayed.last?.id)
    }

    @MainActor
    func testNearestVisibleIdReturnsNilWhenNothingDisplayed() {
        let tool = Message(role: .tool, content: "r", toolCallId: "c1", name: "fn")
        context.insert(tool)
        let all = [tool]
        let displayed = ChatMessageFilter.visibleMessages(all, isVerbose: false)
        XCTAssertTrue(displayed.isEmpty)
        XCTAssertNil(ChatMessageFilter.nearestVisibleId(to: tool.id, all: all, displayed: displayed))
    }
}

// MARK: - Bottom Settle Loop Tests

/// Tests for `ChatScrollState.requestBottomSettle`, the mechanism that makes
/// "scroll to bottom" land in one user action even while async rendering
/// (markdown, tables, syntax highlighting, images) keeps changing the content
/// height under the scroll animation.
@MainActor
final class ChatScrollStateSettleTests: XCTestCase {

    private func makeScrollView(contentHeight: CGFloat, offsetY: CGFloat) -> UIScrollView {
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        sv.contentSize = CGSize(width: 375, height: contentHeight)
        sv.contentOffset = CGPoint(x: 0, y: offsetY)
        return sv
    }

    func testSettleTicksWhileShortOfBottomAndStopsAtAttemptLimit() async throws {
        let state = ChatScrollState()
        // Far from bottom and nothing will move it (no SwiftUI answering the
        // ticks), so every pass should tick until attempts are exhausted.
        // (scrollView is weak — keep a strong reference for the test's lifetime.)
        let sv = makeScrollView(contentHeight: 2000, offsetY: 0)
        state.scrollView = sv

        state.requestBottomSettle(attempts: 3, initialDelay: 0.03, interval: 0.03)
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(state.bottomCorrectionTick, 3,
            "Settle loop should tick once per pass and stop at the attempt limit")
        withExtendedLifetime(sv) {}
    }

    func testSettleDoesNotTickWhenAlreadyAtBottom() async throws {
        let state = ChatScrollState()
        let sv = makeScrollView(contentHeight: 2000, offsetY: 0)
        sv.contentOffset = CGPoint(x: 0, y: ChatScrollGeometry.maxOffsetY(sv))
        state.scrollView = sv

        state.requestBottomSettle(attempts: 3, initialDelay: 0.03, interval: 0.03)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(state.bottomCorrectionTick, 0,
            "No correction needed when the view is already settled at the bottom")
        withExtendedLifetime(sv) {}
    }

    func testSettleStopsOnceBottomIsReached() async throws {
        let state = ChatScrollState()
        let sv = makeScrollView(contentHeight: 2000, offsetY: 0)
        state.scrollView = sv

        state.requestBottomSettle(attempts: 6, initialDelay: 0.03, interval: 0.05)
        // Let at least one pass fire, then simulate SwiftUI answering the tick
        // by moving the offset to the bottom.
        try await Task.sleep(for: .milliseconds(120))
        sv.contentOffset = CGPoint(x: 0, y: ChatScrollGeometry.maxOffsetY(sv))
        let ticksWhenSettled = state.bottomCorrectionTick
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertGreaterThanOrEqual(ticksWhenSettled, 1,
            "At least one pass should have fired before the bottom was reached")
        XCTAssertLessThan(state.bottomCorrectionTick, 6,
            "Once the bottom is reached the loop must stop instead of burning all attempts")
        withExtendedLifetime(sv) {}
    }

    func testSettleRespectsUserScrollAway() async throws {
        let state = ChatScrollState()
        let sv = makeScrollView(contentHeight: 2000, offsetY: 0)
        state.scrollView = sv
        state.userDidScrollAway = true

        state.requestBottomSettle(attempts: 3, initialDelay: 0.03, interval: 0.03)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(state.bottomCorrectionTick, 0,
            "The settle loop must never fight a user who scrolled away")
        withExtendedLifetime(sv) {}
    }

    func testUserScrollAwayMidLoopStopsSubsequentPasses() async throws {
        let state = ChatScrollState()
        let sv = makeScrollView(contentHeight: 2000, offsetY: 0)
        state.scrollView = sv

        state.requestBottomSettle(attempts: 6, initialDelay: 0.03, interval: 0.05)
        try await Task.sleep(for: .milliseconds(120))
        state.userDidScrollAway = true
        let ticksAtGrab = state.bottomCorrectionTick
        try await Task.sleep(for: .milliseconds(400))

        XCTAssertEqual(state.bottomCorrectionTick, ticksAtGrab,
            "Grabbing the scroll view mid-settle must stop further corrections")
        withExtendedLifetime(sv) {}
    }

    func testSettleWithoutScrollViewRetriesWithoutCrashing() async throws {
        let state = ChatScrollState()
        // scrollView never attached — the loop should retry and expire quietly.
        state.requestBottomSettle(attempts: 3, initialDelay: 0.03, interval: 0.03)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertEqual(state.bottomCorrectionTick, 0)
    }

    func testNewerSettleRequestSupersedesOlder() async throws {
        let state = ChatScrollState()
        let sv = makeScrollView(contentHeight: 2000, offsetY: 0)
        state.scrollView = sv

        state.requestBottomSettle(attempts: 5, initialDelay: 0.03, interval: 0.03)
        state.requestBottomSettle(attempts: 5, initialDelay: 0.03, interval: 0.03)
        try await Task.sleep(for: .milliseconds(600))

        XCTAssertLessThanOrEqual(state.bottomCorrectionTick, 5,
            "The first request must be cancelled by the second; ticks must not accumulate across generations")
        XCTAssertGreaterThanOrEqual(state.bottomCorrectionTick, 1,
            "The surviving request must still run its passes")
        withExtendedLifetime(sv) {}
    }

    func testIsUserInteractingFalseWithoutScrollView() {
        let state = ChatScrollState()
        XCTAssertFalse(state.isUserInteracting)
    }

    func testIsUserInteractingFalseForIdleScrollView() {
        let state = ChatScrollState()
        let sv = makeScrollView(contentHeight: 2000, offsetY: 0)
        state.scrollView = sv
        XCTAssertFalse(state.isUserInteracting)
        withExtendedLifetime(sv) {}
    }
}

// MARK: - Content Growth Gating Tests

/// Tests for the contentSize observer's growth gating: streaming-induced
/// growth re-anchors to the bottom, but growth caused by the user expanding
/// a tool-call / thinking card while idle must NOT yank the viewport down.
@MainActor
final class ScrollObserverGrowthGatingTests: XCTestCase {

    private func makeObservedPair() -> (ChatScrollState, ScrollViewOffsetObserver.Coordinator, UIScrollView) {
        let state = ChatScrollState()
        let observer = ScrollViewOffsetObserver(scrollState: state)
        let coordinator = observer.makeCoordinator()
        let sv = UIScrollView(frame: CGRect(x: 0, y: 0, width: 375, height: 812))
        sv.contentSize = CGSize(width: 375, height: 1000)
        state.scrollView = sv
        coordinator.observe(sv)
        return (state, coordinator, sv)
    }

    func testGrowthDuringGenerationTriggersBottomCorrection() async throws {
        let (state, coordinator, sv) = makeObservedPair()
        state.isGenerationActive = true

        // Content grows well past the follow threshold while pinned at bottom.
        sv.contentSize = CGSize(width: 375, height: 2000)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertGreaterThanOrEqual(state.bottomCorrectionTick, 1,
            "Streaming growth must re-anchor the view to the bottom")
        withExtendedLifetime((coordinator, sv)) {}
    }

    func testGrowthWhileIdleDoesNotTriggerBottomCorrection() async throws {
        let (state, coordinator, sv) = makeObservedPair()
        state.isGenerationActive = false

        // Same growth, but no generation running — e.g. the user expanded a
        // tool-call card. Re-anchoring would scroll the expansion out of view.
        sv.contentSize = CGSize(width: 375, height: 2000)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.bottomCorrectionTick, 0,
            "Idle growth (card expansion) must not yank the viewport to the bottom")
        withExtendedLifetime((coordinator, sv)) {}
    }

    func testGrowthWhileScrolledAwayNeverTicks() async throws {
        let (state, coordinator, sv) = makeObservedPair()
        state.isGenerationActive = true
        state.userDidScrollAway = true

        sv.contentSize = CGSize(width: 375, height: 2000)
        try await Task.sleep(for: .milliseconds(100))

        XCTAssertEqual(state.bottomCorrectionTick, 0,
            "Growth while the user reads history must not re-anchor")
        withExtendedLifetime((coordinator, sv)) {}
    }

    func testShrinkLeavesNoBlankSpaceBelowContent() async throws {
        let (state, coordinator, sv) = makeObservedPair()
        state.isGenerationActive = false
        sv.contentSize = CGSize(width: 375, height: 3000)
        sv.contentOffset = CGPoint(x: 0, y: 2000)
        try await Task.sleep(for: .milliseconds(50))

        // Content collapses under the current offset (e.g. streaming bubble
        // removed, or a huge card collapsed). Depending on the OS version,
        // UIKit may clamp the offset itself during setContentSize — in which
        // case the observer correctly stays quiet — or leave it over-scrolled,
        // in which case the observer must clamp/re-anchor. Either way the end
        // state must have no blank space below the content.
        sv.contentSize = CGSize(width: 375, height: 1000)
        try await Task.sleep(for: .milliseconds(300))

        XCTAssertGreaterThanOrEqual(ChatScrollGeometry.distanceToBottom(sv), -1,
            "After a shrink the offset must end inside the legal range (no blank screen)")
        withExtendedLifetime((coordinator, state, sv)) {}
    }

    func testDirectOverScrollIsClampedBackToContentEnd() async throws {
        // makeObservedPair starts with contentSize 1000 in an 812pt viewport.
        let (state, coordinator, sv) = makeObservedPair()
        state.isGenerationActive = false

        // Force an over-scrolled offset directly. Unlike a contentSize shrink,
        // UIKit does not clamp direct contentOffset assignment, so this
        // deterministically exercises the observer's display-link clamp.
        sv.contentOffset = CGPoint(x: 0, y: 2000)
        try await Task.sleep(for: .milliseconds(300))

        let maxY = ChatScrollGeometry.maxOffsetY(sv)
        XCTAssertEqual(sv.contentOffset.y, maxY, accuracy: 1,
            "An over-scrolled offset must be clamped back to maxOffsetY (no blank screen)")
        withExtendedLifetime((coordinator, state, sv)) {}
    }
}

// MARK: - Markdown Streaming Robustness Tests

/// Streaming delivers markdown incrementally, so the parser constantly sees
/// truncated constructs (open code fences, half-written tables, dangling
/// emphasis). Every prefix must parse without crashing and without runaway
/// output, otherwise the streaming bubble's height thrashes or the row goes
/// blank mid-scroll.
final class MarkdownStreamingRobustnessTests: XCTestCase {

    private let complexDocument = """
    # Result Summary

    Here is *emphasis*, **bold**, `inline code`, and a [link](https://example.com).

    ```swift
    func greet(_ name: String) -> String {
        return "Hello, \\(name)!"
    }
    ```

    | Column A | Column B | Column C |
    |:---------|:--------:|---------:|
    | a1       | b1       | c1       |
    | a2       | b2       | c2       |

    - bullet one
    - bullet two

    1. first
    2. second

    - [ ] todo item
    - [x] done item

    > A blockquote
    > spanning two lines

    ---

    ![diagram](https://example.com/diagram.png)

    Final paragraph with ~~strikethrough~~.
    """

    func testEveryStreamingPrefixParsesWithoutCrashing() {
        let full = complexDocument
        var step = 1
        var length = 0
        while length <= full.count {
            let prefix = String(full.prefix(length))
            let blocks = MarkdownContentView(prefix).parseBlocks()
            // Sanity: block count can never exceed line count + 1.
            let lineCount = prefix.components(separatedBy: "\n").count
            XCTAssertLessThanOrEqual(blocks.count, lineCount + 1,
                "Prefix of length \(length) produced runaway block count")
            length += step
            step = min(step + 1, 17) // vary the chunk size like real deltas
        }
    }

    func testUnterminatedCodeFenceParsesAsSingleCodeBlock() {
        let content = "```swift\nlet x = 1\nlet y = 2"
        let blocks = MarkdownContentView(content).parseBlocks()
        XCTAssertEqual(blocks.count, 1)
        if case .codeBlock(let lang, let code) = blocks.first {
            XCTAssertEqual(lang, "swift")
            XCTAssertEqual(code, "let x = 1\nlet y = 2")
        } else {
            XCTFail("Expected an (unterminated) code block, got \(blocks)")
        }
    }

    func testHalfWrittenTableDoesNotProduceTableBlock() {
        // Header line alone — the separator hasn't streamed in yet.
        let blocks = MarkdownContentView("| Col A | Col B |").parseBlocks()
        XCTAssertFalse(blocks.contains { if case .table = $0 { return true } else { return false } },
            "A header row without a separator must not become a table yet")
    }

    func testTableAppearsOnceSeparatorArrives() {
        let content = "| Col A | Col B |\n|---|---|\n| a | b |"
        let blocks = MarkdownContentView(content).parseBlocks()
        XCTAssertEqual(blocks.count, 1)
        if case .table(let table) = blocks.first {
            XCTAssertEqual(table.headers, ["Col A", "Col B"])
            XCTAssertEqual(table.rows, [["a", "b"]])
        } else {
            XCTFail("Expected a table block, got \(blocks)")
        }
    }

    func testParsingIsDeterministicAcrossRepeatedCalls() {
        let blocks1 = MarkdownContentView(complexDocument).parseBlocks()
        let blocks2 = MarkdownContentView(complexDocument).parseBlocks()
        XCTAssertEqual(blocks1, blocks2,
            "Same content must always produce identical blocks (cache correctness relies on this)")
    }

    func testFullDocumentBlockInventory() {
        let blocks = MarkdownContentView(complexDocument).parseBlocks()
        func count(_ predicate: (MarkdownBlock) -> Bool) -> Int { blocks.filter(predicate).count }

        XCTAssertEqual(count { if case .heading = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(count { if case .codeBlock = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(count { if case .table = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(count { if case .bulletList = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(count { if case .orderedList = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(count { if case .taskList = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(count { if case .blockquote = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(count { if case .horizontalRule = $0 { return true } else { return false } }, 1)
        XCTAssertEqual(count { if case .image = $0 { return true } else { return false } }, 1)
    }

    func testDanglingInlineMarkersRenderAsPlainText() {
        let cases = ["**bold never closes", "`code never closes", "~~strike never closes",
                     "[link never closes", "![image never closes"]
        for text in cases {
            let result = MarkdownContentView.parseInlineMarkdown(text, isUserMessage: false)
            XCTAssertFalse(String(result.characters).isEmpty,
                "Dangling marker in \(text) must still render text, not vanish")
        }
    }
}
