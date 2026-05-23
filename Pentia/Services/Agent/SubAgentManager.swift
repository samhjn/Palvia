import Foundation
import SwiftData

/// Manages sub-agent lifecycle: creation, messaging, inflight tracking, stop, and cleanup.
final class SubAgentManager {
    static let maxNestingDepth = 5

    private let agentService: AgentService
    private let modelContext: ModelContext
    private let nestingDepth: Int

    /// Maps subAgentId → active session for that agent.
    private var activeSessions: [UUID: Session] = [:]

    /// Tracks in-flight tasks by subAgentId so they can be cancelled.
    private var inflightTasks: [UUID: Task<String, Error>] = [:]

    init(modelContext: ModelContext, nestingDepth: Int = 0) {
        self.modelContext = modelContext
        self.nestingDepth = nestingDepth
        self.agentService = AgentService(modelContext: modelContext)
    }

    // MARK: - Create

    func createSubAgent(
        name: String,
        parentAgent: Agent,
        initialContext: String?,
        providerIdOverride: UUID? = nil,
        modelNameOverride: String? = nil,
        type: SubAgentType = .temp,
        parentSessionId: UUID? = nil
    ) -> (agent: Agent, session: Session) {
        let subAgent = agentService.createSubAgent(
            name: name,
            parentAgent: parentAgent,
            initialContext: initialContext
        )
        subAgent.subAgentType = type.rawValue

        if let overrideId = providerIdOverride {
            subAgent.primaryProviderId = overrideId
            subAgent.primaryModelNameOverride = modelNameOverride
        } else if let subDefault = parentAgent.subAgentProviderId {
            subAgent.primaryProviderId = subDefault
            subAgent.primaryModelNameOverride = parentAgent.subAgentModelNameOverride
        } else {
            // Resolve the parent's actual primary provider (including global default fallback)
            // so the sub-agent inherits the effective model, not just the raw field.
            let router = ModelRouter(modelContext: modelContext)
            let resolvedChain = router.resolveProviderChainWithModels(for: parentAgent)
            if let primary = resolvedChain.first {
                subAgent.primaryProviderId = primary.provider.id
                subAgent.primaryModelNameOverride = primary.modelName
            } else {
                subAgent.primaryProviderId = parentAgent.primaryProviderId
                subAgent.primaryModelNameOverride = parentAgent.primaryModelNameOverride
            }
        }
        // Copy fallback chain: resolve parent's effective chain, skip the first (primary).
        let router = ModelRouter(modelContext: modelContext)
        let fullChain = router.resolveProviderChainWithModels(for: parentAgent)
        if fullChain.count > 1 {
            let fallbacks = Array(fullChain.dropFirst())
            subAgent.fallbackProviderIds = fallbacks.map { $0.provider.id }
            subAgent.fallbackModelNames = fallbacks.map { $0.modelName ?? "" }
        } else {
            subAgent.fallbackProviderIds = parentAgent.fallbackProviderIds
            subAgent.fallbackModelNamesRaw = parentAgent.fallbackModelNamesRaw
        }

        // Inherit model whitelist from parent
        subAgent.allowedModelIdsRaw = parentAgent.allowedModelIdsRaw

        try? modelContext.save()

        let session = Session(title: "Sub: \(name)")
        session.parentSessionIdRaw = parentSessionId?.uuidString
        modelContext.insert(session)
        session.agent = subAgent
        try? modelContext.save()

        activeSessions[subAgent.id] = session

        return (subAgent, session)
    }

    // MARK: - Message (with tool call loop)

    struct SubAgentResponse {
        let text: String
        let imageAttachments: [ImageAttachment]?
    }

    @MainActor
    func sendMessage(
        to subAgentId: UUID,
        content: String,
        imageAttachments: [ImageAttachment]? = nil
    ) async throws -> SubAgentResponse {
        guard nestingDepth < Self.maxNestingDepth else {
            throw SubAgentError.maxDepthExceeded(nestingDepth)
        }

        guard let subAgent = agentService.fetchAgent(id: subAgentId),
              let session = activeSessions[subAgentId] ?? subAgent.sessions.last else {
            throw SubAgentError.agentNotFound
        }

        let userMsg = Message(role: .user, content: content)
        if let images = imageAttachments, !images.isEmpty,
           let data = try? JSONEncoder().encode(images) {
            userMsg.imageAttachmentsData = data
            userMsg.recalculateTokenEstimate()
        }
        modelContext.insert(userMsg)
        session.messages.append(userMsg)
        session.isActive = true
        try? modelContext.save()

        defer {
            session.isActive = false
            inflightTasks.removeValue(forKey: subAgentId)
            try? modelContext.save()
        }

        guard !Task.isCancelled else {
            throw CancellationError()
        }

        let response = try await runAgentLoop(subAgent: subAgent, session: session)

        if subAgent.isTempSubAgent {
            scheduleCleanup(subAgent: subAgent)
        }

        return response
    }

