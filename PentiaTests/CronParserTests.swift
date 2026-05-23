import XCTest
@testable import iClaw

final class CronParserTests: XCTestCase {

    // MARK: - Basic Parsing

    func testParseEveryMinute() throws {
        let schedule = try CronParser.parse("* * * * *")
        XCTAssertEqual(schedule.minutes, Set(0...59))
        XCTAssertEqual(schedule.hours, Set(0...23))
        XCTAssertEqual(schedule.daysOfMonth, Set(1...31))
        XCTAssertEqual(schedule.months, Set(1...12))
        XCTAssertEqual(schedule.daysOfWeek, Set(0...6))
    }

    func testParseExactValues() throws {
        let schedule = try CronParser.parse("30 9 15 6 3")
        XCTAssertEqual(schedule.minutes, [30])
        XCTAssertEqual(schedule.hours, [9])
        XCTAssertEqual(schedule.daysOfMonth, [15])
        XCTAssertEqual(schedule.months, [6])
        XCTAssertEqual(schedule.daysOfWeek, [3])
    }

    func testParseListValues() throws {
        let schedule = try CronParser.parse("0,15,30,45 * * * *")
        XCTAssertEqual(schedule.minutes, [0, 15, 30, 45])
    }

    func testParseRangeValues() throws {
        let schedule = try CronParser.parse("* 9-17 * * *")
        XCTAssertEqual(schedule.hours, Set(9...17))
    }

    func testParseStepFromStar() throws {
        let schedule = try CronParser.parse("*/15 * * * *")
        XCTAssertEqual(schedule.minutes, [0, 15, 30, 45])
    }

    func testParseStepWithinRange() throws {
        let schedule = try CronParser.parse("1-30/5 * * * *")
        XCTAssertEqual(schedule.minutes, [1, 6, 11, 16, 21, 26])
    }

    func testParseStepFromBase() throws {
        let schedule = try CronParser.parse("5/10 * * * *")
        XCTAssertEqual(schedule.minutes, [5, 15, 25, 35, 45, 55])
    }

    // MARK: - Day of Week Normalization

    func testDayOfWeekSundayAsZero() throws {
        let schedule = try CronParser.parse("* * * * 0")
        XCTAssertEqual(schedule.daysOfWeek, [0])
    }

    func testDayOfWeekSundayAsSeven() throws {
        let schedule = try CronParser.parse("* * * * 7")
        XCTAssertEqual(schedule.daysOfWeek, [0])
    }

    func testDayOfWeekWeekdays() throws {
        let schedule = try CronParser.parse("* * * * 1-5")
        XCTAssertEqual(schedule.daysOfWeek, Set(1...5))
    }

    // MARK: - Presets

