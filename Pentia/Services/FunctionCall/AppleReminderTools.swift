import Foundation
import EventKit

struct AppleReminderTools {
    private var store: EKEventStore { ApplePermissionManager.shared.eventStore }

    func listReminders(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureRemindersAccess() { return err }

        var calendars: [EKCalendar]?
        if let listName = arguments["list_name"] as? String {
            let all = store.calendars(for: .reminder)
            if let cal = all.first(where: { $0.title.lowercased() == listName.lowercased() }) {
                calendars = [cal]
            } else {
                let available = all.map(\.title).joined(separator: ", ")
                return "[Error] List '\(listName)' not found. Available: \(available)"
            }
        }

        let showCompleted = (arguments["include_completed"] as? Bool) ?? false

        let predicate: NSPredicate
        if showCompleted {
            predicate = store.predicateForReminders(in: calendars)
        } else {
            predicate = store.predicateForIncompleteReminders(
                withDueDateStarting: nil, ending: nil, calendars: calendars)
        }

        let reminders = await withCheckedContinuation { (c: CheckedContinuation<[EKReminder]?, Never>) in
            store.fetchReminders(matching: predicate) { c.resume(returning: $0) }
        } ?? []

        if reminders.isEmpty {
            return "(No reminders found)"
        }

        let limit = min(reminders.count, 50)
        let result = reminders.prefix(limit).enumerated().map { idx, r in
            let status = r.isCompleted ? "[x]" : "[ ]"
            var line = "\(idx + 1). \(status) \(r.title ?? "(No title)")"
            if let due = r.dueDateComponents, let date = Calendar.current.date(from: due) {
                line += " | Due: \(formatDate(date))"
            }
            let prio = describePriority(r.priority)
            if !prio.isEmpty { line += " | Priority: \(prio)" }
            line += "\n   List: \(r.calendar.title) | ID: \(r.calendarItemIdentifier)"
            return line
        }.joined(separator: "\n")

        let suffix = reminders.count > limit ? "\n(... and \(reminders.count - limit) more)" : ""
        return result + suffix
    }

    func listReminderLists(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureRemindersAccess() { return err }

        let calendars = store.calendars(for: .reminder)
        if calendars.isEmpty { return "(No reminder lists found)" }

        let defaultId = store.defaultCalendarForNewReminders()?.calendarIdentifier
        return calendars.map { cal in
            let isDefault = cal.calendarIdentifier == defaultId
            return "- \(cal.title)\(isDefault ? " (default)" : "") [id: \(cal.calendarIdentifier)]"
        }.joined(separator: "\n")
    }

    func createReminder(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureRemindersAccess() { return err }

        guard let title = arguments["title"] as? String else {
            return "[Error] Missing required parameter: title"
        }

        let reminder = EKReminder(eventStore: store)
        reminder.title = title

        if let notes = arguments["notes"] as? String {
            reminder.notes = notes
        }

        if let dueStr = arguments["due_date"] as? String, let dueDate = parseDate(dueStr) {
            reminder.dueDateComponents = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: dueDate)
            if let alertMinutes = arguments["alert_minutes"] as? Double {
                reminder.addAlarm(EKAlarm(absoluteDate: dueDate.addingTimeInterval(-alertMinutes * 60)))
            }
        }

        if let prio = arguments["priority"] as? String {
            reminder.priority = parsePriority(prio)
        } else if let prioNum = arguments["priority"] as? Int {
            reminder.priority = max(0, min(9, prioNum))
        }

        if let listName = arguments["list_name"] as? String {
            let all = store.calendars(for: .reminder)
            if let cal = all.first(where: { $0.title.lowercased() == listName.lowercased() }) {
                reminder.calendar = cal
            } else {
                return "[Error] List '\(listName)' not found."
            }
        } else {
            reminder.calendar = store.defaultCalendarForNewReminders()
        }

        do {
            try store.save(reminder, commit: true)
            return """
            Reminder created successfully.
            - Title: \(reminder.title ?? "")
            - List: \(reminder.calendar.title)
            - ID: \(reminder.calendarItemIdentifier)
            """
        } catch {
            return "[Error] Failed to create reminder: \(error.localizedDescription)"
        }
    }

    func completeReminder(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureRemindersAccess() { return err }

        guard let reminderId = arguments["reminder_id"] as? String else {
            return "[Error] Missing required parameter: reminder_id"
        }

        guard let item = store.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return "[Error] Reminder not found with id: \(reminderId)"
        }

        let completed = (arguments["completed"] as? Bool) ?? true
        item.isCompleted = completed
        if completed { item.completionDate = Date() } else { item.completionDate = nil }

        do {
            try store.save(item, commit: true)
            return "Reminder '\(item.title ?? "")' marked as \(completed ? "completed" : "incomplete")."
        } catch {
            return "[Error] Failed to update reminder: \(error.localizedDescription)"
        }
    }

    func deleteReminder(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureRemindersAccess() { return err }

        guard let reminderId = arguments["reminder_id"] as? String else {
            return "[Error] Missing required parameter: reminder_id"
        }

        guard let item = store.calendarItem(withIdentifier: reminderId) as? EKReminder else {
            return "[Error] Reminder not found with id: \(reminderId)"
        }

        let title = item.title ?? "(No title)"
        do {
            try store.remove(item, commit: true)
            return "Reminder '\(title)' deleted successfully."
        } catch {
            return "[Error] Failed to delete reminder: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func parseDate(_ str: String) -> Date? {
        let formatters: [DateFormatter] = {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            iso.locale = Locale(identifier: "en_US_POSIX")
            let dateOnly = DateFormatter()
            dateOnly.dateFormat = "yyyy-MM-dd"
            dateOnly.locale = Locale(identifier: "en_US_POSIX")
            let short = DateFormatter()
            short.dateFormat = "yyyy-MM-dd HH:mm"
            short.locale = Locale(identifier: "en_US_POSIX")
            return [iso, short, dateOnly]
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

    private func describePriority(_ p: Int) -> String {
        switch p {
        case 1...4: return "High"
        case 5: return "Medium"
        case 6...9: return "Low"
        default: return ""
        }
    }

    private func parsePriority(_ s: String) -> Int {
        switch s.lowercased() {
        case "high", "h", "1": return 1
        case "medium", "m", "5": return 5
        case "low", "l", "9": return 9
        default: return 0
        }
    }
}
