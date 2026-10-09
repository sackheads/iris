import Foundation

/// A begun power-management activity, handed back to end it. Opaque on purpose: the real
/// implementation holds an `NSObjectProtocol` from `ProcessInfo`, which is neither `Sendable` nor
/// anything a caller should be passing around.
struct ActivityToken: Hashable, Sendable {
    private let id = UUID()
}

/// What a job run asks the system for while it is working: stay awake long enough to finish
/// (#187 §4). A protocol rather than a direct `ProcessInfo` call so a test can watch the begin/end
/// pair without putting the machine's real sleep policy under a test suite.
protocol ActivityAPI: Sendable {
    func begin(reason: String) -> ActivityToken
    func end(_ token: ActivityToken)
}

/// The real one: `.idleSystemSleepDisabled` only, so an unattended run keeps the machine from
/// idling out mid-turn but never stops a lid close or a user-requested sleep. The deadline is what
/// caps it — see `ActivityHolder` — because an assertion that outlives its run is a Mac that never
/// sleeps again.
final class ProcessInfoActivity: ActivityAPI, @unchecked Sendable {
    private let lock = NSLock()
    /// Keyed by the token handed out: `endActivity` needs the very object `beginActivity` returned.
    private var activities: [ActivityToken: NSObjectProtocol] = [:]

    func begin(reason: String) -> ActivityToken {
        let token = ActivityToken()
        let activity = ProcessInfo.processInfo.beginActivity(options: [.idleSystemSleepDisabled],
                                                             reason: reason)
        lock.withLock { activities[token] = activity }
        return token
    }

    func end(_ token: ActivityToken) {
        guard let activity = lock.withLock({ activities.removeValue(forKey: token) }) else { return }
        ProcessInfo.processInfo.endActivity(activity)
    }
}

/// Records what it was asked to do, in order, and touches nothing. Lives here rather than in the
/// test bundle because it is the seam's other half: the ordering it records — begun before the
/// turn, ended once, by whichever of the turn and the deadline came first — is the contract.
final class RecordingActivity: ActivityAPI, @unchecked Sendable {
    enum Event: Equatable, Sendable {
        case begin(String)
        case end
    }

    private let lock = NSLock()
    private var recorded: [Event] = []

    var events: [Event] { lock.withLock { recorded } }

    func begin(reason: String) -> ActivityToken {
        lock.withLock { recorded.append(.begin(reason)) }
        return ActivityToken()
    }

    func end(_ token: ActivityToken) {
        lock.withLock { recorded.append(.end) }
    }
}

/// One activity, endable exactly once, from either of the two places that race to end it: the run
/// finishing and the deadline watchdog. An actor because those two are different tasks, and a
/// second `endActivity` for an assertion already given back is the kind of imbalance that leaves a
/// Mac awake for the rest of the session.
actor ActivityHolder {
    private let api: any ActivityAPI
    private var token: ActivityToken?

    init(api: any ActivityAPI, reason: String) {
        self.api = api
        self.token = api.begin(reason: reason)
    }

    func end() {
        guard let token else { return }
        self.token = nil
        api.end(token)
    }
}
