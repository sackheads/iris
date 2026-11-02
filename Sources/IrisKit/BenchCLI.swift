import Foundation

/// What a `background` bench scenario's job carries (#853). Any of them makes it a `mutating` job: a
/// read-only job may not carry a grant, and a job with none is the "no grant" case, where the VM has
/// no mounts and a file tool outside the allowlist stops the run.
enum BenchGrant: Equatable, Sendable {
    /// A read-only mount of this directory (`--grant-read`).
    case readOnly(String)
    /// A read-write mount of this directory (`--grant-write`): a `write_file` under it is allowed, and
    /// the container's commands write the host directory.
    case readWrite(String)
    /// A mutating job with no grant at all (`--mutating-no-grant`).
    case none
}

/// Parsed `--bench` invocation options.
struct BenchOptions: Sendable {
    var scenarioPath: String?
    var real: Bool
    /// `--dump-requests DIR`: write every model request of the run to DIR (what `--perf` already does).
    var dumpRequestsDir: String?
    /// `--grant-read DIR`: stamp a read-only grant on DIR, as a granted job has, so a file inside
    /// it can be read by a background run (otherwise that read needs an approval nobody can give).
    /// `--grant-write DIR` stamps a read-write one; `--mutating-no-grant` a mutating job with none.
    var grant: BenchGrant?
    /// `--transcript`: print each turn's messages after the summary, so a refused or denied tool
    /// call can be read, not inferred from the timings.
    var transcript: Bool = false
}

/// Headless benchmark entry point: parse `--bench [scenario.json] [--real] [--dump-requests DIR] [--grant-read DIR | --grant-write DIR | --mutating-no-grant] [--transcript]`, run a scenario
/// through `ScenarioRunner`, and print a timing breakdown. Invoked from `main.swift` before any
/// SwiftUI window is created, so `swift run iris --bench …` behaves like a standalone tool.
enum BenchCLI {
    /// Returns nil when `--bench` is absent (normal app launch). Otherwise reads an optional
    /// scenario path (first non-flag token after `--bench`) and the `--real` flag.
    static func parse(_ args: [String]) -> BenchOptions? {
        guard let benchIdx = args.firstIndex(of: "--bench") else { return nil }
        let rest = Array(args[(benchIdx + 1)...])
        var path: String?
        var dir: String?
        var grant: BenchGrant?
        var i = 0
        while i < rest.count {
            if rest[i] == "--dump-requests" || rest[i] == "--grant-read" || rest[i] == "--grant-write" {
                // A flag's value is not the scenario path.
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                    switch rest[i] {
                    case "--grant-read": grant = .readOnly(rest[i + 1])
                    case "--grant-write": grant = .readWrite(rest[i + 1])
                    default: dir = rest[i + 1]
                    }
                    i += 1
                } else {
                    FileHandle.standardError.write(Data("iris --bench: \(rest[i]) needs a directory; ignored\n".utf8))
                }
            } else if rest[i] == "--mutating-no-grant" {
                grant = BenchGrant.none
            } else if !rest[i].hasPrefix("--"), path == nil {
                path = rest[i]
            }
            i += 1
        }
        return BenchOptions(scenarioPath: path, real: rest.contains("--real"), dumpRequestsDir: dir, grant: grant,
                            transcript: rest.contains("--transcript"))
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

    /// Why this run cannot happen, or nil. A grant makes a mutating job, and with a real model that
    /// would run unattended with write and run tools open (the mount is read-only, the profile is
    /// not), so the grant is for a scripted client only. Judged on the resolved scenario: the file
    /// can set `clientMode: "real"` itself.
    static func refusal(_ opts: BenchOptions, scenario: Scenario) -> String? {
        opts.grant != nil && scenario.clientMode == .real
            ? "a bench grant makes a mutating job; it is for a scripted run, not a real model" : nil
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
        if let why = refusal(opts, scenario: scenario) {
            FileHandle.standardError.write(Data("iris --bench: \(why)\n".utf8))
            exit(1)
        }
        // A fake run needs no provider secrets; skip the Keychain so this ad-hoc-signed CLI
        // binary doesn't block on an access prompt. Must be set before ConfigManager.shared is
        // first touched (inside ScenarioRunner.run). Real runs keep Keychain access for auth.
        // Bench runs never write to the user's real preferences.
        IrisDefaults.useVolatileCopyOfStandard()
        let result = await runScenario(scenario, dumpRequestsTo: opts.dumpRequestsDir.map { URL(fileURLWithPath: $0) },
                                        grant: opts.grant)
        print(BenchSummary.render(scenarioName: scenario.name, result: result))
        if opts.transcript { print(BenchSummary.renderTranscript(result)) }
    }

    /// Runs `scenario`, entering `HeadlessMode`'s scope first when it's a fake run. Separated from
    /// `run` so a test can exercise exactly this decision — does the fake lane actually enter the
    /// scope — without calling `IrisDefaults.useVolatileCopyOfStandard()`, which is its own
    /// process-wide latch (#324) and not this seam's concern. `clientOverride` exists only for that
    /// test seam; production never passes it. Scoped to this call's task tree (#318) — see
    /// `HeadlessMode`. Since this is the process's outermost task and `main.swift` exits right
    /// after, the scope in practice covers the whole remaining real-CLI run.
    @MainActor
    static func runScenario(_ scenario: Scenario, clientOverride: (any LLMClientProtocol)? = nil,
                            dumpRequestsTo: URL? = nil, grant: BenchGrant? = nil) async -> ScenarioResult {
        if scenario.clientMode == .fake {
            return await HeadlessMode.withEnabled {
                await ScenarioRunner.run(scenario, clientOverride: clientOverride, grant: grant, dumpRequestsTo: dumpRequestsTo)
            }
        }
        return await ScenarioRunner.run(scenario, clientOverride: clientOverride, grant: grant, dumpRequestsTo: dumpRequestsTo)
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

    /// Each turn's messages as `role: content`, a message cut at 400 characters.
    static func renderTranscript(_ result: ScenarioResult) -> String {
        var lines = [""]
        for (i, turn) in result.turnMessages.enumerated() {
            lines.append("Transcript, turn \(i + 1):")
            for m in turn {
                let flat = m.replacingOccurrences(of: "\n", with: " ")
                lines.append("  " + (flat.count > 400 ? String(flat.prefix(400)) + "..." : flat))
            }
        }
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
