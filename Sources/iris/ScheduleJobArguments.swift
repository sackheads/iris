import Foundation

/// A refusal the model is meant to read, carried as the failure half of a `Result`. It is a type
/// rather than a bare `String` because `Result`'s failure must be an `Error`, and conforming
/// `String` to `Error` module-wide to get that would make every string in the app throwable.
/// `ExpressibleByStringInterpolation` keeps the construction sites reading like the sentences they
/// are, here and in the tests that pin them.
struct ToolMessage: Error, Equatable, Sendable, ExpressibleByStringInterpolation, CustomStringConvertible {
    let text: String

    init(_ text: String) { self.text = text }
    init(stringLiteral value: String) { self.text = value }

    var description: String { text }
}

/// Everything `schedule_job` accepts, parsed once into a shape the job machinery understands.
///
/// The tool's arguments arrive from a model, so they are loose in two directions: the same number
/// can turn up as `.int`, `.double`, or a numeric `.string` depending on the provider, and the
/// schedule itself can be expressed as a cron string, an interval, or a handful of cron fields.
/// Parsing lives here rather than in the handler so both the shape-fixing and the refusal
/// sentences can be tested without a conversation, an engine, or a database.
struct ScheduleJobArguments: Equatable, Sendable {
    let prompt: String
    let name: String?
    let alias: ScheduleAlias
    let profile: String?

    /// Reads the tool call's arguments. The only hard requirement is a prompt: a schedule that
    /// resolves to nothing is `makeJob`'s refusal, not this one, so the caller can report the
    /// specific thing that was wrong with the cadence rather than "bad arguments".
    static func parse(_ args: [String: JSONValue]) -> Result<ScheduleJobArguments, ToolMessage> {
        guard let prompt = text(args["prompt"]) else { return .failure("schedule_job needs a prompt.") }
        let weekdays: [Int]?
        switch weekdayList(args["weekdays"]) {
        case .failure(let message): return .failure(message)
        case .success(let values): weekdays = values
        }
        let alias = ScheduleAlias(
            minute: integer(args["minute"]),
            hour: integer(args["hour"]),
            day: integer(args["day"]),
            month: integer(args["month"]),
            weekday: integer(args["weekday"]),
            weekdays: weekdays,
            intervalSeconds: integer(args["intervalSeconds"]),
            cron: text(args["cron"]),
            timeZone: text(args["timezone"])
        )
        return .success(ScheduleJobArguments(
            prompt: prompt, name: text(args["name"]), alias: alias, profile: text(args["profile"])))
    }

    /// Builds the job to store, or the sentence explaining why there is none. `existingNames` is
    /// every job name already in the ledger, so a second "check the PR queue" becomes
    /// `check-the-pr-queue-2` instead of colliding with the first on the ledger's UNIQUE index.
    /// `sandboxAvailable` is whether a `mutating` job would actually get the VM it is promised —
    /// the runtime installed AND sandboxing switched on, since `SandboxPolicy.resolve`
    /// short-circuits to the host when the master switch is off, however the conversation is
    /// pinned. Injected so the refusal can be tested on a machine either way. A `mutating` job
    /// always runs in that VM (spec §0.2), so without it there is nowhere safe to run one and the
    /// tool says so rather than creating a job that would quietly fall back to the host.
    /// `JobRunner` asks the same question again at every fire: this one can only speak for today.
    func makeJob(defaultTimeZone: String, createdIn: UUID?, existingNames: Set<String>,
                 sandboxAvailable: Bool = SandboxPolicy.mutatingJobCanRun()) -> Result<Job, ToolMessage> {
        // Anything that is not the word `mutating` reads as read-only, including a value this
        // build does not recognize: the narrow surface is the safe guess, and a refusal over a
        // spelling would cost a retry to arrive at the same job.
        let wantsMutating = profile?.lowercased() == JobProfile.mutating.rawValue.lowercased()
        if wantsMutating, !sandboxAvailable { return .failure(ToolMessage(Self.noRuntimeForMutating)) }
        switch alias.resolve(defaultTimeZone: defaultTimeZone) {
        case .failure(let failure):
            return .failure(Self.message(for: failure))
        case .success(let schedule):
            return .success(Job(
                name: Self.uniqueName(Job.slug(from: name ?? prompt), existing: existingNames),
                prompt: prompt,
                trigger: .schedule(schedule),
                profile: wantsMutating ? .mutating : .readOnly,
                createdInConversationId: createdIn))
        }
    }

    /// The refusal a `mutating` job gets when the VM it would run in is unavailable — the runtime
    /// is not installed, or sandboxing is switched off. One sentence for both causes, because
    /// Settings → Sandboxing is where either is fixed. Spelled once: the test that pins it and the
    /// tool that returns it read the same string.
    static let noRuntimeForMutating = "A mutating job always runs in the apple/container VM, and that VM is not available: install the runtime and turn sandboxing on in Settings → Sandboxing, or create the job read-only."

