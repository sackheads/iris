# Agency Deliverable 1: Job Model, Cron, and Tools — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Replace `ScheduledJob`/`ScheduleManager` and `WatcherRule` with one `Job` model stored in the conversation database, with a cron subset, a per-job time zone, and the two creation tools rewritten to produce jobs, while jobs keep firing exactly as they do today.

**Architecture:** Pure value types (`Job`, `Trigger`, `CronSchedule`) in their own files; one GRDB migration `v8_jobs` that creates both `jobs` and `job_runs` and the two conversation columns (deliverable 2 fills `job_runs`); a `JobLedger` sharing the store's writer; a `JobScheduler` actor that polls the ledger for due jobs and hands them to a fire handler. In this deliverable the handler is today's `handleSystemEvent`, so behaviour is unchanged; deliverable 2 swaps it for the background runner.

**Tech Stack:** Swift 6 strict concurrency, GRDB (`DatabaseMigrator`, `db.create(table:)`), Foundation `Calendar`/`TimeZone`, Swift Testing.

**Spec:** `docs/specs/2026-09-21-agency-model-and-ledger.md` (§3, §4 jobs table, §5, §9 first two tools, §11, §12 cron/alias/ledger tests, §13). Facts about the current code: `.superpowers/briefs/agency-facts.md` in the main checkout.

## Global Constraints

- Every persisted `Codable` type has a hand-written `init(from:)` using `decodeIfPresent` (AGENTS.md invariant 1).
- Tests are Swift Testing; never XCTest. Tests never mutate `ConfigManager.shared` or `IrisDefaults.store`, never touch `~/.iris`, never hit the network (invariant 7). Any `UserDefaults` a test uses is `UserDefaults(suiteName:)` with a unique name, removed in a `defer`.
- Tool declarations and handlers stay in sync (`iris.swift` for `schedule_job`, `ToolExecutor.swift` for `register_directory_watcher`); a description that is no longer true is a bug (invariant 9).
- Cron day-of-week is `0-6`, `0`=Sunday, `7` accepted as Sunday. Tool aliases `weekday`/`weekdays` are `1-7`, `1`=Sunday; `cronDay = weekday - 1`.
- `CronSchedule.next(after:calendar:)` walks minute by minute from `after + 60 s` and returns nil after 366 days.
- The `UserDefaults` keys `iris_scheduled_jobs` and `WATCHER_RULES` are removed on first launch after v8; nothing reads them.
- `swift test; echo exit=$?` = 0 and zero `with [1-9][0-9]* failures` lines before each commit. Conventional commits ending `Co-Authored-By: Claude Fable 5.1 <noreply@anthropic.com>`. Never `git add` anything under `.superpowers/` or `.claude/`.

---

### Task 1: `CronSchedule` — parse and next fire

**Files:**
- Create: `Sources/iris/CronSchedule.swift`
- Test: `Tests/irisTests/CronScheduleTests.swift`

**Interfaces:**
- Produces:
  ```swift
  struct CronSchedule: Codable, Equatable, Sendable {
      var expression: String
      var timeZone: String
      init(expression: String, timeZone: String)
      init(from decoder: Decoder) throws            // decodeIfPresent; defaults "* * * * *", TimeZone.current.identifier
      static func parse(_ expression: String) -> Result<CronFields, CronParseError>
      func next(after date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date?
  }
  struct CronFields: Equatable, Sendable { let minutes, hours, daysOfMonth, months, daysOfWeek: Set<Int>; let dayOfMonthRestricted, dayOfWeekRestricted: Bool }
  enum CronParseError: Error, Equatable { case fieldCount(Int), badToken(field: String, token: String), outOfRange(field: String, value: Int) }
  ```

- [ ] **Step 1: Write the failing tests**

```swift
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
    func parseRejects() {
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

    @Test("gives up after 366 days")
    func giveUp() {
        #expect(Self.cron("0 0 30 2 *").next(after: Self.date(2026, 9, 16, 0, 0)) == nil)
    }

    @Test("decodes with defaults when fields are absent")
    func lenientDecode() throws {
        let s = try JSONDecoder().decode(CronSchedule.self, from: Data("{}".utf8))
        #expect(s.expression == "* * * * *")
        #expect(TimeZone(identifier: s.timeZone) != nil)
    }
}
```

- [ ] **Step 2: Run to verify failure**

Run: `swift test --filter CronScheduleTests 2>&1 | grep -E "error:|✘|✔ Test run" | head`
Expected: compile error, `cannot find 'CronSchedule' in scope`.

- [ ] **Step 3: Implement**

