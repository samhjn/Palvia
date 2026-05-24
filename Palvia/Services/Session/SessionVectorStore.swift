import Foundation
import SwiftData
import CryptoKit

final class SessionVectorStore {
    private let modelContext: ModelContext
    private let localService = LocalEmbeddingService()

    init(modelContext: ModelContext) {
        self.modelContext = modelContext
    }

    // MARK: - Embedding Management

    /// Compute and store (or update) the embedding for a session using on-device NLEmbedding.
    func updateEmbedding(for session: Session) {
        let text = Self.buildEmbeddingText(for: session)
        guard !text.isEmpty else { return }

        let hash = Self.sha256(text)

        // Skip if embedding is already up-to-date
        if let existing = fetchEmbedding(for: session.id),
           existing.sourceTextHash == hash {
            return
        }

        if let vector = localService.embed(text: text) {
            upsertEmbedding(sessionId: session.id, vector: vector, modelName: "NLEmbedding.local", sourceTextHash: hash)
        }
    }

    /// Delete the embedding for a session.
    func deleteEmbedding(for sessionId: UUID) {
        let idStr = sessionId.uuidString
        var descriptor = FetchDescriptor<SessionEmbedding>()
        descriptor.predicate = #Predicate { $0.sessionIdRaw == idStr }
        if let existing = (try? modelContext.fetch(descriptor))?.first {
            modelContext.delete(existing)
            try? modelContext.save()
        }
    }

    // MARK: - Backfill

    /// Returns sessions that still need an embedding vector computed.
    func sessionsNeedingEmbedding() -> [Session] {
        let allSessions: [Session]
        do {
            var descriptor = FetchDescriptor<Session>()
            descriptor.predicate = #Predicate { $0.isArchived == false }
            allSessions = try modelContext.fetch(descriptor)
        } catch { return [] }

        let existingIds = Set(fetchAllEmbeddings().map(\.sessionIdRaw))

        return allSessions.filter { session in
            !existingIds.contains(session.id.uuidString)
                && session.messages.count >= 2
                && !Self.buildEmbeddingText(for: session).isEmpty
        }
    }

    /// Compute embeddings for all sessions that don't have one yet.
    /// Designed to be called on app launch as a background task.
    func backfillMissingEmbeddings() {
        let pending = sessionsNeedingEmbedding()
        var count = 0
        for session in pending {
            updateEmbedding(for: session)
            count += 1
        }

        #if DEBUG
        if count > 0 {
            print("[VectorStore] Backfilled \(count) session embedding(s)")
        }
        #endif
    }

    // MARK: - Similarity Search

    /// Find the most similar sessions to the query text.
    /// Uses local embedding for the query vector; matches against stored embeddings.
    func search(
        query: String,
        agent: Agent,
        excludeSessionId: UUID? = nil,
        limit: Int = 10
    ) -> [(sessionId: UUID, score: Float)] {
        guard let queryVec = localService.embed(text: query) else { return [] }

        let agentSessionIds = Set(
            agent.sessions.filter { !$0.isArchived }.map(\.id.uuidString)
        )
        let allEmbeddings = fetchAllEmbeddings()
        let relevant = allEmbeddings.filter {
            agentSessionIds.contains($0.sessionIdRaw)
                && $0.sessionId != excludeSessionId
        }

        guard !relevant.isEmpty else { return [] }

        var scored: [(sessionId: UUID, score: Float)] = []

        for emb in relevant {
            let sim = Self.cosineSimilarity(queryVec, emb.vector)
            if sim > 0.3 {
                scored.append((emb.sessionId, sim))
            }
        }

        return scored
            .sorted { $0.score > $1.score }
            .prefix(limit)
            .map { $0 }
    }

    // MARK: - Text Preparation

    /// Build the text to embed for a session: title + compressed context or recent messages.
    static func buildEmbeddingText(for session: Session) -> String {
        var parts: [String] = []
        if !session.title.isEmpty {
            parts.append(session.title)
        }
        if let compressed = session.compressedContext, !compressed.isEmpty {
            parts.append(compressed)
        } else {
            let recent = session.sortedMessages
                .filter { $0.role == .user || $0.role == .assistant }
                .suffix(10)
                .compactMap(\.content)
                .joined(separator: "\n")
            if !recent.isEmpty {
                parts.append(String(recent.prefix(2000)))
            }
        }
        return String(parts.joined(separator: "\n\n").prefix(6000))
    }

    // MARK: - Vector Math

    static func cosineSimilarity(_ a: [Float], _ b: [Float]) -> Float {
        guard a.count == b.count, !a.isEmpty else { return 0 }
        var dot: Float = 0, normA: Float = 0, normB: Float = 0
        for i in 0..<a.count {
            dot += a[i] * b[i]
            normA += a[i] * a[i]
            normB += b[i] * b[i]
        }
        let denom = sqrt(normA) * sqrt(normB)
        return denom > 0 ? dot / denom : 0
    }

    static func sha256(_ text: String) -> String {
        let hash = SHA256.hash(data: Data(text.utf8))
        return hash.map { String(format: "%02x", $0) }.joined()
    }

    // MARK: - SwiftData Helpers

    private func fetchEmbedding(for sessionId: UUID) -> SessionEmbedding? {
        let idStr = sessionId.uuidString
        var descriptor = FetchDescriptor<SessionEmbedding>()
        descriptor.predicate = #Predicate { $0.sessionIdRaw == idStr }
        descriptor.fetchLimit = 1
        return (try? modelContext.fetch(descriptor))?.first
    }

    private func fetchAllEmbeddings() -> [SessionEmbedding] {
        (try? modelContext.fetch(FetchDescriptor<SessionEmbedding>())) ?? []
    }

    private func upsertEmbedding(sessionId: UUID, vector: [Float], modelName: String, sourceTextHash: String) {
        if let existing = fetchEmbedding(for: sessionId) {
            existing.vector = vector
            existing.modelName = modelName
            existing.sourceTextHash = sourceTextHash
            existing.createdAt = Date()
        } else {
            modelContext.insert(SessionEmbedding(
                sessionId: sessionId,
                vector: vector,
                modelName: modelName,
                sourceTextHash: sourceTextHash
            ))
        }
        try? modelContext.save()
    }

    /// Insert or update an embedding with a pre-computed vector. Used by background
    /// tasks that compute embeddings off-main-actor but persist on `@MainActor`.
    func upsertEmbeddingDirect(sessionId: UUID, vector: [Float], sourceText: String) {
        let hash = Self.sha256(sourceText)
        upsertEmbedding(sessionId: sessionId, vector: vector, modelName: "NLEmbedding.local", sourceTextHash: hash)
    }
}
