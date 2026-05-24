import Foundation
import SwiftData

struct CronTools {
    let agent: Agent
    let modelContext: ModelContext

    func scheduleCron(arguments: [String: Any]) -> String {
        guard let name = arguments["name"] as? String else {
            return "[Error] Missing required parameter: name"
        }
        guard let expression = arguments["cron_expression"] as? String else {
            return "[Error] Missing required parameter: cron_expression"
        }
        guard let hint = arguments["job_hint"] as? String else {
            return "[Error] Missing required parameter: job_hint"
        }

        if let validationError = CronParser.validate(expression) {
            return "[Error] Invalid cron expression: \(validationError)"
        }

        let enabled = parseBool(arguments["enabled"], default: true)

        let job = CronJob(
            name: name,
            cronExpression: expression,
            jobHint: hint,
            isEnabled: enabled
        )

        if let next = try? CronParser.nextFireDate(after: Date(), for: expression) {
            job.nextRunAt = next
        }

        modelContext.insert(job)
        agent.cronJobs.append(job)
        try? modelContext.save()

        let description = CronParser.describe(expression)
        let nextStr = job.nextRunAt.map { formatDate($0) } ?? "unknown"

        return """
        Cron job created successfully.
        - Name: \(name)
        - ID: \(job.id.uuidString)
        - Schedule: \(expression) (\(description))
        - Next run: \(nextStr)
        - Enabled: \(enabled)

        The job will automatically create a new session and run your hint as a trigger message at each scheduled time.

        💡 **Tip: 使用 Apple Shortcuts 确保定时任务可靠触发**
        iOS 后台限制可能导致任务延迟。建议在 Shortcuts App 中创建自动化：
        1. 打开「快捷指令」→「自动化」→ 新建「特定时间」自动化
        2. 添加「打开URL」动作，填入: `iclaw://cron/trigger/\(job.id.uuidString)`
        3. 关闭「运行前询问」

        也可使用 `iclaw://cron/run-due` 统一触发所有到期任务。
        """
    }

    func unscheduleCron(arguments: [String: Any]) -> String {
        guard let jobIdStr = arguments["job_id"] as? String,
              let jobId = UUID(uuidString: jobIdStr) else {
            return "[Error] Missing or invalid job_id parameter"
        }

        let deleteCompletely = parseBool(arguments["delete"], default: false)

        guard let job = agent.cronJobs.first(where: { $0.id == jobId }) else {
            let available = agent.cronJobs.map { "  - \($0.name): \($0.id.uuidString)" }.joined(separator: "\n")
            return "[Error] Job not found. Available jobs:\n\(available.isEmpty ? "  (none)" : available)"
        }

        if deleteCompletely {
            let name = job.name
            modelContext.delete(job)
            try? modelContext.save()
            return "Cron job '\(name)' has been permanently deleted."
        } else {
            job.isEnabled = false
            job.updatedAt = Date()
            try? modelContext.save()
            return "Cron job '\(job.name)' has been disabled. Use schedule_cron to create a new one or re-enable via UI."
        }
    }

    func listCron() -> String {
        let jobs = agent.cronJobs
        if jobs.isEmpty {
            return "(No cron jobs configured for this agent)"
        }

        return jobs.map { job in
            let status = job.isEnabled ? "enabled" : "disabled"
            let nextStr = job.nextRunAt.map { formatDate($0) } ?? "not scheduled"
            let lastStr = job.lastRunAt.map { formatDate($0) } ?? "never"
            let description = CronParser.describe(job.cronExpression)

            return """
            - **\(job.name)** [\(status)]
              ID: \(job.id.uuidString)
              Schedule: \(job.cronExpression) (\(description))
              Next: \(nextStr) | Last: \(lastStr) | Runs: \(job.runCount)
              Hint: \(job.jobHint.prefix(100))\(job.jobHint.count > 100 ? "..." : "")
            """
        }.joined(separator: "\n\n")
    }

    private func parseBool(_ value: Any?, default defaultValue: Bool) -> Bool {
        if let b = value as? Bool { return b }
        if let n = value as? NSNumber { return n.boolValue }
        if let s = value as? String {
            switch s.lowercased() {
            case "true", "yes", "1": return true
            case "false", "no", "0": return false
            default: break
            }
        }
        return defaultValue
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
