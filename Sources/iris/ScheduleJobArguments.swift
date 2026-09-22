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
    /// The gate, in the three shapes a model can ask for one (#187 §7). At most one may be given:
    /// which of two contradictory checks a job should be run on is not something to guess at.
    let gateURL: String?
    let gatePath: String?
    let gateScript: String?
    /// A script gate's inputs, `source[:target]` — always mounted read-only, whatever was written.
    let gateMounts: [String]?
    let gateTimeoutSeconds: Int?

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
        // A `gate_*` that is not the type it should be is a refusal, not a drop. Dropping it
        // creates an **ungated** job on the same cadence — the exact opposite of what was asked,
        // running a turn every tick — and nothing in the answer would say so. Same reasoning as
        // `weekdays`, where dropping an unreadable element would silently widen the schedule.
        for key in ["gate_url", "gate_path", "gate_script"] where present(args[key]) {
            guard text(args[key]) != nil else {
                return .failure(ToolMessage("\(key) must be a non-empty string."))
            }
        }
        let gateMounts: [String]?
        switch stringList(args["gate_mounts"]) {
        case .failure(let message): return .failure(message)
        case .success(let values): gateMounts = values
        }
        if present(args["gate_timeout_seconds"]), integer(args["gate_timeout_seconds"]) == nil {
            return .failure("gate_timeout_seconds must be a number of seconds.")
        }
        return .success(ScheduleJobArguments(
            prompt: prompt, name: text(args["name"]), alias: alias, profile: text(args["profile"]),
            gateURL: text(args["gate_url"]), gatePath: text(args["gate_path"]),
            gateScript: text(args["gate_script"]), gateMounts: gateMounts,
            gateTimeoutSeconds: integer(args["gate_timeout_seconds"])))
    }

    /// Builds the job to store, or the sentence explaining why there is none. `existingNames` is
    /// every job name already in the ledger, so a second "check the PR queue" becomes
    /// `check-the-pr-queue-2` instead of colliding with the first on the ledger's UNIQUE index.
    /// `sandboxAvailable` is whether a `mutating` job would actually get the VM it is promised —
    /// the runtime installed AND sandboxing switched on, since `SandboxPolicy.resolve`
    /// short-circuits to the host when the master switch is off, however the conversation is
    /// pinned. Injected so the refusal can be tested on a machine either way. A `mutating` job's
    /// *commands* always run in that VM (spec §0.2) — the rest of its tools run on the host behind
    /// the user's allowlist, as in any run — so without the VM there is nowhere safe to run a
    /// command and the tool says so rather than creating a job whose commands would quietly fall
    /// back to the host.
    /// `JobRunner` asks the same question again at every fire: this one can only speak for today —
    /// and a `script` gate is held to the same rule for the same reason (`resolvedGate`).
    ///
    /// A job that carries a gate becomes a `.poll` over the cadence it was given: same schedule,
    /// with the gate deciding at each occurrence whether there is anything to run.
    func makeJob(defaultTimeZone: String, createdIn: UUID?, existingNames: Set<String>,
                 sandboxAvailable: Bool = SandboxPolicy.mutatingJobCanRun(),
                 fileManager: FileManager = .default,
                 directoryEntryLimit: Int = GateEvaluator.directoryEntryLimit) -> Result<Job, ToolMessage> {
        // Anything that is not the word `mutating` reads as read-only, including a value this
        // build does not recognize: the narrow surface is the safe guess, and a refusal over a
        // spelling would cost a retry to arrive at the same job.
        let wantsMutating = profile?.lowercased() == JobProfile.mutating.rawValue.lowercased()
        if wantsMutating, !sandboxAvailable { return .failure(ToolMessage(Self.noRuntimeForMutating)) }
        let gate: Gate?
        switch resolvedGate(sandboxAvailable: sandboxAvailable, fileManager: fileManager,
                            directoryEntryLimit: directoryEntryLimit) {
        case .failure(let message): return .failure(message)
        case .success(let resolved): gate = resolved
        }
        switch alias.resolve(defaultTimeZone: defaultTimeZone) {
        case .failure(let failure):
            return .failure(Self.message(for: failure))
        case .success(let schedule):
            // A gate needs a cadence to be checked on, so a gated job is a `poll` over the same
            // schedule an ungated one would have run on.
            let trigger: Trigger = gate.map { .poll(PollSpec(schedule: schedule, gate: $0)) }
                ?? .schedule(schedule)
            return .success(Job(
                name: Self.uniqueName(Job.slug(from: name ?? prompt), existing: existingNames),
                prompt: prompt,
                trigger: trigger,
                profile: wantsMutating ? .mutating : .readOnly,
                createdInConversationId: createdIn))
        }
    }

    /// The gate these arguments describe, `nil` for none, or the sentence saying why they describe
    /// no usable one. Everything a gate can be wrong about is decided here, while there is still a
    /// person in the conversation to read the answer: the alternative is a job that fails silently
    /// on a cadence until three errors pause it.
    func resolvedGate(sandboxAvailable: Bool, fileManager: FileManager = .default,
                      directoryEntryLimit: Int = GateEvaluator.directoryEntryLimit) -> Result<Gate?, ToolMessage> {
        let asked = [gateURL, gatePath, gateScript].compactMap { $0 }
        guard asked.count <= 1 else { return .failure(ToolMessage(Self.oneGateOnly)) }
        // The two script-only options, given without one — or beside a gate that cannot use them.
        // Ignoring them would store a gate the user thinks has inputs and a deadline of its own.
        guard gateScript != nil || (gateMounts == nil && gateTimeoutSeconds == nil) else {
            return .failure(ToolMessage(Self.gateOptionsNeedAScript))
        }
        if let gateURL {
            guard let url = URL(string: gateURL), let scheme = url.scheme?.lowercased(),
                  scheme == "http" || scheme == "https" else {
                return .failure("gate_url must be an http(s) URL (got '\(gateURL)').")
            }
            return .success(.urlChanged(url: gateURL))
        }
        if let gatePath {
            guard gatePath.hasPrefix("/") else {
                return .failure("gate_path must be an absolute path (got '\(gatePath)').")
            }
            var isDirectory: ObjCBool = false
            guard fileManager.fileExists(atPath: gatePath, isDirectory: &isDirectory) else {
                return .failure("There is nothing at \(gatePath), so a gate watching it could never answer.")
            }
            // Walked here, with the cap the evaluation uses, so "my home folder" is refused in the
            // conversation that asked for it rather than becoming a job that errors on a cadence.
            // The walk stops one entry past the cap, so the refusal costs the same as the check.
            if isDirectory.boolValue,
               GateEvaluator.walk(gatePath, fileManager: fileManager, limit: directoryEntryLimit).overLimit {
                return .failure(ToolMessage(
                    "gate_path: \(GateEvaluator.tooManyEntriesDetail(gatePath, limit: directoryEntryLimit))."))
            }
            return .success(.pathChanged(path: gatePath))
        }
        guard let gateScript else { return .success(nil) }
        // R28: a script gate runs in the VM or nowhere. Refused at creation, and asked again at
        // every evaluation — where the answer is a gate error, never a command on the host.
        guard sandboxAvailable else { return .failure(ToolMessage(Self.noRuntimeForGateScript)) }
        let declared = gateMounts ?? []
        var resolved: [String] = []
        for entry in declared {
            if let refusal = GateEvaluator.mountRefusal(entry, fileManager: fileManager) {
                return .failure(ToolMessage("gate_mounts: \(refusal)."))
            }
            // Stored resolved, never as typed: the review is about to be shown these paths, and
            // the evaluation compares against them at every tick. A source that resolves somewhere
            // else after today is then a gate error rather than a silent swap.
            resolved.append(GateEvaluator.canonicalMount(entry))
        }
        return .success(.script(
            command: gateScript,
            mounts: GateEvaluator.readOnly(resolved),
            timeoutSeconds: GateEvaluator.clampedTimeout(gateTimeoutSeconds
                ?? GateEvaluator.defaultTimeoutSeconds)))
    }

    /// The refusal a `mutating` job gets when the VM its commands would run in is unavailable —
    /// the runtime is not installed, or sandboxing is switched off. One sentence for both causes,
    /// because Settings → Sandboxing is where either is fixed. Spelled once: the test that pins it
    /// and the tool that returns it read the same string.
    static let noRuntimeForMutating = "A mutating job's commands always run in the apple/container VM, and that VM is not available: install the runtime and turn sandboxing on in Settings → Sandboxing, or create the job read-only."

    /// The same refusal for a gate script, which runs in that VM on every tick for as long as the
    /// job exists and never anywhere else. It offers the two gates that need no VM, because a
    /// "check whether this page or this file changed" gate is what most requests turn out to be.
    static let noRuntimeForGateScript = "A gate script always runs in the apple/container VM, and that VM is not available: install the runtime and turn sandboxing on in Settings → Sandboxing, or use gate_url or gate_path, which run no code."

    /// Two gates on one job: a refusal rather than a guess about which check the user meant.
    static let oneGateOnly = "Give one gate: gate_url, gate_path or gate_script — not more than one."

    static let gateOptionsNeedAScript = "gate_mounts and gate_timeout_seconds only apply to gate_script."

    static let gateMountsShape: ToolMessage = "gate_mounts must be a directory path, or a list of them."

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
        // A gated job's cadence is how often its gate is *looked at*, not how often it runs:
        // "next run" would promise a turn that, if the gate is doing its job, is not coming.
        let label = stored.trigger.gate == nil ? "Next run" : "Next check"
        return "Scheduled '\(stored.name)' (\(stored.trigger.summary)). \(label): \(formatFire(next, zone: stored.trigger.timeZoneIdentifier))."
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

    /// Whether the model sent this key at all. A JSON `null` reads as absent: it is how several
    /// providers spell "no value", and refusing it as a wrong type would fail a call that asked
    /// for nothing.
    private static func present(_ value: JSONValue?) -> Bool {
        guard let value else { return false }
        if case .null = value { return false }
        return true
    }

    /// A list of non-empty strings — `gate_mounts`. A model that sends one mount as a bare string
    /// rather than a one-element array means the same thing, so both are read.
    ///
    /// An empty array is *absent*, not a refusal: it is a common way for a model to say "none",
    /// and "gate_mounts must be a directory path, or a list of them" is no help to a caller that
    /// sent a list. An element that is not a string **is** a refusal, for the same reason the
    /// `gate_*` keys above are: dropping it stores a gate with fewer inputs than was asked for,
    /// and nothing in the answer would say so.
    private static func stringList(_ value: JSONValue?) -> Result<[String]?, ToolMessage> {
        guard present(value) else { return .success(nil) }
        if let single = text(value) { return .success([single]) }
        guard case .array(let items) = value else { return .failure(Self.gateMountsShape) }
        var values: [String] = []
        for item in items {
            guard let path = text(item) else { return .failure(Self.gateMountsShape) }
            values.append(path)
        }
        return .success(values.isEmpty ? nil : values)
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

/// The one review a gate script gets (#187 §7).
///
/// A gate script is the only model-written code in the system that executes repeatedly, unattended,
/// with no further review: it is checked once here, at creation, and then runs on every tick for as
/// long as the job exists. The sandbox, the read-only mounts and the timeout are the standing
/// mitigation; this is the moment a person is still in the loop.
///
/// Both halves are closures so the decision can be tested without a model, a dialog or an engine:
/// `verdict` is Vibecop over the script and the capability it comes with (as a `run_command` in
/// the sandbox, which is what it is), and `ask` is the ordinary approval dialog, reached only when
/// Vibecop escalates or cannot answer. Both are handed the same `details` text.
struct GateScriptReview: Sendable {
    let verdict: @Sendable (String) async -> VibecopDecision?
    let ask: @Sendable (String) async -> Bool

    /// What both halves of the review are shown: the script, the directories it will be able to
    /// read, and how long it may take.
    ///
    /// The mounts are not decoration. They are the durable capability being granted — a standing,
    /// unattended read of somebody's disk whose output comes back into a model's prompt — and the
    /// script is only the half that says what is done with them. `find /in -type f` is
    /// unremarkable until `/in` turns out to be the home directory, so a reviewer shown the script
    /// alone is reviewing the wrong half. Each mount is rendered as the resolved source and the
    /// path the script will see it at, because that is what will actually be bound.
    static func details(script: String, mounts: [String], timeoutSeconds: Int) -> String {
        let rendered = mounts.map { entry -> String in
            let parts = GateEvaluator.mountParts(entry)
            return "  \(parts.source) \u{2192} \(parts.target), read-only"
        }
        let inputs = rendered.isEmpty
            ? "  (none \u{2014} the script can read nothing of yours)" : rendered.joined(separator: "\n")
        // The capability block comes first and the script last, under its own label: a script is
        // free text, and one that ended with a forged "What it can read: (none)" would otherwise
        // sit exactly where the real list is expected. Put the fixed part where nothing the model
        // wrote can precede it.
        return """
            This script runs unattended inside the sandbox VM every time the job's schedule comes \
            round, for as long as the job exists. What it can read:
            """ + "\n" + inputs + "\n" + "It is stopped after \(timeoutSeconds) seconds." + "\n\nScript:\n" + script
    }

    /// `APPROVE` creates the job; `DENY` refuses it and says why; anything else — an `ESCALATE`, a
    /// verdict this build does not recognize, or no verdict at all because Vibecop is off, wedged
    /// or timed out — asks the user, who is right there typing. Fail *open to the person*, never
    /// past them: the same shape `AppState.requestApproval` uses for an attended call.
    ///
    /// Both halves see the same text, mounts and timeout included: an escalation is a second
    /// opinion on what Vibecop was asked about, and showing the person less than the model was
    /// shown is how an authorisation gets given without sight of what it authorises.
    func review(script: String, mounts: [String], timeoutSeconds: Int) async -> Result<Void, ToolMessage> {
        let subject = Self.details(script: script, mounts: mounts, timeoutSeconds: timeoutSeconds)
        let decision = await verdict(subject)
        switch decision?.decision {
        case "APPROVE":
            return .success(())
        case "DENY":
            return .failure(ToolMessage(Self.denied(decision?.reason ?? "")))
        default:
            return await ask(subject) ? .success(()) : .failure(ToolMessage(Self.declined))
        }
    }

    /// What the model is told when the review refused the script. The reason is quoted so the
    /// model can rewrite the gate rather than retry the same one.
    static func denied(_ reason: String) -> String {
        let trimmed = reason.trimmingCharacters(in: .whitespacesAndNewlines)
        let because = trimmed.isEmpty ? "" : " \(trimmed)"
        return "That gate script was refused by the safety review, so no job was created:\(because)"
            + " Describe the check in gate_url or gate_path terms, or propose a narrower script."
    }

    static let declined = "That gate script was not approved, so no job was created."
}
