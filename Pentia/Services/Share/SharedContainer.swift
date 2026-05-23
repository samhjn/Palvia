import Foundation

/// Central App Group constants and helpers used by both the main app and the
/// Share Extension. The App Group is the only channel for exchanging data
/// between the two processes.
enum SharedContainer {
    static let appGroupId = "group.com.iclaw.app"

    /// Key under which the main app publishes the read-only list of root agents
    /// that the Share Extension shows in its picker.
    static let agentsSnapshotKey = "AgentsSnapshot.v1"

    /// The root of the App Group's shared file container.
    static var containerURL: URL? {
        FileManager.default.containerURL(forSecurityApplicationGroupIdentifier: appGroupId)
    }

    /// Directory where the Share Extension stages incoming files until the
    /// main app picks them up and moves them into the target agent's folder.
    static var stagingDirectory: URL? {
        containerURL?.appendingPathComponent("ShareStaging", isDirectory: true)
    }

    /// Directory for a specific handoff, named by `handoffId`.
    static func stagingDirectory(handoffId: UUID) -> URL? {
        stagingDirectory?.appendingPathComponent(handoffId.uuidString, isDirectory: true)
    }

    /// Shared `UserDefaults` scoped to the App Group.
    static var defaults: UserDefaults? {
        UserDefaults(suiteName: appGroupId)
    }

    /// Create the staging directory if it doesn't exist and return its URL.
    @discardableResult
    static func ensureStagingDirectory() -> URL? {
        guard let dir = stagingDirectory else { return nil }
        if !FileManager.default.fileExists(atPath: dir.path) {
            try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        }
        return dir
    }
}
