import Testing
import Foundation
@testable import iris

@Suite("PerformanceProfiler value types")
struct PerformanceProfilerValueTypeTests {

    @Test("CommandProfile.add accumulates ms and count per category")
    func addAccumulates() {
        var profile = CommandProfile(id: UUID(), label: "test", source: "UI", startedAt: Date())
        profile.add(.primaryLLM, durationMs: 100)
        profile.add(.primaryLLM, durationMs: 50)
        profile.add(.vibecop, durationMs: 30)

        #expect(profile.categories[.primaryLLM]?.ms == 150)
        #expect(profile.categories[.primaryLLM]?.count == 2)
        #expect(profile.categories[.vibecop]?.ms == 30)
        #expect(profile.categories[.vibecop]?.count == 1)
    }

    @Test("derivedOtherMs is total minus top-level phases, clamped at 0")
    func derivedOther() {
        var profile = CommandProfile(id: UUID(), label: "test", source: "UI", startedAt: Date())
        profile.totalMs = 1000
        profile.add(.primaryLLM, durationMs: 400)
        profile.add(.toolExecution, durationMs: 300)
        profile.add(.hooks, durationMs: 50)
        profile.add(.contextAssembly, durationMs: 50)
        // vibecop/injection are sub-measures of tool time and must NOT reduce Other
        profile.add(.vibecop, durationMs: 200)
        profile.add(.injectionGuard, durationMs: 100)

        #expect(profile.derivedOtherMs == 200) // 1000 - (400+300+50+50)
    }

    @Test("derivedOtherMs clamps to 0 when phases exceed total")
    func derivedOtherClamps() {
        var profile = CommandProfile(id: UUID(), label: "test", source: "UI", startedAt: Date())
        profile.totalMs = 100
        profile.add(.primaryLLM, durationMs: 400)
        #expect(profile.derivedOtherMs == 0)
    }

    @Test("guard categories are flagged as sub-measures")
    func guardFlag() {
        #expect(PerfCategory.vibecop.isGuardSubMeasure)
        #expect(PerfCategory.injectionGuard.isGuardSubMeasure)
        #expect(!PerfCategory.toolExecution.isGuardSubMeasure)
        #expect(!PerfCategory.primaryLLM.isGuardSubMeasure)
    }
}

@Suite("PerformanceProfiler lifecycle")
struct PerformanceProfilerLifecycleTests {

    @Test("record attributes to the active turn")
    func recordAttributes() {
        let profiler = PerformanceProfiler()
        let id = profiler.beginTurn(label: "hello world", source: "UI")
        profiler.record(turnID: id, category: .primaryLLM, durationMs: 42)
        profiler.record(turnID: id, category: .primaryLLM, durationMs: 8)

        #expect(profiler.activeProfileForTesting(id)?.categories[.primaryLLM]?.ms == 50)
    }

    @Test("record with nil turn id is a no-op")
    func recordNilNoop() {
        let profiler = PerformanceProfiler()
        profiler.record(turnID: nil, category: .primaryLLM, durationMs: 42) // must not crash
        #expect(profiler.activeCountForTesting == 0)
    }

