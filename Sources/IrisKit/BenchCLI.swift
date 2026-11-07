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
    /// More than one of the three grant flags was given. They exclude each other, and the one that came
    /// last would win silently, which may be the safer one's loss, so the run refuses (#865 review).
    var grantConflict = false
    /// `--transcript`: print each turn's messages after the summary, so a refused or denied tool
    /// call can be read, not inferred from the timings.
    var transcript: Bool = false
    /// `--local-openai URL`, `--local-model NAME`, `--local-canary NAME` (#854): a loopback OpenAI-compatible
    /// server (Ollama) as the primary model of a `--real` run. Raw as typed; `refusal` judges them.
    var localOpenAI: String?
    var localModel: String?
    var localCanary: String?

    /// The target when both URL and model were given. Half a target is refused, never guessed.
    var localTarget: BenchLocalTarget? {
        guard let url = localOpenAI, let model = localModel else { return nil }
        return BenchLocalTarget(baseURL: url, model: model, canaryModel: localCanary ?? BenchLocalTarget.defaultCanaryModel)
    }
}

/// #854: a loopback OpenAI-compatible server as the primary model of a `--bench --real` run, so a local model's
/// compliance with a planted request can be measured for free. Bench-only: the flags exist in `BenchCLI.parse`
/// and nowhere in the app. Its key is a placeholder held in memory (`KeychainManager.requestHeadlessBypass`
/// before `ConfigManager.shared` loads), so the run neither reads nor writes the user's Keychain items, and the
/// URL must be loopback, so no prompt, file or key can leave the Mac.
struct BenchLocalTarget: Equatable, Sendable {
    /// The canary #801 ships.
    static let defaultCanaryModel = "gemma4:12b"

    var baseURL: String
    var model: String
    var canaryModel: String

    /// Why this URL cannot be the target, or nil. http or https, and a loopback host exactly (`EndpointURL`'s
    /// check, which `127.0.0.1.evil.example` and `localhost.evil.example` do not pass).
    static func urlRefusal(_ url: String) -> String? {
        let scheme = URLComponents(string: url.trimmingCharacters(in: .whitespacesAndNewlines))?.scheme?.lowercased()
        guard scheme == "http" || scheme == "https", EndpointURL.isLoopbackURL(url) else {
            return "--local-openai needs a loopback http(s) URL (127.0.0.1, localhost or ::1); \(url.isEmpty ? "(empty)" : url) is not"
        }
        return nil
    }

    /// Points a config at the local server: the primary provider (every tier), a placeholder key, the tier-3
    /// canary on the same server, and the guard and sandbox switches a granted background run relies on. The
    /// config must be a volatile copy's (the caller has made it one), and its guarded settings in memory.
    @MainActor
    func apply(to config: ConfigManager) {
        config.primaryProvider = LLMProvider.openai.rawValue
        config.openAIBaseURL = baseURL
        config.openAIAPIKey = "bench-local"
        config.openaiModelEasy = model
        config.openaiModelMedium = model
        config.openaiModelHard = model
        config.promptGuardEngine = "ollama"
        config.promptGuardModel = canaryModel
        config.enableAdvancedPromptInjectionProtection = true
        config.enableSandboxing = true
    }
}

