import Foundation
import SwiftData
import Observation

@Observable
final class LaunchTaskManager {

    enum TaskPhase: Equatable {
        case idle
        case running(description: String, progress: Double?)
        case done
    }

    private(set) var phase: TaskPhase = .idle
    private(set) var completedCount = 0
    private(set) var totalCount = 0

    private let container: ModelContainer

    init(container: ModelContainer) {
        self.container = container
    }

    // MARK: - Public

    @MainActor
    func runAll() {
        guard phase == .idle else { return }
        totalCount = 2
        completedCount = 0
        phase = .running(description: L10n.Launch.cleaningUp, progress: nil)

        // Keep built-in skills in sync with the current UI locale before any
        // view reads from SwiftData. The call is cheap (field-by-field diff;
        // most launches are a no-op) and running it on the main actor here
        // avoids racing with SkillLibraryView/AgentSkillsView, which also
        // trigger `ensureBuiltInSkills` on appear.
        let skillService = SkillService(modelContext: ModelContext(container))
        skillService.ensureBuiltInSkills()
        // Pick up any package the user dropped under <Documents>/Skills/
        // since the last launch (Files.app drag-in, zip extraction, Working
        // Copy clone). New folders without a matching Skill row become rows
        // here so they appear in the library without an explicit import.
        skillService.discoverDiskPackages()
        // Plan the row → on-disk-package migration on the main actor (cheap:
        // SwiftData fetch + slug + snapshot, no disk I/O). The actual disk
        // writes happen off-main below so a user with many legacy skills
        // doesn't see a launch stall.
        let pendingSkillMigrations = skillService.planMigrationToOnDiskPackages()

        // Wire the auto-reload bridge so writes through `fs.*` to user skills
        // under the `/skills/` mount refresh the matching `Skill` row's
        // cached fields on the next agent turn (last-good cache semantics).
        SkillsAutoReloader.shared.start(container: container)

        // Create `<Documents>/Skills/` eagerly so it shows up in the iOS
        // Files app even before the first user skill is authored or
        // imported. Built-in skills live in the read-only bundle and are
        // intentionally not visible there — only user-authored / imported
        // packages live under Documents/Skills.
        let skillsRoot = AgentFileManager.shared.skillsRoot
        if !FileManager.default.fileExists(atPath: skillsRoot.path) {
            try? FileManager.default.createDirectory(
                at: skillsRoot,
                withIntermediateDirectories: true
            )
        }

        Task.detached(priority: .utility) { [weak self] in
            guard let self else { return }

            // Disk writes for the planned row → on-disk-package migration.
            // No SwiftData access here; the snapshots already captured every
            // field we need. Failures log + continue.
            SkillService.commitPendingMigrations(pendingSkillMigrations)

            await self.cleanupOrphanAgentFiles()
            await MainActor.run {
                self.completedCount = 1
                self.phase = .running(
                    description: L10n.Launch.buildingIndex,
                    progress: 0
                )
            }

            await self.backfillSessionEmbeddings()
            await MainActor.run {
                self.completedCount = 2
                self.phase = .done
            }
        }
    }

    // MARK: - Cleanup orphan agent files

    private func cleanupOrphanAgentFiles() async {
        await MainActor.run {
            let context = ModelContext(container)
            let descriptor = FetchDescriptor<Agent>()
            let allAgents = (try? context.fetch(descriptor)) ?? []
            let knownIds = Set(allAgents.map(\.id))
            if !knownIds.isEmpty {
                AgentFileManager.shared.cleanupOrphanDirectories(knownAgentIds: knownIds)
            }
            // Publish friendly-named symlinks in Documents/Agents/ so the iOS Files
            // app can show folders by agent name instead of raw UUIDs.
            AgentDirectoryPublisher.shared.syncAll(agents: allAgents)
        }
    }

    // MARK: - Backfill embeddings (CPU-throttled)

    private func backfillSessionEmbeddings() async {
        let pending: [SessionEmbeddingTask] = await MainActor.run {
            let context = ModelContext(container)
            let store = SessionVectorStore(modelContext: context)
            return store.sessionsNeedingEmbedding().map {
                SessionEmbeddingTask(sessionId: $0.id, text: SessionVectorStore.buildEmbeddingText(for: $0))
            }
        }
        let total = pending.count
        guard total > 0 else { return }

        let localService = LocalEmbeddingService()
        let batchSize = 5

        var computed: [(sessionId: UUID, vector: [Float], text: String)] = []

        for (index, task) in pending.enumerated() {
            if Task.isCancelled { break }

            guard !task.text.isEmpty else { continue }
            guard let vector = localService.embed(text: task.text) else { continue }
            computed.append((task.sessionId, vector, task.text))

            let progress = Double(index + 1) / Double(total)
            await MainActor.run {
                self.phase = .running(
                    description: L10n.Launch.buildingIndex,
                    progress: progress
                )
            }

            if (index + 1) % batchSize == 0 && index + 1 < total {
                try? await Task.sleep(for: .milliseconds(100))
            }
        }

        guard !computed.isEmpty else { return }
        let results = computed
        await MainActor.run {
            let context = ModelContext(self.container)
            let store = SessionVectorStore(modelContext: context)
            for item in results {
                store.upsertEmbeddingDirect(
                    sessionId: item.sessionId,
                    vector: item.vector,
                    sourceText: item.text
                )
            }
        }
    }
}

private struct SessionEmbeddingTask {
    let sessionId: UUID
    let text: String
}
