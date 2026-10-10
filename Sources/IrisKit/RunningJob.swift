import Foundation

/// One job with work in flight right now (D6 decision 5). Keyed by job id on
/// `AppState.runningJobs`, so a scheduled run and an approved call of the same job are one entry
/// with two activities, and the status item counts jobs, not runs. Transient: never on a
/// `Codable` type and never persisted (the invariant 5 pattern).
struct RunningJob: Equatable, Sendable {
    let name: String
    var activities: Int
}
