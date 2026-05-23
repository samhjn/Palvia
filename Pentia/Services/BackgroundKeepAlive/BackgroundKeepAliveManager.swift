import Foundation
import UIKit

/// Orchestrates the Live Activity background keep-alive strategy based on
/// the user's preference.
///
/// Tracks all active sessions (chat generations, cron jobs, sub-agents) and
/// manages the Dynamic Island / Lock Screen Live Activity accordingly.
///
/// Uses `UIApplication.beginBackgroundTask` alongside the Live Activity to
/// request additional execution time from iOS when entering the background.
///
/// The feature is persisted as a boolean in `UserDefaults` and is **off** by
/// default.
@MainActor
final class BackgroundKeepAliveManager {

    nonisolated static let enabledKey = "backgroundKeepAliveEnabled"

    private let liveActivityManager = CronLiveActivityManager()

    /// Active session IDs currently running.
    private var activeSessions: Set<UUID> = []
    /// Maps active session IDs to their display names.
    private var sessionNames: [UUID: String] = [:]
    /// Maps active session IDs to their latest silent-mode brief (text + SF symbol icon).
    private var sessionBriefs: [UUID: (text: String, icon: String)] = [:]
    /// Index for rotating through session names in the Live Activity.
    private var rotationIndex: Int = 0
    /// Timer for rotating session names in the Dynamic Island.
    private var rotationTimer: Timer?
    /// Whether the app is currently in the background.
    private(set) var isInBackground = false
    /// Whether any new tasks were started while the app was in background.
    private var hadNewTasksDuringBackground = false
    /// Name and error state of the last completed session (persists until new task starts).
    private var lastCompletionName: String?
    private var lastCompletionIsError: Bool = false
    /// Whether we are currently showing a completion status.
    private var isShowingCompletion = false

    /// System background task identifier for extending execution time.
    private var bgTaskId: UIBackgroundTaskIdentifier = .invalid

    /// Whether the Live Activity keep-alive is enabled (read from UserDefaults).
    var isEnabled: Bool {
        get { UserDefaults.standard.bool(forKey: Self.enabledKey) }
        set {
            UserDefaults.standard.set(newValue, forKey: Self.enabledKey)
            updatePreserveFlag()
            if !newValue { forceDeactivate() }
        }
    }

    /// Whether there are tasks actively running that should be kept alive.
    var hasActiveSessions: Bool { !activeSessions.isEmpty }

    /// Atomic flag set when there are active sessions and the feature is enabled.
    /// Readable from any isolation context for stream preservation decisions.
    private nonisolated(unsafe) var _shouldPreserveStreams = false

    /// Whether streams should be preserved rather than cancelled when entering background.
    nonisolated var shouldPreserveStreams: Bool { _shouldPreserveStreams }

    // MARK: - Lifecycle

    /// Called when the app moves to background.
    func activate() {
        isInBackground = true
        hadNewTasksDuringBackground = false
        guard isEnabled else { return }

        // Only start background keep-alive when there are active sessions
        guard !activeSessions.isEmpty else { return }

        beginSystemBackgroundTask()
        startOrUpdateActivity()
    }

    /// Called when the app returns to foreground.
    func onReturnToForeground() {
        isInBackground = false
        stopRotationTimer()
        endSystemBackgroundTask()

        if activeSessions.isEmpty && !hadNewTasksDuringBackground {
            // No tasks ran during background and nothing active now — dismiss
            liveActivityManager.stop()
            clearCompletion()
        }
        // If tasks are still active, keep the Live Activity visible
    }

    /// Force-stop the Live Activity (used when user disables the feature).
    private func forceDeactivate() {
        stopRotationTimer()
        liveActivityManager.stop()
        endSystemBackgroundTask()
        clearCompletion()
    }

    // MARK: - System Background Task

    /// Request additional background execution time from iOS.
    private func beginSystemBackgroundTask() {
        guard bgTaskId == .invalid else { return }
        bgTaskId = UIApplication.shared.beginBackgroundTask(withName: "iClaw.agentKeepAlive") { [weak self] in
            // System is about to expire our time — clean up
            Task { @MainActor in
                self?.endSystemBackgroundTask()
            }
        }
    }

    /// End the system background task if one is active.
    private func endSystemBackgroundTask() {
        guard bgTaskId != .invalid else { return }
        UIApplication.shared.endBackgroundTask(bgTaskId)
        bgTaskId = .invalid
    }

    // MARK: - Session Tracking

    /// Called when any agent task starts (chat, cron, sub-agent).
    func onSessionStarted(sessionId: UUID, sessionName: String) {
        activeSessions.insert(sessionId)
        sessionNames[sessionId] = sessionName
        updatePreserveFlag()

        if isInBackground {
            hadNewTasksDuringBackground = true
            // Ensure we have a background task when new work starts in background
            beginSystemBackgroundTask()
        }

        // Clear completion status when a new task starts
        clearCompletion()

        guard isEnabled else { return }
        startOrUpdateActivity()
    }

