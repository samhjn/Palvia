import Foundation
import Observation

/// Bridges the app-level deep-link handler to `SessionListView`, which
/// observes `pendingSession` and programmatically selects it when set.
@Observable
final class PendingSessionRouter {
    /// The session to navigate to. `SessionListView` clears this back to `nil`
    /// after consuming it to allow subsequent shares to trigger again.
    var pendingSession: Session?
}
