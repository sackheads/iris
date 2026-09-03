import Foundation

/// Parsed `--bench` invocation options.
struct BenchOptions: Sendable {
    var scenarioPath: String?
    var real: Bool
}

/// Headless benchmark entry point: parse `--bench [scenario.json] [--real]`, run a scenario
/// through `ScenarioRunner`, and print a timing breakdown. Invoked from `main.swift` before any
/// SwiftUI window is created, so `swift run iris --bench …` behaves like a standalone tool.
enum BenchCLI {
    /// Returns nil when `--bench` is absent (normal app launch). Otherwise reads an optional
    /// scenario path (first non-flag token after `--bench`) and the `--real` flag.
    static func parse(_ args: [String]) -> BenchOptions? {
        guard let benchIdx = args.firstIndex(of: "--bench") else { return nil }
        let rest = args[(benchIdx + 1)...]
        let path = rest.first { !$0.hasPrefix("--") }
        let real = rest.contains("--real")
        return BenchOptions(scenarioPath: path, real: real)
    }

    /// A tiny fake goal loop used when no scenario file is supplied: run one command, then finish.
    static var defaultScenario: Scenario {
        Scenario(
            name: "default-echo",
            clientMode: .fake,
            tier: .medium,
            turns: [Scenario.Turn(prompt: "Run a quick command and finish.")],
            scriptedResponses: [
                Scenario.ScriptedResponse(kind: .toolCalls, text: nil, calls: [
                    Scenario.ScriptedCall(name: "run_command", args: ["command": .string("echo iris-bench")])
                ]),
                Scenario.ScriptedResponse(kind: .text, text: "Done.", calls: nil)
            ])
    }

    /// Load the scenario for these options, applying `--real` as an override.
    static func resolveScenario(_ opts: BenchOptions) throws -> Scenario {
        var scenario: Scenario
        if let path = opts.scenarioPath {
            scenario = try Scenario.load(at: path)
        } else {
            scenario = defaultScenario
        }
        if opts.real { scenario.clientMode = .real }
        return scenario
    }

    /// Run the scenario and print its summary. Prints an error to stderr and exits non-zero on
    /// a bad scenario file. Called on the main actor from `main.swift`.
    @MainActor
    static func run(_ opts: BenchOptions) async {
        let scenario: Scenario
        do {
            scenario = try resolveScenario(opts)
        } catch {
            FileHandle.standardError.write(Data("iris --bench: \(error.localizedDescription)\n".utf8))
            exit(1)
        }
        // A fake run needs no provider secrets; skip the Keychain so this ad-hoc-signed CLI
        // binary doesn't block on an access prompt. Must be set before ConfigManager.shared is
        // first touched (inside ScenarioRunner.run). Real runs keep Keychain access for auth.
        if scenario.clientMode == .fake {
            setenv("IRIS_HEADLESS", "1", 1)
        }
        let result = await ScenarioRunner.run(scenario)
        print(BenchSummary.render(scenarioName: scenario.name, result: result))
    }
}

/// Renders a `ScenarioResult` as a plain-text timing table.
enum BenchSummary {
    static func render(scenarioName: String, result: ScenarioResult) -> String {
        var lines: [String] = []
        lines.append("Scenario: \(scenarioName)")
        lines.append("Turns: \(result.turnProfiles.count)   Wall-clock: \(fmt(result.wallClockMs)) ms")
        lines.append("")

        // Aggregate categories across all turns.
        var totals: [PerfCategory: CategoryStat] = [:]
        var grandTotalMs = 0.0
        for profile in result.turnProfiles {
            grandTotalMs += profile.totalMs
            for (cat, stat) in profile.categories {
                totals[cat, default: CategoryStat()].ms += stat.ms
                totals[cat, default: CategoryStat()].count += stat.count
            }
        }

        lines.append(row("Category", "ms", "calls"))
        lines.append(String(repeating: "-", count: 40))
        for cat in PerfCategory.allCases {
            guard let stat = totals[cat] else { continue }
            let label = cat.isGuardSubMeasure ? "  \(cat.displayName)" : cat.displayName
            lines.append(row(label, fmt(stat.ms), "\(stat.count)"))
        }
        lines.append(row("Total (turns)", fmt(grandTotalMs), ""))
        return lines.joined(separator: "\n")
    }

    private static func fmt(_ ms: Double) -> String {
        String(format: "%.1f", ms)
    }

    private static func row(_ a: String, _ b: String, _ c: String) -> String {
        let left = a.padding(toLength: 22, withPad: " ", startingAt: 0)
        let mid = b.padding(toLength: 12, withPad: " ", startingAt: 0)
        return left + mid + c
    }
}
