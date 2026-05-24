import Foundation
import SwiftData

extension Notification.Name {
    /// Posted by `AppleEcosystemBridge` after any successful write under the
    /// reserved `skills/<user-slug>/` mount. The user-info dictionary carries
    /// `slug: String` — the affected skill's slug. Built-in writes never
    /// reach here (they're rejected by the resolver).
    ///
    /// Observed by `SkillsAutoReloader.start(container:)` which dispatches to
    /// `SkillService.reload(slug:)` with last-good cache semantics.
    static let skillsMountWrite = Notification.Name("iclaw.skill.mountWrite")
}

/// Wires `AppleEcosystemBridge`'s skills-mount write notifications to
/// `SkillService.reload(slug:)`.
///
/// The bridge can't hold a `ModelContext` directly (it lives in the WKWebView
/// dispatch context, the model lives in the SwiftData layer). This actor
/// bridges the two: it owns a reference to the app's `ModelContainer` and
/// creates a fresh `ModelContext` for each reload.
///
/// Wired up at app launch in `LaunchTaskManager` after `ensureBuiltInSkills`.
@MainActor
final class SkillsAutoReloader {

    static let shared = SkillsAutoReloader()
    private init() {}

    private weak var container: ModelContainer?
    private var observer: NSObjectProtocol?

    /// Start observing the skills-mount write notification and dispatching to
    /// `SkillService.reload`. Idempotent — calling twice replaces the observer.
    func start(container: ModelContainer) {
        stop()
        self.container = container
        observer = NotificationCenter.default.addObserver(
            forName: .skillsMountWrite,
            object: nil,
            queue: .main
        ) { [weak self] note in
            guard let slug = note.userInfo?["slug"] as? String, !slug.isEmpty else { return }
            // The closure runs on the main queue; bounce to the main actor.
            Task { @MainActor in
                self?.handle(slug: slug)
            }
        }
    }

    func stop() {
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
    }

    private func handle(slug: String) {
        guard let container else { return }
        let context = ModelContext(container)
        let service = SkillService(modelContext: context)
        _ = service.reload(slug: slug)
    }
}