    func testPresetYearly() throws {
        let schedule = try CronParser.parse("@yearly")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, [0])
        XCTAssertEqual(schedule.daysOfMonth, [1])
        XCTAssertEqual(schedule.months, [1])
        XCTAssertEqual(schedule.daysOfWeek, Set(0...6))
    }

    func testPresetAnnually() throws {
        let schedule = try CronParser.parse("@annually")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, [0])
    }

    func testPresetMonthly() throws {
        let schedule = try CronParser.parse("@monthly")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, [0])
        XCTAssertEqual(schedule.daysOfMonth, [1])
        XCTAssertEqual(schedule.months, Set(1...12))
    }

    func testPresetWeekly() throws {
        let schedule = try CronParser.parse("@weekly")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, [0])
        XCTAssertEqual(schedule.daysOfWeek, [0])
    }

    func testPresetDaily() throws {
        let schedule = try CronParser.parse("@daily")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, [0])
        XCTAssertEqual(schedule.daysOfMonth, Set(1...31))
    }

    func testPresetMidnight() throws {
        let schedule = try CronParser.parse("@midnight")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, [0])
    }

    func testPresetHourly() throws {
        let schedule = try CronParser.parse("@hourly")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, Set(0...23))
    }

    func testPresetCaseInsensitive() throws {
        let schedule = try CronParser.parse("@DAILY")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, [0])
    }

    // MARK: - Error Cases

    func testInvalidFormatTooFewFields() {
        XCTAssertThrowsError(try CronParser.parse("* * *")) { error in
            XCTAssertTrue(error is CronParser.ParseError)
            if case CronParser.ParseError.invalidFormat = error {} else {
                XCTFail("Expected invalidFormat")
            }
        }
    }

    func testInvalidFormatTooManyFields() {
        XCTAssertThrowsError(try CronParser.parse("* * * * * *")) { error in
            XCTAssertTrue(error is CronParser.ParseError)
        }
    }

    func testInvalidFieldOutOfRange() {
        XCTAssertThrowsError(try CronParser.parse("60 * * * *")) { error in
            if case CronParser.ParseError.invalidField = error {} else {
                XCTFail("Expected invalidField for minute=60")
            }
        }
    }

    func testInvalidFieldNegative() {
        XCTAssertThrowsError(try CronParser.parse("-1 * * * *"))
    }

    func testInvalidFieldBadRange() {
        XCTAssertThrowsError(try CronParser.parse("5-2 * * * *"))
    }

    func testInvalidFieldBadStep() {
        XCTAssertThrowsError(try CronParser.parse("*/0 * * * *"))
    }

    func testEmptyExpression() {
        XCTAssertThrowsError(try CronParser.parse(""))
    }

    // MARK: - Validation

    func testValidateSuccess() {
        XCTAssertNil(CronParser.validate("0 9 * * 1-5"))
    }

    func testValidateFailure() {
        let error = CronParser.validate("bad expression")
        XCTAssertNotNil(error)
    }

    func testValidatePreset() {
        XCTAssertNil(CronParser.validate("@daily"))
    }

    // MARK: - Next Fire Date

    func testNextFireDateEveryMinute() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 24
        comps.hour = 10; comps.minute = 30; comps.second = 0
        let date = cal.date(from: comps)!

        let next = try CronParser.nextFireDate(after: date, for: "* * * * *", calendar: cal)
        XCTAssertNotNil(next)

        let nextComps = cal.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(nextComps.hour, 10)
        XCTAssertEqual(nextComps.minute, 31)
    }

    func testNextFireDateSpecificTime() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 24
        comps.hour = 8; comps.minute = 0; comps.second = 0
        let date = cal.date(from: comps)!

        let next = try CronParser.nextFireDate(after: date, for: "0 9 * * *", calendar: cal)
        XCTAssertNotNil(next)

        let nextComps = cal.dateComponents([.hour, .minute], from: next!)
        XCTAssertEqual(nextComps.hour, 9)
        XCTAssertEqual(nextComps.minute, 0)
    }

    func testNextFireDateSkipsToNextDay() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 24
        comps.hour = 10; comps.minute = 0; comps.second = 0
        let date = cal.date(from: comps)!

        let next = try CronParser.nextFireDate(after: date, for: "0 9 * * *", calendar: cal)
        XCTAssertNotNil(next)

        let nextComps = cal.dateComponents([.day, .hour], from: next!)
        XCTAssertEqual(nextComps.day, 25)
        XCTAssertEqual(nextComps.hour, 9)
    }

    func testNextFireDateWeekdayOnly() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        // 2025-03-22 is Saturday
        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 22
        comps.hour = 10; comps.minute = 0; comps.second = 0
        let date = cal.date(from: comps)!

        let next = try CronParser.nextFireDate(after: date, for: "0 9 * * 1-5", calendar: cal)
        XCTAssertNotNil(next)

        let nextComps = cal.dateComponents([.day, .weekday], from: next!)
        XCTAssertEqual(nextComps.day, 24) // Monday
        XCTAssertEqual(nextComps.weekday, 2) // Monday in Calendar.weekday
    }

    func testNextFireDateSpecificMonth() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        var comps = DateComponents()
        comps.year = 2025; comps.month = 4; comps.day = 1
        comps.hour = 0; comps.minute = 0; comps.second = 0
        let date = cal.date(from: comps)!

        // Only in January
        let next = try CronParser.nextFireDate(after: date, for: "0 0 1 1 *", calendar: cal)
        XCTAssertNotNil(next)

        let nextComps = cal.dateComponents([.year, .month, .day], from: next!)
        XCTAssertEqual(nextComps.year, 2026)
        XCTAssertEqual(nextComps.month, 1)
        XCTAssertEqual(nextComps.day, 1)
    }

    func testNextFireDateAdvancesAtLeastOneMinute() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!

        var comps = DateComponents()
        comps.year = 2025; comps.month = 3; comps.day = 24
        comps.hour = 9; comps.minute = 0; comps.second = 0
        let date = cal.date(from: comps)!

        // Even though 09:00 matches "0 9 * * *", it should advance to at least 09:01
        let next = try CronParser.nextFireDate(after: date, for: "* * * * *", calendar: cal)
        XCTAssertNotNil(next)
        XCTAssertTrue(next! > date)
    }

    // MARK: - Complex Expressions

    func testComplexExpression() throws {
        let schedule = try CronParser.parse("0,30 9-17 1,15 * 1-5")
        XCTAssertEqual(schedule.minutes, [0, 30])
        XCTAssertEqual(schedule.hours, Set(9...17))
        XCTAssertEqual(schedule.daysOfMonth, [1, 15])
        XCTAssertEqual(schedule.months, Set(1...12))
        XCTAssertEqual(schedule.daysOfWeek, Set(1...5))
    }

    func testWhitespaceTrimming() throws {
        let schedule = try CronParser.parse("  0  9  *  *  *  ")
        XCTAssertEqual(schedule.minutes, [0])
        XCTAssertEqual(schedule.hours, [9])
    }

    // MARK: - Describe

    func testDescribeDoesNotCrashOnValid() {
        let desc = CronParser.describe("0 9 * * 1-5")
        XCTAssertFalse(desc.isEmpty)
    }

    func testDescribeReturnsNonEmptyForInvalid() {
        let desc = CronParser.describe("invalid")
        XCTAssertFalse(desc.isEmpty)
    }
}
