import Foundation
import SwiftData

@Model
final class InstalledSkill {
    var id: UUID
    var agent: Agent?
    var skill: Skill?
    var isEnabled: Bool
    var priority: Int = 0
    var configRaw: String = "{}"
    var installedAt: Date

    var config: [String: String] {
        get { (try? JSONDecoder().decode([String: String].self, from: Data(configRaw.utf8))) ?? [:] }
        set { configRaw = (try? String(data: JSONEncoder().encode(newValue), encoding: .utf8)) ?? "{}" }
    }

    init(isEnabled: Bool = true, priority: Int = 0) {
        self.id = UUID()
        self.isEnabled = isEnabled
        self.priority = priority
        self.configRaw = "{}"
        self.installedAt = Date()
    }
}
