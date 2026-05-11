import Foundation
import SwiftData
import Observation

/// Pre-computed row data for the agent list, avoiding direct @Model
/// relationship reads (sessions.count, activeSkills.count, cronJobs.count)
/// that would register SwiftData observation in the List's ForEach rows.
struct AgentRowData {
    let name: String
    let sessionCount: Int
    let activeSkillCount: Int
    let cronJobCount: Int
}

@Observable
@MainActor
final class AgentViewModel {
    var agents: [Agent] = []
    var rowDataCache: [UUID: AgentRowData] = [:]
    var agentToDelete: Agent?

    private var modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
        fetchAgents()
    }

    func fetchAgents() {
        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.parentAgent == nil },
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        agents = (try? modelContext.fetch(descriptor)) ?? []
        rebuildRowDataCache()
    }

    private func rebuildRowDataCache() {
        var cache: [UUID: AgentRowData] = [:]
        cache.reserveCapacity(agents.count)
        for agent in agents {
            cache[agent.id] = AgentRowData(
                name: agent.name,
                sessionCount: agent.sessions.count,
                activeSkillCount: agent.activeSkills.count,
                cronJobCount: agent.cronJobs.count
            )
        }
        rowDataCache = cache
    }

    func createAgent(name: String) -> Agent {
        let soul = DefaultPrompts.defaultSoul
        let memory = DefaultPrompts.defaultMemory
        let user = DefaultPrompts.defaultUser

        let agent = Agent(
            name: name,
            soulMarkdown: soul,
            memoryMarkdown: memory,
            userMarkdown: user
        )
        modelContext.insert(agent)
        try? modelContext.save()
        fetchAgents()
        AgentSnapshotExporter.export(context: modelContext)
        AgentDirectoryPublisher.shared.syncAll(agents: agents)
        return agent
    }

    func deleteAgent(_ agent: Agent) {
        let agentId = agent.id

        // ── 1. Update view state FIRST ──────────────────────────────
        agents = agents.filter { $0.id != agentId }

        // ── 2. Cancel, persist, cleanup ─────────────────────────────
        cancelAllActiveGenerations(for: agent)
        modelContext.delete(agent)
        try? modelContext.save()
        AgentFileManager.shared.cleanupAgentFiles(agentId: agentId)
        AgentDirectoryPublisher.shared.removeLinks(pointingTo: agentId)
        AgentDirectoryPublisher.shared.syncAll(agents: agents)
        AgentSnapshotExporter.export(context: modelContext)
        // No fetchAgents() — array is already correct from step 1.
    }

    /// Cancel active ChatViewModel generations for all sessions under this agent
    /// (including sub-agent sessions) before cascade deletion.
    private func cancelAllActiveGenerations(for agent: Agent) {
        for session in agent.sessions where session.isActive {
            ChatViewModel.cancelAndClearGeneration(for: session.id)
            session.isActive = false
            session.pendingStreamingContent = nil
        }
        for subAgent in agent.subAgents {
            cancelAllActiveGenerations(for: subAgent)
        }
    }

    func renameAgent(_ agent: Agent, to newName: String) {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        agent.name = trimmed
        updateAgent(agent)
    }

    func updateAgent(_ agent: Agent) {
        agent.updatedAt = Date()
        try? modelContext.save()
        fetchAgents()
        AgentSnapshotExporter.export(context: modelContext)
        AgentDirectoryPublisher.shared.syncAll(agents: agents)
    }
}
