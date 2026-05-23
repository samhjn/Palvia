import Foundation
import EventKit

struct AppleCalendarTools {
    private var store: EKEventStore { ApplePermissionManager.shared.eventStore }

    func listCalendars(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureCalendarAccess() { return err }

        let calendars = store.calendars(for: .event)
        if calendars.isEmpty { return "(No calendars found)" }

        return calendars.map { cal in
            let isDefault = cal.calendarIdentifier == store.defaultCalendarForNewEvents?.calendarIdentifier
            return "- \(cal.title) [id: \(cal.calendarIdentifier)]\(isDefault ? " (default)" : "")\n  Source: \(cal.source.title) | Type: \(describeCalType(cal.type))"
        }.joined(separator: "\n")
    }

    func createEvent(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureCalendarAccess() { return err }

        guard let title = arguments["title"] as? String else {
            return "[Error] Missing required parameter: title"
        }
        guard let startStr = arguments["start_date"] as? String else {
            return "[Error] Missing required parameter: start_date"
        }
        guard let start = parseDate(startStr) else {
            return "[Error] Invalid start_date format. Use ISO 8601 (e.g. '2025-03-24T14:00:00')"
        }

        let event = EKEvent(eventStore: store)
        event.title = title
        event.startDate = start

        if let endStr = arguments["end_date"] as? String, let end = parseDate(endStr) {
            event.endDate = end
        } else {
            event.endDate = start.addingTimeInterval(3600)
        }

        if let allDay = arguments["all_day"] as? Bool, allDay {
            event.isAllDay = true
        }

        if let location = arguments["location"] as? String {
            event.location = location
        }
        if let notes = arguments["notes"] as? String {
            event.notes = notes
        }
        if let url = arguments["url"] as? String {
            event.url = URL(string: url)
        }

        if let calId = arguments["calendar_id"] as? String,
           let cal = store.calendar(withIdentifier: calId) {
            event.calendar = cal
        } else {
            event.calendar = store.defaultCalendarForNewEvents
        }

        if let alertMinutes = arguments["alert_minutes"] as? Double {
            event.addAlarm(EKAlarm(relativeOffset: -alertMinutes * 60))
        }

        do {
            try store.save(event, span: .thisEvent)
            return """
            Event created successfully.
            - Title: \(event.title ?? "")
            - Start: \(formatDate(event.startDate))
            - End: \(formatDate(event.endDate))
            - Calendar: \(event.calendar.title)
            - ID: \(event.eventIdentifier ?? "unknown")
            """
        } catch {
            return "[Error] Failed to create event: \(error.localizedDescription)"
        }
    }

    func searchEvents(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureCalendarAccess() { return err }

        let now = Date()
        let start: Date
        let end: Date

        if let startStr = arguments["start_date"] as? String, let s = parseDate(startStr) {
            start = s
        } else {
            start = Calendar.current.startOfDay(for: now)
        }

        if let endStr = arguments["end_date"] as? String, let e = parseDate(endStr) {
            end = e
        } else {
            end = Calendar.current.date(byAdding: .day, value: 7, to: start)!
        }

        var calendars: [EKCalendar]?
        if let calId = arguments["calendar_id"] as? String,
           let cal = store.calendar(withIdentifier: calId) {
            calendars = [cal]
        }

        let predicate = store.predicateForEvents(withStart: start, end: end, calendars: calendars)
        let events = store.events(matching: predicate)

        if events.isEmpty {
            return "(No events found between \(formatDate(start)) and \(formatDate(end)))"
        }

        let keyword = (arguments["keyword"] as? String)?.lowercased()
        let filtered = keyword != nil
            ? events.filter { ($0.title?.lowercased().contains(keyword!) ?? false) || ($0.location?.lowercased().contains(keyword!) ?? false) }
            : events

        let limit = min(filtered.count, 50)
        let result = filtered.prefix(limit).map { ev in
            let time = ev.isAllDay
                ? "All Day \(formatDateOnly(ev.startDate))"
                : "\(formatDate(ev.startDate)) → \(formatDate(ev.endDate))"
            var line = "- **\(ev.title ?? "(No title)")** | \(time)"
            if let loc = ev.location, !loc.isEmpty { line += "\n  Location: \(loc)" }
            line += "\n  Calendar: \(ev.calendar.title) | ID: \(ev.eventIdentifier ?? "")"
            return line
        }.joined(separator: "\n")

        let suffix = filtered.count > limit ? "\n(... and \(filtered.count - limit) more)" : ""
        return result + suffix
    }

    func updateEvent(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureCalendarAccess() { return err }

        guard let eventId = arguments["event_id"] as? String else {
            return "[Error] Missing required parameter: event_id"
        }
        guard let event = store.event(withIdentifier: eventId) else {
            return "[Error] Event not found with id: \(eventId)"
        }

        if let title = arguments["title"] as? String { event.title = title }
        if let startStr = arguments["start_date"] as? String, let s = parseDate(startStr) { event.startDate = s }
        if let endStr = arguments["end_date"] as? String, let e = parseDate(endStr) { event.endDate = e }
        if let location = arguments["location"] as? String { event.location = location }
        if let notes = arguments["notes"] as? String { event.notes = notes }

        do {
            try store.save(event, span: .thisEvent)
            return "Event '\(event.title ?? "")' updated successfully."
        } catch {
            return "[Error] Failed to update event: \(error.localizedDescription)"
        }
    }

    func deleteEvent(arguments: [String: Any]) async -> String {
        if let err = await ApplePermissionManager.shared.ensureCalendarAccess() { return err }

        guard let eventId = arguments["event_id"] as? String else {
            return "[Error] Missing required parameter: event_id"
        }
        guard let event = store.event(withIdentifier: eventId) else {
            return "[Error] Event not found with id: \(eventId)"
        }

        let title = event.title ?? "(No title)"
        do {
            try store.remove(event, span: .thisEvent)
            return "Event '\(title)' deleted successfully."
        } catch {
            return "[Error] Failed to delete event: \(error.localizedDescription)"
        }
    }

    // MARK: - Helpers

    private func parseDate(_ str: String) -> Date? {
        let formatters: [DateFormatter] = {
            let iso = DateFormatter()
            iso.dateFormat = "yyyy-MM-dd'T'HH:mm:ss"
            iso.locale = Locale(identifier: "en_US_POSIX")

            let isoZ = DateFormatter()
            isoZ.dateFormat = "yyyy-MM-dd'T'HH:mm:ssZ"
            isoZ.locale = Locale(identifier: "en_US_POSIX")

            let dateOnly = DateFormatter()
            dateOnly.dateFormat = "yyyy-MM-dd"
            dateOnly.locale = Locale(identifier: "en_US_POSIX")

            let short = DateFormatter()
            short.dateFormat = "yyyy-MM-dd HH:mm"
            short.locale = Locale(identifier: "en_US_POSIX")

            return [iso, isoZ, short, dateOnly]
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

    private func formatDateOnly(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateFormat = "yyyy-MM-dd"
        return f.string(from: date)
    }

    private func describeCalType(_ type: EKCalendarType) -> String {
        switch type {
        case .local: return "Local"
        case .calDAV: return "CalDAV"
        case .exchange: return "Exchange"
        case .subscription: return "Subscription"
        case .birthday: return "Birthday"
        @unknown default: return "Other"
        }
    }
}
