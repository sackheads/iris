import Testing
import Foundation
@testable import IrisKit

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

    /// By design: a task-local is visible to the task that set it and every task it spawns,
    /// *including* a plain unstructured `Task { ... }` (Swift copies the creating task's
    /// task-locals into it) — but NOT a `Task.detached`, which starts an unrelated task tree with
    /// no inherited context. This mirrors `CoreMLEvaluator.$scopedModel` and
    /// `AuxiliaryModelManager.$scopedEngines`, which have the same gap; AGENTS invariant 7 doesn't
    /// spell this particular case out, but it's the same family of "a scope doesn't reach where you
    /// assumed it would" hazard those seams exist to guard against. Today's detached tasks on the
    /// CLI entry points' call path (`ToolExecutor`'s file-I/O helpers, `AppState`'s store-write and
    /// ledger tasks) never read `HeadlessMode.isEnabled` or re-derive a
    /// `KeychainManager`/`ConversationStore` singleton, so none of them are affected — but a future
    /// detached task on that path would silently read the process default (`false`) instead of the
    /// CLI's intent.
    @Test("a detached task started inside the scope does not inherit it")
    func detachedTaskDoesNotInherit() async {
        var sawInsideDetached: Bool?
        await HeadlessMode.withEnabled {
            sawInsideDetached = await Task.detached { HeadlessMode.isEnabled }.value
        }
        #expect(sawInsideDetached == false)
    }

    // MARK: - The CLI entry points actually enter the scope (fix round 1, item 3)
    //
    // The tests above cover the seam in isolation; they would stay green even if someone deleted
    // the `HeadlessMode.withEnabled` call from `BenchCLI.run` or `PerfCLI.execute`'s fake lane,
    // since nothing exercises those entry points. `BenchCLI.runScenario` and
    // `PerfCLI.runSuiteRespectingLane` are the halves of each entry point that make the
    // fake/not-fake decision and enter the scope — extracted so these tests can call them directly
    // without also calling `IrisDefaults.useVolatileCopyOfStandard()`, a separate process-wide
    // latch (#324) that neither `run` nor `execute` resets and that no test may trip.

    @MainActor
    @Test("BenchCLI's fake lane actually enters the headless scope")
    func benchCLIFakeLaneEntersScope() async {
        let probe = HeadlessProbingLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil)
        ])
        // `clientOverride` wins over `scenario.clientMode`, so the probe answers directly —
        // `defaultScenario`'s own `scriptedResponses` are never consulted.
        _ = await BenchCLI.runScenario(BenchCLI.defaultScenario, clientOverride: probe)
        #expect(probe.sawHeadlessDuringCall)
    }

    @MainActor
    @Test("PerfCLI's fake-lane suite actually enters the headless scope")
    func perfCLIFakeLaneEntersScope() async throws {
        let probe = HeadlessProbingLLMClient(responses: [
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "Canberra.")]))], usageMetadata: nil)
        ])
        let suite = PerfSuite(name: "scope-probe", lane: .fake, repetitions: 1, rungs: [5],
                              scenarios: ["perf/prompts/fake/text-only.json"])
        let code = try await PerfCLI.runSuiteRespectingLane(suite, repetitionsOverride: 1,
                                                            out: FileManager.default.temporaryDirectory
                                                                .appendingPathComponent("iris-perfcli-scope-\(UUID().uuidString)").path,
                                                            dumpRequestsDir: nil, client: probe)
        #expect(code == 0)
        #expect(probe.sawHeadlessDuringCall)
    }
}

/// Samples `HeadlessMode.isEnabled` from inside a live model call. See
/// `RunJobCLITests.HeadlessProbingLLMClient` for the same pattern and the reason sampling must
/// happen during the call rather than by reading `isEnabled` afterward.
private final class HeadlessProbingLLMClient: LLMClientProtocol, @unchecked Sendable {
    private let inner: FakeLLMClient
    private(set) var sawHeadlessDuringCall = false
    init(responses: [GeminiResponse]) { inner = FakeLLMClient(responses: responses) }
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        if HeadlessMode.isEnabled { sawHeadlessDuringCall = true }
        return try await inner.generateContent(request: request, tier: tier)
    }
}
