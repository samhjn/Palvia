import Foundation
import SwiftData

struct SubAgentTools {
    let agent: Agent
    let modelContext: ModelContext
    let subAgentManager: SubAgentManager
    let parentSessionId: UUID?

    func createSubAgent(arguments: [String: Any]) -> String {
        guard let name = arguments["name"] as? String else {
            return "[Error] Missing required parameter: name"
        }

        let initialContext = arguments["initial_context"] as? String
        var providerIdOverride: UUID?
        if let modelIdStr = arguments["model_id"] as? String {
            providerIdOverride = UUID(uuidString: modelIdStr)
        }
        let modelNameOverride = arguments["model_name"] as? String

        let typeStr = arguments["type"] as? String ?? "temp"
        let type: SubAgentType = typeStr == "persistent" ? .persistent : .temp

        let parentSessionId = agent.sessions.last?.id

        // Validate requested model against the agent's whitelist
        var effectiveProviderOverride = providerIdOverride
        var effectiveModelOverride = modelNameOverride
        if let pid = providerIdOverride {
            let router = ModelRouter(modelContext: modelContext)
            let effectiveModel = modelNameOverride ?? router.providerById(pid)?.modelName ?? ""
            if !agent.isModelAllowed(providerId: pid, modelName: effectiveModel) {
                effectiveProviderOverride = nil
                effectiveModelOverride = nil
            }
        }

        let (subAgent, _) = subAgentManager.createSubAgent(
            name: name,
            parentAgent: agent,
            initialContext: initialContext,
            providerIdOverride: effectiveProviderOverride,
            modelNameOverride: effectiveModelOverride,
            type: type,
            parentSessionId: parentSessionId
        )

        let router = ModelRouter(modelContext: modelContext)
        let modelInfo: String
        if let primary = router.resolveProviderChainWithModels(for: subAgent).first {
            let effectiveModel = primary.modelName ?? primary.provider.modelName
            modelInfo = "\(primary.provider.name) (\(effectiveModel))"
        } else {
            modelInfo = "inherited"
        }

        let typeLabel = type == .persistent ? "persistent (long-lived)" : "temp (auto-destroy after task)"

        return """
        Sub-agent created.
        agent_id: \(subAgent.id.uuidString)
        name: \(subAgent.name)
        type: \(typeLabel)
        model: \(modelInfo)

        Next step: call message_sub_agent with agent_id="\(subAgent.id.uuidString)" and your message.
        After done, call collect_sub_agent_output with the same agent_id to retrieve results\(type == .temp ? " (temp agent auto-destroys after collection)" : "").
        """
    }

    @MainActor
    func messageSubAgent(arguments: [String: Any]) async throws -> ToolCallResult {
        guard let agentIdStr = arguments["agent_id"] as? String,
              let agentId = UUID(uuidString: agentIdStr) else {
            return ToolCallResult("[Error] Missing or invalid agent_id parameter")
        }
        guard let message = arguments["message"] as? String else {
            return ToolCallResult("[Error] Missing required parameter: message")
        }

        let forwardImages = arguments["forward_images"] as? String ?? "none"
        let imageRefs = resolveForwardImageRefs(mode: forwardImages)

        // Embed agentfile:// image refs in the message text.
        // ContextManager will auto-resolve them to actual images for the sub-agent's LLM context.
        let enrichedMessage: String
        if imageRefs.isEmpty {
            enrichedMessage = message
        } else {
            let refLines = imageRefs.enumerated().map { i, ref in
                "![forwarded image \(i + 1)](\(ref))"
            }.joined(separator: "\n")
            enrichedMessage = message + "\n\n" + refLines
        }

        do {
            let response = try await subAgentManager.sendMessage(
                to: agentId,
                content: enrichedMessage
            )
            return ToolCallResult(response.text, imageAttachments: response.imageAttachments)
        } catch is CancellationError {
            throw CancellationError()
        } catch {
            return ToolCallResult("[Error] \(error.localizedDescription)")
        }
    }