    /// Full agent loop: send, process tool calls, repeat until text response.
    @MainActor
    private func runAgentLoop(
        subAgent: Agent,
        session: Session,
        maxRounds: Int = 10
    ) async throws -> SubAgentResponse {
        let router = ModelRouter(modelContext: modelContext)
        let promptBuilder = PromptBuilder()
        let contextManager = ContextManager()
        let fnRouter = FunctionCallRouter(agent: subAgent, modelContext: modelContext, sessionId: session.id, nestingDepth: nestingDepth + 1)

        let caps = router.primaryModelCapabilities(for: subAgent)

        for _ in 0..<maxRounds {
            guard !Task.isCancelled else { throw CancellationError() }

            let systemPrompt = promptBuilder.buildSystemPrompt(for: subAgent, isSubAgent: true)
            var messages = contextManager.buildContextWindow(session: session, systemPrompt: systemPrompt)
            ChatViewModel.stripUnsupportedModalities(from: &messages, capabilities: caps)

            let (response, _) = try await router.chatCompletionWithFailover(
                agent: subAgent,
                messages: messages,
                tools: ToolDefinitions.tools(for: subAgent)
            )

            guard !Task.isCancelled else { throw CancellationError() }

            guard let choice = response.choices.first, let msg = choice.message else {
                throw SubAgentError.emptyResponse
            }

            if let toolCalls = msg.toolCalls, !toolCalls.isEmpty {
                let assistantMsg = Message(
                    role: .assistant,
                    content: msg.content,
                    toolCallsData: try? JSONEncoder().encode(toolCalls)
                )
                let rootAgentId = AgentFileManager.shared.resolveAgentId(for: subAgent)
                assistantMsg.extractAndStoreInlineImages(agentId: rootAgentId)
                modelContext.insert(assistantMsg)
                session.messages.append(assistantMsg)

                for tc in toolCalls {
                    guard !Task.isCancelled else { throw CancellationError() }
                    let result = await fnRouter.execute(toolCall: tc)
                    let toolMsg = Message(
                        role: .tool,
                        content: result.text,
                        toolCallId: tc.id,
                        name: tc.function.name
                    )
                    if let images = result.imageAttachments,
                       let data = try? JSONEncoder().encode(images) {
                        toolMsg.imageAttachmentsData = data
                        toolMsg.recalculateTokenEstimate()
                    }
                    modelContext.insert(toolMsg)
                    session.messages.append(toolMsg)
                }
                try? modelContext.save()
                continue
            }

            if let content = msg.content, !content.isEmpty {
                let assistantMsg = Message(role: .assistant, content: content)
                let rootAgentId = AgentFileManager.shared.resolveAgentId(for: subAgent)
                assistantMsg.extractAndStoreInlineImages(agentId: rootAgentId)
                modelContext.insert(assistantMsg)
                session.messages.append(assistantMsg)
                session.updatedAt = Date()
                try? modelContext.save()

                let imageAttachments: [ImageAttachment]? = assistantMsg.imageAttachmentsData.flatMap {
                    try? JSONDecoder().decode([ImageAttachment].self, from: $0)
                }
                return SubAgentResponse(
                    text: assistantMsg.content ?? content,
                    imageAttachments: imageAttachments
                )
            }

            break
        }

        throw SubAgentError.emptyResponse
    }

    // MARK: - Inflight Management

    /// Returns all inflight (active) sub-agent sessions for a parent agent.
    func inflightSubAgentSessions(for parentAgent: Agent) -> [(agent: Agent, session: Session)] {
        parentAgent.subAgents.compactMap { sub in
            guard let session = activeSessions[sub.id] ?? sub.sessions.last,
                  session.isActive else { return nil }
            return (sub, session)
        }
    }

    /// Returns all sub-agent sessions (active or not) for a parent agent.
    func allSubAgentSessions(for parentAgent: Agent) -> [(agent: Agent, session: Session, isActive: Bool)] {
        parentAgent.subAgents.compactMap { sub in
            guard let session = activeSessions[sub.id] ?? sub.sessions.last else { return nil }
            return (sub, session, session.isActive)
        }
    }

    /// Force-stop an inflight sub-agent session.
    func forceStop(subAgentId: UUID) {
        inflightTasks[subAgentId]?.cancel()
        inflightTasks[subAgentId] = nil

        if let session = activeSessions[subAgentId] {
            session.isActive = false
            try? modelContext.save()
        }
    }

