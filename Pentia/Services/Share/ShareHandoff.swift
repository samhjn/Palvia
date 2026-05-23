import Foundation
import SwiftData
import os.log

/// Processes `iclaw://session/new?agentId=<uuid>&handoffId=<uuid>` deep links
/// emitted by the Share Extension. When the deep-link open fails (Apple
/// disabled the legacy `openURL:` selector in iOS 18), the main app falls
/// back to `processPending(…)` on launch / foreground to pick up any
/// unclaimed staged directories.
///
/// Responsibilities:
/// 1. Look up the target root agent.
/// 2. Create a new session for that agent.
/// 3. Move staged files from the App Group's `ShareStaging/<handoffId>/`
///    directory into the agent's on-disk file folder.
/// 4. Seed in-memory `ChatViewModel` caches so the compose area shows the
///    shared files as pending attachments without writing `Session.draft*`.
/// 5. Publish the new session via `PendingSessionRouter` so
///    `SessionListView` navigates to it.
/// 6. Delete the staging directory.
enum ShareHandoff {

    private static let log = OSLog(subsystem: "com.iclaw.share", category: "handoff")

    // MARK: - Public entry points

    /// Returns true if the URL is a share-handoff deep link this processor
    /// knows how to handle.
    static func isHandoffURL(_ url: URL) -> Bool {
        guard url.scheme == "iclaw" else { return false }
        guard url.host == "session" else { return false }
        let components = url.pathComponents.filter { $0 != "/" }
        return components.first == "new"
    }

    /// Process a deep link. Must run on the main actor because it touches
    /// SwiftData relationships.
    @MainActor
    static func apply(
        url: URL,
        modelContainer: ModelContainer,
        router: PendingSessionRouter
    ) {
        guard isHandoffURL(url) else { return }
        guard let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let handoffIdStr = components.queryItems?.first(where: { $0.name == "handoffId" })?.value,
              let handoffId = UUID(uuidString: handoffIdStr) else {
            os_log(.error, log: log, "Invalid handoff URL: %{public}@", url.absoluteString)
            return
        }
        _ = applyStagedHandoff(
            handoffId: handoffId,
            modelContainer: modelContainer,
            router: router
        )
    }

    /// Scan the staging directory for unclaimed handoffs and process the
    /// newest one (if any). Called on app launch and foreground so a share
    /// eventually lands even if the extension couldn't open a deep link.
    @MainActor
    static func processPending(
        modelContainer: ModelContainer,
        router: PendingSessionRouter
    ) {
        guard let staging = SharedContainer.stagingDirectory else {
            os_log(.error, log: log,
                   "processPending: App Group container unavailable — entitlement missing on main app?")
            return
        }
        guard FileManager.default.fileExists(atPath: staging.path) else {
            os_log(.default, log: log,
                   "processPending: no staging directory at %{public}@ (nothing to process)",
                   staging.path)
            return
        }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: staging,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else {
            os_log(.error, log: log,
                   "processPending: could not enumerate %{public}@", staging.path)
            return
        }

        os_log(.default, log: log,
               "processPending: scanning %{public}@, %d entries",
               staging.path, entries.count)

        // Collect (handoffId, mtime) for directories with a valid manifest,
        // sorted newest-first.
        struct Pending {
            let id: UUID
            let mtime: Date
        }
        let staleCutoff = Date().addingTimeInterval(-5 * 60) // 5 minutes
        let candidates: [Pending] = entries.compactMap { url in
            guard let id = UUID(uuidString: url.lastPathComponent) else {
                os_log(.default, log: log,
                       "processPending: skipping non-uuid entry %{public}@",
                       url.lastPathComponent)
                return nil
            }
            let m = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            guard HandoffManifest.load(from: url) != nil else {
                os_log(.default, log: log,
                       "processPending: skipping %{public}@ (no manifest)",
                       url.lastPathComponent)
                // Clean up a broken/manifestless leftover so it doesn't linger.
                if m < staleCutoff {
                    try? FileManager.default.removeItem(at: url)
                    os_log(.default, log: log,
                           "processPending: removed stale manifestless %{public}@",
                           url.lastPathComponent)
                }
                return nil
            }
            return Pending(id: id, mtime: m)
        }.sorted { $0.mtime > $1.mtime }

        guard !candidates.isEmpty else {
            os_log(.default, log: log, "processPending: no valid handoffs to process")
            return
        }

        os_log(.default, log: log, "Found %d pending handoff(s)", candidates.count)

        // Process all candidates, but only the newest drives navigation —
        // earlier ones still populate their sessions so nothing is lost.
        for (index, pending) in candidates.enumerated() {
            let navigateForThis = (index == 0)
            _ = applyStagedHandoff(
                handoffId: pending.id,
                modelContainer: modelContainer,
                router: navigateForThis ? router : PendingSessionRouter()
            )
        }
    }

    // MARK: - Core handoff

