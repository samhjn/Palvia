import Foundation
import SwiftData

final class AgentService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func createAgent(
        name: String,
        soulMarkdown: String? = nil,
        memoryMarkdown: String? = nil,
        userMarkdown: String? = nil,
        parentAgent: Agent? = nil
    ) -> Agent {
        let agent = Agent(
            name: name,
            soulMarkdown: soulMarkdown ?? DefaultPrompts.defaultSoul,
            memoryMarkdown: memoryMarkdown ?? DefaultPrompts.defaultMemory,
            userMarkdown: userMarkdown ?? DefaultPrompts.defaultUser
        )
        modelContext.insert(agent)
        if let parentAgent {
            parentAgent.subAgents.append(agent)
        }
        try? modelContext.save()
        if parentAgent == nil {
            AgentSnapshotExporter.export(context: modelContext)
        }
        return agent
    }

    func createSubAgent(
        name: String,
        parentAgent: Agent,
        initialContext: String? = nil
    ) -> Agent {
        let subAgent = Agent(
            name: name,
            soulMarkdown: parentAgent.soulMarkdown,
            memoryMarkdown: "",
            userMarkdown: parentAgent.userMarkdown
        )
        modelContext.insert(subAgent)
        parentAgent.subAgents.append(subAgent)
        try? modelContext.save()
        return subAgent
    }

    func readConfig(agent: Agent, key: String) -> String? {
        switch key.lowercased() {
        case "soul", "soul.md":
            return agent.soulMarkdown
        case "memory", "memory.md":
            return agent.memoryMarkdown
        case "user", "user.md":
            return agent.userMarkdown
        default:
            return agent.customConfigs.first { $0.key == key }?.content
        }
    }

    func writeConfig(agent: Agent, key: String, content: String) {
        switch key.lowercased() {
        case "soul", "soul.md":
            agent.soulMarkdown = content
        case "memory", "memory.md":
            agent.memoryMarkdown = content
        case "user", "user.md":
            agent.userMarkdown = content
        default:
            if let existing = agent.customConfigs.first(where: { $0.key == key }) {
                existing.content = content
                existing.updatedAt = Date()
            } else {
                let config = AgentConfig(key: key, content: content)
                modelContext.insert(config)
                agent.customConfigs.append(config)
            }
        }
        agent.updatedAt = Date()
        try? modelContext.save()
    }

    func listConfigs(agent: Agent) -> [String] {
        var keys = ["SOUL.md", "MEMORY.md", "USER.md"]
        keys += agent.customConfigs.map { $0.key }
        return keys
    }

    func fetchAgent(id: UUID) -> Agent? {
        let descriptor = FetchDescriptor<Agent>(
            predicate: #Predicate { $0.id == id }
        )
        return try? modelContext.fetch(descriptor).first
    }
}
