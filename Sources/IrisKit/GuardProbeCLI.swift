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
    }

    static let defaultText = "The build finished in 42 seconds and all tests passed."

    static let usage = "usage: iris --guard-probe [--text TEXT] [--reps N] [--prebuild SECONDS]"

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
            case "--prebuild":
                guard let value = rest.next(), let s = Double(value), s >= 0 else { return .failure(.badValue(flag)) }
                options.prebuildSeconds = s
            default:
                return .failure(.unknownFlag(flag))
            }
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
        let config = ConfigManager.shared
        guard config.enableAdvancedPromptInjectionProtection else {
            print("guard-probe: prompt-injection protection is off in this home; nothing to measure")
            return 1
        }
        let engine = config.promptGuardEngine
        let maxTier: InjectionGuard.SanitizationTier = engine == "cloud" ? .tier2_coreML : .tier3_canary
        print("guard-probe: tier 2 \(config.promptGuardCoreMLModel.isEmpty ? "(none)" : config.promptGuardCoreMLModel); "
              + "tier 3 \(engine) \(config.promptGuardModel)\(engine == "cloud" ? " skipped (cloud)" : "")")

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
            let outcome = await InjectionGuard.classify(text(options.text, rep: rep), contextTag: "guard-probe", maxTier: maxTier)
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
