import Testing
import Foundation
@testable import iris

/// #318: `HeadlessMode` used to be a process-global, one-way latch — the first test that drove a
/// fake-lane suite through `PerfCLI.execute` would turn it on for every suite that ran afterward in
/// the same `swift test` process. It is now task-scoped (`$scoped`, bound by `withEnabled`), the
/// same seam `CoreMLEvaluator.$scopedModel` and `AuxiliaryModelManager.$scopedEngines` use.
///
/// These tests exercise the seam itself (`HeadlessMode.withEnabled`) rather than a full
/// `PerfCLI.execute(.run(...))` call: `execute`'s `.run` case also calls
/// `IrisDefaults.useVolatileCopyOfStandard()` unconditionally, which is its OWN process-global latch
/// that no test exercises today (AGENTS invariant 7) — driving a real suite through `execute` here
/// would introduce exactly the class of bug this issue fixes, in a different flag. `withEnabled` is
/// the mechanism both `BenchCLI.run` and `PerfCLI.execute`'s fake lane are built on, so asserting
/// against it covers what those entry points actually do to `HeadlessMode`.
@Suite("HeadlessMode (#318)")
struct HeadlessModeTests {
    @Test("isEnabled is false with no scope active")
    func noScopeIsOff() {
        #expect(!HeadlessMode.isEnabled)
    }

    @Test("withEnabled turns isEnabled on for its body and leaves it off once it returns")
    func scopeDoesNotLeak() async {
        #expect(!HeadlessMode.isEnabled)
        var sawEnabledInside = false
        await HeadlessMode.withEnabled {
            sawEnabledInside = HeadlessMode.isEnabled
        }
        #expect(sawEnabledInside)
        #expect(!HeadlessMode.isEnabled,
                "a fake-lane run's scope must not leak into suites that run after it in this process (#318)")
    }

    @Test("a real reader (ConversationStore.shouldIsolate) sees headless on inside the scope")
    func readerSeesScopedValue() async {
        #expect(!ConversationStore.shouldIsolate(xctestLinked: false, headless: HeadlessMode.isEnabled, volatileDefaults: false))
        await HeadlessMode.withEnabled {
            #expect(ConversationStore.shouldIsolate(xctestLinked: false, headless: HeadlessMode.isEnabled, volatileDefaults: false))
        }
        #expect(!ConversationStore.shouldIsolate(xctestLinked: false, headless: HeadlessMode.isEnabled, volatileDefaults: false))
    }

    @Test("structured children of the scope (a task group) inherit it")
    func structuredChildInherits() async {
        let sawEnabledInChild = await HeadlessMode.withEnabled {
            await withTaskGroup(of: Bool.self) { group in
                group.addTask { HeadlessMode.isEnabled }
                return await group.next() ?? false
            }
        }
        #expect(sawEnabledInChild)
    }

    /// By design: a task-local is only visible to the task that set it and the structured children
    /// that task spawns (task groups, `async let`). `Task.detached` starts an unrelated task tree,
    /// so it does not inherit `$scoped` even when started from inside `withEnabled`'s body — this
    /// mirrors `CoreMLEvaluator.$scopedModel` and `AuxiliaryModelManager.$scopedEngines`, which have
    /// the same gap. Today's detached tasks on the CLI entry points' call path (`ToolExecutor`'s
    /// file-I/O helpers, `AppState`'s store-write and ledger tasks) never read `HeadlessMode.isEnabled`
    /// or re-derive a `KeychainManager`/`ConversationStore` singleton, so none of them are affected —
    /// but a future detached task on that path would silently read the process default (`false`)
    /// instead of the CLI's intent, exactly the hazard AGENTS invariant 7 calls out for task-locals.
    @Test("a detached task started inside the scope does not inherit it")
    func detachedTaskDoesNotInherit() async {
        var sawInsideDetached: Bool?
        await HeadlessMode.withEnabled {
            sawInsideDetached = await Task.detached { HeadlessMode.isEnabled }.value
        }
        #expect(sawInsideDetached == false)
    }
}
