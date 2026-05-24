import Foundation
import SwiftData

struct SessionRAGTools {
    let agent: Agent
    let modelContext: ModelContext
    let currentSessionId: UUID?

    private var sessionService: SessionService {
        SessionService(modelContext: modelContext)
    }

    // MARK: - search_sessions

    func searchSessions(arguments: [String: Any]) -> String {
        guard let query = arguments["query"] as? String, !query.isEmpty else {
            return toolError("Missing required parameter: query")
        }

        let limit = min(max((arguments["limit"] as? Int) ?? 10, 1), 20)

        let results = sessionService.searchSessionsHybrid(
            query: query,
            agent: agent,
            excludeSessionId: currentSessionId,
            limit: limit
        )

        guard !results.isEmpty else {
            return "No sessions found matching '\(query)'."
        }

        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        var output = "Found \(results.count) session(s):\n"
        for session in results {
            let msgCount = session.messages.count
            let hasCompressed = session.compressedContext != nil && !(session.compressedContext?.isEmpty ?? true)
            let isCurrent = session.id == currentSessionId
            output += "\n- **\(session.title)**\(isCurrent ? " (current session)" : "")"
            output += "\n  ID: `\(session.id.uuidString)`"
            output += "\n  Updated: \(df.string(from: session.updatedAt))"
            output += "\n  Messages: \(msgCount)\(hasCompressed ? " (has compressed history)" : "")"
        }
        output += "\n\nUse `recall_session` with a session ID to retrieve its context."
        return output
    }

    // MARK: - recall_session

    func recallSession(arguments: [String: Any]) -> String {
        guard let sessionIdStr = arguments["session_id"] as? String,
              let sessionId = UUID(uuidString: sessionIdStr) else {
            return toolError("Missing or invalid parameter: session_id (must be a valid UUID)")
        }

        // Verify ownership before fetching context
        let agentId = agent.id
        var descriptor = FetchDescriptor<Session>()
        descriptor.predicate = #Predicate { $0.id == sessionId }
        descriptor.fetchLimit = 1
        guard let session = (try? modelContext.fetch(descriptor))?.first else {
            return toolError("Session not found: \(sessionIdStr)")
        }
        if session.agent?.id != agentId {
            return toolError("Session not found: \(sessionIdStr)")
        }

        // Paging: limit (page size, default 3) + offset (skip from end, default 0)
        let limit = min((arguments["max_messages"] as? Int) ?? 3, 50)
        let offset = max((arguments["offset"] as? Int) ?? 0, 0)

        guard let snapshot = sessionService.fetchSessionContext(
            sessionId: sessionId,
            limit: limit,
            offset: offset
        ) else {
            return toolError("Session not found: \(sessionIdStr)")
        }

        return snapshot.formatted(maxTokens: 4000)
    }

    private func toolError(_ message: String) -> String {
        "[Error] \(message)"
    }
}
