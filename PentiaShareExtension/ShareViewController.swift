import UIKit
import SwiftUI
import os.log

private let vcLog = OSLog(subsystem: "com.iclaw.share", category: "viewcontroller")

/// Principal class for the Share Extension. Hosts `SharePickerView` and
/// orchestrates the lifecycle: load agent snapshot → user picks agent →
/// stage attachments → open host app via deep link.
final class ShareViewController: UIViewController {

    private var hostingController: UIViewController?

    override func viewDidLoad() {
        super.viewDidLoad()

        let containerAvailable = SharedContainer.containerURL != nil
        let snapshot = AgentSnapshot.load()
        let agents = snapshot?.agents ?? []

        NSLog("[iClawShare] viewDidLoad — containerAvailable=%@ snapshotAgents=%d",
              containerAvailable ? "YES" : "NO",
              agents.count)
        os_log(.default, log: vcLog,
               "viewDidLoad containerAvailable=%{public}@ snapshotAgents=%d",
               containerAvailable ? "YES" : "NO", agents.count)

        let picker = SharePickerView(
            agents: agents,
            containerAvailable: containerAvailable,
            onSelect: { [weak self] agent in
                self?.handleSelection(agent: agent)
            },
            onCancel: { [weak self] in
                self?.cancel()
            }
        )

        let host = UIHostingController(rootView: picker)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    // MARK: - Flow

    private func handleSelection(agent: AgentSnapshotEntry) {
        let items = (extensionContext?.inputItems as? [NSExtensionItem]) ?? []
        NSLog("[iClawShare] handleSelection agent=%@ inputItems=%d",
              agent.name, items.count)
        Task { [weak self] in
            guard let self else { return }
            let handoffId = await ShareItemStager.stage(items: items, agentId: agent.id)
            await MainActor.run {
                guard let handoffId else {
                    NSLog("[iClawShare] stager returned nil — nothing to share")
                    self.finish(withError: ShareL10n.errorNothingToShare)
                    return
                }
                NSLog("[iClawShare] stager produced handoffId=%@", handoffId.uuidString)
                self.openHostApp(agentId: agent.id, handoffId: handoffId)
            }
        }
    }

    private func openHostApp(agentId: UUID, handoffId: UUID) {
        var components = URLComponents()
        components.scheme = "iclaw"
        components.host = "session"
        components.path = "/new"
        components.queryItems = [
            URLQueryItem(name: "agentId", value: agentId.uuidString),
            URLQueryItem(name: "handoffId", value: handoffId.uuidString),
        ]
        guard let url = components.url else {
            os_log(.error, log: vcLog, "Could not build handoff URL")
            cancel()
            return
        }
        os_log(.default, log: vcLog, "Opening host app url=%{public}@", url.absoluteString)

        guard let context = extensionContext else {
            os_log(.error, log: vcLog, "No extension context")
            cancel()
            return
        }

        // Best-effort: NSExtensionContext.open is documented only for
        // messaging/action/Today extensions, but on some iOS versions it
        // opens the host for share extensions too. We try it; regardless of
        // the outcome, the host app's foreground-sweep will materialize the
        // staged handoff the next time the user opens iClaw.
        context.open(url) { [weak self, weak context] success in
            os_log(.default, log: vcLog,
                   "context.open returned success=%{public}@",
                   success ? "true" : "false")
            DispatchQueue.main.async {
                if success {
                    context?.completeRequest(returningItems: [], completionHandler: nil)
                } else {
                    self?.showOpenIClawPrompt(handoffId: handoffId)
                }
            }
        }
    }

    /// Swap the agent picker for a success screen instructing the user to
    /// open iClaw manually, since iOS won't let a share extension foreground
    /// its host app.
    private func showOpenIClawPrompt(handoffId: UUID) {
        let promptView = ShareDoneView { [weak self] in
            self?.extensionContext?.completeRequest(returningItems: [], completionHandler: nil)
        }
        hostingController?.willMove(toParent: nil)
        hostingController?.view.removeFromSuperview()
        hostingController?.removeFromParent()

        let host = UIHostingController(rootView: promptView)
        addChild(host)
        view.addSubview(host.view)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        NSLayoutConstraint.activate([
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor),
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
        ])
        host.didMove(toParent: self)
        hostingController = host
    }

    private func cancel() {
        extensionContext?.cancelRequest(withError: NSError(
            domain: "com.iclaw.share",
            code: NSUserCancelledError,
            userInfo: nil
        ))
    }

    private func finish(withError message: String) {
        let alert = UIAlertController(title: nil, message: message, preferredStyle: .alert)
        alert.addAction(UIAlertAction(title: ShareL10n.errorOK, style: .default) { [weak self] _ in
            self?.cancel()
        })
        present(alert, animated: true)
    }
}
