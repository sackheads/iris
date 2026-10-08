import Testing
import Foundation
@testable import IrisKit

/// #345: the two callers of `withTimeout`, now that it returns at the deadline rather than when
/// the operation gets round to finishing.
@Suite("run_command timeout on the host", .timeLimit(.minutes(1)))
struct RunCommandTimeoutTests {

    @Test("a command past its deadline returns on time and its process is gone")
    func timedOutCommandIsKilled() async {
        // A duration nothing else on this machine would be sleeping for, so `pgrep` matches only ours.
        let marker = "29.\(Int.random(in: 100_000...999_999))"
        let started = Date()
        let out = await ToolExecutor().runCommand("sleep \(marker)", cwd: nil, timeoutSeconds: 1)
        let wall = Date().timeIntervalSince(started)

        #expect(out == ToolExecutor.commandTimedOutMessage(seconds: 1))
        #expect(wall < 3, "returned after \(wall)s; the deadline was 1s")
        // Abandoning the wait is not abandoning the process: the cancellation handler terminates it.
        #expect(await Self.gone("sleep \(marker)", within: 3), "sleep \(marker) outlived its deadline")
    }

    @Test("a command inside its deadline returns its output")
    func fastCommandReturnsOutput() async {
        let out = await ToolExecutor().runCommand("echo iris-345", cwd: nil, timeoutSeconds: 10)
        #expect(out == "iris-345\n")
    }

    private static func gone(_ needle: String, within seconds: Double) async -> Bool {
        let deadline = Date().addingTimeInterval(seconds)
        while Date() < deadline {
            if !exists(needle) { return true }
            try? await Task.sleep(nanoseconds: 50_000_000)
        }
        return !exists(needle)
    }

    private static func exists(_ needle: String) -> Bool {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/pgrep")
        p.arguments = ["-f", needle]
        p.standardOutput = FileHandle.nullDevice
        p.standardError = FileHandle.nullDevice
        do { try p.run() } catch { return false }
        p.waitUntilExit()
        return p.terminationStatus == 0
    }
}

@Suite("Vibecop timeout", .timeLimit(.minutes(1)))
struct VibecopTimeoutTests {

    /// A native inference call does not look at cancellation; before #345 the "timeout" waited it out.
    @Test("an evaluation that ignores cancellation yields no verdict at the deadline")
    func nonCooperativeEvaluationTimesOut() async {
        let started = Date()
        let verdict = await AppState.boundedVibecopVerdict(seconds: 0.2) {
            await TimeoutTests.ignoresCancellation(seconds: 2)
            return VibecopDecision(decision: "APPROVE", reason: "too late to count")
        }
        #expect(verdict == nil, "a late APPROVE must not be honoured")
        #expect(Date().timeIntervalSince(started) < 1.0)
    }

    @Test("an evaluation inside the deadline passes its verdict through")
    func fastEvaluationPassesThrough() async {
        let verdict = await AppState.boundedVibecopVerdict(seconds: 5) {
            VibecopDecision(decision: "DENY", reason: "no")
        }
        #expect(verdict?.decision == "DENY")
    }

    @Test("an Ollama warm-up probe that never answers is bounded, and taken as a cold model")
    func wedgedOllamaProbeIsBounded() async {
        let started = Date()
        let budget = await AppState.ollamaVibecopBudget(configured: 7, probeSeconds: 0.2) {
            await TimeoutTests.ignoresCancellation(seconds: 3)
            return true
        }
        #expect(Date().timeIntervalSince(started) < 1.0)
        #expect(budget == AppState.ollamaColdBudgetSeconds)
    }

    @Test("the Ollama probe's answer picks the budget")
    func ollamaProbeAnswers() async {
        #expect(await AppState.ollamaVibecopBudget(configured: 7, probeSeconds: 5) { true } == 7)
        #expect(await AppState.ollamaVibecopBudget(configured: 7, probeSeconds: 5) { false } == AppState.ollamaColdBudgetSeconds)
        // No engine to ask: the configured bound, as before.
        #expect(await AppState.ollamaVibecopBudget(configured: 7, probeSeconds: 5) { nil } == 7)
    }

    @Test("an evaluation that throws yields no verdict")
    func failingEvaluation() async {
        struct Down: Error {}
        let verdict = await AppState.boundedVibecopVerdict(seconds: 5) { throw Down() }
        #expect(verdict == nil)
    }
}