    /// Called by ChatViewModel/CronExecutor whenever a session's silent-mode
    /// progress changes (e.g. "think:2", "tool:browser_navigate").
    ///
    /// The raw status string (and optional last-tool hint) is formatted into
    /// a localized brief + SF Symbol icon and pushed to the Live Activity
    /// when the updated session is the one currently being displayed.
    func onSessionStatusUpdate(sessionId: UUID, silentStatus: String, lastTool: String?) {
        guard activeSessions.contains(sessionId) else { return }
        let brief = Self.formatSilentStatusBrief(silentStatus: silentStatus, lastTool: lastTool)
        sessionBriefs[sessionId] = brief

        guard isEnabled, !isShowingCompletion else { return }
        // Only refresh the Live Activity when the updated session is the one
        // currently on screen (rotation-aware) to avoid thrashing it.
        if sessionId == currentRotationSessionId() {
            startOrUpdateActivity()
        }
    }

    /// Called when any agent task completes.
    func onSessionCompleted(sessionId: UUID, sessionName: String, isError: Bool) {
        activeSessions.remove(sessionId)
        sessionNames.removeValue(forKey: sessionId)
        sessionBriefs.removeValue(forKey: sessionId)
        updatePreserveFlag()

        guard isEnabled else { return }

        if activeSessions.isEmpty {
            // All tasks done — show completion status
            stopRotationTimer()
            lastCompletionName = sessionName
            lastCompletionIsError = isError
            isShowingCompletion = true
            liveActivityManager.showCompletionStatus(sessionName: sessionName, isError: isError)

            // No more work — release the background task
            if isInBackground {
                endSystemBackgroundTask()
            }
        } else {
            // Other tasks still running — update the count
            startOrUpdateActivity()
        }
    }

    // MARK: - Internal

    private func startOrUpdateActivity() {
        let count = activeSessions.count
        let currentId = currentRotationSessionId()
        let name = currentId.flatMap { sessionNames[$0] } ?? ""
        let brief = currentId.flatMap { sessionBriefs[$0] } ?? (text: "", icon: "")

        let statusText: String
        if count > 0 {
            statusText = L10n.LiveActivity.agentsRunning(count)
        } else {
            statusText = L10n.LiveActivity.running
        }

        if liveActivityManager.isActive {
            liveActivityManager.update(
                activeAgentCount: count,
                sessionName: name,
                statusText: statusText,
                statusBrief: brief.text,
                statusBriefIcon: brief.icon
            )
        } else {
            liveActivityManager.start(
                activeAgentCount: max(count, 1),
                sessionName: name,
                statusText: statusText,
                statusBrief: brief.text,
                statusBriefIcon: brief.icon
            )
        }

        // Start rotation timer if multiple sessions
        if count > 1 && rotationTimer == nil {
            startRotationTimer()
        } else if count <= 1 {
            stopRotationTimer()
        }
    }

    /// Returns the session ID for the current rotation index (stable ordering
    /// by UUID so index → session mapping is deterministic).
    private func currentRotationSessionId() -> UUID? {
        let ids = activeSessions.sorted { $0.uuidString < $1.uuidString }
        guard !ids.isEmpty else { return nil }
        let index = rotationIndex % ids.count
        return ids[index]
    }

    private func startRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            Task { @MainActor in
                self?.rotateSessionName()
            }
        }
    }

    private func stopRotationTimer() {
        rotationTimer?.invalidate()
        rotationTimer = nil
        rotationIndex = 0
    }

    private func rotateSessionName() {
        guard !activeSessions.isEmpty else { return }
        rotationIndex += 1
        startOrUpdateActivity()
    }

    private func clearCompletion() {
        lastCompletionName = nil
        lastCompletionIsError = false
        isShowingCompletion = false
    }

    /// Keep the nonisolated flag in sync with current state.
    private func updatePreserveFlag() {
        _shouldPreserveStreams = isEnabled && !activeSessions.isEmpty
    }

    // MARK: - Silent-Mode Brief Formatting

    /// Turns a raw silent-mode status string (as stored by ChatViewModel) into
    /// a localized, human-readable brief suitable for display on the Live
    /// Activity. Mirrors the parsing in `ChatView.silentLabel` so what the
    /// user sees in the app matches what appears on the Lock Screen /
    /// Dynamic Island.
    ///
    /// - Parameters:
    ///   - silentStatus: One of `"think:N"`, `"tool:<name>"`, or empty.
    ///   - lastTool: Most recently executed tool name, used as a visual hint
    ///               while the agent is thinking between tool batches.
    /// - Returns: A tuple of (display text, SF Symbol icon name).
    static func formatSilentStatusBrief(silentStatus: String,
                                        lastTool: String?) -> (text: String, icon: String) {
        if silentStatus.hasPrefix("tool:") {
            let name = String(silentStatus.dropFirst(5))
            let meta = ToolMeta.resolve(name)
            return (meta.displayName, meta.icon)
        }
        if silentStatus.hasPrefix("think:"),
           let n = Int(silentStatus.dropFirst(6)), n > 1 {
            let icon = lastTool.map { ToolMeta.resolve($0).icon } ?? "brain.head.profile"
            return (L10n.Chat.silentThinking(n), icon)
        }
        if silentStatus.isEmpty {
            return ("", "")
        }
        return (L10n.Chat.thinking, "brain.head.profile")
    }
}
