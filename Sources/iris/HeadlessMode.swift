import Foundation

/// Task-scoped switch for headless (`--bench`, fake-lane `--perf run`) execution.
///
/// Deliberately **not** read from the process environment. This flag skips `InjectionGuard`'s
/// model-backed tiers, so an env var would let anything that can set the app's environment —
/// including a shell command the agent itself was talked into running — turn off the very
/// defense that exists to contain injected instructions. The only legitimate setters are
/// `BenchCLI.run` (a fake scenario) and `PerfCLI.execute` (a fake-lane suite).
///
/// Task-local rather than process-global (#318). A process-global flip is a one-way latch for
/// the rest of that process: the first test that drives a fake-lane suite through
/// `PerfCLI.execute` would turn headless mode on for every suite that happens to run afterward
/// in the same `swift test` process (AGENTS invariant 7) — and `TurnContextTests.agentsMdGuardedOnce`
/// used to gate its own assertions on `!HeadlessMode.isEnabled`, so it would have started silently
/// skipping them the moment that happened, rather than failing.
///
/// `$scoped` is the same seam as `CoreMLEvaluator.$scopedModel` / `AuxiliaryModelManager.$scopedEngines`:
/// visible only inside the `withEnabled` body and the structured tasks it spawns (task groups,
/// `async let`), so a fake-lane run through `execute`/`run` leaves the process exactly as it
/// found it the moment that call returns — nothing to reset, nothing for a later suite to inherit.
///
/// `withEnabled` is bound at the CLI entry point itself, wrapping everything from there to that
/// call's return. For the real `iris --bench` / `iris --perf run` processes that span is, in
/// practice, the entire remaining process run — `main.swift` exits right after — so this reads
/// identically to the old process-global flag for real CLI behavior. The one thing a task-local
/// does NOT cover is a `Task.detached` spawned inside that call tree: a detached task starts a new
/// task tree and does not inherit `$scoped`. None of today's detached tasks in that path
/// (`ToolExecutor`'s file-I/O helpers, `AppState`'s store-write/ledger tasks) read `isEnabled` or
/// re-derive a `KeychainManager`/`ConversationStore` singleton — they operate on an instance
/// already resolved inside the scope — but a new detached task on this path must be checked
/// against the readers below before assuming it sees headless mode.
///
/// Readers, and where each gets its value:
///   - `KeychainManager.usesInMemoryStore` — computed once, at `KeychainManager.shared`'s first
///     touch. In both CLI entry points that touch happens inside the scope (via `ConfigManager.shared`
///     loading secrets from inside the wrapped run), so it sees the scoped value. Under `swift test`
///     the `XCTestCase`-linked check already forces the in-memory store regardless.
///   - `ConversationStore.makeDefault()` — called once, as `AppState`'s default-parameter
///     initializer, evaluated at the `AppState()` call site inside `ScenarioRunner.run`, which
///     only ever runs inside the scope for a fake lane.
///   - `InjectionGuard.classifyDetailed` — read on every call, from inside `IrisEngine`'s
///     `withTaskGroup` tool dispatch (AGENTS invariant 3), which is structured concurrency and so
///     inherits the scope from its parent task.
enum HeadlessMode {
    @TaskLocal private static var scoped: Bool?

    static var isEnabled: Bool {
        scoped ?? false
    }

    /// Runs `operation` with headless mode enabled for its entire structured call tree. Called
    /// only from `BenchCLI.run` and `PerfCLI.execute`'s fake lane — production never sets this
    /// anywhere else, and a test that drives either entry point directly sees the scope end when
    /// `operation` returns, leaving the process as it found it.
    ///
    /// `isolation` forwards the caller's actor (both call sites are `@MainActor`) so the compiler
    /// doesn't treat handing an actor-isolated closure to this nonisolated function as crossing an
    /// isolation boundary — the same parameter `TaskLocal.withValue` itself takes.
    static func withEnabled<T>(
        isolation: isolated (any Actor)? = #isolation,
        _ operation: () async throws -> T
    ) async rethrows -> T {
        try await $scoped.withValue(true, operation: operation, isolation: isolation)
    }
}
