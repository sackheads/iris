import Foundation

/// Whether a job's turns run with tool access limited to read-only operations (`readOnly`, the
/// default) or may also mutate the filesystem/network/other state (`mutating`). The runner stamps
/// it on the run's hidden conversation; the engine's tool-list builder narrows a `readOnly` run's
/// declarations by it and the dispatcher fails closed on anything it still gets asked for (#187
/// deliverable 3, spec §0.2 and §4). A `mutating` job's *commands* always run in the
/// `apple/container` VM — `run_command` is what the VM routes; `write_file` and the other native
/// tools execute on the host behind the user's allowlist or the job's grant (#282), as they do in
/// any run — so it is refused
/// both at creation and at every fire when that VM is unavailable; see
/// `SandboxPolicy.mutatingJobCanRun`.
enum JobProfile: String, Codable, Sendable {
    case readOnly
    case mutating
}

extension JobProfile {
    /// The whole native tool surface of a `readOnly` run (spec §0.2, ruling R11). An allowlist,
    /// like `EvaluatorToolset.allowedNames` and for the same reason: a denylist's default answer
    /// is "allowed", so every tool anyone adds later joins the read-only surface silently. The
    /// first draft of this was a denylist written from the spec's sentence, and it left
    /// `update_soul`, `update_memory`, `update_user_profile` and `save_fact` — which write files
    /// under `~/.iris` and the shared fact store, with no approval path to catch them — on the
    /// surface of a run the docs said could not change anything.
    ///
    /// Adding a name here is a deliberate decision about a tool that changes nothing outside the
    /// run's own conversation, and `JobProfileTests` pins the resulting surface as a set so the
    /// decision cannot be made by accident.
    ///
    /// It is a ceiling, not the offer. `list_jobs` and `get_job_run` are declared only in a pinned
    /// conversation (`IrisEngine.jobToolDeclarations(isPinned:)`) and a run's hidden conversation
    /// never is, so they sit here without ever reaching a run's tool surface. That is deliberate:
    /// the dispatcher's answer must not depend on how the declaration list happened to be built.
    ///
    /// Two tools are judged dynamically rather than listed: `run_command` (allowed only in the
    /// container) and MCP tools (allowed only where the server annotated them read-only). Notably
    /// absent: `set_workspace`, because a workspace is what gives a sandboxed `run_command` a
    /// read-write bind mount — a read-only run that could set one could write to the host through
    /// the sandbox it is confined to. Since #282 §0.10 no unattended run of either profile may
    /// call it: the dispatcher refuses it (`IrisEngine.unattendedWorkspaceRefusal`).
    static let readOnlyAllowed: Set<String> = [
        "read_file", "search_web", "search_memory", "reflect",
        "list_jobs", "get_job_run",
        "google_tasks_list_tasklists", "google_tasks_list_tasks", "google_calendar_list_events",
        "google_docs_get", "google_drive_search", "google_sheets_get", "gmail_list_unread",
    ]

    /// What `MCPManager` joins a server name and a tool name with.
    static let mcpNameSeparator = "___"

    static func isMCPTool(_ toolName: String) -> Bool { toolName.contains(mcpNameSeparator) }

    /// Whether a `readOnly` run may not call `toolName`.
    ///
    /// - Parameters:
    ///   - sandboxedRunCommand: whether a `run_command` in this conversation would run in the
    ///     container. On the host it writes to the user's machine, so it is denied there (§0.2).
    ///   - readOnlyMCPTools: the prefixed names of MCP tools whose server annotated them
    ///     `readOnlyHint: true`. That annotation is the server's own claim, not something this
    ///     harness verifies — it is the only signal the protocol offers. Every other MCP tool is
    ///     denied: a tool that says nothing about itself is one nobody can vouch for, and an
    ///     unattended run is the wrong place to guess.
    static func readOnlyDenies(_ toolName: String, sandboxedRunCommand: Bool,
                               readOnlyMCPTools: Set<String>) -> Bool {
        if toolName == "run_command" { return !sandboxedRunCommand }
        if isMCPTool(toolName) { return !readOnlyMCPTools.contains(toolName) }
        return !readOnlyAllowed.contains(toolName)
    }
}