```swift
import Foundation

struct CronFields: Equatable, Sendable {
    let minutes: Set<Int>, hours: Set<Int>, daysOfMonth: Set<Int>, months: Set<Int>, daysOfWeek: Set<Int>
    let dayOfMonthRestricted: Bool, dayOfWeekRestricted: Bool
}

enum CronParseError: Error, Equatable {
    case fieldCount(Int)
    case badToken(field: String, token: String)
    case outOfRange(field: String, value: Int)
}

struct CronSchedule: Codable, Equatable, Sendable {
    var expression: String
    var timeZone: String

    init(expression: String, timeZone: String) { self.expression = expression; self.timeZone = timeZone }

    enum CodingKeys: String, CodingKey { case expression, timeZone }
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        expression = try c.decodeIfPresent(String.self, forKey: .expression) ?? "* * * * *"
        timeZone = try c.decodeIfPresent(String.self, forKey: .timeZone) ?? TimeZone.current.identifier
    }

    static let maxLookaheadDays = 366

    static func parse(_ expression: String) -> Result<CronFields, CronParseError> {
        let parts = expression.split(whereSeparator: { $0 == " " || $0 == "\t" }).map(String.init)
        guard parts.count == 5 else { return .failure(.fieldCount(parts.count)) }
        func field(_ raw: String, _ name: String, _ range: ClosedRange<Int>, mapSeven: Bool = false) -> Result<(Set<Int>, Bool), CronParseError> {
            var out = Set<Int>(); var restricted = false
            for token in raw.split(separator: ",").map(String.init) {
                let (base, stepText) = token.split(separator: "/", maxSplits: 1).map(String.init).count == 2
                    ? (String(token.split(separator: "/", maxSplits: 1)[0]), String(token.split(separator: "/", maxSplits: 1)[1]))
                    : (token, nil as String?)
                var step = 1
                if let stepText { guard let s = Int(stepText), s >= 1 else { return .failure(.badToken(field: name, token: token)) }; step = s }
                var lo = range.lowerBound, hi = range.upperBound
                if base == "*" {
                    if stepText != nil { restricted = true }
                } else if base.contains("-") {
                    let b = base.split(separator: "-", maxSplits: 1).map(String.init)
                    guard b.count == 2, let a = Int(b[0]), let z = Int(b[1]) else { return .failure(.badToken(field: name, token: token)) }
                    for v in [a, z] where !range.contains(v) && !(mapSeven && v == 7) { return .failure(.outOfRange(field: name, value: v)) }
                    lo = a; hi = z; restricted = true
                } else {
                    guard let v = Int(base) else { return .failure(.badToken(field: name, token: token)) }
                    guard range.contains(v) || (mapSeven && v == 7) else { return .failure(.outOfRange(field: name, value: v)) }
                    lo = v; hi = stepText == nil ? v : range.upperBound; restricted = true
                }
                guard lo <= hi else { return .failure(.badToken(field: name, token: token)) }
                var v = lo
                while v <= hi { out.insert(mapSeven && v == 7 ? 0 : v); v += step }
            }
            return .success((out, restricted))
        }
        guard case .success(let mi) = field(parts[0], "minute", 0...59) else { return .failure(errorOf(field(parts[0], "minute", 0...59))) }
        guard case .success(let h) = field(parts[1], "hour", 0...23) else { return .failure(errorOf(field(parts[1], "hour", 0...23))) }
        guard case .success(let dom) = field(parts[2], "day-of-month", 1...31) else { return .failure(errorOf(field(parts[2], "day-of-month", 1...31))) }
        guard case .success(let mo) = field(parts[3], "month", 1...12) else { return .failure(errorOf(field(parts[3], "month", 1...12))) }
        guard case .success(let dow) = field(parts[4], "day-of-week", 0...6, mapSeven: true) else { return .failure(errorOf(field(parts[4], "day-of-week", 0...6, mapSeven: true))) }
        return .success(CronFields(minutes: mi.0, hours: h.0, daysOfMonth: dom.0, months: mo.0, daysOfWeek: dow.0,
                                   dayOfMonthRestricted: dom.1, dayOfWeekRestricted: dow.1))
    }
    private static func errorOf<T>(_ r: Result<T, CronParseError>) -> CronParseError {
        if case .failure(let e) = r { return e }; return .fieldCount(0)
    }

    /// Minute-stepping search in the schedule's zone. nil when nothing matches within 366 days.
    func next(after date: Date, calendar base: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        guard case .success(let f) = Self.parse(expression), let tz = TimeZone(identifier: timeZone) else { return nil }
        var cal = base; cal.timeZone = tz
        // Start at the next whole minute strictly after `date`.
        let floored = cal.date(bySetting: .second, value: 0, of: date) ?? date
        var t = floored.addingTimeInterval(60)
        let limit = date.addingTimeInterval(TimeInterval(Self.maxLookaheadDays) * 86_400)
        while t <= limit {
            let c = cal.dateComponents([.minute, .hour, .day, .month, .weekday], from: t)
            let dow = (c.weekday! - 1)   // Foundation 1=Sun → cron 0=Sun
            let domOK = f.daysOfMonth.contains(c.day!), dowOK = f.daysOfWeek.contains(dow)
            let dayOK: Bool = (f.dayOfMonthRestricted && f.dayOfWeekRestricted) ? (domOK || dowOK) : (domOK && dowOK)
            if f.months.contains(c.month!) && dayOK && f.hours.contains(c.hour!) && f.minutes.contains(c.minute!) {
                return cal.date(bySetting: .second, value: 0, of: t)
            }
            // Skip whole days/hours that cannot match, to keep the worst case cheap.
            if !f.months.contains(c.month!) || !dayOK {
                let startOfNext = cal.date(bySettingHour: 0, minute: 0, second: 0, of: cal.date(byAdding: .day, value: 1, to: t)!)!
                t = startOfNext; continue
            }
            if !f.hours.contains(c.hour!) {
                t = cal.date(bySetting: .minute, value: 0, of: cal.date(byAdding: .hour, value: 1, to: t)!)!; continue
            }
            t = t.addingTimeInterval(60)
        }
        return nil
    }
}
```

Note for the DST test: `Calendar.date(bySettingHour:...)` and minute stepping through real `Date` instants never produce the non-existent 02:30 on the spring-forward day, so the search lands on the next day's 02:30, which the test expects. Verify rather than assume; if the skip-ahead makes the gap test fail, step by 60 s only (drop the hour/day skips) and confirm the month-end test still runs under a second.

- [ ] **Step 4: Run to verify pass**