    /// Collect agentfile:// image references from the parent session.
    private func resolveForwardImageRefs(mode: String) -> [String] {
        guard mode != "none", let sessionId = parentSessionId else { return [] }

        let descriptor = FetchDescriptor<Session>(predicate: #Predicate { $0.id == sessionId })
        guard let session = try? modelContext.fetch(descriptor).first else { return [] }

        let sorted = session.sortedMessages.filter { $0.role != .system }

        switch mode {
        case "latest":
            if let msg = sorted.last(where: { $0.imageAttachmentsData != nil }),
               let data = msg.imageAttachmentsData,
               let images = try? JSONDecoder().decode([ImageAttachment].self, from: data),
               !images.isEmpty {
                return images.compactMap(\.fileReference)
            }
            return []

        case "all":
            var allRefs: [String] = []
            for msg in sorted {
                if let data = msg.imageAttachmentsData,
                   let images = try? JSONDecoder().decode([ImageAttachment].self, from: data) {
                    allRefs.append(contentsOf: images.compactMap(\.fileReference))
                }
            }
            return allRefs

        default:
            return []
        }
    }

    func collectSubAgentOutput(arguments: [String: Any]) -> ToolCallResult {
        guard let agentIdStr = arguments["agent_id"] as? String,
              let agentId = UUID(uuidString: agentIdStr) else {
            return ToolCallResult("[Error] Missing or invalid agent_id parameter")
        }

        let mode = arguments["mode"] as? String ?? "summary"
        let autoDestroy = arguments["auto_destroy"] as? Bool ?? true

        let result: SubAgentManager.SessionCollectResult
        if mode == "full" {
            result = subAgentManager.collectFullTranscript(subAgentId: agentId)
        } else {
            result = subAgentManager.collectSessionSummary(subAgentId: agentId)
        }

        if autoDestroy {
            let agentService = AgentService(modelContext: modelContext)
            if let subAgent = agentService.fetchAgent(id: agentId), subAgent.isTempSubAgent {
                subAgentManager.destroyTempAgent(agentId)
            }
        }

        return ToolCallResult(
            result.text,
            imageAttachments: result.imageAttachments.isEmpty ? nil : result.imageAttachments
        )
    }

    func listSubAgents(arguments: [String: Any]) -> String {
        let allSessions = subAgentManager.allSubAgentSessions(for: agent)

        if allSessions.isEmpty && agent.subAgents.isEmpty {
            return "(No sub-agents)"
        }

        var lines: [String] = []
        for sub in agent.subAgents {
            let typeLabel = sub.subAgentType ?? "unknown"
            let sessionInfo = allSessions.first(where: { $0.agent.id == sub.id })
            let statusLabel = sessionInfo?.isActive == true ? "🟢 active" : "⚪ idle"
            let msgCount = sessionInfo?.session.messages.count ?? 0

            lines.append("""
            - **\(sub.name)** [\(typeLabel)] \(statusLabel)
              ID: \(sub.id.uuidString)
              Messages: \(msgCount)
            """)
        }
        return lines.joined(separator: "\n")
    }

    func stopSubAgent(arguments: [String: Any]) -> String {
        guard let agentIdStr = arguments["agent_id"] as? String,
              let agentId = UUID(uuidString: agentIdStr) else {
            return "[Error] Missing or invalid agent_id parameter"
        }

        subAgentManager.forceStop(subAgentId: agentId)
        return "Sub-agent session force-stopped."
    }

    func deleteSubAgent(arguments: [String: Any]) -> String {
        guard let agentIdStr = arguments["agent_id"] as? String,
              let agentId = UUID(uuidString: agentIdStr) else {
            return "[Error] Missing or invalid agent_id parameter"
        }

        subAgentManager.deletePersistentAgent(agentId)
        return "Sub-agent deleted."
    }
}
