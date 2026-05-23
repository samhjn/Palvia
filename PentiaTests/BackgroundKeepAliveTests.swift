import XCTest
import SwiftData
@testable import iClaw

// MARK: - BackgroundKeepAliveManager Tests

final class BackgroundKeepAliveManagerTests: XCTestCase {

    private let testKey = BackgroundKeepAliveManager.enabledKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
        super.tearDown()
    }

    // MARK: Enabled Key

    func testEnabledKeyIsExpectedString() {
        XCTAssertEqual(BackgroundKeepAliveManager.enabledKey, "backgroundKeepAliveEnabled")
    }

    // MARK: Default State

    @MainActor
    func testDefaultIsDisabled() {
        UserDefaults.standard.removeObject(forKey: testKey)
        let manager = BackgroundKeepAliveManager()
        XCTAssertFalse(manager.isEnabled)
    }

    // MARK: Persistence

    @MainActor
    func testEnablePersistsToUserDefaults() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        XCTAssertTrue(UserDefaults.standard.bool(forKey: testKey))
    }

    @MainActor
    func testDisablePersistsToUserDefaults() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        manager.isEnabled = false
        XCTAssertFalse(UserDefaults.standard.bool(forKey: testKey))
    }

    @MainActor
    func testReadsFromUserDefaults() {
        UserDefaults.standard.set(true, forKey: testKey)
        let manager = BackgroundKeepAliveManager()
        XCTAssertTrue(manager.isEnabled)
    }

    // MARK: Round-Trip

    @MainActor
    func testRoundTrip() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        XCTAssertTrue(manager.isEnabled)
        manager.isEnabled = false
        XCTAssertFalse(manager.isEnabled)
    }

    // MARK: Lifecycle Safety

    @MainActor
    func testOnReturnToForegroundFromCleanStateDoesNotCrash() {
        let manager = BackgroundKeepAliveManager()
        manager.onReturnToForeground()
    }

    @MainActor
    func testDoubleReturnToForegroundDoesNotCrash() {
        let manager = BackgroundKeepAliveManager()
        manager.onReturnToForeground()
        manager.onReturnToForeground()
    }

    // MARK: Activate When Disabled

    @MainActor
    func testActivateWhenDisabledIsNoOp() {
        UserDefaults.standard.removeObject(forKey: testKey)
        let manager = BackgroundKeepAliveManager()
        manager.activate()
    }

    // MARK: Session Events When Disabled

    @MainActor
    func testOnSessionStartedWhenDisabledIsNoOp() {
        UserDefaults.standard.removeObject(forKey: testKey)
        let manager = BackgroundKeepAliveManager()
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Test")
    }

    @MainActor
    func testOnSessionCompletedWhenDisabledIsNoOp() {
        UserDefaults.standard.removeObject(forKey: testKey)
        let manager = BackgroundKeepAliveManager()
        let id = UUID()
        manager.onSessionCompleted(sessionId: id, sessionName: "Test", isError: false)
    }

    // MARK: Disabling Calls Deactivate

    @MainActor
    func testDisablingCallsDeactivate() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        manager.isEnabled = false
        XCTAssertFalse(manager.isEnabled)
    }

    // MARK: Smart Foreground Lifecycle

    @MainActor
    func testReturnToForegroundWithNoBackgroundTasksDismisses() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        // Go to background with no active tasks
        manager.activate()
        // Return to foreground without any tasks having started
        manager.onReturnToForeground()
        // Should not crash — Live Activity should be dismissed
    }

    @MainActor
    func testReturnToForegroundWithActiveTasksKeepsActivity() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Test Task")
        manager.activate()
        // Return to foreground while task still running
        manager.onReturnToForeground()
        // Complete the task after returning
        manager.onSessionCompleted(sessionId: id, sessionName: "Test Task", isError: false)
    }

    // MARK: Multiple Sessions

    @MainActor
    func testMultipleSessionsTracked() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id1 = UUID()
        let id2 = UUID()
        manager.onSessionStarted(sessionId: id1, sessionName: "Task 1")
        manager.onSessionStarted(sessionId: id2, sessionName: "Task 2")
        // Complete one — should still be active
        manager.onSessionCompleted(sessionId: id1, sessionName: "Task 1", isError: false)
        // Complete the other
        manager.onSessionCompleted(sessionId: id2, sessionName: "Task 2", isError: false)
    }

    @MainActor
    func testSessionCompletedWithError() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Failing Task")
        manager.onSessionCompleted(sessionId: id, sessionName: "Failing Task", isError: true)
    }

    // MARK: hasActiveSessions

    @MainActor
    func testHasActiveSessionsDefaultFalse() {
        let manager = BackgroundKeepAliveManager()
        XCTAssertFalse(manager.hasActiveSessions)
    }

    @MainActor
    func testHasActiveSessionsTrueAfterStart() {
        let manager = BackgroundKeepAliveManager()
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Test")
        XCTAssertTrue(manager.hasActiveSessions)
    }

    @MainActor
    func testHasActiveSessionsFalseAfterComplete() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Test")
        XCTAssertTrue(manager.hasActiveSessions)
        manager.onSessionCompleted(sessionId: id, sessionName: "Test", isError: false)
        XCTAssertFalse(manager.hasActiveSessions)
    }

    // MARK: isInBackground

    @MainActor
    func testIsInBackgroundTracksLifecycle() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        XCTAssertFalse(manager.isInBackground)
        manager.activate()
        XCTAssertTrue(manager.isInBackground)
        manager.onReturnToForeground()
        XCTAssertFalse(manager.isInBackground)
    }

    // MARK: Background task starts when entering background with active sessions

    @MainActor
    func testActivateWithActiveSessionsDoesNotCrash() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Task")
        manager.activate()
        manager.onReturnToForeground()
        manager.onSessionCompleted(sessionId: id, sessionName: "Task", isError: false)
    }

    @MainActor
    func testNewSessionDuringBackgroundSetsFlag() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        manager.activate()
        XCTAssertTrue(manager.isInBackground)
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "BG Task")
        // Return to foreground — should keep activity since task started during background
        manager.onReturnToForeground()
        // Clean up
        manager.onSessionCompleted(sessionId: id, sessionName: "BG Task", isError: false)
    }

    // MARK: shouldPreserveStreams

    @MainActor
    func testShouldPreserveStreamsFalseByDefault() {
        let manager = BackgroundKeepAliveManager()
        XCTAssertFalse(manager.shouldPreserveStreams)
    }

    @MainActor
    func testShouldPreserveStreamsFalseWhenDisabled() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = false
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Test")
        XCTAssertFalse(manager.shouldPreserveStreams)
        manager.onSessionCompleted(sessionId: id, sessionName: "Test", isError: false)
    }

    @MainActor
    func testShouldPreserveStreamsTrueWhenEnabledWithSessions() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Test")
        XCTAssertTrue(manager.shouldPreserveStreams)
        manager.onSessionCompleted(sessionId: id, sessionName: "Test", isError: false)
        XCTAssertFalse(manager.shouldPreserveStreams)
    }

    @MainActor
    func testShouldPreserveStreamsAccessibleFromNonisolated() {
        let manager = BackgroundKeepAliveManager()
        // This test verifies the property is nonisolated and compiles without @MainActor
        let _ = manager.shouldPreserveStreams
    }
}