Run: `swift test --filter CronScheduleTests 2>&1 | grep -E "error:|✘|✔ Test run"`
Expected: `✔ Test run with 10 tests in 1 suite passed`.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/CronSchedule.swift Tests/irisTests/CronScheduleTests.swift
git commit -m "feat(jobs): CronSchedule — five-field cron subset with a per-schedule time zone (#187)"
```

---

### Task 2: `Job`, `Trigger`, and the schedule aliases

**Files:**
- Create: `Sources/iris/Job.swift`, `Sources/iris/ScheduleAlias.swift`
- Test: `Tests/irisTests/JobModelTests.swift`, `Tests/irisTests/ScheduleAliasTests.swift`

**Interfaces:**
- Consumes: `CronSchedule` from Task 1.
- Produces:
  ```swift
  enum JobProfile: String, Codable, Sendable { case readOnly, mutating }
  struct FSWatch: Codable, Equatable, Sendable { var path: String; var quietWindowSeconds: Int /* default 3 */ }
  struct PollSpec: Codable, Equatable, Sendable { var schedule: Schedule; var gate: String }
  enum Schedule: Codable, Equatable, Sendable { case cron(CronSchedule); case interval(seconds: Int)
      func next(after: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? }
  enum Trigger: Codable, Equatable, Sendable { case schedule(Schedule); case fsEvent(FSWatch); case poll(PollSpec)
      var kind: String /* "schedule" | "fsEvent" | "poll" */ }
  struct Job: Identifiable, Codable, Equatable, Sendable {
      let id: UUID; var name: String; var prompt: String; var trigger: Trigger; var profile: JobProfile
      var destinationConversationId: UUID?; var createdInConversationId: UUID?; var createdAt: Date
      var enabled: Bool; var nextFireAt: Date?; var lastRunAt: Date?; var pausedReason: String?
      init(id: UUID = UUID(), name: String, prompt: String, trigger: Trigger, profile: JobProfile = .readOnly,
           destinationConversationId: UUID? = nil, createdInConversationId: UUID? = nil, createdAt: Date = Date(),
           enabled: Bool = true, nextFireAt: Date? = nil, lastRunAt: Date? = nil, pausedReason: String? = nil)
      static func slug(from prompt: String) -> String   // lowercase, [a-z0-9-], first 4 words, max 32 chars, "job" if empty
  }
  struct ScheduleAlias: Equatable, Sendable {
      var minute: Int?, hour: Int?, day: Int?, month: Int?, weekday: Int?, weekdays: [Int]?, intervalSeconds: Int?
      var cron: String?, timeZone: String?
      enum Failure: Error, Equatable { case nothingSpecified, invalidWeekday([Int]), badCron(CronParseError), badTimeZone(String), conflicting }
      func resolve(defaultTimeZone: String) -> Result<Schedule, Failure>
  }
  ```
- `Trigger`/`Schedule` encode as `{"kind": "...", ...}` objects with hand-written `init(from:)`; an unknown `kind` throws `DecodingError.dataCorrupted` (the ledger skips the row, Task 3).

- [ ] **Step 1: Write the failing tests**

`JobModelTests.swift`:
```swift
import Testing
import Foundation
@testable import iris

@Suite("Job model")
struct JobModelTests {
    @Test("round-trips every trigger kind")
    func roundTrip() throws {
        let triggers: [Trigger] = [
            .schedule(.cron(CronSchedule(expression: "0 9 * * 1-5", timeZone: "America/Los_Angeles"))),
            .schedule(.interval(seconds: 90)),
            .fsEvent(FSWatch(path: "/tmp/x", quietWindowSeconds: 3)),
            .poll(PollSpec(schedule: .interval(seconds: 300), gate: "curl -sI https://example.com")),
        ]
        for t in triggers {
            let data = try JSONEncoder().encode(t)
            #expect(try JSONDecoder().decode(Trigger.self, from: data) == t)
        }
        #expect(triggers.map(\.kind) == ["schedule", "schedule", "fsEvent", "poll"])
    }

    @Test("Job decodes with defaults for absent optional fields")
    func lenientJob() throws {
        let json = #"{"id":"6F9619FF-8B86-D011-B42D-00C04FC964FF","name":"n","prompt":"p","trigger":{"kind":"schedule","schedule":{"kind":"interval","seconds":60}},"createdAt":0}"#
        let job = try JSONDecoder().decode(Job.self, from: Data(json.utf8))
        #expect(job.profile == .readOnly)
        #expect(job.enabled == true)
        #expect(job.destinationConversationId == nil && job.nextFireAt == nil && job.pausedReason == nil)
    }

    @Test("unknown trigger kind is a decoding error, not a crash")
    func unknownKind() {
        let json = #"{"kind":"telepathy"}"#
        #expect(throws: DecodingError.self) { try JSONDecoder().decode(Trigger.self, from: Data(json.utf8)) }
    }

    @Test("FSWatch quiet window defaults to 3")
    func fsWatchDefault() throws {
        let w = try JSONDecoder().decode(FSWatch.self, from: Data(#"{"path":"/tmp"}"#.utf8))
        #expect(w.quietWindowSeconds == 3)
    }

    @Test("slug from prompt")
    func slug() {
        #expect(Job.slug(from: "Check the PR queue every morning!") == "check-the-pr-queue")
        #expect(Job.slug(from: "   ") == "job")
        #expect(Job.slug(from: String(repeating: "abcdefghij ", count: 6)).count <= 32)
    }

    @Test("interval schedule next fire is after + seconds")
    func intervalNext() {
        let d = Date(timeIntervalSince1970: 1_000_000)
        #expect(Schedule.interval(seconds: 90).next(after: d) == d.addingTimeInterval(90))
    }
}
```

`ScheduleAliasTests.swift`:
```swift
import Testing
import Foundation
@testable import iris

@Suite("Schedule aliases (old schedule_job parameters)")
struct ScheduleAliasTests {
    let tz = "America/Los_Angeles"

    @Test("weekdays [2,3,4,5,6] hour 9 → '0 9 * * 1-5' equivalent set")
    func weekdays() throws {
        let s = try ScheduleAlias(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6]).resolve(defaultTimeZone: tz).get()
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
        let s = try ScheduleAlias(hour: 9, minute: 0, weekdays: [2, 3, 4, 5, 6]).resolve(defaultTimeZone: tz).get()
        #expect(s.next(after: friday) == cal.date(from: DateComponents(year: 2026, month: 9, day: 21, hour: 9)))
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter "JobModelTests|ScheduleAliasTests"`; expected compile errors for the missing types.

- [ ] **Step 3: Implement**

`Job.swift` — the types from Interfaces. Encoding shape for `Trigger`:
```swift
enum Trigger: Codable, Equatable, Sendable {
    case schedule(Schedule), fsEvent(FSWatch), poll(PollSpec)
    var kind: String { switch self { case .schedule: "schedule"; case .fsEvent: "fsEvent"; case .poll: "poll" } }
    private enum K: String, CodingKey { case kind, schedule, watch, poll }
    func encode(to e: Encoder) throws {
        var c = e.container(keyedBy: K.self); try c.encode(kind, forKey: .kind)
        switch self {
        case .schedule(let s): try c.encode(s, forKey: .schedule)
        case .fsEvent(let w): try c.encode(w, forKey: .watch)
        case .poll(let p): try c.encode(p, forKey: .poll)
        }
    }
    init(from d: Decoder) throws {
        let c = try d.container(keyedBy: K.self)
        switch try c.decodeIfPresent(String.self, forKey: .kind) ?? "" {
        case "schedule": self = .schedule(try c.decode(Schedule.self, forKey: .schedule))
        case "fsEvent": self = .fsEvent(try c.decode(FSWatch.self, forKey: .watch))
        case "poll": self = .poll(try c.decode(PollSpec.self, forKey: .poll))
        case let other: throw DecodingError.dataCorrupted(.init(codingPath: d.codingPath, debugDescription: "unknown trigger kind '\(other)'"))
        }
    }
}
```
`Schedule` uses the same pattern with keys `kind` ("cron"/"interval"), `cron`, `seconds`; `Schedule.next(after:calendar:)` delegates to `CronSchedule.next` or adds the interval. `Job.init(from:)` decodes every optional with `decodeIfPresent`, `profile` defaulting to `.readOnly`, `enabled` to `true`, `createdAt` to `Date(timeIntervalSince1970: 0)` when absent. `Job.slug(from:)`: lowercase, replace non `[a-z0-9]` runs with `-`, trim `-`, take the first four `-`-separated words, cut to 32 characters trimming a trailing `-`, `"job"` if empty.

`ScheduleAlias.swift`:
```swift
struct ScheduleAlias: Equatable, Sendable {
    var minute: Int? = nil, hour: Int? = nil, day: Int? = nil, month: Int? = nil
    var weekday: Int? = nil, weekdays: [Int]? = nil, intervalSeconds: Int? = nil
    var cron: String? = nil, timeZone: String? = nil
    enum Failure: Error, Equatable { case nothingSpecified, invalidWeekday([Int]), badCron(CronParseError), badTimeZone(String), conflicting }

    func resolve(defaultTimeZone: String) -> Result<Schedule, Failure> {
        let hasFields = minute != nil || hour != nil || day != nil || month != nil || weekday != nil || !(weekdays ?? []).isEmpty
        if let tz = timeZone, TimeZone(identifier: tz) == nil { return .failure(.badTimeZone(tz)) }
        let zone = timeZone ?? defaultTimeZone
        if let interval = intervalSeconds {
            if hasFields || cron != nil { return .failure(.conflicting) }
            return interval >= 1 ? .success(.interval(seconds: interval)) : .failure(.nothingSpecified)
        }
        if let cron {
            if hasFields { return .failure(.conflicting) }
            if case .failure(let e) = CronSchedule.parse(cron) { return .failure(.badCron(e)) }
            return .success(.cron(CronSchedule(expression: cron, timeZone: zone)))
        }
        guard hasFields else { return .failure(.nothingSpecified) }
        let days = (weekdays?.isEmpty == false ? weekdays! : weekday.map { [$0] } ?? [])
        let bad = days.filter { !(1...7).contains($0) }
        if !bad.isEmpty { return .failure(.invalidWeekday(bad)) }
        let dow = days.isEmpty ? "*" : Array(Set(days.map { $0 - 1 })).sorted().map(String.init).joined(separator: ",")
        let minuteText = String(minute ?? 0)
        let hourText = hour.map(String.init) ?? "*"
        let expr = "\(minuteText) \(hourText) \(day.map(String.init) ?? "*") \(month.map(String.init) ?? "*") \(dow)"
        if case .failure(let e) = CronSchedule.parse(expr) { return .failure(.badCron(e)) }
        return .success(.cron(CronSchedule(expression: expr, timeZone: zone)))
    }
}
```
Note the `minute` rule: when any alias field is present and `minute` is nil, minute is `0` (that is what the old `DateComponents` matching did in practice for hourly jobs it was given an hour for). `minute` alone gives `"30 * * * *"`.

- [ ] **Step 4: Run to verify pass** — `swift test --filter "JobModelTests|ScheduleAliasTests"`; expected 13 tests pass.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/Job.swift Sources/iris/ScheduleAlias.swift Tests/irisTests/JobModelTests.swift Tests/irisTests/ScheduleAliasTests.swift
git commit -m "feat(jobs): Job and Trigger model with lenient decoding; schedule_job parameter aliases resolve to cron (#187)"
```

---

### Task 3: Migration `v8_jobs` and `JobLedger` (jobs half)

**Files:**
- Modify: `Sources/iris/ConversationStore.swift` (migrator after `v7_archive` ~:334-339; `init(writer:path:)` ~:163; add `let ledger: JobLedger`)
- Create: `Sources/iris/JobLedger.swift`
- Test: `Tests/irisTests/JobLedgerTests.swift`

**Interfaces:**
- Consumes: `Job`, `Trigger` (Task 2).
- Produces:
  ```swift
  final class JobLedger: Sendable {
      init(writer: any DatabaseWriter)
      func upsert(_ job: Job) throws
      func delete(jobId: UUID) throws
      func jobs() throws -> [Job]                       // enabled and disabled, by createdAt
      func job(named: String) throws -> Job?
      func dueJobs(at now: Date) throws -> [Job]        // enabled, nextFireAt != nil, nextFireAt <= now, ordered by nextFireAt
      func setNextFire(jobId: UUID, at: Date?, lastRunAt: Date?) throws
      func setPaused(jobId: UUID, reason: String?) throws
      var unreadableJobCount: Int { get }               // rows skipped by the last jobs() call
  }
  // ConversationStore: `let ledger: JobLedger`
  ```
- The migration also creates `job_runs` exactly as spec §4 and adds `isBackground`/`isPinned` to `conversations`; Task 3 does not use them beyond the migration test.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
import GRDB
@testable import iris

@Suite("JobLedger")
struct JobLedgerTests {
    func makeJob(_ name: String, next: Date? = nil) -> Job {
        Job(name: name, prompt: "p \(name)", trigger: .schedule(.interval(seconds: 60)), nextFireAt: next)
    }

    @Test("upsert, list, fetch by name, delete")
    func crud() throws {
        let store = try ConversationStore.inMemory()
        var a = makeJob("a"); try store.ledger.upsert(a)
        try store.ledger.upsert(makeJob("b"))
        #expect(try store.ledger.jobs().map(\.name) == ["a", "b"])
        a.prompt = "changed"; try store.ledger.upsert(a)
        #expect(try store.ledger.job(named: "a")?.prompt == "changed")
        try store.ledger.delete(jobId: a.id)
        #expect(try store.ledger.jobs().map(\.name) == ["b"])
    }

    @Test("name is unique: a second job with the same name and a different id fails")
    func uniqueName() throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(makeJob("dup"))
        #expect(throws: (any Error).self) { try store.ledger.upsert(makeJob("dup")) }
    }

    @Test("dueJobs is inclusive at the boundary, skips disabled and nil nextFireAt, orders by nextFireAt")
    func due() throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        try store.ledger.upsert(makeJob("late", next: now.addingTimeInterval(-10)))
        try store.ledger.upsert(makeJob("exact", next: now))
        try store.ledger.upsert(makeJob("future", next: now.addingTimeInterval(1)))
        var off = makeJob("off", next: now.addingTimeInterval(-100)); off.enabled = false; try store.ledger.upsert(off)
        try store.ledger.upsert(makeJob("never"))
        #expect(try store.ledger.dueJobs(at: now).map(\.name) == ["late", "exact"])
    }

    @Test("setNextFire and setPaused update only their columns")
    func updates() throws {
        let store = try ConversationStore.inMemory()
        let j = makeJob("j"); try store.ledger.upsert(j)
        let t = Date(timeIntervalSince1970: 2_000_000)
        try store.ledger.setNextFire(jobId: j.id, at: t, lastRunAt: t.addingTimeInterval(-5))
        try store.ledger.setPaused(jobId: j.id, reason: "why")
        let back = try store.ledger.job(named: "j")!
        #expect(back.nextFireAt == t && back.lastRunAt == t.addingTimeInterval(-5) && back.pausedReason == "why" && back.prompt == "p j")
    }

    @Test("a row with an unreadable trigger is skipped and counted, not fatal")
    func unreadableRow() throws {
        let store = try ConversationStore.inMemory()
        try store.ledger.upsert(makeJob("good"))
        try store.writer.write { db in
            try db.execute(sql: "INSERT INTO jobs (id, name, prompt, triggerKind, trigger, createdAt) VALUES (?, ?, ?, ?, ?, ?)",
                           arguments: [UUID().uuidString, "bad", "p", "schedule", "{\"kind\":\"telepathy\"}", Date()])
        }
        #expect(try store.ledger.jobs().map(\.name) == ["good"])
        #expect(store.ledger.unreadableJobCount == 1)
    }

    @Test("v7 database migrates to v8 with conversations intact and new columns reading false")
    func migrateFromV7() throws {
        let queue = try DatabaseQueue()
        try ConversationStore.migrator.migrate(queue, upTo: "v7_archive")
        try queue.write { db in
            try db.execute(sql: "INSERT INTO conversations (id, position, title, createdAt, updatedAt, tokenUsage) VALUES (?, 0, 'old', ?, ?, '{}')",
                           arguments: [UUID().uuidString, Date(), Date()])
        }
        try ConversationStore.migrator.migrate(queue)
        let (count, bg, pinned, tables) = try queue.read { db -> (Int, Bool?, Bool?, Set<String>) in
            let row = try Row.fetchOne(db, sql: "SELECT isBackground, isPinned FROM conversations")!
            let names = try String.fetchSet(db, sql: "SELECT name FROM sqlite_master WHERE type='table'")
            return (try Int.fetchOne(db, sql: "SELECT count(*) FROM conversations")!, row["isBackground"], row["isPinned"], names)
        }
        #expect(count == 1 && bg == nil && pinned == nil)
        #expect(tables.isSuperset(of: ["jobs", "job_runs"]))
    }
}
```
If `store.writer` is private, add `internal var writerForTests: any DatabaseWriter { writer }` guarded by a comment, or insert through a `JobLedger` test seam — prefer exposing `writer` as `internal` (it is `let`).

- [ ] **Step 2: Run to verify failure** — `swift test --filter JobLedgerTests`; expected `no member 'ledger'`.

- [ ] **Step 3: Implement**

Migration, appended before `return m` in `ConversationStore.migrator`:
```swift
        // #187 deliverables 1–2: jobs and their run ledger live beside the conversations they
        // produce. Both tables are created here so deliverable 2 needs no second migration; the
        // two conversation columns are nullable so NULL reads back as false for every existing row.
        m.registerMigration("v8_jobs") { db in
            try db.create(table: "jobs") { t in
                t.column("id", .text).primaryKey()
                t.column("name", .text).notNull().unique()
                t.column("prompt", .text).notNull()
                t.column("triggerKind", .text).notNull()
                t.column("trigger", .text).notNull()
                t.column("profile", .text).notNull().defaults(to: "readOnly")
                t.column("destinationConversationId", .text)
                t.column("createdInConversationId", .text)
                t.column("createdAt", .datetime).notNull()
                t.column("enabled", .boolean).notNull().defaults(to: true)
                t.column("nextFireAt", .datetime)
                t.column("lastRunAt", .datetime)
                t.column("pausedReason", .text)
            }
            try db.create(index: "jobs_due", on: "jobs", columns: ["enabled", "nextFireAt"])
            try db.create(table: "job_runs") { t in
                t.column("id", .text).primaryKey()
                t.column("jobId", .text).notNull().references("jobs", onDelete: .cascade)
                t.column("jobName", .text).notNull()
                t.column("triggerKind", .text).notNull()
                t.column("startedAt", .datetime).notNull()
                t.column("finishedAt", .datetime)
                t.column("status", .text).notNull()
                t.column("outcome", .text)
                t.column("failureReason", .text)
                t.column("blockedTool", .text)
                t.column("promptTokens", .integer).notNull().defaults(to: 0)
                t.column("candidateTokens", .integer).notNull().defaults(to: 0)
                t.column("totalTokens", .integer).notNull().defaults(to: 0)
                t.column("costMicros", .integer)
                t.column("gateSignal", .text)
                t.column("transcriptConversationId", .text)
                t.column("acknowledgedAt", .datetime)
            }
            try db.create(index: "job_runs_by_job", on: "job_runs", columns: ["jobId", "startedAt"])
            try db.create(index: "job_runs_open", on: "job_runs", columns: ["status", "acknowledgedAt"])
            try db.alter(table: "conversations") { t in
                t.add(column: "isBackground", .boolean)
                t.add(column: "isPinned", .boolean)
            }
        }
```
`init(writer:path:)` gains `self.ledger = JobLedger(writer: writer)` after migration. `JobLedger` stores rows with `Job` scalar columns and `trigger` as JSON (`JSONEncoder` with `.sortedKeys`); `jobs()` decodes each row inside a `do/catch`, counting failures into a `Mutex<Int>` (or `OSAllocatedUnfairLock`) exposed as `unreadableJobCount`, and logging once per call `"[JobLedger] skipped \(n) unreadable job row(s)"`. `upsert` uses `INSERT ... ON CONFLICT(id) DO UPDATE SET ...` so a rename collision surfaces as the UNIQUE error the test expects. Dates go through GRDB's native `Date` support (the store already stores `createdAt` that way).

- [ ] **Step 4: Run to verify pass** — `swift test --filter "JobLedgerTests|ConversationStore"`; expected all pass, including the existing store suites.

- [ ] **Step 5: Commit**

```bash
git add Sources/iris/ConversationStore.swift Sources/iris/JobLedger.swift Tests/irisTests/JobLedgerTests.swift
git commit -m "feat(store): migration v8_jobs — jobs and job_runs tables, isBackground/isPinned columns; JobLedger (#187)"
```

---

### Task 4: `JobScheduler` replaces `ScheduleManager`

**Files:**
- Create: `Sources/iris/JobScheduler.swift`
- Modify: `Sources/iris/iris.swift:145-148` (start wiring), `Sources/iris/AppState.swift` (expose `store.ledger`; nothing else)
- Delete: `Sources/iris/ScheduleManager.swift`, `Tests/irisTests/ScheduledJobWeekdaysTests.swift`
- Test: `Tests/irisTests/JobSchedulerTests.swift`

**Interfaces:**
- Consumes: `JobLedger`, `Job`, `Schedule.next(after:calendar:)`.
- Produces:
  ```swift
  actor JobScheduler {
      typealias FireHandler = @Sendable (Job, _ reason: String) async -> Void
      init(ledger: JobLedger, now: @escaping @Sendable () -> Date = Date.init, maxFiresPerTick: Int = 3)
      func setFireHandler(_ handler: @escaping FireHandler)
      func tick() async -> Int              // fires due jobs (capped), returns how many fired
      func start(interval: TimeInterval = 10) // polling loop + didWakeNotification observer
      func stop()
      func schedule(_ job: Job) async throws -> Job   // computes nextFireAt for schedule triggers, upserts, returns the stored job
      static func removeLegacyDefaults(from store: UserDefaults)   // deletes iris_scheduled_jobs and WATCHER_RULES
  }
  ```
- `tick()` order: fetch due → for each of the first `maxFiresPerTick`: compute next via `Schedule.next(after: now)`; if nil → `setPaused(reason: "no matching time in the next year")` and `setNextFire(at: nil)`; else `setNextFire(at: next, lastRunAt: now)` **before** calling the handler, so a crash mid-fire cannot double-fire. Jobs already firing (an in-memory `Set<UUID>` cleared when the handler returns) are skipped — the spec's `skip` overlap policy; the ledger row for a skip is deliverable 2's.

- [ ] **Step 1: Write the failing tests**

```swift
import Testing
import Foundation
@testable import iris

@Suite("JobScheduler")
struct JobSchedulerTests {
    final class Fired: @unchecked Sendable { var names: [String] = []; let lock = NSLock()
        func add(_ n: String) { lock.lock(); names.append(n); lock.unlock() } }

    func scheduler(_ store: ConversationStore, now: Date, cap: Int = 3) -> (JobScheduler, Fired) {
        let fired = Fired()
        let s = JobScheduler(ledger: store.ledger, now: { now }, maxFiresPerTick: cap)
        return (s, fired)
    }

    @Test("a due interval job fires once and is rescheduled from now")
    func firesAndReschedules() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, fired) = scheduler(store, now: now)
        await s.setFireHandler { job, _ in fired.add(job.name) }
        try store.ledger.upsert(Job(name: "j", prompt: "p", trigger: .schedule(.interval(seconds: 300)), nextFireAt: now.addingTimeInterval(-1)))
        #expect(await s.tick() == 1)
        #expect(fired.names == ["j"])
        #expect(try store.ledger.job(named: "j")?.nextFireAt == now.addingTimeInterval(300))
        #expect(await s.tick() == 0)
    }

    @Test("at most maxFiresPerTick jobs start per tick; the rest wait")
    func cap() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, fired) = scheduler(store, now: now, cap: 2)
        await s.setFireHandler { job, _ in fired.add(job.name) }
        for n in ["a", "b", "c", "d"] {
            try store.ledger.upsert(Job(name: n, prompt: "p", trigger: .schedule(.interval(seconds: 3600)), nextFireAt: now.addingTimeInterval(-10)))
        }
        #expect(await s.tick() == 2)
        #expect(await s.tick() == 2)
        #expect(Set(fired.names) == ["a", "b", "c", "d"])
    }

    @Test("a cron job with no match in a year is paused with a reason")
    func pausesUnmatchable() async throws {
        let store = try ConversationStore.inMemory()
        let now = Date(timeIntervalSince1970: 1_000_000)
        let (s, _) = scheduler(store, now: now)
        let job = Job(name: "never", prompt: "p", trigger: .schedule(.cron(CronSchedule(expression: "0 0 30 2 *", timeZone: "UTC"))), nextFireAt: now)
        try store.ledger.upsert(job)
        _ = await s.tick()
        let back = try store.ledger.job(named: "never")!
        #expect(back.pausedReason == "no matching time in the next year" && back.nextFireAt == nil)
    }

    @Test("schedule(_:) computes the first fire for a cron job")
    func scheduleComputesNext() async throws {
        let store = try ConversationStore.inMemory()
        var cal = Calendar(identifier: .gregorian); cal.timeZone = TimeZone(identifier: "UTC")!
        let now = cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 8))!
        let (s, _) = scheduler(store, now: now)
        let stored = try await s.schedule(Job(name: "nine", prompt: "p", trigger: .schedule(.cron(CronSchedule(expression: "0 9 * * *", timeZone: "UTC")))))
        #expect(stored.nextFireAt == cal.date(from: DateComponents(year: 2026, month: 9, day: 16, hour: 9)))
    }

    @Test("legacy defaults keys are removed")
    func legacyKeys() {
        let name = "iris-tests-legacy-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        defer { defaults.removePersistentDomain(forName: name) }
        defaults.set(Data("[]".utf8), forKey: "iris_scheduled_jobs")
        defaults.set(Data("[]".utf8), forKey: "WATCHER_RULES")
        JobScheduler.removeLegacyDefaults(from: defaults)
        #expect(defaults.data(forKey: "iris_scheduled_jobs") == nil && defaults.data(forKey: "WATCHER_RULES") == nil)
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter JobSchedulerTests`; expected `cannot find 'JobScheduler'`.

- [ ] **Step 3: Implement**

`JobScheduler.swift` per Interfaces. `start(interval:)` mirrors the old loop: a stored `Task` sleeping `interval` seconds between `tick()`s, plus `NotificationCenter.default.addObserver(forName: NSWorkspace.didWakeNotification, object: nil, queue: nil)` whose closure spawns `Task { await self.tick() }`; `stop()` cancels the task and removes the observer. `removeLegacyDefaults` calls `removeObject(forKey:)` for both keys.

`iris.swift` start wiring becomes:
```swift
        JobScheduler.removeLegacyDefaults(from: IrisDefaults.store)
        let scheduler = await MainActor.run { JobScheduler(ledger: localState.store.ledger) }
        await scheduler.setFireHandler { [weak self] job, reason in
            // Deliverable 1: unchanged behaviour — a fire is a system event in the job's creating
            // conversation, or the selected one. Deliverable 2 replaces this with JobRunner.
            await self?.handleSystemEvent("Scheduled Job Triggered: \(job.prompt)", source: "Scheduler",
                                          conversationId: job.createdInConversationId)
        }
        await scheduler.start()
        self.jobScheduler = scheduler
```
(`IrisEngine` gets `private(set) var jobScheduler: JobScheduler?`; Task 5's tool handler uses it.) Delete `ScheduleManager.swift` and `ScheduledJobWeekdaysTests.swift`; fix every remaining reference (`grep -rn "ScheduleManager\|ScheduledJob" Sources Tests` must be empty except the handler Task 5 rewrites — leave the handler compiling by temporarily routing it through `jobScheduler.schedule` with the alias resolver, which Task 5 finishes).

- [ ] **Step 4: Run to verify pass** — full `swift test; echo exit=$?` (the deletion touches the whole target); expected 0.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/iris Tests/irisTests
git status --short   # confirm nothing under .superpowers/ or .claude/ is staged
git commit -m "feat(jobs): JobScheduler polls the ledger for due jobs; ScheduleManager and the legacy defaults are gone (#187)"
```

---

### Task 5: The two creation tools write jobs; watchers read jobs

**Files:**
- Modify: `Sources/iris/iris.swift:615-632` (declaration) and `:1330-1368` (handler); `Sources/iris/ToolExecutor.swift:61-72` (declaration), `:153-157` (handler); `Sources/iris/WatcherManager.swift` (rules come from the ledger)
- Create: `Sources/iris/ScheduleJobArguments.swift`
- Test: `Tests/irisTests/ScheduleJobArgumentsTests.swift`, `Tests/irisTests/WatcherJobsTests.swift`

**Interfaces:**
- Consumes: `ScheduleAlias`, `Job`, `JobScheduler.schedule(_:)`, `JobLedger`.
- Produces:
  ```swift
  struct ScheduleJobArguments: Equatable, Sendable {
      let prompt: String; let name: String?; let alias: ScheduleAlias; let profile: String?
      static func parse(_ args: [String: JSONValue]) -> Result<ScheduleJobArguments, String>  // String = message for the model
      func makeJob(defaultTimeZone: String, createdIn: UUID?, existingNames: Set<String>) -> Result<Job, String>
  }
  // WatcherManager: init(ledger:) ; func reload() async  (starts a FileWatcher per enabled .fsEvent job) ; func setCallback(_ : @Sendable (Job, [String]) async -> Void)
  ```

- [ ] **Step 1: Write the failing tests**

`ScheduleJobArgumentsTests.swift`:
```swift
import Testing
import Foundation
@testable import iris

@Suite("schedule_job arguments")
struct ScheduleJobArgumentsTests {
    @Test("old-style arguments still parse; numbers may arrive as strings or doubles")
    func oldStyle() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("stand-up"), "hour": .string("9"), "minute": .double(30), "weekdays": .array([.int(2), .string("3")])]).get()
        #expect(a.alias == ScheduleAlias(minute: 30, hour: 9, weekdays: [2, 3]))
        #expect(a.name == nil && a.profile == nil)
    }

    @Test("new-style cron + timezone + name")
    func newStyle() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("p"), "cron": .string("*/5 * * * *"), "timezone": .string("Asia/Tokyo"), "name": .string("Five Min")]).get()
        #expect(a.alias.cron == "*/5 * * * *" && a.alias.timeZone == "Asia/Tokyo" && a.name == "Five Min")
    }

    @Test("missing prompt and mutating profile are refused with a message")
    func refusals() {
        #expect(ScheduleJobArguments.parse(["hour": .int(9)]) == .failure("schedule_job needs a prompt."))
        let a = try? ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9), "profile": .string("mutating")]).get()
        #expect(a?.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []) == .failure("mutating jobs arrive with deliverable 3; create the job without a profile to run it read-only."))
    }

    @Test("name is slugged and made unique against existing names")
    func naming() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("Check the PR queue"), "hour": .int(9)]).get()
        let j1 = try a.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []).get()
        #expect(j1.name == "check-the-pr-queue")
        let j2 = try a.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: ["check-the-pr-queue"]).get()
        #expect(j2.name == "check-the-pr-queue-2")
        let named = try ScheduleJobArguments.parse(["prompt": .string("p"), "hour": .int(9), "name": .string("My Job!")]).get()
        #expect(try named.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []).get().name == "my-job")
    }

    @Test("alias failures become model-readable messages")
    func aliasFailure() throws {
        let a = try ScheduleJobArguments.parse(["prompt": .string("p"), "weekdays": .array([.int(9)]), "hour": .int(9)]).get()
        #expect(a.makeJob(defaultTimeZone: "UTC", createdIn: nil, existingNames: []) == .failure("Invalid weekday value(s) 9: use 1-7 with 1 = Sunday, or a cron expression."))
    }
}
```

`WatcherJobsTests.swift` (no FSEvents; tests the ledger-to-watcher mapping only):
```swift
import Testing
import Foundation
@testable import iris

@Suite("Watcher jobs")
struct WatcherJobsTests {
    @Test("reload starts one watcher per enabled fsEvent job and none for schedules or disabled jobs")
    func reload() async throws {
        let store = try ConversationStore.inMemory()
        let tmp = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: tmp) }
        try store.ledger.upsert(Job(name: "w1", prompt: "i", trigger: .fsEvent(FSWatch(path: tmp.path, quietWindowSeconds: 3))))
        var off = Job(name: "w2", prompt: "i", trigger: .fsEvent(FSWatch(path: tmp.path + "/b", quietWindowSeconds: 3))); off.enabled = false
        try store.ledger.upsert(off)
        try store.ledger.upsert(Job(name: "s", prompt: "i", trigger: .schedule(.interval(seconds: 60))))
        let wm = WatcherManager(ledger: store.ledger)
        await wm.reload()
        #expect(await wm.activeJobIds.count == 1)
        await wm.stopAll()
    }
}
```

- [ ] **Step 2: Run to verify failure** — `swift test --filter "ScheduleJobArgumentsTests|WatcherJobsTests"`; expected missing-type errors.

- [ ] **Step 3: Implement**

`ScheduleJobArguments.parse`: `prompt` required (`.stringValue` non-empty); integers accepted from `.int`, `.double` (truncated), or numeric `.string`; `weekdays` from `.array` of the same; `name`, `cron`, `timezone`, `profile` as strings. `makeJob`: refuse `profile == "mutating"` with the exact message above; resolve the alias with `defaultTimeZone`; map `ScheduleAlias.Failure` to messages (`nothingSpecified` → "Give a schedule: cron, intervalSeconds, or hour/minute/weekdays."; `invalidWeekday(v)` → the message in the test; `badCron(e)` → "Cron expression rejected: \(e)"; `badTimeZone(z)` → "Unknown time zone '\(z)'."; `conflicting` → "Use one of: cron, intervalSeconds, or the hour/minute/day/month/weekday fields."); name = `Job.slug(from: name ?? prompt)` made unique with `-2`, `-3`, ….

Handler in `iris.swift` (replacing 1330–1368):
```swift
        } else if functionCall.name == "schedule_job" {
            switch ScheduleJobArguments.parse(functionCall.args) {
            case .failure(let message): result = message
            case .success(let args):
                let existing = Set((try? await MainActor.run { try localState?.store.ledger.jobs().map(\.name) }) ?? [])
                switch args.makeJob(defaultTimeZone: TimeZone.current.identifier, createdIn: conversationId, existingNames: existing) {
                case .failure(let message): result = message
                case .success(let job):
                    do {
                        let stored = try await jobScheduler?.schedule(job) ?? job
                        result = "Scheduled '\(stored.name)' (\(stored.trigger.summary)). Next run: \(stored.nextFireAt.map { Self.formatFire($0, zone: stored.trigger.timeZoneIdentifier) } ?? "none")."
                    } catch { result = "Could not save the job: \(error.localizedDescription)" }
                }
            }
        }
```
`Trigger.summary` ("cron 0 9 * * 1-5 America/Los_Angeles", "every 90 s", "watch /path") and `timeZoneIdentifier` are small computed properties on `Trigger` added in `Job.swift`. Declaration: parameters `prompt` (required), `name`, `cron`, `timezone`, `intervalSeconds`, `minute`, `hour`, `day`, `month`, `weekday`, `weekdays`; description: "Create a recurring job. Give a cron expression (five fields: minute hour day-of-month month day-of-week, 0 = Sunday) with an optional IANA timezone, or intervalSeconds, or hour/minute/weekdays (1 = Sunday … 7 = Saturday). The job persists across restarts; a job that was due while the app was asleep runs once on wake. Jobs run read-only." Example sentence: "every weekday at 9 → cron '0 9 * * 1-5'".

`register_directory_watcher` handler in `ToolExecutor.swift`: build `Job(name: Job.slug(from: URL(fileURLWithPath: watchPath).lastPathComponent), prompt: instructions, trigger: .fsEvent(FSWatch(path: watchPath, quietWindowSeconds: 3)), createdInConversationId: conversationId)`, make the name unique, `upsert`, then `await WatcherManager.shared.reload()`. `ToolExecutor` reaches the ledger through a new `var ledgerProvider: @Sendable () async -> JobLedger?` set by the engine at start (default nil → returns "Jobs are not available yet."). Description updated to say it creates a job that runs in the background.

`WatcherManager`: `init(ledger:)`; `shared` becomes `static var shared: WatcherManager!` set by the engine at start (or keep a `configure(ledger:)` on the existing singleton — pick the smaller diff and say which in the report); `reload()` stops all, then for each `ledger.jobs()` with `enabled` and `.fsEvent` starts a `FileWatcher` and stores it in `activeWatchers[job.id]`; `activeJobIds: [UUID]`; the change callback becomes `(Job, [String])` and the engine's start wiring passes it to `handleSystemEvent("System Event: Files modified at \(paths.joined(separator: ", ")).\nYour standing instructions for this event are: \(job.prompt)\nAnalyze the event and take action silently or acknowledge it if necessary.", source: "FileWatcher", conversationId: job.createdInConversationId)` — same text as today, now with the creating conversation as the target. `WatcherRule`, `addRule`, `removeRule`, `saveRules`, and the `WATCHER_RULES` read are deleted.

- [ ] **Step 4: Run to verify pass** — full `swift test; echo exit=$?` = 0; `grep -rn "WatcherRule\|ScheduleManager\|ScheduledJob\|iris_scheduled_jobs\|WATCHER_RULES" Sources Tests` returns only `JobScheduler.removeLegacyDefaults` and its test.

- [ ] **Step 5: Commit**

```bash
git add -A Sources/iris Tests/irisTests
git commit -m "feat(jobs): schedule_job and register_directory_watcher create jobs; watchers read the ledger (#187)"
```

---

### Task 6: Documentation

**Files:**
- Modify: `README.md` (bullets ~:20, ~:25, ~:40, tool entry ~:88), `docs/agency/agency.md` (deliverable 1 line), `docs/prompt_injection_guard_design.md:11` (check only)
- Create: `docs/jobs.md`

- [ ] **Step 1: Falsify the docs** — `grep -n "schedule_job\|FSEventStream\|didWake\|catch-up\|catches up\|watcher" README.md docs/*.md` and list every sentence that is no longer true.

- [ ] **Step 2: Rewrite** — README: one "Jobs" bullet: jobs are created with `schedule_job` (cron with a time zone, or an interval) or `register_directory_watcher`, stored in the conversation database, and run in the background; a job due during sleep runs once on wake. Remove the wake-notification "guarantee" wording. `docs/jobs.md`: the cron subset with examples, the aliases table (old parameter → cron), profiles (read-only now, mutating with deliverable 3), where jobs are stored, what happens on sleep, and a pointer to the ledger and cards as "deliverable 2". `docs/agency/agency.md` deliverable 1: append "— landed: PR #<this PR>, see `docs/specs/2026-09-21-agency-model-and-ledger.md`". Confirm the trusted-tools sentence in `docs/prompt_injection_guard_design.md` is still true (it is: the tool still exists and is still tier-1-capped).

- [ ] **Step 3: Build and full suite** — `swift build 2>&1 | grep -c warning:` unchanged from `main`; `swift test; echo exit=$?` = 0.

- [ ] **Step 4: Commit**

```bash
git add README.md docs/jobs.md docs/agency/agency.md
git commit -m "docs(jobs): the job model, cron subset and aliases; retire the wake-catch-up wording (#187)"
```

---

## Self-review

- **Spec coverage (D1 slice):** §3 types → Task 2; §3.1 cron and aliases → Tasks 1–2; §3.2 profile refusal → Task 5; §4 tables and ledger job methods → Task 3 (run methods are D2); §5 polling, cap, pause-on-unmatchable, legacy key removal → Task 4 (overlap ledger row and watcher quiet window are D2/D4 by the spec); §9 first two tools → Task 5; §11 removals → Tasks 4–5; §12 cron/alias/ledger/migration tests → Tasks 1–3; §13 docs → Task 6. Not in this plan by design: everything under D2 (`job_runs` writes, `isBackground` runs, cards, `/jobs`, retention).
- **Placeholders:** none; every step has code or an exact command.
- **Type consistency:** `Schedule.next(after:calendar:)` (Task 2) is what `JobScheduler` (Task 4) calls; `JobLedger.setNextFire(jobId:at:lastRunAt:)` and `setPaused(jobId:reason:)` (Task 3) match Task 4's use; `ScheduleAlias.Failure` cases (Task 2) match the messages in Task 5; `Trigger.summary`/`timeZoneIdentifier` are introduced in Task 5 and live in `Job.swift`.
