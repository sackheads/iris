import Testing
import Foundation
@testable import iris

/// Carries a `next(after:)` result back from the task that computed it, so a schedule that spins
/// forever fails a deadline here instead of wedging the whole suite.
private actor NextBox {
    private var result: Date??
    func put(_ value: Date?) { result = value }
    func take() -> Date?? { result }
}

@Suite("CronSchedule")
struct CronScheduleTests {
    static let la = TimeZone(identifier: "America/Los_Angeles")!
    static func date(_ y: Int, _ mo: Int, _ d: Int, _ h: Int, _ mi: Int, tz: TimeZone = la) -> Date {
        var c = Calendar(identifier: .gregorian); c.timeZone = tz
        return c.date(from: DateComponents(year: y, month: mo, day: d, hour: h, minute: mi))!
    }
    static func cron(_ e: String, tz: String = "America/Los_Angeles") -> CronSchedule { CronSchedule(expression: e, timeZone: tz) }

    /// `schedule.next(after:)` with a hard deadline. The outer optional is the deadline: `nil`
    /// means it never came back, which is the regression this guards (`next` is a synchronous
    /// loop, so it is run off this task rather than wrapped in a cancellable one — a spin would
    /// ignore cancellation anyway).
    static func boundedNext(_ schedule: CronSchedule, after: Date, seconds: Double = 5) async -> Date?? {
        let box = NextBox()
        let work = Task.detached { await box.put(schedule.next(after: after)) }
        defer { work.cancel() }
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if let result = await box.take() { return result }
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        return nil
    }

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

    @Test("an empty list element and a wrapping range are both rejected")
    func parseRejectsEmptyAndWrapping() {
        #expect(CronSchedule.parse("1,,2 * * * *") == .failure(.badToken(field: "minute", token: "")))
        #expect(CronSchedule.parse("0 9 * * 1-5,") == .failure(.badToken(field: "day-of-week", token: "")))
        #expect(CronSchedule.parse("0 , * * *") == .failure(.badToken(field: "hour", token: "")))
        // A range that wraps midnight is not a range Iris accepts; two tokens say it instead.
        #expect(CronSchedule.parse("0 22-2 * * *") == .failure(.badToken(field: "hour", token: "22-2")))
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
    func dstFallBackRepeatedHour() async {
        // Hours 2-23: the repeated hour (01:00-02:00, which America/Los_Angeles walks twice on
        // 2026-11-01) is deliberately NOT in the set, so both passes go through the hour
        // skip-ahead rather than matching minute by minute.
        //
        // 2026-11-01 01:30 PDT — the FIRST of the two passes. Built from its UTC epoch, because
        // the wall-clock components name both passes and going through them is exactly what this
        // pins.
        let after = Date(timeIntervalSince1970: 1_793_521_800)          // 2026-11-01T08:30:00Z
        guard let next = await Self.boundedNext(Self.cron("*/15 2-23 * * *"), after: after) else {
            Issue.record("next(after:) never returned from the first pass"); return
        }
        #expect(next.map { $0 > after } == true)
        #expect(next == Date(timeIntervalSince1970: 1_793_527_200))     // 10:00Z = 02:00 PST

        // And from the SECOND pass, whose wall clock reads 01:30 too. Flooring through
        // wall-clock components resolved that back to the first pass and handed back a fire an
        // hour in the past; flooring the instant itself cannot.
        let afterPST = Date(timeIntervalSince1970: 1_793_525_400)       // 2026-11-01T09:30:00Z
        guard let nextPST = await Self.boundedNext(Self.cron("*/15 2-23 * * *"), after: afterPST) else {
            Issue.record("next(after:) never returned from the second pass"); return
        }
        #expect(nextPST.map { $0 > afterPST } == true)
        #expect(nextPST == Date(timeIntervalSince1970: 1_793_527_200))  // 10:00Z = 02:00 PST
    }

    @Test("an hour skip starting inside the repeated hour terminates, from either pass")
    func dstFallBackHourSkipTerminates() async {
        // `t + 1h` from inside the first pass lands on the same local hour in the new offset, and
        // rebuilding that hour from components resolved it back to the first pass: `t` stopped
        // advancing and the search span forever, wedging the scheduler actor with it.
        for (label, start) in [("PDT", 1_793_521_860), ("PST", 1_793_525_460)] {   // 01:31 in each pass
            let after = Date(timeIntervalSince1970: TimeInterval(start))
            guard let next = await Self.boundedNext(Self.cron("0 9 * * *"), after: after) else {
                Issue.record("next(after:) never returned from the \(label) pass"); return
            }
            #expect(next == Date(timeIntervalSince1970: 1_793_552_400))  // 17:00Z = 2026-11-01 09:00 PST
        }
    }

    @Test("decodes with defaults when fields are absent")
    func lenientDecode() throws {
        let s = try JSONDecoder().decode(CronSchedule.self, from: Data("{}".utf8))
        #expect(s.expression == "* * * * *")
        #expect(TimeZone(identifier: s.timeZone) != nil)
    }
}
