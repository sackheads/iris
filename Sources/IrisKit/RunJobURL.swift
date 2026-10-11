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

    /// Decision 14's lines. Fixed text, the job's name and the holder's pid at most: never the
    /// token or the link.
    static func waitingLine(_ name: String, pid: Int32) -> String {
        "Waiting for the other Iris process (pid \(pid)) to finish before firing \(name) from a URL."
    }
    static func waitEndedLine(_ name: String, pid: Int32) -> String {
        "The other Iris process (pid \(pid)) finished; firing \(name) from the link that was waiting."
    }
    static func gaveUpLine(_ name: String, pid: Int32) -> String {
        "Did not fire \(name) from a URL: the other Iris process (pid \(pid)) was still running after 10 minutes. Open the link again; try again after the other Iris process finishes."
    }
    static func waitAbandonedLine(_ name: String, reason: String) -> String {
        "Did not fire \(name) from the link that was waiting: \(reason)."
    }
    static func foreignHolderNotice(pid: Int32) -> String {
        "Another Iris process (pid \(pid)) held the store at launch. A link opened before it finishes waits for it."
    }
    static let deletedWhileWaitingReason = "it was deleted while it waited"
    static let replacedWhileWaitingReason = "its URL trigger was turned off or replaced while it waited"

    static func url(token: String, identity: BuildIdentity) -> String {
        "\(identity.urlScheme)://\(host)/\(token)"
    }

    /// The rolling window both the URL limit and refusal coalescing count over.
    static let window: TimeInterval = 3_600
    /// How often a coalesced refusal line catches up with its count (the D2 throttle).
    static let refusalFlushInterval: TimeInterval = 1

    /// Why a link was refused before any job was looked up. A fixed sentence each: the link is
    /// unauthenticated input, so no part of it is echoed into Iris.
    enum Refusal: Error, Equatable, Sendable {
        case otherScheme, wrongHost, hasQuery, hasFragment, wrongPath, malformedToken, unreadable

        var sentence: String {
            switch self {
            case .otherScheme: return "the link is for the other Iris build"
            case .wrongHost: return "the link is not a run-job link"
            case .hasQuery, .hasFragment: return "run-job links take no input, and this one carried some"
            case .wrongPath: return "the link has something other than one token after run-job/"
            case .unreadable: return "the link could not be read as a URL"
            case .malformedToken: return "the link's token is not one Iris made; a job's id or name does not work, and `/jobs url <name> on` makes a link"
            }
        }
    }

    /// The token, or why the link is refused (decision 12): this build's scheme, the `run-job`
    /// host (in any case, as hosts are, but never percent-encoded), no user, password, port,
    /// query or fragment, and exactly one path component that is a well-formed token. The path
    /// is read still encoded, and a well-formed token has no `%`, so nothing is decoded first.
    static func parse(_ url: URL, identity: BuildIdentity) -> Result<String, Refusal> {
        guard let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.scheme?.lowercased() == identity.urlScheme else { return .failure(.otherScheme) }
        guard parts.percentEncodedUser == nil, parts.percentEncodedPassword == nil, parts.port == nil,
              parts.percentEncodedHost?.lowercased() == host else { return .failure(.wrongHost) }
        guard parts.percentEncodedQuery == nil else { return .failure(.hasQuery) }
        guard parts.percentEncodedFragment == nil else { return .failure(.hasFragment) }
        let path = parts.percentEncodedPath
        guard path.hasPrefix("/") else { return .failure(.wrongPath) }
        let token = String(path.dropFirst())
        guard !token.isEmpty, !token.contains("/") else { return .failure(.wrongPath) }
        guard URLTriggerToken.isWellFormed(token) else { return .failure(.malformedToken) }
        // And the link must be exactly the one Iris makes for that token, with only the scheme's
        // and the host's case free: anything URLComponents normalised away (`run-job:` with an
        // empty port, say) is refused rather than read past.
        let canonical = Self.url(token: token, identity: identity)
        let incoming = url.absoluteString
        let authority = canonical.utf8.count - token.utf8.count
        guard incoming.utf8.count == canonical.utf8.count,
              String(decoding: incoming.utf8.prefix(authority), as: UTF8.self).lowercased()
                == String(decoding: canonical.utf8.prefix(authority), as: UTF8.self),
              incoming.hasSuffix("/" + token) else { return .failure(.wrongHost) }
        return .success(token)
    }

    static let notSetUpReason = "Iris is not set up yet; finish setup in the chat window, then open the link again"
    static let startupFloodReason = "too many links arrived while Iris was starting"
    static let unknownTokenReason = "the link matches no job's URL trigger; it may have been turned off or replaced"
    static let ledgerUnreadableReason = "the jobs table could not be read"
    static let overLimitReason = "URL fires are limited to \(maxFiresPerHour) an hour per job"
    static let disabledReason = "it is disabled"
    static func triggerOffReason(_ name: String) -> String { "\(name) has URL triggers off" }
    static func pausedReason(_ job: Job) -> String {
        "it is paused (\(job.pausedReason ?? "")); `/jobs resume \(job.name)` first"
    }

    /// One refusal line, or the running count of a coalesced one (decision 13, plan note 8).
    static func refusalLine(subject: String?, reason: String, count: Int) -> String {
        let of = subject.map { " of \($0)" } ?? ""
        if count <= 1 { return "Refused a URL fire\(of): \(reason)." }
        return "Refused \(count) URL fires\(of) in the last hour. The latest: \(reason)."
    }
}