    @Test("endTurn moves the profile into recentCommands with its total")
    func endTurnFinalizes() async {
        let profiler = PerformanceProfiler()
        let id = profiler.beginTurn(label: "hello", source: "UI")
        profiler.record(turnID: id, category: .toolExecution, durationMs: 10)
        profiler.endTurn(id, totalMs: 100)

        // recentCommands is updated on the main thread; give it a tick.
        try? await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            #expect(profiler.recentCommands.count == 1)
            #expect(profiler.recentCommands.first?.totalMs == 100)
            #expect(profiler.recentCommands.first?.label == "hello")
        }
        #expect(profiler.activeCountForTesting == 0)
    }

    /// Reference collector so the @Sendable sink can capture and mutate under Swift 6 concurrency.
    final class ProfileCollector: @unchecked Sendable {
        private let lock = NSLock()
        private var items: [CommandProfile] = []
        func append(_ p: CommandProfile) { lock.lock(); items.append(p); lock.unlock() }
        var all: [CommandProfile] { lock.lock(); defer { lock.unlock() }; return items }
    }

    @Test("runSink captures only turns ended within its task-local scope")
    func runSinkScoped() async {
        let profiler = PerformanceProfiler()
        let collector = ProfileCollector()

        // A turn ended INSIDE the binding is captured...
        await PerformanceProfiler.$runSink.withValue({ collector.append($0) }) {
            let id = profiler.beginTurn(label: "inside", source: "System")
            profiler.record(turnID: id, category: .toolExecution, durationMs: 25)
            profiler.endTurn(id, totalMs: 200)
        }
        // ...a turn ended OUTSIDE the binding (as a parallel test would) is not.
        let outsideId = profiler.beginTurn(label: "outside", source: "System")
        profiler.endTurn(outsideId, totalMs: 5)

        let captured = collector.all
        #expect(captured.count == 1)
        #expect(captured.first?.label == "inside")
        #expect(captured.first?.totalMs == 200)
        #expect(captured.first?.categories[.toolExecution]?.ms == 25)
    }

    @Test("ring buffer keeps only the most recent maxRecent profiles")
    func ringBufferEvicts() async {
        let profiler = PerformanceProfiler()
        for i in 0..<(PerformanceProfiler.maxRecent + 5) {
            let id = profiler.beginTurn(label: "cmd \(i)", source: "UI")
            profiler.endTurn(id, totalMs: Double(i))
        }
        try? await Task.sleep(nanoseconds: 50_000_000)
        await MainActor.run {
            #expect(profiler.recentCommands.count == PerformanceProfiler.maxRecent)
            // newest last; oldest ("cmd 0".."cmd 4") evicted
            #expect(profiler.recentCommands.last?.label == "cmd \(PerformanceProfiler.maxRecent + 4)")
        }
    }

    @Test("a span recorded in a child task attributes to the parent turn")
    func taskLocalPropagation() async {
        let profiler = PerformanceProfiler()
        let id = profiler.beginTurn(label: "parent", source: "UI")
        await PerformanceProfiler.$currentTurnID.withValue(id) {
            await withTaskGroup(of: Void.self) { group in
                group.addTask {
                    // Inherits currentTurnID from parent.
                    profiler.record(turnID: PerformanceProfiler.currentTurnID, category: .vibecop, durationMs: 7)
                }
                await group.waitForAll()
            }
        }
        #expect(profiler.activeProfileForTesting(id)?.categories[.vibecop]?.ms == 7)
    }
}

@Suite("PerformanceProfiler measure helpers")
struct PerformanceProfilerMeasureTests {

    @Test("measure records elapsed time to the current turn on shared profiler")
    func measureRecords() async {
        let id = PerformanceProfiler.shared.beginTurn(label: "measure", source: "UI")
        await PerformanceProfiler.$currentTurnID.withValue(id) {
            _ = await measure(.primaryLLM) {
                try? await Task.sleep(nanoseconds: 20_000_000) // ~20ms
            }
        }
        let ms = PerformanceProfiler.shared.activeProfileForTesting(id)?.categories[.primaryLLM]?.ms ?? 0
        #expect(ms >= 10) // generous lower bound to avoid flakiness
        PerformanceProfiler.shared.endTurn(id, totalMs: ms)
    }

    @Test("measureSync records and returns the value")
    func measureSyncReturns() {
        let id = PerformanceProfiler.shared.beginTurn(label: "sync", source: "UI")
        let out: Int = PerformanceProfiler.$currentTurnID.withValue(id) {
            measureSync(.injectionGuard) { 21 + 21 }
        }
        #expect(out == 42)
        #expect((PerformanceProfiler.shared.activeProfileForTesting(id)?.categories[.injectionGuard]?.count ?? 0) == 1)
        PerformanceProfiler.shared.endTurn(id, totalMs: 0)
    }
}