/// A filesystem watch trigger on `path`, which is stored canonical and absolute (`WatchRoot`).
///
/// `quietWindowSeconds` is the window a burst of edits is coalesced into one run over: the watch
/// fires once the directory has been quiet for that long, and — because a directory under
/// continuous change must not starve — once the burst has lasted `ceilingSeconds` regardless.
/// `ignore` is the per-watch glob list, relative to `path`, on top of the built-in set of editor
/// and VCS noise.
struct FSWatch: Codable, Equatable, Sendable {
    var path: String
    /// 1…300 seconds; clamped here, on decode and at the tool, so no other layer has to ask
    /// whether a stored window is sane.
    var quietWindowSeconds: Int
    /// Globs, relative to `path`, whose changes this watch absorbs. Default empty.
    var ignore: [String]

    /// The window a watch gets when none is asked for: long enough to swallow an editor's save
    /// burst, short enough that the run still feels like an answer to the save.
    static let defaultQuietWindowSeconds = 3

    init(path: String, quietWindowSeconds: Int = FSWatch.defaultQuietWindowSeconds,
         ignore: [String] = []) {
        self.path = path
        self.quietWindowSeconds = Self.clampQuietWindow(quietWindowSeconds)
        self.ignore = ignore
    }

    /// The bounds in one place: a window under a second is a busy-wait and one over five minutes
    /// is a job nobody can tell has stopped working.
    static func clampQuietWindow(_ seconds: Int) -> Int { min(max(seconds, 1), 300) }

    /// How long a burst may last before it fires anyway: a fixed multiple of the window, derived
    /// and never stored, so there is only ever one knob to get wrong. The multiple is the
    /// coordinator's, spelled once, so the figure `/jobs` prints is the one the burst was cut at.
    var ceilingSeconds: Int { quietWindowSeconds * WatchCoordinator.ceilingMultiplier }

    private enum CodingKeys: String, CodingKey { case path, quietWindowSeconds, ignore }

    /// Invariant 1 — an absent window is the default and an absent ignore list is empty — and the
    /// clamp applies here too: a row written before the bounds existed, or by hand, must not hand
    /// the coordinator a zero-second window.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        quietWindowSeconds = Self.clampQuietWindow(
            try container.decodeIfPresent(Int.self, forKey: .quietWindowSeconds)
                ?? Self.defaultQuietWindowSeconds)
        ignore = try container.decodeIfPresent([String].self, forKey: .ignore) ?? []
    }
}

/// The check that decides whether a polled job has anything to do (#187 deliverable 3, spec §7).
/// The two built-ins run on the host with no model and no container and only read; a `script` gate
/// is model-written code that runs in the `apple/container` VM with exactly the `mounts` it
/// declared, read-only, under `timeoutSeconds`.
///
/// A script gate's verdict is a token on stdout's last line (`CHANGED`/`UNCHANGED`), never the exit
/// code — `diff -q` and `grep -q` disagree about what zero means, so any exit-code convention makes
/// a plausible gate fire every tick or never. `GateEvaluator` is what asks; this is the stored
/// shape.
enum Gate: Codable, Equatable, Sendable {
    /// A HEAD request whose ETag, Last-Modified or Content-Length changed since the last signal.
    case urlChanged(url: String)
    /// A file's mtime or hash, or the newest mtime under a directory, changed since the last signal.
    case pathChanged(path: String)
    case script(command: String, mounts: [String], timeoutSeconds: Int)

    private enum CodingKeys: String, CodingKey { case kind, url, path, command, mounts, timeoutSeconds }

    var kind: String {
        switch self {
        case .urlChanged: return "urlChanged"
        case .pathChanged: return "pathChanged"
        case .script: return "script"
        }
    }

