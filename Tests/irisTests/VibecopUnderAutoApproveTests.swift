import Testing
import Foundation
@testable import iris

/// Headless runs auto-approve tools, and until #135 `requestApproval` returned before Vibecop
/// ran, so rung 5 of the perf ladder never paid the Vibecop call a real `run_command` pays.
/// With `vibecopUnderAutoApprove` the evaluation runs (and records its span) and the tool is
/// approved regardless of the verdict: a benchmark measures the cost, it never blocks on it.
@MainActor
@Suite("Vibecop under headless auto-approve", .serialized)   // tests share the process-global mock engine
struct VibecopUnderAutoApproveTests {
    /// Answers every Vibecop prompt with a fixed decision and counts how often it was asked.
    private final class CountingVibecop: AuxiliaryInferenceEngine, @unchecked Sendable {
        private let lock = NSLock()
        private var count = 0
        let decision: String
        init(decision: String) { self.decision = decision }
        var calls: Int { lock.withLock { count } }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            lock.withLock { count += 1 }
            return #"{"decision":"\#(decision)","reason":"test"}"#
        }
    }

    /// Run one approval inside a profiler turn; return the verdict and the vibecop span count.
    private func approve(auto: Bool, measure: Bool, vibecopEnabled: Bool) async -> (Bool, Int) {
        let app = AppState()
        app.autoApproveTools = auto
        app.vibecopUnderAutoApprove = measure
        let id = PerformanceProfiler.shared.beginTurn(label: "approve", source: "test")
        defer { PerformanceProfiler.shared.endTurn(id, totalMs: 0) }
        let ok = await PerformanceProfiler.$currentTurnID.withValue(id) {
            await app.requestApproval(toolName: "run_command", details: "uname -sr", vibecopEnabled: vibecopEnabled)
        }
        let spans = PerformanceProfiler.shared.activeProfileForTesting(id)?.spans["vibecop"]?.count ?? 0
        return (ok, spans)
    }

    @Test("auto-approve alone never consults Vibecop")
    func autoApproveSkipsVibecop() async {
        let engine = CountingVibecop(decision: "APPROVE")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
            let (ok, spans) = await approve(auto: true, measure: false, vibecopEnabled: true)
            #expect(ok)
            #expect(engine.calls == 0)
            #expect(spans == 0)
        }
    }

    @Test("measuring auto-approve consults Vibecop once, records the span, and approves")
    func measuredAutoApproveConsultsVibecop() async {
        let engine = CountingVibecop(decision: "APPROVE")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
            let (ok, spans) = await approve(auto: true, measure: true, vibecopEnabled: true)
            #expect(ok)
            #expect(engine.calls == 1)
            #expect(spans == 1)
        }
    }

    @Test("a DENY verdict is recorded but does not block a headless run")
    func denyStillApproves() async {
        let engine = CountingVibecop(decision: "DENY")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
            let (ok, _) = await approve(auto: true, measure: true, vibecopEnabled: true)
            #expect(ok)
            #expect(engine.calls == 1)
        }
    }

    @Test("with Vibecop disabled nothing is consulted even when measuring")
    func disabledVibecopIsNotConsulted() async {
        let engine = CountingVibecop(decision: "APPROVE")
        await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
            let (ok, spans) = await approve(auto: true, measure: true, vibecopEnabled: false)
            #expect(ok)
            #expect(engine.calls == 0)
            #expect(spans == 0)
        }
    }

    @Test("ScenarioRunner measures Vibecop unless guards are off")
    func runnerSetsTheFlag() async {
        let scenario = Scenario(name: "flag", clientMode: .fake, turns: [Scenario.Turn(prompt: "hi")],
                                scriptedResponses: [Scenario.ScriptedResponse(kind: .text, text: "ok", calls: nil)])
        let configured = await ScenarioRunner.run(scenario)
        #expect(configured.vibecopMeasured == true)
        let off = await ScenarioRunner.run(scenario, guards: .off)
        #expect(off.vibecopMeasured == false)
    }
}
