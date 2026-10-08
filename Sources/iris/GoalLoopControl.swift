import Foundation

/// An engine's goal-loop bookkeeping, lock-based so it can be read and stopped synchronously from
/// outside the actor — a subagent's `stop` closure runs from a cancellation handler (#399).
///
/// The goal loop runs one turn per `processInput`, then schedules the next as a reprompt task of
/// its own. So "the first `processInput` returned" is not the loop's end: the loop is live while a
/// turn is running or a reprompt is pending, and only that says when a subagent has finished.
final class GoalLoopControl: @unchecked Sendable {
    private struct Pending {
        let token: UUID
        let task: Task<Void, Never>
    }

    private let lock = NSLock()
    private var pending: [UUID: Pending] = [:]
    private var turnsInFlight: [UUID: Int] = [:]
    private var halted: Set<UUID> = []
    /// Called as each turn begins (true), before it does anything, and as the last turn in flight
    /// ends (false): a subagent's per-turn deadline runs only between the two (#402), so it is
    /// stamped at the turn's real start and the gap between turns never counts against it.
    private var turnObservers: [UUID: @Sendable (Bool) -> Void] = [:]

    /// Stores `task` as the conversation's pending reprompt, cancelling the one it replaces.
    /// Nothing is stored for a halted loop: the task is cancelled instead and the call returns
    /// false. This is the halt's only check, and it is under the same lock as the halt, so no
    /// reprompt can be scheduled after one.
    @discardableResult
    func setReprompt(_ task: Task<Void, Never>, token: UUID, for id: UUID) -> Bool {
        let (toCancel, accepted): (Task<Void, Never>?, Bool) = lock.withLock {
            if halted.contains(id) { return (task, false) }
            let old = pending[id]?.task
            pending[id] = Pending(token: token, task: task)
            return (old, true)
        }
        toCancel?.cancel()
        return accepted
    }

    /// Called by a reprompt task as it exits: removes its entry unless a newer one replaced it.
    func finishReprompt(token: UUID, for id: UUID) {
        lock.withLock {
            if pending[id]?.token == token { pending[id] = nil }
        }
    }

    func cancelReprompt(for id: UUID) {
        let task = lock.withLock { pending.removeValue(forKey: id)?.task }
        task?.cancel()
    }

    func beginTurn(for id: UUID) {
        let observer = lock.withLock {
            turnsInFlight[id, default: 0] += 1
            return turnObservers[id]
        }
        observer?(true)
    }

    /// Sets (or with nil, removes) what is called as a turn begins and as the last one ends.
    func observeTurns(for id: UUID, _ observer: (@Sendable (Bool) -> Void)?) {
        lock.withLock { turnObservers[id] = observer }
    }

    func endTurn(for id: UUID) {
        let observer: (@Sendable (Bool) -> Void)? = lock.withLock {
            let n = (turnsInFlight[id] ?? 1) - 1
            turnsInFlight[id] = n > 0 ? n : nil
            return n > 0 ? nil : turnObservers[id]
        }
        observer?(false)
    }

    /// True while a turn is running on the conversation or a reprompt is pending for it.
    func isLive(for id: UUID) -> Bool {
        lock.withLock { pending[id] != nil || (turnsInFlight[id] ?? 0) > 0 }
    }

    /// Ends the loop for good: no reprompt is scheduled after this, and the pending one — which
    /// is also where any turn after the first runs — is cancelled. The flag is set before the
    /// cancel, so a turn unwinding from it cannot schedule another.
    /// `cancelling: false` only forbids further turns, leaving a finishing turn to finish — for a
    /// loop that ended on its own (`goal_complete`), whose last turn is still writing its results.
    func halt(_ id: UUID, cancelling: Bool = true) {
        let task: Task<Void, Never>? = lock.withLock {
            halted.insert(id)
            return cancelling ? pending.removeValue(forKey: id)?.task : nil
        }
        task?.cancel()
    }

}
