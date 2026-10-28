import os

/// #463 decision 14: what this process is, set once by `IrisMain` before anything else in its
/// branch runs. `AppState.shared` is legal only in `.app`, and only while this process holds its
/// home's store lock. Never set in the shared test process (only in an exit test's child), so a
/// test that reaches `.shared` crashes the suite: that is the alarm, and it has no disarm.
enum ProcessRole: Sendable, Equatable {
    case app, runJob, perf, bench, seed, probe, eval

    private static let storage = OSAllocatedUnfairLock<ProcessRole?>(initialState: nil)

    static var current: ProcessRole? { storage.withLock { $0 } }

    /// Once per process. Setting a different role later is a programming error.
    static func set(_ role: ProcessRole) {
        storage.withLock { current in
            precondition(current == nil || current == role,
                         "ProcessRole set twice: \(String(describing: current)), then \(role)")
            current = role
        }
    }

    static func mayUseSharedAppState(role: ProcessRole?, holdsStore: Bool) -> Bool {
        role == .app && holdsStore
    }
}
