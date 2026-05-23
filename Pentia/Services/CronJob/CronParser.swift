import Foundation

/// Parses standard 5-field cron expressions: minute hour day-of-month month day-of-week
///
/// Supported syntax per field:
/// - `*`          any value
/// - `5`          exact value
/// - `1,3,5`      list
/// - `1-5`        range
/// - `*/15`       step from start
/// - `1-30/5`     step within range
///
/// Day-of-week: 0=Sunday ... 6=Saturday (7 also accepted as Sunday)
struct CronParser {

    struct CronSchedule {
        let minutes: Set<Int>
        let hours: Set<Int>
        let daysOfMonth: Set<Int>
        let months: Set<Int>
        let daysOfWeek: Set<Int>
    }

    enum ParseError: LocalizedError {
        case invalidFormat(String)
        case invalidField(String, String)

        var errorDescription: String? {
            switch self {
            case .invalidFormat(let expr):
                return "Cron expression must have 5 fields (minute hour day month weekday), got: \(expr)"
            case .invalidField(let field, let detail):
                return "Invalid cron field '\(field)': \(detail)"
            }
        }
    }

    // MARK: - Public

    static func parse(_ expression: String) throws -> CronSchedule {
        let normalized = applyPresets(expression.trimmingCharacters(in: .whitespaces))
        let fields = normalized.components(separatedBy: .whitespaces).filter { !$0.isEmpty }

        guard fields.count == 5 else {
            throw ParseError.invalidFormat(expression)
        }

        let minutes    = try parseField(fields[0], range: 0...59,  name: "minute")
        let hours      = try parseField(fields[1], range: 0...23,  name: "hour")
        let doms       = try parseField(fields[2], range: 1...31,  name: "day-of-month")
        let months     = try parseField(fields[3], range: 1...12,  name: "month")
        var dows       = try parseField(fields[4], range: 0...7,   name: "day-of-week")

        if dows.contains(7) {
            dows.insert(0)
            dows.remove(7)
        }

        return CronSchedule(
            minutes: minutes,
            hours: hours,
            daysOfMonth: doms,
            months: months,
            daysOfWeek: dows
        )
    }

    static func nextFireDate(after date: Date, for expression: String, calendar: Calendar = .current) throws -> Date? {
        let schedule = try parse(expression)
        return nextFireDate(after: date, schedule: schedule, calendar: calendar)
    }

    static func nextFireDate(after date: Date, schedule: CronSchedule, calendar: Calendar = .current) -> Date? {
        var components = calendar.dateComponents([.year, .month, .day, .hour, .minute], from: date)
        components.second = 0

        guard var candidate = calendar.date(from: components) else { return nil }

        // Advance at least 1 minute past the given date
        candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate

        let maxIterations = 525960 // ~1 year in minutes
        for _ in 0..<maxIterations {
            let c = calendar.dateComponents([.year, .month, .day, .hour, .minute, .weekday], from: candidate)
            guard let month = c.month, let dom = c.day, let hour = c.hour, let minute = c.minute, let weekday = c.weekday else {
                return nil
            }

            let cronDow = weekday == 1 ? 0 : weekday - 1

            if !schedule.months.contains(month) {
                candidate = calendar.date(byAdding: .month, value: 1, to: startOfMonth(candidate, calendar: calendar)) ?? candidate
                continue
            }

            if !schedule.daysOfMonth.contains(dom) || !schedule.daysOfWeek.contains(cronDow) {
                candidate = calendar.date(byAdding: .day, value: 1, to: startOfDay(candidate, calendar: calendar)) ?? candidate
                continue
            }

            if !schedule.hours.contains(hour) {
                candidate = calendar.date(byAdding: .hour, value: 1, to: startOfHour(candidate, calendar: calendar)) ?? candidate
                continue
            }

            if !schedule.minutes.contains(minute) {
                candidate = calendar.date(byAdding: .minute, value: 1, to: candidate) ?? candidate
                continue
            }

            return candidate
        }

        return nil
    }

