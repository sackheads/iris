import Testing
import Foundation
@testable import iris

/// The perf suite needs more than six buckets: which model call, which tool, which guard tier.
/// These records ride on the same task-local turn id as the buckets do.
@Suite("PerformanceProfiler records")
struct ProfilerRecordTests {
    /// The argument for running profiler-touching suites unserialized (#250, #269) is that
    /// `active` is keyed per turn. Pin it, so a refactor to a single current profile fails here
    /// rather than silently reintroducing the race the doc comment says cannot happen.
    @Test("two turns on one profiler cannot see each other's spans")
    func turnsAreIsolated() {
        let p = PerformanceProfiler()
        let a = p.beginTurn(label: "a", source: "test")
        let b = p.beginTurn(label: "b", source: "test")
        p.recordSpan(turnID: a, name: "guard.tier2", durationMs: 1)
        #expect(p.activeProfileForTesting(a)?.spans["guard.tier2"]?.count == 1)
        #expect(p.activeProfileForTesting(b)?.spans["guard.tier2"] == nil)
    }

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

    @Test("tool-call arguments are rendered compactly and capped")
    func toolArgsCapped() {
        let short = ToolCallRecord.compactArgs(["command": .string("uname -sr")])
        #expect(short == #"{"command":"uname -sr"}"#)
        let long = ToolCallRecord.compactArgs(["content": .string(String(repeating: "x", count: 2000))])
        #expect(long.count <= ToolCallRecord.argsLimit + 40)
        #expect(long.contains("truncated"))
        let old = ToolCallRecord(name: "read_file", ms: 1, ok: true)
        #expect(old.args == nil, "the initializer without args keeps working")
    }

    @Test("recorded tool arguments redact secret-looking values")
    func toolArgsRedacted() {
        // Key names that carry credentials are redacted whatever the value.
        let byKey = ToolCallRecord.compactArgs(["api_key": .string("plain"), "Authorization": .string("Bearer x"), "command": .string("ls")])
        #expect(byKey.contains(#""command":"ls""#))
        #expect(!byKey.contains("plain") && !byKey.contains("Bearer x"))
        #expect(byKey.contains("[redacted]"))
        // Token shapes are redacted wherever they appear, including inside a shell command.
        let inCommand = ToolCallRecord.compactArgs(["command": .string("curl -H 'X-Key: sk-abcdefghijklmnopqrstuvwxyz0123456789' https://api.example.com && echo ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd")])
        #expect(!inCommand.contains("sk-abcdefghijklmnopqrstuvwxyz0123456789"))
        #expect(!inCommand.contains("ghp_ABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789abcd"))
        #expect(inCommand.contains("curl -H 'X-Key: [redacted]' https://api.example.com"))
        let jwt = ToolCallRecord.compactArgs(["content": .string("token=eyJhbGciOiJIUzI1NiJ9.eyJzdWIiOiIxIn0.abc123def456ghi789")])
        #expect(!jwt.contains("eyJhbGciOiJIUzI1NiJ9"))
        // Ordinary arguments are untouched.
        #expect(ToolCallRecord.compactArgs(["path": .string("~/src/iris/README.md")]) == #"{"path":"~/src/iris/README.md"}"#)
    }
}
