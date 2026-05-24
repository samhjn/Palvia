import Foundation
import SwiftData

@Model
final class CronJob {
    var id: UUID
    var name: String
    var cronExpression: String
    var jobHint: String
    var agent: Agent?
    var isEnabled: Bool
    var lastRunAt: Date?
    var nextRunAt: Date?
    var runCount: Int
    var lastSessionId: UUID?
    var createdAt: Date
    var updatedAt: Date

    init(
        name: String,
        cronExpression: String,
        jobHint: String,
        isEnabled: Bool = true
    ) {
        self.id = UUID()
        self.name = name
        self.cronExpression = cronExpression
        self.jobHint = jobHint
        self.isEnabled = isEnabled
        self.lastRunAt = nil
        self.nextRunAt = nil
        self.runCount = 0
        self.lastSessionId = nil
        self.createdAt = Date()
        self.updatedAt = Date()
    }
}
