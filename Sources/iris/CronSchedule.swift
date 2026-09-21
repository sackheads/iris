import Foundation

struct CronFields: Equatable, Sendable {
    let minutes: Set<Int>
    let hours: Set<Int>
    let daysOfMonth: Set<Int>
    let months: Set<Int>
    let daysOfWeek: Set<Int>
    let dayOfMonthRestricted: Bool
    let dayOfWeekRestricted: Bool
}

enum CronParseError: Error, Equatable {
    case fieldCount(Int)
    case badToken(field: String, token: String)
    case outOfRange(field: String, value: Int)
}

/// A five-field cron expression (minute hour day-of-month month day-of-week) paired with the
/// IANA time zone it should be evaluated in. Supports `*`, numbers, lists (`a,b`), ranges (`a-b`),
/// and steps (`*/n`, `a-b/n`). Day-of-week accepts 0-7, where both 0 and 7 mean Sunday.
struct CronSchedule: Codable, Equatable, Sendable {
    var expression: String
    var timeZone: String

    init(expression: String, timeZone: String) {
        self.expression = expression
        self.timeZone = timeZone
    }

    enum CodingKeys: String, CodingKey { case expression, timeZone }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        expression = try container.decodeIfPresent(String.self, forKey: .expression) ?? "* * * * *"
        timeZone = try container.decodeIfPresent(String.self, forKey: .timeZone) ?? TimeZone.current.identifier
    }

    /// Search horizon for `next(after:)`. Wide enough to find a schedule that only fires on
    /// February 29th across a full four-year leap cycle, while schedules that never fire at all
    /// (e.g. day-of-month 30 in February) still terminate with `nil`.
    static let maxLookaheadDays = 1_466

    static func parse(_ expression: String) -> Result<CronFields, CronParseError> {
        let parts = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5 else { return .failure(.fieldCount(parts.count)) }

        func field(_ raw: String, _ name: String, _ range: ClosedRange<Int>, mapSeven: Bool = false) -> Result<(Set<Int>, Bool), CronParseError> {
            var out = Set<Int>()
            var restricted = false
            for token in raw.split(separator: ",").map(String.init) {
                let slashParts = token.split(separator: "/", maxSplits: 1).map(String.init)
                let base = slashParts[0]
                let stepText = slashParts.count == 2 ? slashParts[1] : nil

                var step = 1
                if let stepText {
                    guard let s = Int(stepText), s >= 1 else { return .failure(.badToken(field: name, token: token)) }
                    step = s
                }

                var lo = range.lowerBound
                var hi = range.upperBound
                if base == "*" {
                    if stepText != nil { restricted = true }
                } else if base.contains("-") {
                    let bounds = base.split(separator: "-", maxSplits: 1).map(String.init)
                    guard bounds.count == 2, let a = Int(bounds[0]), let z = Int(bounds[1]) else {
                        return .failure(.badToken(field: name, token: token))
                    }
                    for v in [a, z] where !range.contains(v) && !(mapSeven && v == 7) {
                        return .failure(.outOfRange(field: name, value: v))
                    }
                    lo = a; hi = z; restricted = true
                } else {
                    guard let v = Int(base) else { return .failure(.badToken(field: name, token: token)) }
                    guard range.contains(v) || (mapSeven && v == 7) else {
                        return .failure(.outOfRange(field: name, value: v))
                    }
                    lo = v; hi = stepText == nil ? v : range.upperBound; restricted = true
                }
                guard lo <= hi else { return .failure(.badToken(field: name, token: token)) }

                var v = lo
                while v <= hi {
                    out.insert(mapSeven && v == 7 ? 0 : v)
                    v += step
                }
            }
            return .success((out, restricted))
        }

        func unwrap(_ result: Result<(Set<Int>, Bool), CronParseError>) throws -> (Set<Int>, Bool) {
            switch result {
            case .success(let value): return value
            case .failure(let error): throw error
            }
        }

        do {
            let minutes = try unwrap(field(parts[0], "minute", 0...59))
            let hours = try unwrap(field(parts[1], "hour", 0...23))
            let daysOfMonth = try unwrap(field(parts[2], "day-of-month", 1...31))
            let months = try unwrap(field(parts[3], "month", 1...12))
            let daysOfWeek = try unwrap(field(parts[4], "day-of-week", 0...6, mapSeven: true))
            return .success(CronFields(
                minutes: minutes.0, hours: hours.0, daysOfMonth: daysOfMonth.0, months: months.0, daysOfWeek: daysOfWeek.0,
                dayOfMonthRestricted: daysOfMonth.1, dayOfWeekRestricted: daysOfWeek.1))
        } catch let error as CronParseError {
            return .failure(error)
        } catch {
            return .failure(.fieldCount(parts.count))
        }
    }

    /// The next Date strictly after `after` that satisfies the schedule, evaluated in `timeZone`.
    /// Steps a whole minute at a time so DST gaps (a wall-clock time that never occurs, e.g. 02:30
    /// on a spring-forward day) are skipped automatically: no real Date instant ever produces that
    /// local time. Skips whole days/hours that cannot match to stay fast even when the next fire is
    /// a year or more away (e.g. a February 29th-only schedule). Returns nil if nothing matches
    /// within `maxLookaheadDays`.
    func next(after date: Date, calendar base: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        guard case .success(let fields) = Self.parse(expression), let tz = TimeZone(identifier: timeZone) else { return nil }
        var cal = base
        cal.timeZone = tz

        // Truncate to the start of the current minute on the instant itself. Not
        // `date(bySetting:value:of:)`, which searches forward for the next occurrence of a
        // component value and would over-skip when `date` has nonzero seconds — and not a
        // round trip through wall-clock components either: on a DST fall-back day two instants
        // an hour apart share one local time, and rebuilding from components collapses both
        // onto the first, so a `date` inside the second pass would come back an hour early and
        // the search would return a fire at or before it.
        let epoch = date.timeIntervalSince1970
        let flooredToMinute = Date(timeIntervalSince1970: epoch - epoch.truncatingRemainder(dividingBy: 60))
        var t = flooredToMinute.addingTimeInterval(60)
        let limit = date.addingTimeInterval(TimeInterval(Self.maxLookaheadDays) * 86_400)

        while t <= limit {
            let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: t)
            let dow = c.weekday! - 1 // Foundation: 1 = Sunday -> cron: 0 = Sunday
            let domOK = fields.daysOfMonth.contains(c.day!)
            let dowOK = fields.daysOfWeek.contains(dow)
            let dayOK = (fields.dayOfMonthRestricted && fields.dayOfWeekRestricted) ? (domOK || dowOK) : (domOK && dowOK)

            if fields.months.contains(c.month!) && dayOK && fields.hours.contains(c.hour!) && fields.minutes.contains(c.minute!) {
                return t
            }

            if !fields.months.contains(c.month!) || !dayOK {
                let nextDay = cal.date(byAdding: .day, value: 1, to: t)!
                t = cal.date(bySettingHour: 0, minute: 0, second: 0, of: nextDay)!
                continue
            }
            if !fields.hours.contains(c.hour!) {
                // `date(bySetting:value:of:)` searches forward for the next time the single
                // component equals value, which rolls to the *next* hour when the target minute
                // (0) is less than the current one; setting hour/minute/second together truncates
                // within the same hour instead, which is what "start of the next hour" needs.
                let nextHour = cal.date(byAdding: .hour, value: 1, to: t)!
                let hourOfNextHour = cal.component(.hour, from: nextHour)
                t = cal.date(bySettingHour: hourOfNextHour, minute: 0, second: 0, of: nextHour)!
                continue
            }
            t = t.addingTimeInterval(60)
        }
        return nil
    }
}
