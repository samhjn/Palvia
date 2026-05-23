import Foundation

/// A minimal, read-only view of a root agent that the Share Extension can
/// display without touching SwiftData.
struct AgentSnapshotEntry: Codable, Identifiable, Hashable {
    let id: UUID
    let name: String
}

/// Snapshot of the user's root agents, published by the main app to the App
/// Group's `UserDefaults` on agent create/rename/delete. The extension reads
/// this on each presentation to populate its picker.
struct AgentSnapshot: Codable {
    let version: Int
    let generatedAt: Date
    let agents: [AgentSnapshotEntry]

    static let currentVersion = 1

    static func load() -> AgentSnapshot? {
        guard let defaults = SharedContainer.defaults,
              let data = defaults.data(forKey: SharedContainer.agentsSnapshotKey) else {
            return nil
        }
        return try? JSONDecoder().decode(AgentSnapshot.self, from: data)
    }

    static func save(_ snapshot: AgentSnapshot) {
        guard let defaults = SharedContainer.defaults,
              let data = try? JSONEncoder().encode(snapshot) else { return }
        defaults.set(data, forKey: SharedContainer.agentsSnapshotKey)
    }

    static func clear() {
        SharedContainer.defaults?.removeObject(forKey: SharedContainer.agentsSnapshotKey)
    }
}