    /// One word for a job listing: what this gate looks at. Not `kind`, which is the stored
    /// discriminator and must not change to suit a table.
    var summary: String {
        switch self {
        case .urlChanged: return "url"
        case .pathChanged: return "path"
        case .script: return "script"
        }
    }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .urlChanged(let url):
            try container.encode(url, forKey: .url)
        case .pathChanged(let path):
            try container.encode(path, forKey: .path)
        case .script(let command, let mounts, let timeoutSeconds):
            try container.encode(command, forKey: .command)
            try container.encode(mounts, forKey: .mounts)
            try container.encode(timeoutSeconds, forKey: .timeoutSeconds)
        }
    }

    /// Throws on an unknown kind, like `Trigger` and `Schedule` and unlike `JobPolicy.CatchUp`: a
    /// gate this build cannot evaluate must not be guessed at — guessing either fires an
    /// unattended job that should have stayed quiet, or silences one that should have fired. The
    /// job row is skipped and counted in `unreadableJobCount` instead.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .kind) ?? "" {
        case "urlChanged":
            self = .urlChanged(url: try container.decode(String.self, forKey: .url))
        case "pathChanged":
            self = .pathChanged(path: try container.decode(String.self, forKey: .path))
        case "script":
            self = .script(
                command: try container.decode(String.self, forKey: .command),
                mounts: try container.decodeIfPresent([String].self, forKey: .mounts) ?? [],
                timeoutSeconds: try container.decodeIfPresent(Int.self, forKey: .timeoutSeconds)
                    ?? PollSpec.legacyGateTimeoutSeconds)
        case let other:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unknown gate kind '\(other)'"))
        }
    }
}

/// A polled trigger: on `schedule`'s cadence, evaluates `gate` and only fires the job when it says
/// something changed. `schedule_job` creates one from `gate_url`, `gate_path` or `gate_script`;
/// `JobRunner.fire` evaluates it as the last thing asked before a turn starts (spec §4 step 5).
struct PollSpec: Codable, Equatable, Sendable {
    var schedule: Schedule
    var gate: Gate

    /// What a gate written before `Gate` existed gets: deliverable 1 stored the gate as a bare
    /// shell-command string with no mounts and no timeout of its own.
    static let legacyGateTimeoutSeconds = 60

    init(schedule: Schedule, gate: Gate) {
        self.schedule = schedule
        self.gate = gate
    }

    private enum CodingKeys: String, CodingKey { case schedule, gate }

    /// `gate` was a `String` in deliverable 1 (spec §7). A stored row still holding one decodes as
    /// the script gate it always meant, with no mounts and the legacy timeout — the job keeps its
    /// cadence rather than becoming an unreadable row.
    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        if let legacy = try? container.decode(String.self, forKey: .gate) {
            gate = .script(command: legacy, mounts: [], timeoutSeconds: Self.legacyGateTimeoutSeconds)
        } else {
            // An absent gate was legal in deliverable 1 (it decoded to ""); keep it legal, as the
            // same empty script gate, rather than dropping the job.
            gate = try container.decodeIfPresent(Gate.self, forKey: .gate)
                ?? .script(command: "", mounts: [], timeoutSeconds: Self.legacyGateTimeoutSeconds)
        }
    }
}

/// A cadence: either a five-field cron expression with its own time zone, or a fixed interval in
/// seconds measured from the last fire (or from now, for the first fire).
enum Schedule: Codable, Equatable, Sendable {
    case cron(CronSchedule)
    case interval(seconds: Int)

    private enum CodingKeys: String, CodingKey { case kind, cron, seconds }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        switch self {
        case .cron(let schedule):
            try container.encode("cron", forKey: .kind)
            try container.encode(schedule, forKey: .cron)
        case .interval(let seconds):
            try container.encode("interval", forKey: .kind)
            try container.encode(seconds, forKey: .seconds)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .kind) ?? "" {
        case "cron":
            self = .cron(try container.decode(CronSchedule.self, forKey: .cron))
        case "interval":
            self = .interval(seconds: try container.decode(Int.self, forKey: .seconds))
        case let other:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unknown schedule kind '\(other)'"))
        }
    }

    /// The next Date strictly after `after` that this schedule fires.
    func next(after date: Date, calendar: Calendar = Calendar(identifier: .gregorian)) -> Date? {
        switch self {
        case .cron(let schedule):
            return schedule.next(after: date, calendar: calendar)
        case .interval(let seconds):
            return date.addingTimeInterval(TimeInterval(seconds))
        }
    }
}

/// What causes a job to run: a cadence (`schedule`), a filesystem watch (`fsEvent`), or a gated
/// poll (`poll`).
enum Trigger: Codable, Equatable, Sendable {
    case schedule(Schedule)
    case fsEvent(FSWatch)
    case poll(PollSpec)

