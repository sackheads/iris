import Testing
import Foundation
@testable import iris

@Suite("CronSchedule")
struct CronScheduleTests {
    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: TimeZone = la) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    static func cron(_ e: String, tz: String = "America/Los_Angeles") -> CronSchedule { CronSchedule(expression: e, timeZone: tz) }

    @Test("parses star, number, list, range, step forms")
    func parseForms() throws {
        let f = try CronSchedule.parse("*/15 9-17 1,15 * 1-5").get()
        #expect(f.minutes == [0, 15, 30, 45])
        #expect(f.hours == Set(9...17))
        #expect(f.daysOfMonth == [1, 15])
        #expect(f.months == Set(1...12))
        #expect(f.daysOfWeek == Set(1...5))
        #expect(f.dayOfMonthRestricted && f.dayOfWeekRestricted)
    }

    @Test("7 is Sunday; names and six fields are rejected; out of range is rejected")
    func parseRejects() throws {
        #expect(try CronSchedule.parse("0 0 * * 7").get().daysOfWeek == [0])
        #expect(CronSchedule.parse("0 0 * * MON") == .failure(.badToken(field: "day-of-week", token: "MON")))
        #expect(CronSchedule.parse("0 0 * * * *") == .failure(.fieldCount(6)))
        #expect(CronSchedule.parse("60 0 * * *") == .failure(.outOfRange(field: "minute", value: 60)))
        #expect(CronSchedule.parse("0 0 32 * *") == .failure(.outOfRange(field: "day-of-month", value: 32)))
    }

    @Test("weekdays at 09:00 from a Friday 10:00 → next Monday 09:00")
    func weekdaysFromFriday() {
        // 2026-09-18 is a Friday
        let next = Self.cron("0 9 * * 1-5").next(after: Self.date(2026, 9, 18, 10, 0))
        #expect(next == Self.date(2026, 9, 21, 9, 0))
    }

    @Test("same-day fire when the time is still ahead")
    func sameDay() {
        #expect(Self.cron("0 9 * * 1-5").next(after: Self.date(2026, 9, 16, 8, 0)) == Self.date(2026, 9, 16, 9, 0))
    }

    @Test("day-of-month OR day-of-week when both are restricted (Vixie)")
    func domOrDow() {
        // 2026-09-15 is a Tuesday; "0 0 15 * 1" fires on the 15th AND every Monday
        let n1 = Self.cron("0 0 15 * 1").next(after: Self.date(2026, 9, 13, 1, 0))   // Sunday → Monday 14th
        #expect(n1 == Self.date(2026, 9, 14, 0, 0))
        let n2 = Self.cron("0 0 15 * 1").next(after: Self.date(2026, 9, 14, 1, 0))   // Monday → 15th
        #expect(n2 == Self.date(2026, 9, 15, 0, 0))
    }

    @Test("month end and February 29")
    func monthEnd() {
        #expect(Self.cron("0 0 31 * *").next(after: Self.date(2026, 9, 1, 0, 0)) == Self.date(2026, 10, 31, 0, 0))
        #expect(Self.cron("0 0 29 2 *").next(after: Self.date(2026, 3, 1, 0, 0)) == Self.date(2028, 2, 29, 0, 0))
    }

    @Test("DST spring forward: 02:30 does not exist on 2026-03-08 in Los Angeles, so the fire is the next day")
    func dstGap() {
        let next = Self.cron("30 2 * * *").next(after: Self.date(2026, 3, 7, 3, 0))
        #expect(next == Self.date(2026, 3, 9, 2, 30))
    }

    @Test("a non-local zone is honoured")
    func tokyo() {
        let tokyo = TimeZone(identifier: "Asia/Tokyo")!
        let next = Self.cron("0 9 * * *", tz: "Asia/Tokyo").next(after: Self.date(2026, 9, 16, 0, 0, tz: tokyo))
        #expect(next == Self.date(2026, 9, 16, 9, 0, tz: tokyo))
    }

    @Test("gives up when the expression can never match")
    func giveUp() {
        #expect(Self.cron("0 0 30 2 *").next(after: Self.date(2026, 9, 16, 0, 0)) == nil)
    }

    @Test("DST fall back: neither pass through the repeated hour yields a fire at or before the start")
    func dstFallBackRepeatedHour() {
        // 2026-11-01 01:30 PDT — the FIRST of the two passes America/Los_Angeles makes through
        // 01:00-02:00 that morning. Built from its UTC epoch, because the wall-clock components
        // name both passes and going through them is exactly what this pins.
        let after = Date(timeIntervalSince1970: 1_793_521_800)          // 2026-11-01T08:30:00Z
        let next = Self.cron("*/15 * * * *").next(after: after)
        #expect(next.map { $0 > after } == true)
        #expect(next == Date(timeIntervalSince1970: 1_793_522_700))     // 08:45Z = 01:45 PDT

        // And from the SECOND pass, whose wall clock reads 01:30 too. Flooring through
        // wall-clock components resolved that back to the first pass and handed back a fire an
        // hour in the past; flooring the instant itself cannot.
        let afterPST = Date(timeIntervalSince1970: 1_793_525_400)       // 2026-11-01T09:30:00Z
        let nextPST = Self.cron("*/15 * * * *").next(after: afterPST)
        #expect(nextPST.map { $0 > afterPST } == true)
        #expect(nextPST == Date(timeIntervalSince1970: 1_793_526_300))  // 09:45Z = 01:45 PST
    }

    @Test("decodes with defaults when fields are absent")
    func lenientDecode() throws {
        let s = try JSONDecoder().decode(CronSchedule.self, from: Data("{}".utf8))
        #expect(s.expression == "* * * * *")
        #expect(TimeZone(identifier: s.timeZone) != nil)
    }
}