/// Headless benchmark entry point: parse `--bench [scenario.json] [--real] [--dump-requests DIR] [--grant-read DIR | --grant-write DIR | --mutating-no-grant] [--local-openai URL --local-model NAME [--local-canary NAME]] [--transcript]`, run a scenario
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
        var grantFlags = 0
        var localOpenAI: String?, localModel: String?, localCanary: String?
        var i = 0
        while i < rest.count {
            if rest[i] == "--local-openai" || rest[i] == "--local-model" || rest[i] == "--local-canary" {
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                    switch rest[i] {
                    case "--local-openai": localOpenAI = rest[i + 1]
                    case "--local-model": localModel = rest[i + 1]
                    default: localCanary = rest[i + 1]
                    }
                    i += 1
                } else {
                    FileHandle.standardError.write(Data("iris --bench: \(rest[i]) needs a value; ignored\n".utf8))
                }
            } else if rest[i] == "--dump-requests" || rest[i] == "--grant-read" || rest[i] == "--grant-write" {
                // A flag's value is not the scenario path.
                if i + 1 < rest.count, !rest[i + 1].hasPrefix("--") {
                    switch rest[i] {
                    case "--grant-read": grant = .readOnly(rest[i + 1]); grantFlags += 1
                    case "--grant-write": grant = .readWrite(rest[i + 1]); grantFlags += 1
                    default: dir = rest[i + 1]
                    }
                    i += 1
                } else {
                    FileHandle.standardError.write(Data("iris --bench: \(rest[i]) needs a directory; ignored\n".utf8))
                }
            } else if rest[i] == "--mutating-no-grant" {
                grant = BenchGrant.none; grantFlags += 1
            } else if !rest[i].hasPrefix("--"), path == nil {
                path = rest[i]
            }
            i += 1
        }
        return BenchOptions(scenarioPath: path, real: rest.contains("--real"), dumpRequestsDir: dir, grant: grant,
                            grantConflict: grantFlags > 1, transcript: rest.contains("--transcript"),
                            localOpenAI: localOpenAI, localModel: localModel, localCanary: localCanary)
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
        if opts.grantConflict { return "--grant-read, --grant-write and --mutating-no-grant exclude each other: give one" }
        if opts.localOpenAI != nil || opts.localModel != nil || opts.localCanary != nil {
            if opts.localOpenAI == nil { return "--local-model and --local-canary need --local-openai URL" }
            if opts.localModel == nil { return "--local-openai needs --local-model NAME" }
            if let why = BenchLocalTarget.urlRefusal(opts.localOpenAI ?? "") { return why }
            if scenario.clientMode != .real { return "--local-openai applies to a real run: add --real" }
        }
        guard opts.grant != nil else { return nil }
        if scenario.clientMode == .real, let why = realModelGrantRefusal(opts.grant) { return why }
        // The grant is stamped on a background conversation only; elsewhere it would do nothing, which reads as "granted and still refused".
        if !scenario.background { return "a bench grant applies to a background scenario: set \"background\": true in the scenario file" }
        return nil
    }

    /// A real model with a grant (#854, measuring whether it acts on a planted request): only a
    /// read-write mount that is a folder under the temp root, judged by its REAL path (a link or
    /// `/tmp` -> `/private/tmp` must not move it out), never the temp root itself. Read-only or no
    /// grant with a real model stays refused: a mutating job runs unattended with write and run
    /// tools open, and the mount is what bounds it.
    static func realModelGrantRefusal(_ grant: BenchGrant?) -> String? {
        guard case .readWrite(let dir)? = grant else {
            return "a bench grant makes a mutating job; with a real model only --grant-write on a folder under the temp directory is allowed"
        }
        // An allow: a path that cannot be resolved (a dangling link, a `..`) is refused, not stepped past.
        guard let real = IrisPaths.realPathForAllow(dir) else { return "--grant-write with a real model needs a path that resolves: \(dir)" }
        let roots = Set(tempRoots().map(IrisPaths.realPath))
        let under = roots.contains { real.hasPrefix($0 + "/") && real != $0 }
        return under ? nil : "--grant-write with a real model needs a folder under the temp directory (\(roots.sorted().joined(separator: ", "))); \(real) is not"
    }

    /// The user's temp folder from the system (`confstr`, not `$TMPDIR`, which a caller can point at
    /// their home) and `/tmp`.
    private static func tempRoots() -> [String] {
        var buf = [CChar](repeating: 0, count: Int(PATH_MAX))
        let n = confstr(_CS_DARWIN_USER_TEMP_DIR, &buf, buf.count)
        return (n > 0 ? [String(decoding: buf.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)] : []) + ["/tmp"]
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
        // first touched (inside ScenarioRunner.run). Real runs keep Keychain access for auth, except a local target (below).
        // Bench runs never write to the user's real preferences.
        // A local target keeps the run off the Keychain: in memory before `ConfigManager.shared` first loads its secrets.
        if opts.localTarget != nil { KeychainManager.requestHeadlessBypass() }
        IrisDefaults.useVolatileCopyOfStandard()
        opts.localTarget?.apply(to: ConfigManager.shared)
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
