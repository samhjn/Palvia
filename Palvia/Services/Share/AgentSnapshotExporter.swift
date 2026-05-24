import Foundation
import SwiftData

/// Publishes a read-only snapshot of the user's root agents to the App Group's
/// `UserDefaults` so the Share Extension can list them without touching the
/// SwiftData store.
///
/// Called on launch and after every root-agent create/rename/delete in the
/// main app. Sub-agents are intentionally excluded to match the
/// `NewSessionSheet` picker.
enum AgentSnapshotExporter {

    static func export(context: ModelContext) {
        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.parentAgent == nil },
            sortBy: [SortDescriptor(\.name)]
        )
        let agents = (try? context.fetch(descriptor)) ?? []
        let entries = agents.map { AgentSnapshotEntry(id: $0.id, name: $0.name) }
        let snapshot = AgentSnapshot(
            version: AgentSnapshot.currentVersion,
            generatedAt: Date(),
            agents: entries
        )
        AgentSnapshot.save(snapshot)
    }
}
