import Testing
import Foundation
@testable import iris

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
                                    finalTexts: [], guardsWereOff: false, vibecopMeasured: false, toolsSandboxed: false, turnErrors: [])

        let text = BenchSummary.render(scenarioName: "echo", result: result)
        #expect(text.contains("echo"))
        #expect(text.contains(PerfCategory.primaryLLM.displayName))
        #expect(text.contains(PerfCategory.toolExecution.displayName))
        #expect(text.contains("1234")) // wall-clock ms appears
    }
}
