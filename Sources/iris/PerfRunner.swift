import Foundation

/// Executes a suite: for each scenario, for each rung, `repetitions` samples; then summarizes and
/// packages everything into a `PerfRunRecord`. Rungs 1-3 go through `PerfLadder`; 4 and 5 are
/// `ScenarioRunner` turns with guards off / as configured. In the fake lane guards are always off
/// (a fake run must not reach the network) and `HeadlessMode` is expected to be enabled by the CLI.
@MainActor
enum PerfRunner {
    /// Process-wide: the first repetition of the first scenario is the cold start.
    private static var repetitionsCompleted = 0

    static func run(suite: PerfSuite, repetitionsOverride: Int? = nil, repoRoot: URL,
                    client: (any LLMClientProtocol)? = nil, headless: Bool,
                    workspacePath: String? = nil) async throws -> PerfRunRecord {
        try suite.validate()
        let reps = repetitionsOverride ?? suite.repetitions
        let startedAt = Date()
        var results: [PerfScenarioResult] = []
        var toolCount: Int?
        var anySandboxed = false

        for url in suite.scenarioURLs(relativeTo: repoRoot) {
            let scenario = try Scenario.load(at: url.path)
            let prompt = scenario.turns.first?.prompt ?? ""
            var capture: LadderCapture?
            var rungResults: [PerfRungResult] = []

            for rung in suite.rungs.sorted() {
                var repetitions: [PerfRepetition] = []
                for i in 0..<reps {
                    let cold = repetitionsCompleted == 0
                    let rep: PerfRepetition
                    if rung <= 3 {
                        if capture == nil {
                            capture = await PerfLadder.capture(for: scenario, workspacePath: workspacePath)
                            toolCount = capture?.toolCount
                        }
                        let s = await PerfLadder.sample(rung: rung, prompt: prompt, tier: scenario.tier,
                                                        capture: capture!, client: client ?? LLMClient())
                        rep = PerfRepetition(index: i, coldStart: cold, wallClockMs: s.wallClockMs, turns: [],
                                             modelCalls: s.modelCall.map { [$0] } ?? [], error: s.error)
                    } else {
                        let guards: GuardMode = (rung == 4 || suite.lane == .fake) ? .off : .asConfigured
                        var effective = scenario
                        if suite.lane == .fake { effective.clientMode = .fake }
                        // Real-lane tool prompts run unattended with auto-approve: keep them in the VM.
                        let toolExecution: ToolExecutionMode = suite.lane == .real ? .sandboxed : .asConfigured
                        let result = await ScenarioRunner.run(effective, guards: guards, toolExecution: toolExecution, clientOverride: client,
                                                              workspacePath: workspacePath)
                        if result.toolsSandboxed { anySandboxed = true }
                        let turns = zip(result.turnProfiles, result.finalTexts + Array(repeating: "", count: max(0, result.turnProfiles.count - result.finalTexts.count)))
                            .map { PerfTurn($0, finalText: $1) }
                        // An engine-level LLM failure is caught and posted as a tagged system
                        // message rather than thrown, so `turnProfiles` is never empty for it;
                        // `turnErrors` is how ScenarioRunner surfaces it back to us.
                        let failed = result.turnErrors.compactMap { $0 }.first
                            ?? (result.turnProfiles.isEmpty ? "turn produced no profile" : nil)
                        rep = PerfRepetition(index: i, coldStart: cold, wallClockMs: result.wallClockMs, turns: turns,
                                             modelCalls: [], error: failed)
                    }
                    repetitions.append(rep)
                    repetitionsCompleted += 1
                    if suite.lane == .real, suite.pauseMs > 0 {
                        try? await Task.sleep(nanoseconds: UInt64(suite.pauseMs) * 1_000_000)
                    }
                }
                let ok = repetitions.filter { $0.error == nil }.map(\.wallClockMs)
                rungResults.append(PerfRungResult(rung: rung, repetitions: repetitions,
                                                  medianMs: PerfStats.median(ok) ?? 0, p90Ms: PerfStats.p90(ok) ?? 0))
            }
            if capture == nil, toolCount == nil {
                // No ladder rung ran; still record the tool surface a real turn would send.
                let c = await PerfLadder.capture(for: scenario, workspacePath: workspacePath)
                toolCount = c.toolCount
            }
            results.append(PerfScenarioResult(name: scenario.name, path: relativePath(url, root: repoRoot),
                                              category: category(forScenarioAt: url), lane: suite.lane.rawValue,
                                              rungs: rungResults, summary: PerfSummarizer.summarize(rungResults, expectedTools: scenario.expectedTools)))
        }

        return PerfRunRecord(schemaVersion: PerfRunRecord.currentSchemaVersion, suite: suite.name,
                             startedAt: startedAt, finishedAt: Date(),
                             environment: PerfEnvironment.capture(headless: headless, toolDeclarationCount: toolCount, repoRoot: repoRoot,
                                                                  toolSandbox: anySandboxed ? "sandboxed" : "host"),
                             scenarios: results)
    }

