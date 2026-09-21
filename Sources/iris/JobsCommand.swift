import Foundation

/// `/jobs` (#187 §9): the deterministic view of the agency ledger. It works in every
/// conversation, pinned or not, and never wakes a model turn — a person who wants to know what
/// their jobs are doing should not have to pay for inference to find out, and a person looking at
/// a failed run needs a way to clear it that cannot itself fail.
///
/// Parsing and rendering live here, apart from `AppState`, because they are the whole surface:
/// what the table says, how a run id is matched, and what an unacknowledged failure reads like are
/// all decidable from their inputs. `AppState.handleJobsCommand` is then only the ledger calls
/// between them.
enum JobsCommand: Equatable {
    case list
    case ack(runId: String)
    case pause(name: String)
    case resume(name: String)
    case run(name: String)
    case delete(name: String)
    case usage

    static let usageText = "Usage: /jobs · /jobs ack <run id> · /jobs pause <name> · "
        + "/jobs resume <name> · /jobs run <name> · /jobs delete <name>"

    /// What `/jobs pause` writes, and what `/jobs` then prints in the Next column. Spelled once so
    /// the command that clears it and the table that shows it cannot drift.
    static let pausedByUserReason = "paused by user"

    /// The shortest run-id prefix `/jobs ack` will consider. Eight characters is what an event
    /// card prints (`EventCard.historyLine`), so it is the shortest id a person can actually have
    /// been shown; anything shorter is a typo, and matching it would risk acknowledging a failure
    /// nobody has read.
    static let minimumRunIdPrefix = 8

    // MARK: Parsing

    /// `/jobs`, `/jobs ack <run id>`, `/jobs pause|resume|run|delete <name>`; anything else is
    /// `.usage`. A run id is exactly one token — a second word means the user meant something the
    /// command cannot do, and acting on the first token alone would be a guess. A job name, by
    /// contrast, is the rest of the line: names come from `schedule_job` and may contain spaces.
    static func parse(_ text: String) -> JobsCommand {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard trimmed == "/jobs" || trimmed.hasPrefix("/jobs ") else { return .usage }
        let args = trimmed.dropFirst("/jobs".count).trimmingCharacters(in: .whitespacesAndNewlines)
        if args.isEmpty { return .list }

        if args == "ack" || args.hasPrefix("ack ") {
            let rest = args.dropFirst(3).trimmingCharacters(in: .whitespacesAndNewlines)
            let tokens = rest.split(whereSeparator: \.isWhitespace)
            guard tokens.count == 1 else { return .usage }
            return .ack(runId: String(tokens[0]))
        }
        for (verb, form) in named {
            guard args == verb || args.hasPrefix(verb + " ") else { continue }
            let rest = args.dropFirst(verb.count).trimmingCharacters(in: .whitespacesAndNewlines)
            return rest.isEmpty ? .usage : form(rest)
        }
        return .usage
    }

    /// The forms that take a job name. A table rather than four near-identical branches, since the
    /// only thing that differs between them is which case the name goes into.
    private static let named: [(String, @Sendable (String) -> JobsCommand)] = [
        ("pause", { .pause(name: $0) }),
        ("resume", { .resume(name: $0) }),
        ("run", { .run(name: $0) }),
        ("delete", { .delete(name: $0) }),
    ]

    // MARK: Run-id matching

    /// What `/jobs ack <id>` and `get_job_run` found for what the caller typed.
    enum RunMatch: Equatable {
        case none
        /// More than one run's id starts with the query — refusing beats acknowledging whichever
        /// one happened to be first.
        case ambiguous
        case found(UUID)
    }