    /// Materialize a single staged handoff. Returns the created session, or
    /// `nil` if the handoff was missing / empty / for an unknown agent.
    @MainActor
    @discardableResult
    private static func applyStagedHandoff(
        handoffId: UUID,
        modelContainer: ModelContainer,
        router: PendingSessionRouter
    ) -> Session? {
        guard let stagingDir = SharedContainer.stagingDirectory(handoffId: handoffId),
              FileManager.default.fileExists(atPath: stagingDir.path),
              let manifest = HandoffManifest.load(from: stagingDir) else {
            os_log(.error, log: log, "Missing or invalid staging dir for handoff %{public}@",
                   handoffId.uuidString)
            return nil
        }

        let context = modelContainer.mainContext
        guard let agent = fetchRootAgent(id: manifest.agentId, context: context) else {
            os_log(.error, log: log, "Unknown agent in manifest: %{public}@",
                   manifest.agentId.uuidString)
            cleanupStaging(handoffId: handoffId)
            return nil
        }

        os_log(.default, log: log, "Applying handoff %{public}@: %d files for agent %{public}@",
               handoffId.uuidString, manifest.files.count, agent.name)

        let resolvedAgentId = AgentFileManager.shared.resolveAgentId(for: agent)

        var pendingImages: [ImageAttachment] = []
        var pendingFiles: [FileAttachment] = []
        var pendingVideoRefs: [String] = []

        for file in manifest.files {
            let src = stagingDir.appendingPathComponent(file.name)
            guard FileManager.default.fileExists(atPath: src.path),
                  let data = try? Data(contentsOf: src) else {
                continue
            }

            let finalName = uniqueFilename(preferred: file.name, agentId: resolvedAgentId)
            do {
                try AgentFileManager.shared.writeFile(agentId: resolvedAgentId, name: finalName, data: data)
            } catch {
                os_log(.error, log: log, "Failed to copy staged file %{public}@: %{public}@",
                       file.name, String(describing: error))
                continue
            }
            let ref = AgentFileManager.makeFileReference(agentId: resolvedAgentId, filename: finalName)

            switch file.kind {
            case .image:
                if let img = ImageAttachment.from(fileReference: ref) {
                    pendingImages.append(img)
                } else if let fallback = FileAttachment.from(fileReference: ref) {
                    pendingFiles.append(fallback)
                }
            case .video:
                pendingVideoRefs.append(ref)
            case .file, .text:
                if let f = FileAttachment.from(fileReference: ref) {
                    pendingFiles.append(f)
                }
            }
        }

        guard !(pendingImages.isEmpty && pendingFiles.isEmpty && pendingVideoRefs.isEmpty) else {
            os_log(.error, log: log, "Handoff %{public}@ had no usable files", handoffId.uuidString)
            cleanupStaging(handoffId: handoffId)
            return nil
        }

        let session = Session(title: L10n.Chat.newChat)
        context.insert(session)
        session.agent = agent
        do {
            try context.save()
        } catch {
            os_log(.error, log: log, "Failed to save new session: %{public}@", String(describing: error))
            cleanupStaging(handoffId: handoffId)
            return nil
        }

        if !pendingImages.isEmpty {
            ChatViewModel.seedPendingImages(for: session.id, append: pendingImages)
        }
        if !pendingFiles.isEmpty {
            ChatViewModel.seedPendingFiles(for: session.id, append: pendingFiles)
        }
        os_log(.default, log: log, "Seeded %d images, %d files, %d video refs pending for session %{public}@",
               pendingImages.count, pendingFiles.count, pendingVideoRefs.count, session.id.uuidString)

        let sessionId = session.id
        for ref in pendingVideoRefs {
            Task { @MainActor in
                if let vid = await VideoAttachment.from(fileReference: ref) {
                    ChatViewModel.seedPendingVideos(for: sessionId, append: [vid])
                }
            }
        }

        router.pendingSession = session
        cleanupStaging(handoffId: handoffId)
        return session
    }

    // MARK: - Orphan sweep

    /// Delete staging directories older than `maxAge` seconds. Covers the
    /// case where a user shared something but never returned to iClaw.
    static func sweepOrphans(maxAge: TimeInterval = 24 * 60 * 60) {
        guard let staging = SharedContainer.stagingDirectory else { return }
        sweepOrphans(in: staging, maxAge: maxAge, now: Date())
    }

    /// Internal helper, test-visible. Sweeps a caller-provided staging root.
    static func sweepOrphans(
        in stagingRoot: URL,
        maxAge: TimeInterval,
        now: Date
    ) {
        guard FileManager.default.fileExists(atPath: stagingRoot.path) else { return }
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: stagingRoot,
            includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }
        let cutoff = now.addingTimeInterval(-maxAge)
        for url in entries {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate ?? .distantPast
            if mtime < cutoff {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    // MARK: - Helpers

    private static func fetchRootAgent(id: UUID, context: ModelContext) -> Agent? {
        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.id == id && $0.parentAgent == nil }
        )
        return try? context.fetch(descriptor).first
    }

    private static func uniqueFilename(preferred: String, agentId: UUID) -> String {
        let safe = AgentFileManager.isSafeFilename(preferred) ? preferred : "file_\(UUID().uuidString.prefix(8))"
        guard AgentFileManager.shared.fileExists(agentId: agentId, name: safe) else { return safe }
        let ns = safe as NSString
        let base = ns.deletingPathExtension
        let ext = ns.pathExtension
        let suffix = UUID().uuidString.prefix(6)
        if ext.isEmpty {
            return "\(base)_\(suffix)"
        }
        return "\(base)_\(suffix).\(ext)"
    }

    private static func cleanupStaging(handoffId: UUID) {
        guard let dir = SharedContainer.stagingDirectory(handoffId: handoffId) else { return }
        try? FileManager.default.removeItem(at: dir)
    }
}
