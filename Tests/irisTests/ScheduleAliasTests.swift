import Testing
import Foundation
@testable import iris

@Suite("Schedule aliases (old schedule_job parameters)")
struct ScheduleAliasTests {
    let tz = "America/Los_Angeles"

    @Test("weekdays [2,3,4,5,6] hour 9 → '0 9 * * 1-5' equivalent set")
    func weekdays() throws {
        let s = try ScheduleAlias(minute: 0, hour: 9, weekdays: [2, 3, 4, 5, 6]).resolve(defaultTimeZone: tz).get()
        guard case .cron(let c) = s else { Issue.record("expected cron"); return }
        #expect(c.expression == "0 9 * * 1,2,3,4,5")
        #expect(c.timeZone == tz)
    }

    @Test("single weekday 1 (Sunday) → cron 0; hour without minute → minute 0")
    func sunday() throws {
        let s = try ScheduleAlias(hour: 7, weekday: 1).resolve(defaultTimeZone: tz).get()
        guard case .cron(let c) = s else { Issue.record("expected cron"); return }
        #expect(c.expression == "0 7 * * 0")
    }

    @Test("minute only → hourly; day+month → yearly")
    func partials() throws {
        #expect(try ScheduleAlias(minute: 30).resolve(defaultTimeZone: tz).get() == .cron(CronSchedule(expression: "30 * * * *", timeZone: tz)))
        #expect(try ScheduleAlias(minute: 0, hour: 8, day: 1, month: 4).resolve(defaultTimeZone: tz).get() == .cron(CronSchedule(expression: "0 8 1 4 *", timeZone: tz)))
    }

    @Test("intervalSeconds wins alone; combined with cron fields is conflicting")
    func interval() {
        #expect(ScheduleAlias(intervalSeconds: 120).resolve(defaultTimeZone: tz) == .success(.interval(seconds: 120)))
        #expect(ScheduleAlias(hour: 9, intervalSeconds: 120).resolve(defaultTimeZone: tz) == .failure(.conflicting))
    }

    @Test("intervalSeconds below 1 is an invalid interval, not 'nothing specified'")
    func invalidInterval() {
        #expect(ScheduleAlias(intervalSeconds: 0).resolve(defaultTimeZone: tz) == .failure(.invalidInterval(0)))
        #expect(ScheduleAlias(intervalSeconds: -5).resolve(defaultTimeZone: tz) == .failure(.invalidInterval(-5)))
    }

    @Test("duplicate weekdays collapse: [2,2,3] hour 9 → '0 9 * * 1,2'")
    func duplicateWeekdays() throws {
        let s = try ScheduleAlias(hour: 9, weekdays: [2, 2, 3]).resolve(defaultTimeZone: tz).get()
        guard case .cron(let c) = s else { Issue.record("expected cron"); return }
        #expect(c.expression == "0 9 * * 1,2")
    }

    @Test("explicit cron and timezone pass through; bad ones are reported")
    func explicit() {
        #expect(ScheduleAlias(cron: "*/5 * * * *", timeZone: "Asia/Tokyo").resolve(defaultTimeZone: tz)
                == .success(.cron(CronSchedule(expression: "*/5 * * * *", timeZone: "Asia/Tokyo"))))
        #expect(ScheduleAlias(cron: "* * * *").resolve(defaultTimeZone: tz) == .failure(.badCron(.fieldCount(4))))
        #expect(ScheduleAlias(cron: "* * * * *", timeZone: "Mars/Olympus").resolve(defaultTimeZone: tz) == .failure(.badTimeZone("Mars/Olympus")))
    }

    @Test("nothing specified and invalid weekdays")
    func failures() {
        #expect(ScheduleAlias().resolve(defaultTimeZone: tz) == .failure(.nothingSpecified))
        #expect(ScheduleAlias(hour: 9, weekdays: [0, 8]).resolve(defaultTimeZone: tz) == .failure(.invalidWeekday([0, 8])))
    }

    @Test("alias next fire equals the old semantics: Friday 10:00 → Monday 09:00")
    func parityWithOldWeekdays() throws {
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: tz)!
        let friday = cal.date(from: DateComponents(year: 2026, month: 9, day: 18, hour: 10))!
        let s = try ScheduleAlias(minute: 0, hour: 9, weekdays: [2, 3, 4, 5, 6]).resolve(defaultTimeZone: tz).get()
        #expect(s.next(after: friday) == cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9)))
    }
}
