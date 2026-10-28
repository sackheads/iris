import Foundation

/// `iris --guard-probe`: judge one benign text through tiers 2 and 3 as this dev home configures
/// them and print the timestamped load and guard events (#778). Dev builds only, and read-only: no
/// store, conversation, job or home lock, and a cloud tier 3 is skipped, so it never makes a paid call.
enum GuardProbeCLI {
    struct Options: Equatable {
        var text = GuardProbeCLI.defaultText
        var reps = 1
        /// Build the canary engine (which sends Ollama's preload) this many seconds before the
        /// first judgement: what building it at launch would buy, measured rather than shipped.
        var prebuildSeconds: Double?
        /// Stand-ins for this home's tier-2 model and tier-3 engine and model, for a shell that
        /// can't read its settings (cfprefsd refuses some sandboxed shells). Applied to a volatile
        /// copy of the settings, never written back.
        var engine: String?
        var model: String?
        var tier2: String?

        /// `--fixtures DIR`: #783's bake-off, one arm per run (`GuardProbeFixtures`); `--model`
        /// is then the arm's spec, `ollama:<name>` or `cloud:gemini/<id>`.
        var fixtures: GuardProbeFixtures.Options?
        /// `--compare DIR`: the table from a folder of arms' rows.
        var compare: String?
        var baselineArm: String?

        var overridesConfig: Bool { engine != nil || model != nil || tier2 != nil }
    }

    static let defaultText = "The build finished in 42 seconds and all tests passed."

    static let usage = """
        usage: iris --guard-probe [--text TEXT] [--reps N] [--prebuild SECONDS] [--engine E --model M --tier2 URL]
               iris --guard-probe --fixtures DIR --model ollama:NAME|cloud:gemini/ID --arm LABEL --out DIR
                    [--think on|off] [--thinking-level LEVEL] [--repeats N] [--agreement-sample N]
                    [--baseline ROWS.jsonl] [--flip-repeats N] [--joins] [--latency]
                    [--latency-only] [--allow-paid --max-dollars N [--spend-ledger FILE] [--estimate-only]] [--gemini-auth adc|key]
               iris --guard-probe --compare DIR [--baseline-arm LABEL]
        """

    /// nil when `--guard-probe` is absent. A bad value is a failure carrying the usage line.
    static func parse(_ args: [String]) -> Result<Options, ProbeError>? {
        guard let start = args.firstIndex(of: "--guard-probe") else { return nil }
        var options = Options()
        var rest = args[(start + 1)...].makeIterator()
        while let flag = rest.next() {
            switch flag {
            case "--text":
                guard let value = rest.next(), !value.isEmpty else { return .failure(.badValue(flag)) }
                options.text = value
            case "--reps":
                guard let value = rest.next(), let n = Int(value), n >= 1 else { return .failure(.badValue(flag)) }
                options.reps = n
            case "--engine", "--model", "--tier2":
                guard let value = rest.next(), !value.isEmpty else { return .failure(.badValue(flag)) }
                switch flag {
                case "--engine": options.engine = value
                case "--model": options.model = value
                default: options.tier2 = value
                }
            case "--prebuild":
                guard let value = rest.next(), let s = Double(value), s >= 0 else { return .failure(.badValue(flag)) }
                options.prebuildSeconds = s
            case "--compare", "--baseline-arm":
                guard let value = rest.next(), !value.isEmpty else { return .failure(.badValue(flag)) }
                if flag == "--compare" { options.compare = value } else { options.baselineArm = value }
            case "--joins", "--latency", "--allow-paid", "--estimate-only", "--latency-only":
                var f = options.fixtures ?? GuardProbeFixtures.Options()
                switch flag {
                case "--joins": f.joins = true
                case "--latency": f.latency = true
                case "--estimate-only": f.estimateOnly = true
                case "--latency-only": f.latencyOnly = true; f.latency = true
                default: f.allowPaid = true
                }
                options.fixtures = f
            case "--fixtures", "--arm", "--out", "--think", "--thinking-level", "--repeats", "--agreement-sample",
                 "--baseline", "--flip-repeats", "--max-dollars", "--gemini-auth", "--spend-ledger":
                guard let value = rest.next(), !value.isEmpty else { return .failure(.badValue(flag)) }
                var f = options.fixtures ?? GuardProbeFixtures.Options()
                switch flag {
                case "--fixtures": f.dir = value
                case "--arm": f.arm = value
                case "--out": f.out = value
                case "--think":
                    guard value == "on" || value == "off" else { return .failure(.badValue(flag)) }
                    f.thinkOff = value == "off"
                case "--thinking-level": f.thinkingLevel = value
                case "--repeats", "--agreement-sample", "--flip-repeats":
                    guard let n = Int(value), n >= (flag == "--agreement-sample" ? 0 : 1) else { return .failure(.badValue(flag)) }
                    if flag == "--repeats" { f.repeats = n } else if flag == "--flip-repeats" { f.flipRepeats = n } else { f.agreementSample = n }
                case "--baseline": f.baseline = value
                case "--spend-ledger": f.spendLedger = value
                case "--max-dollars":
                    guard let d = Double(value), d > 0 else { return .failure(.badValue(flag)) }
                    f.maxDollars = d
                default:
                    guard value == "adc" || value == "key" else { return .failure(.badValue(flag)) }
                    f.geminiAuth = value
                }
                options.fixtures = f
            default:
                return .failure(.unknownFlag(flag))
            }
        }
        if var f = options.fixtures {
            // The run options mean nothing without a fixtures folder, an arm and somewhere to write.
            guard !f.dir.isEmpty else { return .failure(.badValue("--fixtures")) }
            guard !f.arm.isEmpty, f.arm.allSatisfy({ $0.isLetter || $0.isNumber || "-_.".contains($0) }) else { return .failure(.badValue("--arm")) }
            guard !f.out.isEmpty else { return .failure(.badValue("--out")) }
            guard let model = options.model, GuardProbeFixtures.Runtime(model) != nil else { return .failure(.badValue("--model")) }
            f.model = model
            options.fixtures = f
        }
        return .success(options)
    }

