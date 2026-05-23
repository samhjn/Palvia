import Foundation
import SwiftData

@Model
final class SessionEmbedding {
    var id: UUID
    /// The session this embedding belongs to (stored as raw string to avoid cascade coupling).
    var sessionIdRaw: String
    /// Raw embedding vector stored as binary Data (little-endian Float array).
    var vectorData: Data
    /// Number of dimensions, for validation.
    var dimensions: Int
    /// The model name that produced this embedding (e.g. "text-embedding-3-small").
    var modelName: String
    /// Hash of the text that was embedded (for cache invalidation).
    var sourceTextHash: String
    var createdAt: Date

    var sessionId: UUID {
        get { UUID(uuidString: sessionIdRaw) ?? UUID() }
        set { sessionIdRaw = newValue.uuidString }
    }

    /// Decode the stored Data into a Float array.
    var vector: [Float] {
        get {
            guard !vectorData.isEmpty else { return [] }
            return vectorData.withUnsafeBytes { Array($0.bindMemory(to: Float.self)) }
        }
        set {
            vectorData = newValue.withUnsafeBytes { Data($0) }
            dimensions = newValue.count
        }
    }

    init(sessionId: UUID, vector: [Float], modelName: String, sourceTextHash: String) {
        self.id = UUID()
        self.sessionIdRaw = sessionId.uuidString
        self.vectorData = vector.withUnsafeBytes { Data($0) }
        self.dimensions = vector.count
        self.modelName = modelName
        self.sourceTextHash = sourceTextHash
        self.createdAt = Date()
    }
}