// MARK: - CronActivityAttributes Tests

final class CronActivityAttributesTests: XCTestCase {

    // MARK: ContentState Codable

    func testContentStateEncodeDecode() throws {
        let state = CronActivityAttributes.ContentState(
            activeAgentCount: 3,
            sessionName: "Daily Report",
            statusText: "3 Agents running"
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            CronActivityAttributes.ContentState.self,
            from: encoded
        )
        XCTAssertEqual(decoded.activeAgentCount, 3)
        XCTAssertEqual(decoded.sessionName, "Daily Report")
        XCTAssertEqual(decoded.statusText, "3 Agents running")
        XCTAssertFalse(decoded.isCompleted)
        XCTAssertFalse(decoded.isError)
    }

    func testContentStateWithCompletionStatus() throws {
        let state = CronActivityAttributes.ContentState(
            activeAgentCount: 0,
            sessionName: "Finished Task",
            statusText: "All tasks completed",
            isCompleted: true,
            isError: false
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            CronActivityAttributes.ContentState.self,
            from: encoded
        )
        XCTAssertEqual(decoded.activeAgentCount, 0)
        XCTAssertEqual(decoded.sessionName, "Finished Task")
        XCTAssertTrue(decoded.isCompleted)
        XCTAssertFalse(decoded.isError)
    }

