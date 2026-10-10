import Foundation

/// `iris://run-job/<token>` (D6 decisions 10 and 12): the link that fires one opted-in job. It
/// carries no input, so no URL content reaches a model and the taint is untouched. Adding any
/// parameter reopens decision 12.
enum RunJobURL {
    static let host = "run-job"

    /// D6 decision 13: URL fires per job per rolling hour, below the breaker's 6.
    static let maxFiresPerHour = 3

    /// Plan note 9: a URL fire costs Iris one line, posted now and updated when admission answers.
    static func firingLine(_ name: String) -> String { "Firing \(name) from a URL …" }
    static func firedLine(_ name: String) -> String { "Fired \(name) from a URL; the result arrives as a card." }
    static func notStartedLine(_ name: String, _ why: String) -> String {
        "Refused a URL fire of \(name): it was not started, because \(why)."
    }
    static func queuedLine(_ name: String) -> String {
        "Queued a URL fire of \(name): a run is already in progress, so it will start after that one."
    }
    static func pausedLine(_ name: String, _ reason: String) -> String {
        "Refused a URL fire of \(name): it was not started, and the job is now paused (\(reason))."
    }

    /// The line a URL fire ends on, for what admission decided. A queued fire was not refused,
    /// and a breaker or budget answer paused the job, so neither reads as a plain refusal.
    static func admissionLine(_ name: String, _ admission: JobRunner.Admission) -> String {
        switch admission {
        case .run: return firedLine(name)
        case .queued: return queuedLine(name)
        case .pauseBreaker(let count): return pausedLine(name, JobRunner.breakerReason(count: count))
        case .pauseBudget(let scope, let used, let limit):
            return pausedLine(name, JobRunner.budgetReason(scope: scope, used: used, limit: limit))
        default: return notStartedLine(name, JobRunner.refusalText(admission) ?? "")
        }
    }

    static func url(token: String, identity: BuildIdentity) -> String {
        "\(identity.urlScheme)://\(host)/\(token)"
    }
}
