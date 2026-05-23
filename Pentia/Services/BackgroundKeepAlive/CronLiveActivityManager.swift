import ActivityKit
import Foundation

/// Manages a Live Activity that appears on the Dynamic Island / Lock Screen
/// while background tasks are running, giving the system a reason to keep the app
/// active and providing the user with at-a-glance status.
@MainActor
final class CronLiveActivityManager {

    private var currentActivity: Activity<CronActivityAttributes>?
    private(set) var isActive = false

    /// Starts (or updates) the Live Activity with the current task info.
    func start(activeAgentCount: Int = 1,
               sessionName: String = "",
               statusText: String? = nil,
               statusBrief: String = "",
               statusBriefIcon: String = "") {
        guard ActivityAuthorizationInfo().areActivitiesEnabled else {
            print("[LiveActivity] Live Activities are not enabled")
            return
        }

        let state = CronActivityAttributes.ContentState(
            activeAgentCount: activeAgentCount,
            sessionName: sessionName,
            statusText: statusText ?? L10n.LiveActivity.running,
            statusBrief: statusBrief,
            statusBriefIcon: statusBriefIcon
        )

        if let existing = currentActivity {
            Task {
                await existing.update(
                    ActivityContent(state: state, staleDate: nil)
                )
            }
            return
        }

        let attributes = CronActivityAttributes()
        do {
            currentActivity = try Activity.request(
                attributes: attributes,
                content: .init(state: state, staleDate: nil),
                pushType: nil
            )
            isActive = true
            print("[LiveActivity] Started activity")
        } catch {
            print("[LiveActivity] Failed to start: \(error)")
        }
    }

    /// Updates the Live Activity with current task state.
    func update(activeAgentCount: Int,
                sessionName: String = "",
                statusText: String? = nil,
                isCompleted: Bool = false,
                isError: Bool = false,
                statusBrief: String = "",
                statusBriefIcon: String = "") {
        guard let activity = currentActivity else { return }
        let state = CronActivityAttributes.ContentState(
            activeAgentCount: activeAgentCount,
            sessionName: sessionName,
            statusText: statusText ?? L10n.LiveActivity.running,
            isCompleted: isCompleted,
            isError: isError,
            statusBrief: statusBrief,
            statusBriefIcon: statusBriefIcon
        )
        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: nil)
            )
        }
    }

    /// Shows completion status on the Live Activity without ending it.
    func showCompletionStatus(sessionName: String, isError: Bool) {
        guard let activity = currentActivity else { return }
        let state = CronActivityAttributes.ContentState(
            activeAgentCount: 0,
            sessionName: sessionName,
            statusText: isError ? L10n.LiveActivity.error : L10n.LiveActivity.done,
            isCompleted: !isError,
            isError: isError
        )
        Task {
            await activity.update(
                ActivityContent(state: state, staleDate: nil)
            )
        }
    }

    /// Ends the Live Activity (e.g. when all tasks finish or the user disables the feature).
    func stop() {
        guard let activity = currentActivity else { return }
        let finalState = CronActivityAttributes.ContentState(
            activeAgentCount: 0,
            sessionName: "",
            statusText: L10n.LiveActivity.done
        )
        Task {
            await activity.end(
                ActivityContent(state: finalState, staleDate: nil),
                dismissalPolicy: .immediate
            )
        }
        currentActivity = nil
        isActive = false
        print("[LiveActivity] Stopped activity")
    }
}