    enum ProbeError: Error, Equatable, LocalizedError {
        case badValue(String)
        case unknownFlag(String)
        var errorDescription: String? {
            switch self {
            case .badValue(let flag): return "\(flag) needs a value"
            case .unknownFlag(let flag): return "unknown option \(flag)"
            }
        }
    }

    /// The text judged on rep `n`. A suffix per rep, so the process's verdict cache never answers
    /// for the model.
    static func text(_ base: String, rep: Int) -> String {
        rep == 1 ? base : "\(base) (\(rep))"
    }

    static func run(_ options: Options, build: BuildIdentity = .current) async -> Int32 {
        guard build == .dev else {
            FileHandle.standardError.write(Data("iris --guard-probe: dev builds only; this is the release app\n".utf8))
            return 1
        }
        if let dir = options.compare { return GuardProbeFixtures.compare(dir, baselineArm: options.baselineArm) }
        if let fixtures = options.fixtures { return await GuardProbeFixtures.run(fixtures) }
        // Before the first touch of `ConfigManager.shared`, as `--perf` does: the overrides land in
        // a copy that goes with the process.
        if options.overridesConfig { IrisDefaults.useVolatileCopyOfStandard() }
        let config = ConfigManager.shared
        if let engine = options.engine { config.promptGuardEngine = engine }
        if let model = options.model { config.promptGuardModel = model }
        if let tier2 = options.tier2 { config.promptGuardCoreMLModel = tier2 }
        // With overrides the guard is judged on, whatever the unreadable home says: passed as the
        // call's own flag, so the guarded setting (and its Keychain item) is never written.
        let protection: Bool? = options.overridesConfig ? true : nil
        guard options.overridesConfig || config.enableAdvancedPromptInjectionProtection else {
            print("guard-probe: prompt-injection protection is off in this home; nothing to measure")
            return 1
        }
        let engine = config.promptGuardEngine
        let maxTier: InjectionGuard.SanitizationTier = engine == "cloud" ? .tier2_coreML : .tier3_canary
        print("guard-probe: tier 2 \(config.promptGuardCoreMLModel.isEmpty ? "(none)" : config.promptGuardCoreMLModel); "
              + "tier 3 \(engine) \(config.promptGuardModel)\(engine == "cloud" ? " skipped (cloud)" : "")"
              + (options.overridesConfig ? " (from options, not this home)" : ""))

        if let wait = options.prebuildSeconds, maxTier == .tier3_canary {
            PerformanceProfiler.event("guard-probe prebuild canary")
            let type = AuxiliaryEngineType(rawValue: engine) ?? .llamaCPP
            _ = try? await AuxiliaryModelManager.shared.getEngine(
                for: "canary", config: AuxiliaryModelConfig(role: "canary", engineType: type, modelPathOrName: config.promptGuardModel))
            try? await Task.sleep(for: .seconds(wait))
        }

        for rep in 1...options.reps {
            PerformanceProfiler.event("guard-probe rep=\(rep) start")
            let start = MonotonicClock.nowMs()
            let outcome = await InjectionGuard.classify(text(options.text, rep: rep), contextTag: "guard-probe", maxTier: maxTier,
                                                       protectionEnabled: protection)
            let verdict: String
            switch outcome {
            case .passed: verdict = "passed"
            case .blocked(let marker): verdict = "blocked \(marker)"
            }
            PerformanceProfiler.event("guard-probe rep=\(rep) end ms=\(Int(MonotonicClock.nowMs() - start)) verdict=\(verdict)")
        }
        return 0
    }
}