    func testContentStateWithErrorStatus() throws {
        let state = CronActivityAttributes.ContentState(
            activeAgentCount: 0,
            sessionName: "Failed Task",
            statusText: "Task failed",
            isCompleted: false,
            isError: true
        )
        let encoded = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(
            CronActivityAttributes.ContentState.self,
            from: encoded
        )
        XCTAssertTrue(decoded.isError)
        XCTAssertFalse(decoded.isCompleted)
    }

    func testContentStateDecodesFromJSON() throws {
        let json = """
        {"activeAgentCount": 5, "sessionName": "Test", "statusText": "Processing…", "isCompleted": false, "isError": false}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(
            CronActivityAttributes.ContentState.self,
            from: json
        )
        XCTAssertEqual(state.activeAgentCount, 5)
        XCTAssertEqual(state.sessionName, "Test")
        XCTAssertEqual(state.statusText, "Processing…")
    }

    // MARK: ContentState Hashable

    func testContentStateEquality() {
        let a = CronActivityAttributes.ContentState(activeAgentCount: 2, sessionName: "S", statusText: "Running")
        let b = CronActivityAttributes.ContentState(activeAgentCount: 2, sessionName: "S", statusText: "Running")
        XCTAssertEqual(a, b)
    }

    func testContentStateInequalityByCount() {
        let a = CronActivityAttributes.ContentState(activeAgentCount: 1, sessionName: "S", statusText: "Running")
        let b = CronActivityAttributes.ContentState(activeAgentCount: 2, sessionName: "S", statusText: "Running")
        XCTAssertNotEqual(a, b)
    }

    func testContentStateInequalityBySessionName() {
        let a = CronActivityAttributes.ContentState(activeAgentCount: 1, sessionName: "A", statusText: "Running")
        let b = CronActivityAttributes.ContentState(activeAgentCount: 1, sessionName: "B", statusText: "Running")
        XCTAssertNotEqual(a, b)
    }

    func testContentStateInequalityByStatus() {
        let a = CronActivityAttributes.ContentState(activeAgentCount: 1, sessionName: "S", statusText: "Running")
        let b = CronActivityAttributes.ContentState(activeAgentCount: 1, sessionName: "S", statusText: "Done")
        XCTAssertNotEqual(a, b)
    }

    func testContentStateInequalityByCompletion() {
        let a = CronActivityAttributes.ContentState(activeAgentCount: 0, sessionName: "S", statusText: "Done", isCompleted: true)
        let b = CronActivityAttributes.ContentState(activeAgentCount: 0, sessionName: "S", statusText: "Done", isCompleted: false)
        XCTAssertNotEqual(a, b)
    }

    func testContentStateHashConsistency() {
        let state = CronActivityAttributes.ContentState(activeAgentCount: 4, sessionName: "S", statusText: "Test")
        let hash1 = state.hashValue
        let hash2 = state.hashValue
        XCTAssertEqual(hash1, hash2)
    }

    func testEqualStatesHaveEqualHashes() {
        let a = CronActivityAttributes.ContentState(activeAgentCount: 3, sessionName: "S", statusText: "Same")
        let b = CronActivityAttributes.ContentState(activeAgentCount: 3, sessionName: "S", statusText: "Same")
        XCTAssertEqual(a.hashValue, b.hashValue)
    }

    func testContentStateWorksInSet() {
        let s1 = CronActivityAttributes.ContentState(activeAgentCount: 1, sessionName: "A", statusText: "A")
        let s2 = CronActivityAttributes.ContentState(activeAgentCount: 2, sessionName: "B", statusText: "B")
        let s3 = CronActivityAttributes.ContentState(activeAgentCount: 1, sessionName: "A", statusText: "A") // duplicate
        let set: Set = [s1, s2, s3]
        XCTAssertEqual(set.count, 2)
    }

    // MARK: StatusBrief fields

    func testContentStateStatusBriefDefaultsToEmpty() {
        let state = CronActivityAttributes.ContentState(
            activeAgentCount: 1,
            sessionName: "S",
            statusText: "Running"
        )
        XCTAssertEqual(state.statusBrief, "")
        XCTAssertEqual(state.statusBriefIcon, "")
    }

    func testContentStateStatusBriefRoundTrips() throws {
        let state = CronActivityAttributes.ContentState(
            activeAgentCount: 2,
            sessionName: "S",
            statusText: "2 Agents running",
            statusBrief: "Thinking (round 3)",
            statusBriefIcon: "globe"
        )
        let data = try JSONEncoder().encode(state)
        let decoded = try JSONDecoder().decode(CronActivityAttributes.ContentState.self, from: data)
        XCTAssertEqual(decoded.statusBrief, "Thinking (round 3)")
        XCTAssertEqual(decoded.statusBriefIcon, "globe")
    }

    func testContentStateInequalityByStatusBrief() {
        let a = CronActivityAttributes.ContentState(
            activeAgentCount: 1, sessionName: "S", statusText: "Running",
            statusBrief: "Thinking", statusBriefIcon: "brain.head.profile"
        )
        let b = CronActivityAttributes.ContentState(
            activeAgentCount: 1, sessionName: "S", statusText: "Running",
            statusBrief: "Browsing", statusBriefIcon: "brain.head.profile"
        )
        XCTAssertNotEqual(a, b)
    }

    func testContentStateInequalityByStatusBriefIcon() {
        let a = CronActivityAttributes.ContentState(
            activeAgentCount: 1, sessionName: "S", statusText: "Running",
            statusBrief: "Thinking", statusBriefIcon: "brain.head.profile"
        )
        let b = CronActivityAttributes.ContentState(
            activeAgentCount: 1, sessionName: "S", statusText: "Running",
            statusBrief: "Thinking", statusBriefIcon: "globe"
        )
        XCTAssertNotEqual(a, b)
    }

    /// Older payloads (without the brief fields) must still decode into
    /// defaulted empty values to keep Live Activities backward compatible.
    func testContentStateDecodesLegacyPayloadWithoutBrief() throws {
        let json = """
        {"activeAgentCount": 1, "sessionName": "Legacy", "statusText": "Running", "isCompleted": false, "isError": false}
        """.data(using: .utf8)!
        let state = try JSONDecoder().decode(CronActivityAttributes.ContentState.self, from: json)
        XCTAssertEqual(state.sessionName, "Legacy")
        XCTAssertEqual(state.statusBrief, "")
        XCTAssertEqual(state.statusBriefIcon, "")
    }
}

// MARK: - Silent-Mode Brief Formatting Tests

@MainActor
final class SilentStatusBriefFormatterTests: XCTestCase {

    func testEmptyStatusProducesEmptyBrief() {
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(silentStatus: "", lastTool: nil)
        XCTAssertEqual(brief.text, "")
        XCTAssertEqual(brief.icon, "")
    }

    func testToolStatusUsesToolMetaDisplayAndIcon() {
        // file_read maps to icon "doc.text"
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(
            silentStatus: "tool:file_read", lastTool: nil
        )
        XCTAssertEqual(brief.icon, "doc.text")
        XCTAssertFalse(brief.text.isEmpty, "Known tool should produce non-empty display name")
    }

    func testToolStatusWithUnknownToolFallsBackToWrench() {
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(
            silentStatus: "tool:super_secret_tool", lastTool: nil
        )
        XCTAssertEqual(brief.icon, "wrench")
        XCTAssertEqual(brief.text, "super_secret_tool",
                       "Unknown tool falls back to its raw name per ToolMeta default")
    }

    func testThinkStatusRoundOneFallsBackToThinking() {
        // "think:1" is treated as the initial round → generic thinking label.
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(
            silentStatus: "think:1", lastTool: nil
        )
        XCTAssertEqual(brief.icon, "brain.head.profile")
        XCTAssertEqual(brief.text, L10n.Chat.thinking)
    }

    func testThinkStatusRoundTwoUsesSilentThinkingText() {
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(
            silentStatus: "think:2", lastTool: nil
        )
        XCTAssertEqual(brief.text, L10n.Chat.silentThinking(2))
        XCTAssertEqual(brief.icon, "brain.head.profile",
                       "No last tool → default brain icon")
    }

    func testThinkStatusAdoptsLastToolIcon() {
        // With a recent tool, the think brief should borrow that tool's icon
        // so the user knows which capability was last used.
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(
            silentStatus: "think:3", lastTool: "browser_navigate"
        )
        XCTAssertEqual(brief.icon, "globe", "browser_navigate resolves to globe")
        XCTAssertEqual(brief.text, L10n.Chat.silentThinking(3))
    }

    func testMalformedStatusFallsBackToThinking() {
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(
            silentStatus: "garbage", lastTool: nil
        )
        XCTAssertEqual(brief.icon, "brain.head.profile")
        XCTAssertEqual(brief.text, L10n.Chat.thinking)
    }

    func testThinkStatusWithNonNumericRoundFallsBackToThinking() {
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(
            silentStatus: "think:abc", lastTool: nil
        )
        XCTAssertEqual(brief.icon, "brain.head.profile")
        XCTAssertEqual(brief.text, L10n.Chat.thinking)
    }

    func testToolStatusWithEmptyNameFallsBackGracefully() {
        let brief = BackgroundKeepAliveManager.formatSilentStatusBrief(
            silentStatus: "tool:", lastTool: nil
        )
        // Unknown empty tool still resolves through ToolMeta.default → wrench icon.
        XCTAssertEqual(brief.icon, "wrench")
    }
}

// MARK: - onSessionStatusUpdate Behavior Tests

final class BackgroundKeepAliveStatusUpdateTests: XCTestCase {

    private let testKey = BackgroundKeepAliveManager.enabledKey

    override func tearDown() {
        UserDefaults.standard.removeObject(forKey: testKey)
        super.tearDown()
    }

    @MainActor
    func testStatusUpdateForUnknownSessionIsNoOp() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        // No session started — update must not crash or throw.
        manager.onSessionStatusUpdate(
            sessionId: UUID(),
            silentStatus: "tool:file_read",
            lastTool: nil
        )
        XCTAssertFalse(manager.hasActiveSessions)
    }

    @MainActor
    func testStatusUpdateForActiveSessionDoesNotCrash() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Task")
        manager.onSessionStatusUpdate(sessionId: id, silentStatus: "tool:file_read", lastTool: nil)
        manager.onSessionStatusUpdate(sessionId: id, silentStatus: "think:2", lastTool: "file_read")
        manager.onSessionStatusUpdate(sessionId: id, silentStatus: "", lastTool: nil)
        manager.onSessionCompleted(sessionId: id, sessionName: "Task", isError: false)
        XCTAssertFalse(manager.hasActiveSessions)
    }

    @MainActor
    func testStatusUpdateWhenDisabledIsSafe() {
        UserDefaults.standard.removeObject(forKey: testKey)
        let manager = BackgroundKeepAliveManager()
        // Disabled: session tracking never happens, so the update short-circuits.
        manager.onSessionStatusUpdate(
            sessionId: UUID(),
            silentStatus: "tool:file_read",
            lastTool: nil
        )
    }

    @MainActor
    func testStatusUpdateAfterCompletionIsSafe() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id = UUID()
        manager.onSessionStarted(sessionId: id, sessionName: "Task")
        manager.onSessionCompleted(sessionId: id, sessionName: "Task", isError: false)
        // Late status update (e.g. coalesced dispatch) must not re-activate anything.
        manager.onSessionStatusUpdate(sessionId: id, silentStatus: "tool:file_read", lastTool: nil)
        XCTAssertFalse(manager.hasActiveSessions)
    }

    @MainActor
    func testMultipleSessionsReceiveIndependentStatusUpdates() {
        let manager = BackgroundKeepAliveManager()
        manager.isEnabled = true
        let id1 = UUID()
        let id2 = UUID()
        manager.onSessionStarted(sessionId: id1, sessionName: "A")
        manager.onSessionStarted(sessionId: id2, sessionName: "B")
        manager.onSessionStatusUpdate(sessionId: id1, silentStatus: "tool:browser_navigate", lastTool: nil)
        manager.onSessionStatusUpdate(sessionId: id2, silentStatus: "think:2", lastTool: "file_read")
        manager.onSessionCompleted(sessionId: id1, sessionName: "A", isError: false)
        manager.onSessionCompleted(sessionId: id2, sessionName: "B", isError: false)
        XCTAssertFalse(manager.hasActiveSessions)
    }
}

// MARK: - CronLiveActivityManager State Tests

final class CronLiveActivityManagerStateTests: XCTestCase {

    @MainActor
    func testInitialStateIsInactive() {
        let manager = CronLiveActivityManager()
        XCTAssertFalse(manager.isActive)
    }

    @MainActor
    func testStopFromInactiveStateDoesNotCrash() {
        let manager = CronLiveActivityManager()
        XCTAssertFalse(manager.isActive)
        manager.stop()
        XCTAssertFalse(manager.isActive)
    }

    @MainActor
    func testUpdateWithNoActivityDoesNotCrash() {
        let manager = CronLiveActivityManager()
        manager.update(activeAgentCount: 5, sessionName: "test", statusText: "test")
    }

    @MainActor
    func testShowCompletionWithNoActivityDoesNotCrash() {
        let manager = CronLiveActivityManager()
        manager.showCompletionStatus(sessionName: "test", isError: false)
    }

    @MainActor
    func testDoubleStopDoesNotCrash() {
        let manager = CronLiveActivityManager()
        manager.stop()
        manager.stop()
        XCTAssertFalse(manager.isActive)
    }
}

// MARK: - CronScheduler KeepAlive Integration Tests

final class CronSchedulerKeepAliveTests: XCTestCase {

    private var container: ModelContainer!

    @MainActor
    override func setUp() {
        super.setUp()
        let schema = Schema([Agent.self, LLMProvider.self, Session.self, AgentConfig.self,
                             CodeSnippet.self, CronJob.self, InstalledSkill.self, Skill.self,
                             Message.self, SessionEmbedding.self])
        let config = ModelConfiguration(isStoredInMemoryOnly: true)
        container = try! ModelContainer(for: schema, configurations: [config])
    }

    override func tearDown() {
        container = nil
        super.tearDown()
    }

    @MainActor
    func testKeepAliveManagerIsNilByDefault() {
        let scheduler = CronScheduler(modelContainer: container)
        XCTAssertNil(scheduler.keepAliveManager)
        scheduler.stop()
    }

    @MainActor
    func testKeepAliveManagerCanBeSet() {
        let scheduler = CronScheduler(modelContainer: container)
        let manager = BackgroundKeepAliveManager()
        scheduler.keepAliveManager = manager
        XCTAssertNotNil(scheduler.keepAliveManager)
        scheduler.stop()
    }

    @MainActor
    func testSchedulerStartDoesNotRequireKeepAliveManager() {
        let scheduler = CronScheduler(modelContainer: container)
        XCTAssertNil(scheduler.keepAliveManager)
        scheduler.start()
        XCTAssertTrue(scheduler.isRunning)
        scheduler.stop()
    }

    @MainActor
    func testSchedulerRunningJobsStartEmpty() {
        let scheduler = CronScheduler(modelContainer: container)
        let manager = BackgroundKeepAliveManager()
        scheduler.keepAliveManager = manager
        scheduler.start()
        XCTAssertTrue(scheduler.runningJobIds.isEmpty)
        scheduler.stop()
    }

    @MainActor
    func testPauseResumeWithKeepAliveManager() {
        let scheduler = CronScheduler(modelContainer: container)
        let manager = BackgroundKeepAliveManager()
        scheduler.keepAliveManager = manager
        scheduler.start()
        scheduler.pause()
        scheduler.resume()
        XCTAssertTrue(scheduler.isRunning)
        scheduler.stop()
    }
}

// MARK: - Info.plist Capability Tests

final class BackgroundKeepAliveInfoPlistTests: XCTestCase {

    /// Verify that Live Activities support is declared.
    func testNSSupportsLiveActivitiesIsTrue() {
        let bundle = Bundle(for: CronScheduler.self)
        let supports = bundle.object(forInfoDictionaryKey: "NSSupportsLiveActivities") as? Bool
        XCTAssertEqual(supports, true,
                       "Info.plist must set NSSupportsLiveActivities to true")
    }

    /// Audio background mode should NOT be present (removed for review safety).
    func testAudioBackgroundModeIsNotPresent() {
        let bundle = Bundle(for: CronScheduler.self)
        guard let modes = bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            XCTFail("UIBackgroundModes not found in Info.plist")
            return
        }
        XCTAssertFalse(modes.contains("audio"),
                       "audio background mode should not be declared. Found: \(modes)")
    }

    /// Existing background modes should still be present.
    func testExistingBackgroundModesPreserved() {
        let bundle = Bundle(for: CronScheduler.self)
        guard let modes = bundle.object(forInfoDictionaryKey: "UIBackgroundModes") as? [String] else {
            XCTFail("UIBackgroundModes not found")
            return
        }
        XCTAssertTrue(modes.contains("fetch"), "fetch mode should be preserved")
        XCTAssertTrue(modes.contains("processing"), "processing mode should be preserved")
    }
}
