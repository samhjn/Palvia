import ActivityKit
import Foundation

/// Manages a Live Activity that appears on the Dynamic Island / Lock Screen
/// while background tasks are running, giving the system a reason to keep the app
/// active and providing the user with at-a-glance status.
@MainActor
final class CronLiveActivityManager {

    /// How long a completion pill stays visible before the system removes it.
    /// The activity is already ended when the pill is shown, so dismissal is
    /// guaranteed by the OS even if the app is suspended or killed meanwhile.
    static let completionDismissalInterval: TimeInterval = 5 * 60

    /// How long after the last update the system may mark the content stale —
    /// a fallback signal for activities the app can no longer update (e.g.
    /// after a crash). The widget renders stale content dimmed.
    static let staleInterval: TimeInterval = 15 * 60

    private var currentActivity: Activity<CronActivityAttributes>?
    /// Observes system-side state changes of `currentActivity`.
    private var stateObservationTask: Task<Void, Never>?
    private(set) var isActive = false

    init() {
        // Anything the system still shows at process start is an orphan from a
        // previous run (crash, force-quit, jetsam) — `currentActivity` only
        // lives in memory, so orphans can never be updated again. End them
        // now; otherwise they linger for hours and the next start() would put
        // a second activity beside them.
        endStrayActivities()
    }

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
                await existing.update(Self.runningContent(state))
            }
            return
        }

        // Sweep completion pills that haven't reached their dismissal date yet
        // so we never show two activities side by side.
        endStrayActivities()

        do {
            let activity = try Activity.request(
                attributes: CronActivityAttributes(),
                content: Self.runningContent(state),
                pushType: nil
            )
            currentActivity = activity
            isActive = true
            observeActivityState(activity)
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
            await activity.update(Self.runningContent(state))
        }
    }

    /// Shows completion status by *ending* the activity with a delayed
    /// dismissal: the pill stays glanceable for a few minutes, then the
    /// system removes it on its own — no app code needs to run, so the pill
    /// can never get stuck if the app is suspended, killed, or never
    /// foregrounded again.
    func showCompletionStatus(sessionName: String, isError: Bool) {
        guard let activity = takeCurrentActivity() else { return }
        let state = CronActivityAttributes.ContentState(
            activeAgentCount: 0,
            sessionName: sessionName,
            statusText: isError ? L10n.LiveActivity.error : L10n.LiveActivity.done,
            isCompleted: !isError,
            isError: isError
        )
        Task {
            await activity.end(
                ActivityContent(state: state, staleDate: nil),
                dismissalPolicy: .after(Date().addingTimeInterval(Self.completionDismissalInterval))
            )
        }
        print("[LiveActivity] Ended activity with completion pill")
    }

    /// Ends the Live Activity immediately (e.g. when all tasks finish without
    /// a completion to show, or the user disables the feature).
    func stop() {
        guard let activity = takeCurrentActivity() else { return }
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
        print("[LiveActivity] Stopped activity")
    }

    // MARK: - Internal

    /// Detaches the tracked activity and resets local state, returning the
    /// activity so the caller can end it.
    private func takeCurrentActivity() -> Activity<CronActivityAttributes>? {
        stateObservationTask?.cancel()
        stateObservationTask = nil
        defer {
            currentActivity = nil
            isActive = false
        }
        return currentActivity
    }

    private static func runningContent(
        _ state: CronActivityAttributes.ContentState
    ) -> ActivityContent<CronActivityAttributes.ContentState> {
        ActivityContent(state: state, staleDate: Date().addingTimeInterval(staleInterval))
    }

    /// Keeps local state in sync with the system: when the user dismisses the
    /// activity from the Lock Screen (or the system ends it), drop our
    /// reference so future updates aren't silently swallowed and the next
    /// task can request a fresh activity.
    private func observeActivityState(_ activity: Activity<CronActivityAttributes>) {
        stateObservationTask?.cancel()
        stateObservationTask = Task { @MainActor [weak self] in
            for await state in activity.activityStateUpdates {
                guard state == .dismissed || state == .ended else { continue }
                guard let self, self.currentActivity?.id == activity.id else { return }
                self.currentActivity = nil
                self.isActive = false
                self.stateObservationTask = nil
                return
            }
        }
    }

    /// Ends every system-registered activity except the one currently
    /// tracked: orphans from a previous process and completion pills still
    /// awaiting their dismissal date.
    private func endStrayActivities() {
        let currentId = currentActivity?.id
        let strays = Activity<CronActivityAttributes>.activities.filter { $0.id != currentId }
        guard !strays.isEmpty else { return }
        Task {
            for stray in strays {
                await stray.end(nil, dismissalPolicy: .immediate)
            }
            print("[LiveActivity] Ended \(strays.count) stray activities")
        }
    }
}
