import Foundation
import SwiftData

final class SessionService {
    private let modelContext: ModelContext

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    func createSession(title: String, agent: Agent) -> Session {
        let session = Session(title: title)
        modelContext.insert(session)
        session.agent = agent
        try? modelContext.save()
        return session
    }

    func updateTitle(_ session: Session, title: String) {
        session.title = title
        session.updatedAt = Date()
        try? modelContext.save()
    }

    func archiveSession(_ session: Session) {
        session.isArchived = true
        session.updatedAt = Date()
        try? modelContext.save()
    }

    func deleteSession(_ session: Session) {
        SessionVectorStore(modelContext: modelContext).deleteEmbedding(for: session.id)
        modelContext.delete(session)
        try? modelContext.save()
    }

    func fetchSessions(for agent: Agent, includeArchived: Bool = false) -> [Session] {
        let agentId = agent.id
        var descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        if !includeArchived {
            descriptor.predicate = #Predicate {
                $0.agent?.id == agentId && $0.isArchived == false
            }
        } else {
            descriptor.predicate = #Predicate {
                $0.agent?.id == agentId
            }
        }
        return (try? modelContext.fetch(descriptor)) ?? []
    }

    func addMessage(to session: Session, role: MessageRole, content: String?, toolCallsData: Data? = nil, toolCallId: String? = nil, name: String? = nil) -> Message {
        let tokenEstimate = estimateTokens(content ?? "")
        let message = Message(
            role: role,
            content: content,
            toolCallsData: toolCallsData,
            toolCallId: toolCallId,
            name: name,
            tokenEstimate: tokenEstimate
        )
        modelContext.insert(message)
        session.messages.append(message)
        session.updatedAt = Date()
        try? modelContext.save()
        return message
    }

    // MARK: - Session Search & RAG

    /// Search sessions by keyword across titles and message content.
    /// Returns sessions belonging to the given agent (excluding the current session if provided).
    func searchSessions(
        query: String,
        agent: Agent,
        excludeSessionId: UUID? = nil,
        limit: Int = 10
    ) -> [Session] {
        let agentId = agent.id
        var descriptor = FetchDescriptor<Session>(
            sortBy: [SortDescriptor(\.updatedAt, order: .reverse)]
        )
        descriptor.predicate = #Predicate {
            $0.agent?.id == agentId && $0.isArchived == false
        }

        guard let allSessions = try? modelContext.fetch(descriptor) else { return [] }

        let keywords = Self.extractSearchKeywords(from: query)
        guard !keywords.isEmpty else { return [] }

        var scored: [(session: Session, score: Int)] = []

        for session in allSessions {
            if session.id == excludeSessionId { continue }

            var score = 0
            let titleLower = session.title.lowercased()

            for keyword in keywords {
                if titleLower.contains(keyword) {
                    score += 3
                }
            }

            // Check compressed context (cheaper than scanning all messages)
            if let compressed = session.compressedContext?.lowercased() {
                for keyword in keywords {
                    if compressed.contains(keyword) {
                        score += 2
                    }
                }
            }

            // Scan recent messages (last 20) for keyword matches
            let recentMessages = session.sortedMessages.suffix(20)
            for msg in recentMessages {
                guard let content = msg.content?.lowercased() else { continue }
                for keyword in keywords {
                    if content.contains(keyword) {
                        score += 1
                        break // one hit per message is enough
                    }
                }
            }

            if score > 0 {
                scored.append((session, score))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map(\.session)
    }

    /// Fetch context from a specific session for RAG recall with paging support.
    /// - `limit`: number of messages per page (default 3)
    /// - `offset`: skip this many messages from the end (0 = most recent page)
    func fetchSessionContext(sessionId: UUID, limit: Int = 3, offset: Int = 0) -> SessionContextSnapshot? {
        var descriptor = FetchDescriptor<Session>()
        descriptor.predicate = #Predicate { $0.id == sessionId }
        descriptor.fetchLimit = 1

        guard let session = (try? modelContext.fetch(descriptor))?.first else { return nil }

        let sorted = session.sortedMessages.filter { $0.role != .system }
        let total = sorted.count

        // Page from the end: offset=0 → last `limit` messages
        let endIdx = max(total - offset, 0)
        let startIdx = max(endIdx - limit, 0)
        let page = sorted[startIdx..<endIdx]

        var transcript: [SessionContextSnapshot.MessageEntry] = []
        for msg in page {
            transcript.append(.init(
                role: msg.role.rawValue,
                content: msg.content ?? "",
                toolName: msg.name,
                timestamp: msg.timestamp
            ))
        }

        return SessionContextSnapshot(
            sessionId: session.id,
            title: session.title,
            createdAt: session.createdAt,
            updatedAt: session.updatedAt,
            compressedContext: session.compressedContext,
            recentMessages: transcript,
            totalMessages: total,
            offset: offset,
            hasMore: startIdx > 0
        )
    }

    /// Find sessions related to the current conversation (for auto-inject).
    /// Uses keywords from the latest user messages to find topically related sessions.
    func findRelatedSessions(
        for session: Session,
        maxResults: Int = 5
    ) -> [(id: UUID, title: String, updatedAt: Date)] {
        guard let agent = session.agent else { return [] }

        // Extract keywords from session title + recent user messages
        var queryParts: [String] = []
        if session.title != L10n.Chat.newChat {
            queryParts.append(session.title)
        }
        let recentUserMessages = session.sortedMessages
            .filter { $0.role == .user }
            .suffix(3)
        for msg in recentUserMessages {
            if let content = msg.content {
                queryParts.append(String(content.prefix(200)))
            }
        }

        let query = queryParts.joined(separator: " ")
        guard !query.isEmpty else { return [] }

        let results = searchSessions(
            query: query,
            agent: agent,
            excludeSessionId: session.id,
            limit: maxResults
        )

        return results.map { (id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    // MARK: - Hybrid Search (Vector + Keyword Fallback)

    /// Hybrid search: try local vector similarity first, fall back to keyword search.
    func searchSessionsHybrid(
        query: String,
        agent: Agent,
        excludeSessionId: UUID? = nil,
        limit: Int = 10
    ) -> [Session] {
        let vectorStore = SessionVectorStore(modelContext: modelContext)
        let vectorResults = vectorStore.search(
            query: query,
            agent: agent,
            excludeSessionId: excludeSessionId,
            limit: limit
        )
        if !vectorResults.isEmpty {
            return lookupSessionsByIds(vectorResults.map(\.sessionId))
        }
        return searchSessions(query: query, agent: agent, excludeSessionId: excludeSessionId, limit: limit)
    }

    /// Find related sessions using vector similarity when available, keyword fallback.
    func findRelatedSessionsHybrid(
        for session: Session,
        maxResults: Int = 5
    ) -> [(id: UUID, title: String, updatedAt: Date)] {
        guard let agent = session.agent else { return [] }

        var queryParts: [String] = []
        if session.title != L10n.Chat.newChat {
            queryParts.append(session.title)
        }
        let recentUserMessages = session.sortedMessages
            .filter { $0.role == .user }
            .suffix(3)
        for msg in recentUserMessages {
            if let content = msg.content {
                queryParts.append(String(content.prefix(200)))
            }
        }
        let query = queryParts.joined(separator: " ")
        guard !query.isEmpty else { return [] }

        let results = searchSessionsHybrid(
            query: query,
            agent: agent,
            excludeSessionId: session.id,
            limit: maxResults
        )
        return results.map { (id: $0.id, title: $0.title, updatedAt: $0.updatedAt) }
    }

    private func lookupSessionsByIds(_ ids: [UUID]) -> [Session] {
        var results: [Session] = []
        for id in ids {
            var descriptor = FetchDescriptor<Session>()
            descriptor.predicate = #Predicate { $0.id == id }
            descriptor.fetchLimit = 1
            if let session = (try? modelContext.fetch(descriptor))?.first {
                results.append(session)
            }
        }
        return results
    }

    // MARK: - Keyword Extraction

    /// Extract meaningful keywords from a query string.
    static func extractSearchKeywords(from text: String) -> [String] {
        let stopWords: Set<String> = [
            "the", "a", "an", "is", "are", "was", "were", "be", "been", "being",
            "have", "has", "had", "do", "does", "did", "will", "would", "could",
            "should", "may", "might", "shall", "can", "need", "must",
            "i", "me", "my", "we", "our", "you", "your", "he", "she", "it",
            "they", "them", "this", "that", "these", "those", "what", "which",
            "who", "whom", "how", "when", "where", "why",
            "and", "or", "but", "if", "then", "so", "for", "of", "in", "on",
            "at", "to", "from", "with", "about", "into", "not", "no", "just",
            "also", "very", "too", "some", "any", "all", "each", "every",
            "了", "的", "是", "在", "我", "有", "和", "就", "不", "人", "都",
            "一", "一个", "上", "也", "很", "到", "说", "要", "去", "你",
            "会", "着", "没有", "看", "好", "自己", "这",
        ]

        let words = text.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.union(.init(charactersIn: "\u{4E00}-\u{9FFF}")).inverted)
            .filter { $0.count >= 2 && !stopWords.contains($0) }

        // Deduplicate while preserving order
        var seen = Set<String>()
        return words.filter { seen.insert($0).inserted }
    }

    private func estimateTokens(_ text: String) -> Int {
        max(1, text.count / 4)
    }
}

// MARK: - Session RAG Types

struct SessionContextSnapshot {
    let sessionId: UUID
    let title: String
    let createdAt: Date
    let updatedAt: Date
    let compressedContext: String?
    let recentMessages: [MessageEntry]
    let totalMessages: Int
    let offset: Int
    let hasMore: Bool

    struct MessageEntry {
        let role: String
        let content: String
        let toolName: String?
        let timestamp: Date
    }

    func formatted(maxTokens: Int = 4000) -> String {
        var parts: [String] = []
        let df = DateFormatter()
        df.dateStyle = .medium
        df.timeStyle = .short

        parts.append("# Session: \(title)")
        parts.append("ID: \(sessionId.uuidString)")
        parts.append("Created: \(df.string(from: createdAt))")
        parts.append("Updated: \(df.string(from: updatedAt))")
        parts.append("Total messages: \(totalMessages)")

        if let compressed = compressedContext, !compressed.isEmpty {
            parts.append("\n## Compressed History\n\(compressed)")
        }

        if !recentMessages.isEmpty {
            parts.append("\n## Messages (offset=\(offset), showing \(recentMessages.count) of \(totalMessages))")
            var tokenEstimate = parts.joined(separator: "\n").count / 4

            for msg in recentMessages {
                let roleName = msg.toolName.map { "\(msg.role) (\($0))" } ?? msg.role
                let entry = "[\(roleName)] \(msg.content)"
                let entryTokens = entry.count / 4

                if tokenEstimate + entryTokens > maxTokens {
                    parts.append("... (token limit reached)")
                    break
                }

                parts.append(entry)
                tokenEstimate += entryTokens
            }
        }

        if hasMore {
            parts.append("\n> Use `recall_session` with `offset: \(offset + recentMessages.count)` to load earlier messages.")
        }

        return parts.joined(separator: "\n")
    }
}