    /// The `triggerKind` column's value for a filesystem watch. Spelled once: the runner decides
    /// whether a run's input was the filesystem's by comparing against it.
    static let fsEventKind = "fsEvent"

    var kind: String {
        switch self {
        case .schedule: return "schedule"
        case .fsEvent: return Self.fsEventKind
        case .poll: return "poll"
        }
    }

    /// A short human-readable description, used in the jobs list UI (Task 5).
    var summary: String {
        switch self {
        case .schedule(.cron(let cron)):
            return "cron \(cron.expression) \(cron.timeZone)"
        case .schedule(.interval(let seconds)):
            return "every \(seconds) s"
        case .fsEvent(let watch):
            return "watch \(watch.path)"
        case .poll(let spec):
            // The gate's kind, not just the cadence: "poll every 900 s" says how often this job
            // *looks*, and someone asking why it has not run in a week needs to know that a check
            // stands between the cadence and the work, and which one.
            switch spec.schedule {
            case .cron(let cron):
                return "poll cron \(cron.expression) \(cron.timeZone) (\(spec.gate.summary) gate)"
            case .interval(let seconds):
                return "poll every \(seconds) s (\(spec.gate.summary) gate)"
            }
        }
    }

    /// The gate this trigger carries, if it has one — only a `poll` does. Read where a fire
    /// decides whether to run (`JobRunner.fire`) and where an edited job's recorded signals are
    /// dropped (`JobLedger.upsert`): a signal recorded under one gate cannot answer for another.
    var gate: Gate? {
        if case .poll(let spec) = self { return spec.gate }
        return nil
    }

    /// The IANA time zone identifier governing this trigger's cadence, when it has one. `nil` for
    /// interval-based cadences and filesystem watches, which have no time-zone-sensitive fields.
    var timeZoneIdentifier: String? {
        switch self {
        case .schedule(.cron(let cron)):
            return cron.timeZone
        case .schedule(.interval):
            return nil
        case .fsEvent:
            return nil
        case .poll(let spec):
            if case .cron(let cron) = spec.schedule { return cron.timeZone }
            return nil
        }
    }

    private enum CodingKeys: String, CodingKey { case kind, schedule, watch, poll }

    func encode(to encoder: Encoder) throws {
        var container = encoder.container(keyedBy: CodingKeys.self)
        try container.encode(kind, forKey: .kind)
        switch self {
        case .schedule(let schedule):
            try container.encode(schedule, forKey: .schedule)
        case .fsEvent(let watch):
            try container.encode(watch, forKey: .watch)
        case .poll(let spec):
            try container.encode(spec, forKey: .poll)
        }
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        switch try container.decodeIfPresent(String.self, forKey: .kind) ?? "" {
        case "schedule":
            self = .schedule(try container.decode(Schedule.self, forKey: .schedule))
        case "fsEvent":
            self = .fsEvent(try container.decode(FSWatch.self, forKey: .watch))
        case "poll":
            self = .poll(try container.decode(PollSpec.self, forKey: .poll))
        case let other:
            throw DecodingError.dataCorrupted(.init(
                codingPath: decoder.codingPath, debugDescription: "unknown trigger kind '\(other)'"))
        }
    }
}

/// A scheduled or event-driven agent task, stored in the conversation database. Replaces the old
/// `UserDefaults`-backed scheduled jobs and watcher rules.
struct Job: Identifiable, Codable, Equatable, Sendable {
    let id: UUID
    var name: String
    var prompt: String
    var trigger: Trigger
    var profile: JobProfile
    /// Where a fire's event card is delivered — used by event-card delivery, deliverable 2.
    var destinationConversationId: UUID?
    /// Not read in D2 — kept for `/jobs` provenance ("scheduled from…") and deliverable 5's
    /// briefing, both of which need the conversation a job was born in.
    var createdInConversationId: UUID?
    var createdAt: Date
    var enabled: Bool
    var nextFireAt: Date?
    var lastRunAt: Date?
    var pausedReason: String?
    /// What this job may spend and how it behaves around overlap, sleep and failure (#187
    /// deliverable 3). One JSON column; a NULL one reads back as `JobPolicy()`.
    var policy: JobPolicy
    /// How many consecutive failures this job has retried through. 0 is "not retrying"; a
    /// completed run resets it, and the fourth failure pauses the job instead of incrementing.
    var retryAttempt: Int
    /// `policy.overlap == .queue` only: the one fire that came due while the previous run was
    /// still going, taken when it finishes. Never more than one.
    var queuedFire: Date?

