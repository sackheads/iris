import Foundation

/// What the ledger says is waiting on the owner (D6 decision 16): blocked runs nobody has
/// acknowledged, plain failures, and paused jobs split by whose doing the pause was. Cached on
/// `AppState.ledgerAttention` and refreshed after the writes that move it, never polled.
struct LedgerAttention: Equatable, Sendable {
    struct Blocked: Equatable, Sendable {
        let runId: UUID
        let jobId: UUID
        let jobName: String
        let tool: String?
        /// A read-only job's refusal rather than a wait on approval (#553).
        var refusedByProfile = false
    }

    struct Paused: Equatable, Sendable {
        let jobId: UUID
        let name: String
        let reason: String
    }

    var blocked: [Blocked] = []
    var failedCount = 0
    /// Paused by a breaker, a budget, the retry ladder, a failing gate, a vanished folder: each
    /// needs `/jobs resume`, so each lights the icon (owner ruling 3).
    var attentionPaused: [Paused] = []
    /// Paused by the owner, a count in the menu only.
    var ownerPausedCount = 0

    static let empty = LedgerAttention()

    /// The pauses the owner made: `/jobs pause`, and the seeder's pause of every job it copied
    /// into a dev home. Neither waits on anyone, so neither lights the icon or notifies. One set,
    /// the ledger's (ruling R4): it also decides which pauses no unattended write may replace and
    /// which a model may not lift without turning the URL trigger off.
    static var ownerPauseReasons: Set<String> { JobLedger.ownerPauseReasons }

    static func make(unacknowledged: [JobRun], paused: [Job]) -> LedgerAttention {
        var out = LedgerAttention()
        for run in unacknowledged {
            switch run.status {
            case .blockedOnApproval:
                out.blocked.append(Blocked(runId: run.id, jobId: run.jobId, jobName: run.jobName,
                                           tool: run.blockedTool, refusedByProfile: run.refusedByProfile))
            case .failed:
                out.failedCount += 1
            case .running, .completed, .interrupted:
                break
            }
        }
        for job in paused {
            guard let reason = job.pausedReason else { continue }
            if ownerPauseReasons.contains(reason) {
                out.ownerPausedCount += 1
            } else {
                out.attentionPaused.append(Paused(jobId: job.id, name: job.name, reason: reason))
            }
        }
        return out
    }

    static func read(_ ledger: JobLedger) throws -> LedgerAttention {
        make(unacknowledged: try ledger.unacknowledgedFailures(), paused: try ledger.pausedJobs())
    }
}