    // MARK: - Content Relay

    struct SessionCollectResult {
        let text: String
        let imageAttachments: [ImageAttachment]
    }

    /// Generates a summary of the sub-agent session's output for the parent session.
    func collectSessionSummary(subAgentId: UUID) -> SessionCollectResult {
        guard let subAgent = agentService.fetchAgent(id: subAgentId),
              let session = activeSessions[subAgentId] ?? subAgent.sessions.last else {
            return SessionCollectResult(text: "[Error] Sub-agent session not found.", imageAttachments: [])
        }

        let assistantMsgs = session.sortedMessages.filter { $0.role == .assistant }

        if assistantMsgs.isEmpty {
            return SessionCollectResult(text: "(No output from sub-agent)", imageAttachments: [])
        }

        var textParts: [String] = []
        var allImages: [ImageAttachment] = []
        for msg in assistantMsgs {
            var segment = msg.content ?? ""
            if let imgData = msg.imageAttachmentsData,
               let images = try? JSONDecoder().decode([ImageAttachment].self, from: imgData),
               !images.isEmpty {
                segment += "\n[\(images.count) image(s) attached]"
                allImages.append(contentsOf: images)
            }
            if !segment.isEmpty { textParts.append(segment) }
        }

        let text = textParts.isEmpty ? "(No output from sub-agent)" : textParts.joined(separator: "\n\n---\n\n")
        return SessionCollectResult(text: text, imageAttachments: allImages)
    }

    /// Returns the full transcript of a sub-agent session for injection into parent context.
    func collectFullTranscript(subAgentId: UUID) -> SessionCollectResult {
        guard let subAgent = agentService.fetchAgent(id: subAgentId),
              let session = activeSessions[subAgentId] ?? subAgent.sessions.last else {
            return SessionCollectResult(text: "[Error] Sub-agent session not found.", imageAttachments: [])
        }

        var allImages: [ImageAttachment] = []
        let lines = session.sortedMessages.compactMap { msg -> String? in
            let role = msg.role.rawValue.capitalized
            var text = msg.content ?? ""
            if let imgData = msg.imageAttachmentsData,
               let images = try? JSONDecoder().decode([ImageAttachment].self, from: imgData),
               !images.isEmpty {
                text += " [+\(images.count) image(s)]"
                if msg.role == .assistant {
                    allImages.append(contentsOf: images)
                }
            }
            guard !text.isEmpty else { return nil }
            return "[\(role)] \(text)"
        }

        return SessionCollectResult(
            text: lines.joined(separator: "\n\n"),
            imageAttachments: allImages
        )
    }

    // MARK: - Cleanup

    /// Schedule cleanup of a temp sub-agent (delete agent + sessions).
    private func scheduleCleanup(subAgent: Agent) {
        guard subAgent.isTempSubAgent else { return }
        // Don't delete immediately — the caller may still need the response.
        // The caller should invoke `destroyTempAgent` when ready.
    }

    /// Destroy a temp sub-agent and all its data.
    func destroyTempAgent(_ subAgentId: UUID) {
        guard let subAgent = agentService.fetchAgent(id: subAgentId),
              subAgent.isTempSubAgent else { return }
        activeSessions.removeValue(forKey: subAgentId)
        inflightTasks.removeValue(forKey: subAgentId)
        modelContext.delete(subAgent)
        try? modelContext.save()
    }

    /// Delete a persistent sub-agent (by main agent or user).
    func deletePersistentAgent(_ subAgentId: UUID) {
        guard let subAgent = agentService.fetchAgent(id: subAgentId) else { return }
        forceStop(subAgentId: subAgentId)
        activeSessions.removeValue(forKey: subAgentId)
        inflightTasks.removeValue(forKey: subAgentId)
        AgentFileManager.shared.cleanupAgentFiles(agentId: subAgentId)
        modelContext.delete(subAgent)
        try? modelContext.save()
    }
}

enum SubAgentType: String {
    case temp
    case persistent
}

enum SubAgentError: LocalizedError {
    case agentNotFound
    case emptyResponse
    case sessionLocked(String)
    case maxDepthExceeded(Int)

    var errorDescription: String? {
        switch self {
        case .agentNotFound: return "Sub-agent not found"
        case .emptyResponse: return "Sub-agent returned an empty response"
        case .sessionLocked(let reason): return "Session locked: \(reason)"
        case .maxDepthExceeded(let depth): return "Sub-agent nesting depth limit exceeded (\(depth)/\(SubAgentManager.maxNestingDepth)). Simplify the task or reduce sub-agent delegation."
        }
    }
}