    static func describe(_ expression: String) -> String {
        guard let schedule = try? parse(expression) else {
            return L10n.CronDesc.invalidExpression
        }

        var parts: [String] = []

        if schedule.minutes == Set(0...59) {
            parts.append(L10n.CronDesc.everyMinute)
        } else if schedule.minutes.count == 1, let m = schedule.minutes.first {
            parts.append(L10n.CronDesc.atMinute(m))
        } else {
            parts.append(L10n.CronDesc.atMinutes(schedule.minutes.sorted().map(String.init).joined(separator: ",")))
        }

        if schedule.hours == Set(0...23) {
            parts.append(L10n.CronDesc.ofEveryHour)
        } else if schedule.hours.count == 1, let h = schedule.hours.first {
            parts.append(L10n.CronDesc.ofHour(h))
        } else {
            parts.append(L10n.CronDesc.ofHours(schedule.hours.sorted().map(String.init).joined(separator: ",")))
        }

        if schedule.daysOfMonth != Set(1...31) {
            parts.append(L10n.CronDesc.onDays(schedule.daysOfMonth.sorted().map(String.init).joined(separator: ",")))
        }

        if schedule.months != Set(1...12) {
            parts.append(L10n.CronDesc.inMonths(schedule.months.sorted().map(String.init).joined(separator: ",")))
        }

        let allDow = Set(0...6)
        if schedule.daysOfWeek != allDow {
            let names = L10n.CronDesc.weekdayNames
            let dowNames = schedule.daysOfWeek.sorted().compactMap { $0 < names.count ? names[$0] : nil }
            parts.append(L10n.CronDesc.onWeekdays(dowNames.joined(separator: ",")))
        }

        return parts.joined(separator: " ")
    }

    static func validate(_ expression: String) -> String? {
        do {
            _ = try parse(expression)
            return nil
        } catch {
            return error.localizedDescription
        }
    }

    // MARK: - Private

    private static func parseField(_ field: String, range: ClosedRange<Int>, name: String) throws -> Set<Int> {
        var result = Set<Int>()

        for part in field.components(separatedBy: ",") {
            let trimmed = part.trimmingCharacters(in: .whitespaces)
            if trimmed.isEmpty { continue }

            if trimmed.contains("/") {
                let stepParts = trimmed.components(separatedBy: "/")
                guard stepParts.count == 2, let step = Int(stepParts[1]), step > 0 else {
                    throw ParseError.invalidField(field, "invalid step in '\(trimmed)'")
                }
                let basePart = stepParts[0]
                let baseRange: ClosedRange<Int>
                if basePart == "*" {
                    baseRange = range
                } else if basePart.contains("-") {
                    baseRange = try parseRange(basePart, range: range, name: name)
                } else {
                    guard let start = Int(basePart), range.contains(start) else {
                        throw ParseError.invalidField(field, "value out of range [\(range.lowerBound)-\(range.upperBound)]")
                    }
                    baseRange = start...range.upperBound
                }
                var v = baseRange.lowerBound
                while v <= baseRange.upperBound {
                    result.insert(v)
                    v += step
                }
            } else if trimmed == "*" {
                result.formUnion(Set(range))
            } else if trimmed.contains("-") {
                let r = try parseRange(trimmed, range: range, name: name)
                result.formUnion(Set(r))
            } else {
                guard let val = Int(trimmed), range.contains(val) else {
                    throw ParseError.invalidField(field, "'\(trimmed)' is not a valid \(name) [\(range.lowerBound)-\(range.upperBound)]")
                }
                result.insert(val)
            }
        }

        if result.isEmpty {
            throw ParseError.invalidField(field, "produced empty set for \(name)")
        }

        return result
    }

    private static func parseRange(_ s: String, range: ClosedRange<Int>, name: String) throws -> ClosedRange<Int> {
        let parts = s.components(separatedBy: "-")
        guard parts.count == 2, let lo = Int(parts[0]), let hi = Int(parts[1]) else {
            throw ParseError.invalidField(s, "invalid range for \(name)")
        }
        guard range.contains(lo) && range.contains(hi) && lo <= hi else {
            throw ParseError.invalidField(s, "range out of bounds [\(range.lowerBound)-\(range.upperBound)]")
        }
        return lo...hi
    }

    private static func applyPresets(_ expr: String) -> String {
        switch expr.lowercased() {
        case "@yearly", "@annually": return "0 0 1 1 *"
        case "@monthly":             return "0 0 1 * *"
        case "@weekly":              return "0 0 * * 0"
        case "@daily", "@midnight":  return "0 0 * * *"
        case "@hourly":              return "0 * * * *"
        default:                     return expr
        }
    }

    private static func startOfMonth(_ date: Date, calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month], from: date)
        return calendar.date(from: c) ?? date
    }

    private static func startOfDay(_ date: Date, calendar: Calendar) -> Date {
        calendar.startOfDay(for: date)
    }

    private static func startOfHour(_ date: Date, calendar: Calendar) -> Date {
        let c = calendar.dateComponents([.year, .month, .day, .hour], from: date)
        return calendar.date(from: c) ?? date
    }
}
