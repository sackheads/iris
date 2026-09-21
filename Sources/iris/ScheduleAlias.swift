import Foundation

/// Resolves the old `schedule_job` tool's loose parameters (a subset of cron fields, or an
/// explicit cron string, or a plain interval) into a `Schedule`. Kept separate from `Schedule`
/// itself so the aliasing rules — which field wins, what "hour without minute" means, which
/// combinations conflict — live in one place instead of being reverse-engineered from call sites.
struct ScheduleAlias: Equatable, Sendable {
    var minute: Int? = nil
    var hour: Int? = nil
    var day: Int? = nil
    var month: Int? = nil
    var weekday: Int? = nil
    var weekdays: [Int]? = nil
    var intervalSeconds: Int? = nil
    var cron: String? = nil
    var timeZone: String? = nil

    enum Failure: Error, Equatable {
        case nothingSpecified
        case invalidWeekday([Int])
        case invalidInterval(Int)
        case badCron(CronParseError)
        case badTimeZone(String)
        case conflicting
    }

    /// `weekday`/`weekdays` use the old 1=Sunday...7=Saturday convention (Foundation's
    /// `DateComponents.weekday`); cron's day-of-week field is 0=Sunday...6=Saturday, so every value
    /// here is translated by subtracting 1 before it lands in an expression.
    func resolve(defaultTimeZone: String) -> Result<Schedule, Failure> {
        let hasFields = minute != nil || hour != nil || day != nil || month != nil || weekday != nil || !(weekdays ?? []).isEmpty

        if let timeZone, TimeZone(identifier: timeZone) == nil {
            return .failure(.badTimeZone(timeZone))
        }
        let zone = timeZone ?? defaultTimeZone

        if let intervalSeconds {
            if hasFields || cron != nil { return .failure(.conflicting) }
            return intervalSeconds >= 1 ? .success(.interval(seconds: intervalSeconds)) : .failure(.invalidInterval(intervalSeconds))
        }

        if let cron {
            if hasFields { return .failure(.conflicting) }
            if case .failure(let error) = CronSchedule.parse(cron) { return .failure(.badCron(error)) }
            return .success(.cron(CronSchedule(expression: cron, timeZone: zone)))
        }

        guard hasFields else { return .failure(.nothingSpecified) }

        let days = (weekdays?.isEmpty == false ? weekdays! : weekday.map { [$0] } ?? [])
        let bad = days.filter { !(1...7).contains($0) }
        if !bad.isEmpty { return .failure(.invalidWeekday(bad)) }

        let dow = days.isEmpty ? "*" : Array(Set(days.map { $0 - 1 })).sorted().map(String.init).joined(separator: ",")
        let minuteText = String(minute ?? 0)
        // A coarser field without an hour means midnight on those days, not every hour of them:
        // `weekday: 2` alone used to resolve to `0 * * * 1` and fire 24 times every Monday.
        // Minute alone keeps meaning hourly, which is the one case where `*` is what was asked.
        let coarserThanHour = day != nil || month != nil || weekday != nil || !(weekdays ?? []).isEmpty
        let hourText = hour.map(String.init) ?? (coarserThanHour ? "0" : "*")
        let dayText = day.map(String.init) ?? "*"
        let monthText = month.map(String.init) ?? "*"
        let expression = "\(minuteText) \(hourText) \(dayText) \(monthText) \(dow)"

        if case .failure(let error) = CronSchedule.parse(expression) { return .failure(.badCron(error)) }
        return .success(.cron(CronSchedule(expression: expression, timeZone: zone)))
    }
}
