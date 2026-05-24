import Foundation
import UserNotifications

struct AppleNotificationTools {
    private var center: UNUserNotificationCenter { .current() }

    func scheduleNotification(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureNotificationAccess() { return err }

        guard let title = arguments["title"] as? String else {
            return "[Error] Missing required parameter: title"
        }

        let body = arguments["body"] as? String ?? ""
        let identifier = arguments["id"] as? String ?? UUID().uuidString

        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        content.sound = .default

        if let subtitle = arguments["subtitle"] as? String {
            content.subtitle = subtitle
        }

        let trigger: UNNotificationTrigger?

        if let dateStr = arguments["date"] as? String, let date = parseDate(dateStr) {
            let components = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute, .second], from: date)
            trigger = UNCalendarNotificationTrigger(dateMatching: components, repeats: false)
        } else if let seconds = arguments["delay_seconds"] as? Double, seconds > 0 {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: seconds, repeats: false)
        } else {
            trigger = UNTimeIntervalNotificationTrigger(timeInterval: 1, repeats: false)
        }

        let request = UNNotificationRequest(identifier: identifier, content: content, trigger: trigger)

        do {
            try await center.add(request)
            var desc = """
            Notification scheduled.
            - Title: \(title)
            - ID: \(identifier)
            """
            if let calTrigger = trigger as? UNCalendarNotificationTrigger,
               let next = calTrigger.nextTriggerDate() {
                desc += "\n- Scheduled for: \(formatDate(next))"
            } else if let timeTrigger = trigger as? UNTimeIntervalNotificationTrigger {
                desc += "\n- Fires in: \(timeTrigger.timeInterval) seconds"
            }
            return desc
        } catch {
            return "[Error] Failed to schedule notification: \(error.localizedDescription)"
        }
    }

    func cancelNotification(arguments: [String: Any]) async -> String {
        guard let id = arguments["id"] as? String else {
            if let cancelAll = arguments["cancel_all"] as? Bool, cancelAll {
                center.removeAllPendingNotificationRequests()
                return "All pending notifications cancelled."
            }
            return "[Error] Missing required parameter: id"
        }

        center.removePendingNotificationRequests(withIdentifiers: [id])
        return "Notification '\(id)' cancelled."
    }

    func listNotifications(arguments: [String: Any]) async -> String {
        let pending = await center.pendingNotificationRequests()

        if pending.isEmpty {
            return "(No pending notifications)"
        }

        return pending.map { req in
            var line = "- **\(req.content.title)** [id: \(req.identifier)]"
            if !req.content.body.isEmpty { line += "\n  Body: \(req.content.body)" }
            if let calTrigger = req.trigger as? UNCalendarNotificationTrigger,
               let next = calTrigger.nextTriggerDate() {
                line += "\n  Scheduled: \(formatDate(next))"
            } else if let timeTrigger = req.trigger as? UNTimeIntervalNotificationTrigger {
                line += "\n  Interval: \(timeTrigger.timeInterval)s"
            }
            return line
        }.joined(separator: "\n")
    }

    // MARK: - Helpers

    private func parseDate(_ str: String) -> Date? {
        let formatters: [DateFormatter] = {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            iso.locale = Locale(identifier: "en_US_POSIX")
            let short = DateFormatter()
            short.dateFormat = "yyyy-MM-dd HH:mm"
            short.locale = Locale(identifier: "en_US_POSIX")
            return [iso, short]
        }()
        for f in formatters {
            if let d = f.date(from: str) { return d }
        }
        return nil
    }

    private func formatDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd HH:mm"
        return f.string(from: date)
    }
}
