import Testing
import Foundation
@testable import iris

/// Pure tests on `ScheduledJob` only — never touch `ScheduleManager.shared`, whose initializer
/// reads the real jobs file (#156).
@Suite("ScheduledJob weekdays (#156)")
struct ScheduledJobWeekdaysTests {
    // Fixed UTC calendar so the test does not depend on the machine's time zone.
    // Reference: 2023-01-01 was a Sunday (weekday 1), so 2023-01-02..07 are Mon(2)..Sat(7).
    static var utcCalendar: Calendar {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC")!
        return cal
    }

    func date(_ year: Int, _ month: Int, _ day: Int, _ hour: Int, _ minute: Int) -> Date {
        var comps = DateComponents()
        comps.year = year; comps.month = month; comps.day = day
        comps.hour = hour; comps.minute = minute
        return Self.utcCalendar.date(from: comps)!
    }

    func job(weekday: Int? = nil, weekdays: [Int]? = nil, hour: Int? = 9, minute: Int? = 0) -> ScheduledJob {
        ScheduledJob(conversationId: nil, prompt: "test", minute: minute, hour: hour, weekday: weekday, weekdays: weekdays, nextFireAt: Date())
    }

    @Test("Monday-Friday from a Friday after the fire time rolls to next Monday")
    func fridayAfterFireTimeRollsToMonday() {
        let j = job(weekdays: [2, 3, 4, 5, 6])
        let friday10am = date(2023, 1, 6, 10, 0) // Friday
        let next = j.calculateNextFireDate(after: friday10am, calendar: Self.utcCalendar)
        #expect(next == date(2023, 1, 9, 9, 0)) // Monday
    }

    @Test("Monday-Friday from a Wednesday before the fire time stays same day")
    func wednesdayBeforeFireTimeStaysSameDay() {
        let j = job(weekdays: [2, 3, 4, 5, 6])
        let wednesday8am = date(2023, 1, 4, 8, 0) // Wednesday
        let next = j.calculateNextFireDate(after: wednesday8am, calendar: Self.utcCalendar)
        #expect(next == date(2023, 1, 4, 9, 0)) // same Wednesday
    }

    @Test("Monday-Friday from a Saturday rolls to Monday")
    func saturdayRollsToMonday() {
        let j = job(weekdays: [2, 3, 4, 5, 6])
        let saturday = date(2023, 1, 7, 10, 0) // Saturday
        let next = j.calculateNextFireDate(after: saturday, calendar: Self.utcCalendar)
        #expect(next == date(2023, 1, 9, 9, 0)) // Monday
    }

    @Test("a single legacy weekday behaves exactly as before")
    func singleWeekdayUnchanged() {
        let j = job(weekday: 6) // Friday
        let wednesday = date(2023, 1, 4, 8, 0)
        let next = j.calculateNextFireDate(after: wednesday, calendar: Self.utcCalendar)
        #expect(next == date(2023, 1, 6, 9, 0)) // Friday
    }

    @Test("JSON without weekdays decodes with weekdays nil")
    func decodesMissingWeekdaysAsNil() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","conversationId":null,"prompt":"hi","minute":0,"hour":9,"day":null,"month":null,"weekday":6,"intervalSeconds":null,"nextFireAt":719528000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScheduledJob.self, from: json)
        #expect(decoded.weekdays == nil)
        #expect(decoded.weekday == 6)
        #expect(decoded.effectiveWeekdays == [6])
    }

    @Test("JSON with both weekday and weekdays prefers weekdays")
    func decodedJobPrefersWeekdaysOverWeekday() throws {
        let json = """
        {"id":"11111111-1111-1111-1111-111111111111","conversationId":null,"prompt":"hi","minute":0,"hour":9,"day":null,"month":null,"weekday":6,"weekdays":[2,3,4,5,6],"intervalSeconds":null,"nextFireAt":719528000}
        """.data(using: .utf8)!
        let decoded = try JSONDecoder().decode(ScheduledJob.self, from: json)
        #expect(decoded.effectiveWeekdays == [2, 3, 4, 5, 6])
    }

    @Test("out-of-range and duplicate weekday entries are dropped")
    func outOfRangeAndDuplicatesDropped() {
        let j = job(weekdays: [2, 2, 0, 8, 6, -1])
        #expect(j.effectiveWeekdays == [2, 6])
    }

    @Test("round trip through encode/decode preserves weekdays")
    func roundTripsThroughCoding() throws {
        let original = job(weekdays: [2, 4, 6])
        let data = try JSONEncoder().encode(original)
        let decoded = try JSONDecoder().decode(ScheduledJob.self, from: data)
        #expect(decoded.weekdays == [2, 4, 6])
    }
}