    /// A run id as it is compared: lower-cased with the hyphens taken out, so an id copied from a
    /// card (`1a2b3c4d`), from a log (`1A2B3C4D-0000-…`) and from a paste that lost its hyphens
    /// (`1a2b3c4d0000`) are all the same id. The prefix length is counted in these characters.
    static func normalizedRunId(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespaces).lowercased().replacingOccurrences(of: "-", with: "")
    }

    /// Matches a full UUID or a unique prefix of at least `minimumRunIdPrefix` characters against
    /// candidates already in hand. A full id is matched exactly first, so an id that is also the
    /// prefix of another is never ambiguous.
    static func matchRun(_ query: String, in runs: [JobRun]) -> RunMatch {
        let needle = normalizedRunId(query)
        guard !needle.isEmpty else { return .none }
        if let exact = runs.first(where: { normalizedRunId($0.id.uuidString) == needle }) {
            return .found(exact.id)
        }
        guard needle.count >= minimumRunIdPrefix else { return .none }
        let hits = runs.filter { normalizedRunId($0.id.uuidString).hasPrefix(needle) }
        if hits.isEmpty { return .none }
        return hits.count == 1 ? .found(hits[0].id) : .ambiguous
    }

    /// The one resolver `/jobs ack` and `get_job_run` share — the only part of this type that
    /// touches the database, kept here so the two surfaces cannot drift on what an id means.
    ///
    /// A full UUID is a primary-key read: no window, no scan, so a run stays reachable by its own
    /// id forever. A prefix is a prefix query (`runs(idPrefix:)`) rather than a filter over the
    /// most recent N runs, because the run a person most needs to acknowledge — an unacknowledged
    /// failure, exempt from retention — is precisely the one that can have aged out of any window.
    static func resolveRun(_ query: String, in ledger: JobLedger) throws -> RunMatch {
        let needle = normalizedRunId(query)
        guard !needle.isEmpty else { return .none }
        if let id = UUID(uuidString: query.trimmingCharacters(in: .whitespaces)),
           try ledger.run(id: id) != nil {
            return .found(id)
        }
        guard needle.count >= minimumRunIdPrefix else { return .none }
        return matchRun(query, in: try ledger.runs(idPrefix: query))
    }

    // MARK: Rendering

    /// The whole `/jobs` listing: a table of jobs, then one line per unacknowledged failure, then
    /// the count of job rows the ledger could not read. `lastRuns` is each job's newest run, keyed
    /// by job id. `now` is a parameter rather than `Date()` so the relative next-fire text is
    /// testable.
    static func render(jobs: [Job], lastRuns: [UUID: JobRun], unacknowledged: [JobRun],
                       unreadableJobs: Int, now: Date) -> String {
        var blocks: [String] = []

        if jobs.isEmpty {
            blocks.append("No jobs.")
        } else {
            var rows = ["| Job | Trigger | Next | Last |", "| --- | --- | --- | --- |"]
            for job in jobs {
                let last = lastRuns[job.id]?.status.text ?? "never"
                rows.append("| \(cell(job.name)) | \(cell(job.trigger.summary)) | "
                            + "\(cell(nextText(for: job, now: now))) | \(cell(last)) |")
            }
            blocks.append(rows.joined(separator: "\n"))
        }

        if !unacknowledged.isEmpty {
            blocks.append(unacknowledged.map(failureLine).joined(separator: "\n"))
        }
        // Said out loud rather than swallowed: a job silently missing from the table is the one
        // case where the listing is actively misleading about what is scheduled.
        if unreadableJobs > 0 {
            blocks.append("\(unreadableJobs) unreadable job row(s)")
        }
        return blocks.joined(separator: "\n\n")
    }

    /// `⚠️ pr-sweep · failed · 1a2b3c4d · could not reach the API` — the run's own account of
    /// itself, named by the same eight characters `/jobs ack` takes back.
    static func failureLine(_ run: JobRun) -> String {
        let shortId = run.id.uuidString.lowercased().prefix(8)
        var line = "⚠️ \(run.jobName) · \(run.status.text) · \(shortId)"
        let detail = [run.outcome, run.failureReason]
            .compactMap { $0 }
            .first { !$0.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        if let detail { line += " · \(flatten(detail))" }
        return line
    }

    /// When this job fires next, as a person reads it. A paused job says why instead; a watch has
    /// no cadence to report. A job part-way up the retry ladder says so beside its next fire (§9),
    /// because "in 1 m" on a five-minute job is otherwise unexplained.
    static func nextText(for job: Job, now: Date) -> String {
        if let reason = job.pausedReason { return "paused: \(reason)" }
        if !job.enabled { return "disabled" }
        var text = "—"
        if case .fsEvent = job.trigger {
            text = "—"
        } else if let next = job.nextFireAt {
            text = relative(from: now, to: next)
        }
        guard job.retryAttempt > 0 else { return text }
        return "\(text) · retry \(job.retryAttempt)/\(JobRunner.backoff.count)"
    }

    /// One unit, rounded down: "in 3 m" is read as "not for a few minutes", and a fire that is
    /// already overdue (the scheduler is between ticks, or the app was asleep) is "due" rather than
    /// a negative interval.
    private static func relative(from now: Date, to date: Date) -> String {
        let delta = date.timeIntervalSince(now)
        if delta <= 0 { return "due" }
        if delta < 60 { return "in \(Int(delta)) s" }
        if delta < 3_600 { return "in \(Int(delta / 60)) m" }
        if delta < 86_400 { return "in \(Int(delta / 3_600)) h" }
        return "in \(Int(delta / 86_400)) d"
    }

    /// A table cell: job names, trigger paths and pause reasons are not written by the harness, and
    /// an unescaped `|` in any of them would open a column of its own.
    private static func cell(_ text: String) -> String {
        flatten(text).replacingOccurrences(of: "|", with: "\\|")
    }

    private static func flatten(_ text: String) -> String {
        text.split(whereSeparator: \.isNewline).joined(separator: " ")
    }
}