    /// `base`, or `base-2`, `base-3`, … — the first form not already taken.
    static func uniqueName(_ base: String, existing: Set<String>) -> String {
        guard existing.contains(base) else { return base }
        var suffix = 2
        while existing.contains("\(base)-\(suffix)") { suffix += 1 }
        return "\(base)-\(suffix)"
    }

    /// Turns a resolution failure into something the model can act on. No case interpolates the
    /// raw `Failure` or a Swift error description: the model sees a sentence naming the field it
    /// got wrong and what a correct value looks like, because that is what it needs to retry.
    static func message(for failure: ScheduleAlias.Failure) -> ToolMessage {
        switch failure {
        case .nothingSpecified:
            return "Give a schedule: cron, intervalSeconds, or hour/minute/weekdays."
        case .invalidWeekday(let values):
            return invalidWeekdayMessage(values.map(String.init))
        case .invalidInterval(let seconds):
            return "intervalSeconds must be at least 1 (got \(seconds))."
        case .badCron(let error):
            return "Cron expression rejected: \(Self.cronMessage(error))"
        case .badTimeZone(let zone):
            return "Unknown time zone '\(zone)'."
        case .conflicting:
            return "Use one of: cron, intervalSeconds, or the hour/minute/day/month/weekday fields."
        }
    }

    /// The one weekday sentence, shared by the values `ScheduleAlias` rejected as out of range and
    /// the ones that were never numbers to begin with.
    static func invalidWeekdayMessage(_ values: [String]) -> ToolMessage {
        ToolMessage("Invalid weekday value(s) \(values.joined(separator: ", ")): use 1-7 with 1 = Sunday, or a cron expression.")
    }

    /// The sentence a stored job's tool call returns. Pure, so both halves — the one that fires and
    /// the one that never will — are testable without a scheduler or a database.
    static func resultSentence(for stored: Job) -> String {
        guard let next = stored.nextFireAt, stored.pausedReason == nil else {
            return "Saved '\(stored.name)' but it will never fire: \(stored.pausedReason ?? JobScheduler.unmatchableReason)."
        }
        return "Scheduled '\(stored.name)' (\(stored.trigger.summary)). Next run: \(formatFire(next, zone: stored.trigger.timeZoneIdentifier))."
    }

    /// A job's next fire, written for the model: minute precision in the zone the job's own cadence
    /// is evaluated in (the user's, for an interval), with that zone named so "09:00" is never
    /// ambiguous when the job was created with an explicit timezone.
    static func formatFire(_ date: Date, zone: String?) -> String {
        let timeZone = zone.flatMap(TimeZone.init(identifier:)) ?? .current
        let formatter = DateFormatter()
        formatter.locale = Locale(identifier: "en_US_POSIX")
        formatter.dateFormat = "yyyy-MM-dd HH:mm"
        formatter.timeZone = timeZone
        return "\(formatter.string(from: date)) \(timeZone.identifier)"
    }

    private static func cronMessage(_ error: CronParseError) -> String {
        switch error {
        case .fieldCount(let count):
            return "give five fields (minute hour day-of-month month day-of-week), not \(count)."
        case .badToken(let field, let token):
            if token.isEmpty { return "the \(field) field has an empty list element — check for a stray comma." }
            return "'\(token)' is not a valid \(field) value."
        case .outOfRange(let field, let value):
            return "\(value) is out of range for \(field)."
        }
    }

    // MARK: Loose argument reading

    /// A non-empty string, or nil. Numbers are accepted as their text so a model that quotes a
    /// name or a cron expression's stray number still gets what it meant; containers and nulls
    /// are not strings at all and read as absent.
    private static func text(_ value: JSONValue?) -> String? {
        guard let value else { return nil }
        switch value {
        case .string(let string):
            let trimmed = string.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? nil : trimmed
        case .int, .double:
            return value.stringValue
        case .bool, .object, .array, .null:
            return nil
        }
    }

    /// An integer from any of the three shapes a model sends one in. A fractional double is
    /// truncated: "every 1.5 minutes" is a cadence cron cannot express, and 1 is closer to the
    /// request than a refusal. A double that no `Int` can hold (`1e30`) is unreadable rather than
    /// a trap — `Int(_: Double)` crashes on those, and the value came from a model.
    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let int): return int
        case .double(let double): return double.isFinite ? Int(exactly: double.rounded(.towardZero)) : nil
        case .string(let string): return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// The `weekdays` array. An element that is not a number is a refusal, not a silent drop:
    /// dropping `["monday", "tuesday"]` would leave no weekday at all, and a cron with `*` for
    /// day-of-week runs every day — far more than was asked for. Absent or empty reads as "not
    /// specified", which is what `ScheduleAlias` expects.
    private static func weekdayList(_ value: JSONValue?) -> Result<[Int]?, ToolMessage> {
        guard case .array(let items) = value else { return .success(nil) }
        var values: [Int] = []
        var unreadable: [String] = []
        for item in items {
            if let int = integer(item) { values.append(int) } else { unreadable.append(item.stringValue) }
        }
        guard unreadable.isEmpty else { return .failure(invalidWeekdayMessage(unreadable)) }
        return .success(values.isEmpty ? nil : values)
    }
}