/// A URL fire the `queue` policy is holding: when it was sent, and which hold it joined.
struct HeldURLFire: Equatable, Sendable {
    let sent: Date
    let generation: Int
}

/// The line a coalesced URL refusal keeps updating, by job id or `unmatched`. The count is
/// trusted between flushes; `written` is what the line last showed.
struct URLRefusalLine: Sendable {
    var messageId: UUID
    let since: Date
    var count: Int
    var written: Int
    var conversationId: UUID
    let subject: String?
    var reason: String
}

/// The URL fires of one job dispatched since its last moment with none outstanding. Their rows
/// may or may not be written yet, so while the batch is open the limit counts its dispatches,
/// every one and with no window filter, instead of any row started at or after `since`: each
/// fire is counted once, whether its row has landed or not, and never less.
///
/// A fire is outstanding until the runner reports its own answer (`pending`), and after that,
/// when the answer was `.queued`, until the held run it joined has begun (`held`).
struct URLFireBatch: Equatable, Sendable {
    let since: Date
    var dispatched: [Date] = []
    var pending = 0
    var held: [HeldURLFire] = []

    var isOutstanding: Bool { pending > 0 || !held.isEmpty }
}

/// D6 decision 14's wait for a foreign store holder. Pure.
enum URLDeferral {
    enum Step: Equatable, Sendable { case wait, fire, giveUp }

    static let interval: TimeInterval = 5
    static let deadline: TimeInterval = 600

    /// A holder gone at the deadline still fires: the wait was for it, and it is over.
    static func decide(holderAlive: Bool, waited: TimeInterval) -> Step {
        if !holderAlive { return .fire }
        return waited >= deadline ? .giveUp : .wait
    }
}

/// How the re-check is scheduled: on a dispatch queue, never `Task.sleep` on the cooperative pool
/// (the invariant 4 rule). A seam so a test can fire it by hand.
struct URLDeferralTimer: Sendable {
    let schedule: @MainActor @Sendable (TimeInterval, @escaping @MainActor @Sendable () -> Void) -> Void

    static let dispatch = URLDeferralTimer { delay, body in
        DispatchQueue.main.asyncAfter(deadline: .now() + delay) { MainActor.assumeIsolated { body() } }
    }
}

/// A URL fire waiting for a foreign store holder to finish. One per job. It keeps the token's
/// digest, never the token, so the wait's end can tell a rotated trigger from the one that was
/// opened.
struct PendingURLFire: Sendable {
    let jobId: UUID
    let jobName: String
    let tokenHash: String
    let holder: Int32
    /// The holder's start time when the wait began, so a reused pid ends the wait (Task 26).
    let holderStart: ProcessStart?
    let since: Date
    let lineId: UUID
    let conversationId: UUID
}
