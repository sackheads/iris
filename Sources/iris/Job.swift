import Foundation

/// Whether a job's turns are meant to run with tool access limited to read-only operations
/// (`readOnly`) or may also mutate the filesystem/network/other state (`mutating`). Stored and
/// refused on (`schedule_job` declines `mutating`) now; nothing narrows the tool surface of a
/// `readOnly` job's turn yet, because deliverable 3 owns gates, budgets and approvals.
enum JobProfile: String, Codable, Sendable {
    case readOnly
    case mutating
}

/// A filesystem watch trigger on `path`. `quietWindowSeconds` is the window a burst of edits is
/// meant to be coalesced into one run over: stored now, enforced by deliverable 4 — deliverable
/// 1's watcher fires on the events it sees.
struct FSWatch: Codable, Equatable, Sendable {
    var path: String
    var quietWindowSeconds: Int

    init(path: String, quietWindowSeconds: Int = 3) {
        self.path = path
        self.quietWindowSeconds = quietWindowSeconds
    }

    private enum CodingKeys: String, CodingKey { case path, quietWindowSeconds }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        path = try container.decode(String.self, forKey: .path)
        quietWindowSeconds = try container.decodeIfPresent(Int.self, forKey: .quietWindowSeconds) ?? 3
    }
}

/// A polled trigger: on `schedule`'s cadence, runs `gate` (a shell command) and only fires the job
/// when it exits zero. Stored and scheduled on its cadence today, but nothing runs the gate and no
/// tool creates one: polls are not creatable until deliverable 3 (gates).
struct PollSpec: Codable, Equatable, Sendable {
    var schedule: Schedule
    var gate: String

    init(schedule: Schedule, gate: String) {
        self.schedule = schedule
        self.gate = gate
    }

    private enum CodingKeys: String, CodingKey { case schedule, gate }

    init(from decoder: Decoder) throws {
        let container = try decoder.container(keyedBy: CodingKeys.self)
        schedule = try container.decode(Schedule.self, forKey: .schedule)
        gate = try container.decodeIfPresent(String.self, forKey: .gate) ?? ""
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

    var kind: String {
        switch self {
        case .schedule: return "schedule"
        case .fsEvent: return "fsEvent"
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
            switch spec.schedule {
            case .cron(let cron):
                return "poll cron \(cron.expression) \(cron.timeZone)"
            case .interval(let seconds):
                return "poll every \(seconds) s"
            }
        }
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
    var createdInConversationId: UUID?
    var createdAt: Date
    var enabled: Bool
    var nextFireAt: Date?
    var lastRunAt: Date?
    var pausedReason: String?

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
        pausedReason: String? = nil
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
    }

    private enum CodingKeys: String, CodingKey {
        case id, name, prompt, trigger, profile
        case destinationConversationId, createdInConversationId, createdAt
        case enabled, nextFireAt, lastRunAt, pausedReason
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
