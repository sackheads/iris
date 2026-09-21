import Foundation

/// A tool result carried as a plain `String` — `ScheduleJobArguments` returns
/// `Result<_, String>`, and `Result` requires its failure type to be an `Error`. The conformance
/// is retroactive because the whole point of these failures is that they are already the sentence
/// the model should read: wrapping them in an error type would mean unwrapping them again at
/// every call site, and there is nothing to carry but the text.
extension String: @retroactive Error {}

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
    static func parse(_ args: [String: JSONValue]) -> Result<ScheduleJobArguments, String> {
        guard let prompt = text(args["prompt"]) else { return .failure("schedule_job needs a prompt.") }
        let alias = ScheduleAlias(
            minute: integer(args["minute"]),
            hour: integer(args["hour"]),
            day: integer(args["day"]),
            month: integer(args["month"]),
            weekday: integer(args["weekday"]),
            weekdays: integers(args["weekdays"]),
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
    func makeJob(defaultTimeZone: String, createdIn: UUID?, existingNames: Set<String>) -> Result<Job, String> {
        // D3 owns budgets and approvals; until then a job that may write is a job nobody is
        // watching, so the tool declines rather than quietly downgrading what was asked for.
        if profile?.lowercased() == JobProfile.mutating.rawValue.lowercased() {
            return .failure("mutating jobs arrive with deliverable 3; create the job without a profile to run it read-only.")
        }
        switch alias.resolve(defaultTimeZone: defaultTimeZone) {
        case .failure(let failure):
            return .failure(Self.message(for: failure))
        case .success(let schedule):
            return .success(Job(
                name: Self.uniqueName(Job.slug(from: name ?? prompt), existing: existingNames),
                prompt: prompt,
                trigger: .schedule(schedule),
                createdInConversationId: createdIn))
        }
    }

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
    static func message(for failure: ScheduleAlias.Failure) -> String {
        switch failure {
        case .nothingSpecified:
            return "Give a schedule: cron, intervalSeconds, or hour/minute/weekdays."
        case .invalidWeekday(let values):
            let list = values.map(String.init).joined(separator: ", ")
            return "Invalid weekday value(s) \(list): use 1-7 with 1 = Sunday, or a cron expression."
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

    private static func cronMessage(_ error: CronParseError) -> String {
        switch error {
        case .fieldCount(let count):
            return "give five fields (minute hour day-of-month month day-of-week), not \(count)."
        case .badToken(let field, let token):
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
    /// request than a refusal.
    private static func integer(_ value: JSONValue?) -> Int? {
        switch value {
        case .int(let int): return int
        case .double(let double): return double.isFinite ? Int(double) : nil
        case .string(let string): return Int(string.trimmingCharacters(in: .whitespaces))
        default: return nil
        }
    }

    /// The `weekdays` array, with anything unreadable dropped. An empty result is nil rather than
    /// `[]` so it reads as "not specified" to `ScheduleAlias`.
    private static func integers(_ value: JSONValue?) -> [Int]? {
        guard case .array(let items) = value else { return nil }
        let values = items.compactMap { integer($0) }
        return values.isEmpty ? nil : values
    }
}