    /// The parent directory name: "model-only", "tool-use", "fake". Pure path function, callable
    /// off the main actor.
    nonisolated static func category(forScenarioAt url: URL) -> String {
        url.deletingLastPathComponent().lastPathComponent
    }

    private static func relativePath(_ url: URL, root: URL) -> String {
        let p = url.standardizedFileURL.path, r = root.standardizedFileURL.path + "/"
        return p.hasPrefix(r) ? String(p.dropFirst(r.count)) : p
    }
}

enum PerfSummarizer {
    static func summarize(_ rungs: [PerfRungResult], expectedTools: [String]? = nil) -> PerfScenarioSummary {
        func median(of rung: Int) -> Double? {
            guard let r = rungs.first(where: { $0.rung == rung }) else { return nil }
            return PerfStats.median(r.repetitions.filter { $0.error == nil }.map(\.wallClockMs))
        }
        let top = rungs.max { $0.rung < $1.rung }
        let topOk = top?.repetitions.filter { $0.error == nil }.map(\.wallClockMs) ?? []
        let r1 = median(of: 1)
        let ratio: (Int) -> Double? = { rung in
            guard let d = r1, d > 0, let n = median(of: rung) else { return nil }
            return n / d
        }
        // Successful repetitions only, consistent with the medians: a turn that then timed out
        // must not count toward the eagerness rate (#137).
        let fullTurns = rungs.first { $0.rung == 5 }?.repetitions.filter { $0.error == nil }.flatMap(\.turns) ?? []
        let firstTokens = fullTurns.flatMap(\.modelCalls).compactMap(\.firstTokenMs)
        let withTools = fullTurns.filter { !$0.toolCalls.isEmpty }.count
        var byName: [String: Int] = [:]
        for call in fullTurns.flatMap(\.toolCalls) { byName[call.name, default: 0] += 1 }
        // Calls outside expectedTools: bait prompts declare [], so any call counts; controls
        // declare their tool, so extras count; unscored scenarios get nil.
        var unexpectedRate: Double?
        var unexpectedByName: [String: Int]?
        var missedRate: Double?
        if let expected = expectedTools {
            let allowed = Set(expected)
            var counts: [String: Int] = [:]
            var turnsWithUnexpected = 0
            var turnsMissing = 0
            for turn in fullTurns {
                let extras = turn.toolCalls.filter { !allowed.contains($0.name) }
                if !extras.isEmpty { turnsWithUnexpected += 1 }
                for call in extras { counts[call.name, default: 0] += 1 }
                if !allowed.isEmpty, !turn.toolCalls.contains(where: { allowed.contains($0.name) }) { turnsMissing += 1 }
            }
            unexpectedRate = fullTurns.isEmpty ? 0 : Double(turnsWithUnexpected) / Double(fullTurns.count)
            unexpectedByName = counts
            if !allowed.isEmpty { missedRate = fullTurns.isEmpty ? 0 : Double(turnsMissing) / Double(fullTurns.count) }
        }
        return PerfScenarioSummary(medianMs: PerfStats.median(topOk) ?? 0, p90Ms: PerfStats.p90(topOk) ?? 0,
                                   overheadRatio: ratio(5), harnessRatio: ratio(4),
                                   toolCallRate: fullTurns.isEmpty ? 0 : Double(withTools) / Double(fullTurns.count),
                                   toolCallsByName: byName,
                                   unexpectedToolCallRate: unexpectedRate, unexpectedToolCallsByName: unexpectedByName,
                                   missedExpectedToolRate: missedRate, medianFirstTokenMs: PerfStats.median(firstTokens))
    }
}
