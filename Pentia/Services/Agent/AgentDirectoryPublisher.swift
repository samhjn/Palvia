import Foundation
import os.log

private let publisherLog = OSLog(subsystem: "com.iclaw.files", category: "agent-directory-publisher")

/// Maintains a human-readable view of each agent's file folder at
/// `<Documents>/Agents/<AgentName>/`, implemented as a symlink to the canonical
/// `<Documents>/AgentFiles/<UUID>/`.
///
/// This is what the user sees in the iOS Files app. The canonical storage at
/// `AgentFiles/<UUID>/` is untouched; only symlinks are created and removed here.
///
/// Name collisions across agents are disambiguated by appending `-<shortUUID>`.
///
/// - Important: Callers must invoke from `@MainActor` — `syncAll(agents:)` reads
///   SwiftData `@Relationship` properties (`parentAgent`) and `agent.name`.
final class AgentDirectoryPublisher {

    static let shared = AgentDirectoryPublisher()
    private init() {}

    private let fm = FileManager.default

    /// Root directory visible in the iOS Files app: `<Documents>/Agents/`.
    var publishedRoot: URL {
        fm.urls(for: .documentDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Agents", isDirectory: true)
    }

    /// Rebuild the symlinks under `publishedRoot` so they match the current set of
    /// top-level agents. Sub-agents are intentionally skipped because they share
    /// the root agent's folder.
    func syncAll(agents: [Agent]) {
        do {
            try fm.createDirectory(at: publishedRoot, withIntermediateDirectories: true)
        } catch {
            os_log(.error, log: publisherLog, "Failed to create published root: %{public}@", error.localizedDescription)
            return
        }

        let rootAgents = agents.filter { $0.parentAgent == nil }

        var assignments: [(url: URL, target: URL, agentId: UUID)] = []
        var usedNames = Set<String>()

        for agent in rootAgents {
            let base = Self.sanitize(agent.name)
            var candidate = base
            if usedNames.contains(candidate) {
                let shortId = String(agent.id.uuidString.prefix(8))
                candidate = "\(base)-\(shortId)"
            }
            usedNames.insert(candidate)

            let linkURL = publishedRoot.appendingPathComponent(candidate, isDirectory: true)
            let targetURL = AgentFileManager.shared.agentDirectory(for: agent.id)
            assignments.append((linkURL, targetURL, agent.id))
        }

        // Reconcile existing entries.
        let desiredLinkPaths = Set(assignments.map { $0.url.path })

        if let existing = try? fm.contentsOfDirectory(at: publishedRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) {
            for url in existing where !desiredLinkPaths.contains(url.path) {
                try? fm.removeItem(at: url)
            }
        }

        for (linkURL, targetURL, agentId) in assignments {
            // Ensure canonical target exists so the symlink actually resolves.
            if !fm.fileExists(atPath: targetURL.path) {
                try? fm.createDirectory(at: targetURL, withIntermediateDirectories: true)
            }

            if let existingTarget = try? fm.destinationOfSymbolicLink(atPath: linkURL.path) {
                if existingTarget == targetURL.path { continue }
                try? fm.removeItem(at: linkURL)
            } else if fm.fileExists(atPath: linkURL.path) {
                // A non-symlink entry collides — remove and re-create.
                try? fm.removeItem(at: linkURL)
            }

            do {
                try fm.createSymbolicLink(at: linkURL, withDestinationURL: targetURL)
                os_log(.info, log: publisherLog, "Linked %{public}@ -> %{public}@", linkURL.lastPathComponent, agentId.uuidString)
            } catch {
                os_log(.error, log: publisherLog, "Failed to link %{public}@: %{public}@", linkURL.lastPathComponent, error.localizedDescription)
            }
        }
    }

    /// Clean every symlink for a deleted agent UUID (called from agent deletion flows).
    func removeLinks(pointingTo agentId: UUID) {
        guard let existing = try? fm.contentsOfDirectory(at: publishedRoot, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]) else { return }
        let canonical = AgentFileManager.shared.agentDirectory(for: agentId).path
        for url in existing {
            if let target = try? fm.destinationOfSymbolicLink(atPath: url.path), target == canonical {
                try? fm.removeItem(at: url)
            }
        }
    }

    /// Normalize `raw` into a filesystem-safe component.
    static func sanitize(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        if trimmed.isEmpty { return "Agent" }
        var out = ""
        for scalar in trimmed.unicodeScalars {
            if scalar == "/" || scalar == "\\" || scalar == ":" || scalar == "\0" {
                out.append("_")
            } else if scalar.value < 0x20 {
                out.append("_")
            } else {
                out.append(Character(scalar))
            }
        }
        // Disallow reserved single/double-dot names.
        if out == "." || out == ".." { return "Agent" }
        if out.count > 120 { out = String(out.prefix(120)) }
        return out
    }
}
