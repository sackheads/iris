import Testing
import Foundation
@testable import iris

/// The perf suite needs more than six buckets: which model call, which tool, which guard tier.
/// These records ride on the same task-local turn id as the buckets do.
@Suite("PerformanceProfiler records")
struct ProfilerRecordTests {
    @Test("model calls, tool calls and spans attribute to the active turn")
    func attributesToTurn() {
        let p = PerformanceProfiler()
        let id = p.beginTurn(label: "t", source: "test")
        p.recordModelCall(turnID: id, ModelCallRecord(round: 0, model: "m", latencyMs: 12,
                                                      promptTokens: 100, outputTokens: 5, returnedToolCalls: false))
        p.recordToolCall(turnID: id, ToolCallRecord(name: "run_command", ms: 3, ok: true))
        p.recordSpan(turnID: id, name: "guard.tier1", durationMs: 1)
        p.recordSpan(turnID: id, name: "guard.tier1", durationMs: 2)
        let profile = p.activeProfileForTesting(id)
        #expect(profile?.modelCalls.count == 1)
        #expect(profile?.modelCalls.first?.promptTokens == 100)
        #expect(profile?.toolCalls.first?.name == "run_command")
        #expect(profile?.spans["guard.tier1"]?.ms == 3)
        #expect(profile?.spans["guard.tier1"]?.count == 2)
    }

    @Test("records outside a turn are dropped")
    func noTurnIsNoop() {
        let p = PerformanceProfiler()
        p.recordModelCall(turnID: nil, ModelCallRecord(round: 0, model: "m", latencyMs: 1,
                                                       promptTokens: nil, outputTokens: nil, returnedToolCalls: false))
        p.recordSpan(turnID: UUID(), name: "x", durationMs: 1)
        #expect(p.activeCountForTesting == 0)
    }

    @Test("records travel with the profile into the run sink")
    func recordsReachTheSink() {
        let p = PerformanceProfiler()
        let id = p.beginTurn(label: "t", source: "test")
        p.recordToolCall(turnID: id, ToolCallRecord(name: "read_file", ms: 1, ok: false))
        final class Box<T>: @unchecked Sendable { var value: T?; init() {} }
        let finished = Box<CommandProfile>()
        PerformanceProfiler.$runSink.withValue({ finished.value = $0 }) {
            p.endTurn(id, totalMs: 10)
        }
        #expect(finished.value?.toolCalls.first?.ok == false)
    }

    @Test("measureSpan attributes to the task-local turn")
    func measureSpanUsesTaskLocal() async {
        let id = PerformanceProfiler.shared.beginTurn(label: "span", source: "test")
        defer { PerformanceProfiler.shared.endTurn(id, totalMs: 0) }
        await PerformanceProfiler.$currentTurnID.withValue(id) {
            _ = await measureSpan("assembly.test") { 42 }
            _ = measureSpanSync("assembly.sync") { 7 }
        }
        let profile = PerformanceProfiler.shared.activeProfileForTesting(id)
        #expect(profile?.spans["assembly.test"]?.count == 1)
        #expect(profile?.spans["assembly.sync"]?.count == 1)
    }

    @Test("CategoryStat round-trips through JSON")
    func categoryStatCodable() throws {
        var s = CategoryStat(); s.add(1.5); s.add(2.5)
        let data = try JSONEncoder().encode(s)
        #expect(try JSONDecoder().decode(CategoryStat.self, from: data) == s)
    }
}