    init(
        id: UUID = UUID(),
        name: String,
        prompt: String,
        trigger: Trigger,
        profile: JobProfile = .readOnly,
        destinationConversationId: UUID? = nil,
        createdInConversationId: UUID? = nil,
        createdAt: Date = Date(),
        enabled: Bool = true,
        nextFireAt: Date? = nil,
        lastRunAt: Date? = nil,
        pausedReason: String? = nil,
        policy: JobPolicy = JobPolicy(),
        retryAttempt: Int = 0,
        queuedFire: Date? = nil
    ) {
        self.id = id
        self.name = name
        self.prompt = prompt
        self.trigger = trigger
        self.profile = profile
        self.destinationConversationId = destinationConversationId
        self.createdInConversationId = createdInConversationId
        self.createdAt = createdAt
        self.enabled = enabled
        self.nextFireAt = nextFireAt
        self.lastRunAt = lastRunAt
        self.pausedReason = pausedReason
        self.policy = policy
        self.retryAttempt = retryAttempt
        self.queuedFire = queuedFire
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, trigger, profile
        case destinationConversationId, createdInConversationId, createdAt
        case enabled, nextFireAt, lastRunAt, pausedReason
        case policy, retryAttempt, queuedFire
    }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        id = try container.decode(UUID.self, forKey: .id)
        name = try container.decodeIfPresent(String.self, forKey: .name) ?? ""
        prompt = try container.decodeIfPresent(String.self, forKey: .prompt) ?? ""
        trigger = try container.decode(Trigger.self, forKey: .trigger)
        profile = try container.decodeIfPresent(JobProfile.self, forKey: .profile) ?? .readOnly
        destinationConversationId = try container.decodeIfPresent(UUID.self, forKey: .destinationConversationId)
        createdInConversationId = try container.decodeIfPresent(UUID.self, forKey: .createdInConversationId)
        createdAt = try container.decodeIfPresent(Date.self, forKey: .createdAt) ?? Date(timeIntervalSince1970: 0)
        enabled = try container.decodeIfPresent(Bool.self, forKey: .enabled) ?? true
        nextFireAt = try container.decodeIfPresent(Date.self, forKey: .nextFireAt)
        lastRunAt = try container.decodeIfPresent(Date.self, forKey: .lastRunAt)
        pausedReason = try container.decodeIfPresent(String.self, forKey: .pausedReason)
        // Invariant 1: every job written before deliverable 3 lacks all three keys.
        policy = try container.decodeIfPresent(JobPolicy.self, forKey: .policy) ?? JobPolicy()
        retryAttempt = try container.decodeIfPresent(Int.self, forKey: .retryAttempt) ?? 0
        queuedFire = try container.decodeIfPresent(Date.self, forKey: .queuedFire)
    }

    /// Derives a short identifier from a job's prompt for use where a display name is needed but
    /// none was given: lowercase, non `[a-z0-9]` runs collapsed to a single `-`, leading/trailing
    /// `-` trimmed, limited to the first four words and 32 characters. `"job"` if that yields
    /// nothing usable.
    static func slug(from prompt: String) -> String {
        let lowered = prompt.lowercased()
        var words: [String] = []
        var current = ""
        for scalar in lowered.unicodeScalars {
            if ("a"..."z").contains(scalar) || ("0"..."9").contains(scalar) {
                current.unicodeScalars.append(scalar)
            } else if !current.isEmpty {
                words.append(current)
                current = ""
            }
        }
        if !current.isEmpty { words.append(current) }
        guard !words.isEmpty else { return "job" }

        var slug = words.prefix(4).joined(separator: "-")
        if slug.count > 32 {
            slug = String(slug.prefix(32))
            while slug.hasSuffix("-") { slug.removeLast() }
        }
        return slug.isEmpty ? "job" : slug
    }
}
