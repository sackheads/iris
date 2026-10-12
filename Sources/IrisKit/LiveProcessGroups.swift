import Foundation

/// #463 decision 17: every `ProcessGroupRunner` group this process has spawned and not yet
/// reaped, so a CLI that is stopping can end them rather than leave them running after it.
///
/// A lock-protected box, not an actor: the signal path reads it synchronously, with no hop onto
/// the cooperative pool (#372).
///
/// It holds runners, not group ids: a signal always goes through the runner's own queue, which
/// never signals once it has reaped its leader, so nothing here can reach a reused group id.
/// A runner leaves only once it has reaped its leader, which is after any kill ladder's SIGKILL.
/// Known gap: a background job that redirected its output, which invariant 4 deliberately leaves
/// running, leaves this registry when its leader is reaped. Nothing ends it on exit.
final class LiveProcessGroups: @unchecked Sendable {
    static let shared = LiveProcessGroups()

    private let lock = NSLock()
    private var runners: [ObjectIdentifier: ProcessGroupRunner] = [:]
    /// Set by `closeAndSnapshot`: the process is exiting, and no new group may start.
    private var closed = false

    /// Records `runner` just before its spawn, so a kill that snapshots now still reaches it: the
    /// kill waits on the runner's queue, where the spawn is. False once closed: the runner must
    /// not spawn, since nothing would end it before `_exit`.
    func admit(_ runner: ProcessGroupRunner) -> Bool {
        lock.withLock {
            guard !closed else { return false }
            runners[ObjectIdentifier(runner)] = runner
            return true
        }
    }
    func remove(_ runner: ProcessGroupRunner) { lock.withLock { _ = runners.removeValue(forKey: ObjectIdentifier(runner)) } }
    var count: Int { lock.withLock { runners.count } }

    /// SIGTERM to every group, then SIGKILL after `ProcessGroupRunner.terminateGraceSeconds`:
    /// each runner's ladder, on its own dispatch queue (invariant 4). Returns at once.
    func terminateAll() { snapshot().forEach { $0.terminate() } }

    /// SIGKILL to every group, now, for an exit that will not wait. Returns once each is sent.
    /// No runner's `onKilled` fires (see `ProcessGroupRunner.killNow`): pair it with
    /// `LiveContainerNames.deleteAll` for the containers those groups were driving.
    /// Closes the registry first, in the same lock as the snapshot, so no runner can be admitted
    /// after it and spawn behind the kill.
    func killAll() { closeAndSnapshot().forEach { $0.killNow() } }

    /// Closes the registry and copies out its runners under one lock.
    func closeAndSnapshot() -> [ProcessGroupRunner] {
        lock.withLock {
            closed = true
            return Array(runners.values)
        }
    }

    /// Blocks until every group has been reaped, or `seconds` pass: what a stopping CLI waits on
    /// before `_exit`, so a group the SIGTERM did not end gets its SIGKILL rung first. Polls with
    /// `usleep` on the caller's thread, never the cooperative pool (invariant 4). True when drained.
    func waitUntilEmpty(within seconds: TimeInterval) -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while count > 0 {
            if Date() >= deadline { return false }
            usleep(10_000)
        }
        return true
    }

    /// Copied out first: a runner finishing calls `remove` from its queue, and `killNow` waits on
    /// that queue, so holding this lock across either would deadlock.
    private func snapshot() -> [ProcessGroupRunner] { lock.withLock { Array(runners.values) } }
}
