import Testing
import Foundation
@testable import IrisKit

@Suite("Bench CLI parsing and summary")
struct BenchCLITests {

    @Test("parse returns nil when --bench is absent")
    func parseNoBench() {
        #expect(BenchCLI.parse(["iris"]) == nil)
    }

    @Test("parse reads a scenario path after --bench")
    func parsePath() {
        let opts = BenchCLI.parse(["iris", "--bench", "foo.json"])
        #expect(opts?.scenarioPath == "foo.json")
        #expect(opts?.real == false)
    }

    @Test("parse treats --real as a flag, not a path")
    func parseRealFlag() {
        let opts = BenchCLI.parse(["iris", "--bench", "--real"])
        #expect(opts?.scenarioPath == nil)
        #expect(opts?.real == true)
    }

    @Test("parse reads both a path and --real")
    func parsePathAndReal() {
        let opts = BenchCLI.parse(["iris", "--bench", "foo.json", "--real"])
        #expect(opts?.scenarioPath == "foo.json")
        #expect(opts?.real == true)
    }

    @Test("built-in default scenario is a fake run with at least one turn")
    func defaultScenario() {
        let scenario = BenchCLI.defaultScenario
        #expect(scenario.clientMode == .fake)
        #expect(!scenario.turns.isEmpty)
        #expect(!scenario.scriptedResponses.isEmpty)
    }

    @Test("summary renders category rows, total, and wall-clock")
    func summaryRenders() {
        var profile = CommandProfile(id: UUID(), label: "echo", source: "User", startedAt: Date())
        profile.totalMs = 1000
        profile.add(.primaryLLM, durationMs: 600)
        profile.add(.toolExecution, durationMs: 300)
        let result = ScenarioResult(turnProfiles: [profile], wallClockMs: 1234.5,
                                    finalTexts: [], guardsWereOff: false, vibecopMeasured: false, toolsSandboxed: false, conversationId: UUID(), turnErrors: [])

        let text = BenchSummary.render(scenarioName: "echo", result: result)
        #expect(text.contains("echo"))
        #expect(text.contains(PerfCategory.primaryLLM.displayName))
        #expect(text.contains(PerfCategory.toolExecution.displayName))
        #expect(text.contains("1234")) // wall-clock ms appears
    }

    @Test("--dump-requests takes a directory and its value is not taken for the scenario path")
    func parseDumpRequests() {
        let a = BenchCLI.parse(["iris", "--bench", "--dump-requests", "out", "foo.json", "--transcript"])
        #expect(a?.scenarioPath == "foo.json")
        #expect(a?.dumpRequestsDir == "out")
        #expect(a?.transcript == true)
        let b = BenchCLI.parse(["iris", "--bench", "foo.json"])
        #expect(b?.dumpRequestsDir == nil)
        #expect(b?.transcript == false)
        #expect(BenchCLI.parse(["iris", "--bench", "foo.json", "--dump-requests"])?.dumpRequestsDir == nil)
    }

    @Test("a background scenario's denied call reaches the transcript, and the requests are dumped")
    @MainActor
    func transcriptAndDumpShowADeniedCall() async throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent("bench-dump-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: dir) }
        let scenario = Scenario(
            name: "denied", clientMode: .fake, tier: .medium,
            turns: [Scenario.Turn(prompt: "go")],
            scriptedResponses: [
                Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                    Scenario.ScriptedCall(name: "run_command", args: ["command": .string("echo bench-denied")])]),
                Scenario.ScriptedResponse(kind: .text, text: "Done.", calls: nil)],
            background: true)
        let result = await BenchCLI.runScenario(scenario, dumpRequestsTo: dir)
        let rendered = BenchSummary.renderTranscript(result)
        let notice = String(format: AppState.unattendedDenialNotice, "run_command")
        #expect(rendered.contains("Transcript, turn 1:"))
        #expect(rendered.contains(notice), "the unattended denial is readable in the transcript")
        let dumped = try FileManager.default.contentsOfDirectory(atPath: dir.path)
        #expect(dumped.contains("1-0.json"))
    }
}
