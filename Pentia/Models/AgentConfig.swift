import Foundation
import SwiftData

@Model
final class AgentConfig {
    var id: UUID
    var key: String
    var content: String
    var agent: Agent?
    var createdAt: Date
    var updatedAt: Date

    init(key: String, content: String) {
        self.id = UUID()
        self.key = key
        self.content = content
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
