import Foundation
import SwiftData

@Model
final class CodeSnippet {
    var id: UUID
    var name: String
    var language: String
    var code: String
    var agent: Agent?
    var createdAt: Date
    var updatedAt: Date

    init(name: String, language: String = "javascript", code: String) {
        self.id = UUID()
        self.name = name
        self.language = language
        self.code = code
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
