import Testing
import Foundation
@testable import IrisKit

/// #854: `--bench --real` can drive a paid cloud model as the primary, only for the two models on the allow
/// list, only under a dollar cap whose projection is checked before the run starts, with the canary pinned
/// (or the guard said to be bypassed) and the key from the environment. Every rule is a refusal.
@Suite("Bench cloud target (#854)")
struct BenchCloudTargetTests {
    private static let models = URL(fileURLWithPath: "/tmp/iris-bench-models")
    private static let flash = ["--cloud-primary", "gemini:gemini-3.8-flash", "--allow-paid", "--max-dollars", "3",
                                "--spend-ledger", "/tmp/ledger.jsonl", "--local-canary", "gemma4:12b"]
    private static let opus = ["--cloud-primary", "anthropic:claude-opus-5-5", "--allow-paid", "--max-dollars", "11",
                               "--spend-ledger", "/tmp/ledger.jsonl", "--bypass-guard"]

    private static var real: Scenario { var s = BenchCLI.defaultScenario; s.clientMode = .real; return s }

    private static func opts(_ extra: [String]) throws -> BenchOptions {
        try #require(BenchCLI.parse(["iris", "--bench", "--real"] + extra))
    }

    /// The refusal with a key present and every file existing, unless the test says otherwise.
    private static func refusal(_ args: [String], scenario: Scenario = real, env: [String: String] = ["GEMINI_API_KEY": "k", "ANTHROPIC_API_KEY": "k"],
                                regularFiles: Set<String> = []) throws -> String? {
        BenchCloudTarget.refusal(try opts(args), scenario: scenario, env: { env[$0] }, modelsDir: models,
                                 isRegularFile: { regularFiles.contains($0) })
    }

    @Test("the two allowed arms parse and pass every check")
    func allowedArms() throws {
        #expect(try Self.refusal(Self.flash) == nil)
        #expect(try Self.refusal(Self.opus) == nil)
        let t = try #require(BenchCloudTarget.target(try Self.opts(Self.flash)))
        #expect(t.provider == .gemini && t.model == "gemini-3.8-flash" && t.canary == .ollama("gemma4:12b") && t.maxDollars == 3)
        let o = try #require(BenchCloudTarget.target(try Self.opts(Self.opus)))
        #expect(o.provider == .anthropic && o.canary == .bypassed)
    }

    @Test("no cloud flag, no cloud rule: a plain or local run is untouched")
    func untouched() throws {
        #expect(try Self.refusal([]) == nil)
        #expect(try Self.refusal(["--local-openai", "http://127.0.0.1:11434/v1", "--local-model", "m"]) == nil)
        #expect(BenchCloudTarget.target(try Self.opts([])) == nil)
    }

    @Test("a model off the allow list, a wrong provider prefix or a lookalike is refused", arguments: [
        "gemini:gemini-3.8-pro", "anthropic:claude-opus-5", "openai:gpt-5", "gemini:claude-opus-5-5", "anthropic:gemini-3.8-flash",
        "gemini-3.8-flash", "Gemini:gemini-3.8-flash", "gemini:gemini-3.8-flash ", "gemini:gemini-3.8-flash:x", ":gemini-3.8-flash", "",
    ])
    func modelRefused(spec: String) throws {
        let args = ["--cloud-primary", spec] + Array(Self.flash.dropFirst(2))
        let why = try Self.refusal(spec.isEmpty ? Array(Self.flash.dropFirst(2)) : args)
        #expect(why != nil, "\(spec) was allowed")
    }

    @Test("a cloud primary needs --real, --allow-paid, a positive cap and a ledger")
    func prerequisites() throws {
        #expect(try Self.refusal(Self.flash, scenario: BenchCLI.defaultScenario)?.contains("--real") == true)
        let noPaid = Self.flash.filter { $0 != "--allow-paid" }
        #expect(try Self.refusal(noPaid)?.contains("--allow-paid") == true)
        let noCap = Array(Self.flash.prefix(2)) + ["--allow-paid"] + Array(Self.flash.suffix(4))
        #expect(try Self.refusal(noCap)?.contains("--max-dollars") == true)
        for bad in ["0", "-1", "abc", "inf", "nan", "", "1e999"] {
            var a = Self.flash; a[a.firstIndex(of: "--max-dollars")! + 1] = bad
            #expect(try Self.refusal(a) != nil, "--max-dollars \(bad) was allowed")
        }
        var big = Self.flash; big[big.firstIndex(of: "--max-dollars")! + 1] = "500"
        #expect(try Self.refusal(big)?.contains("ceiling") == true)
        let noLedger = Array(Self.flash.prefix(5)) + Array(Self.flash.suffix(2))
        #expect(try Self.refusal(noLedger)?.contains("--spend-ledger") == true)
    }

    @Test("paid flags without --cloud-primary are refused, never ignored")
    func orphanFlags() throws {
        for extra in [["--allow-paid"], ["--max-dollars", "3"], ["--spend-ledger", "/tmp/l"], ["--canary-gguf", "m.gguf"], ["--bypass-guard"]] {
            #expect(try Self.refusal(extra)?.contains("--cloud-primary") == true, "\(extra) was ignored")
        }
    }

    @Test("a cloud primary and a local one exclude each other")
    func exclusive() throws {
        #expect(try Self.refusal(Self.flash + ["--local-openai", "http://127.0.0.1:11434/v1", "--local-model", "m"])?.contains("exclude") == true)
    }

    @Test("the canary is never inherited: none, or more than one, is refused")
    func canaryPinned() throws {
        let none = Self.flash.filter { $0 != "--local-canary" && $0 != "gemma4:12b" }
        #expect(try Self.refusal(none)?.contains("exactly one") == true)
        #expect(try Self.refusal(Self.flash + ["--bypass-guard"])?.contains("exactly one") == true)
        #expect(try Self.refusal(Self.flash + ["--canary-gguf", "m.gguf"])?.contains("exactly one") == true)
    }

    @Test("--canary-gguf takes a .gguf file name that is a regular file in the models folder, never a path")
    func gguf() throws {
        let base = Array(Self.flash.prefix(7))
        let file = Self.models.appendingPathComponent("g.gguf").path
        #expect(try Self.refusal(base + ["--canary-gguf", "g.gguf"], regularFiles: [file]) == nil)
        #expect(try Self.refusal(base + ["--canary-gguf", "g.gguf"])?.contains("not a regular file") == true)
        for bad in ["../g.gguf", "/etc/passwd.gguf", "sub/g.gguf", "g.bin", "g.gguf.zip", ".."] {
            #expect(try Self.refusal(base + ["--canary-gguf", bad], regularFiles: [Self.models.appendingPathComponent(bad).path])?.contains("not a path") == true,
                    "\(bad) was allowed")
        }
        let t = try #require(BenchCloudTarget.target(try Self.opts(base + ["--canary-gguf", "g.gguf"])))
        #expect(t.canary == .gguf("g.gguf"))
    }

    @Test("the key is read from the environment of the provider; a missing or blank one is refused")
    func keys() throws {
        #expect(try Self.refusal(Self.flash, env: [:])?.contains("GEMINI_API_KEY") == true)
        #expect(try Self.refusal(Self.opus, env: [:])?.contains("ANTHROPIC_API_KEY") == true)
        #expect(try Self.refusal(Self.opus, env: ["ANTHROPIC_API_KEY": "  \n"])?.contains("ANTHROPIC_API_KEY") == true)
        #expect(try Self.refusal(Self.opus, env: ["GEMINI_API_KEY": "k"])?.contains("ANTHROPIC_API_KEY") == true, "the other provider's key must not do")
    }

    @Test("a cap below one run's projection is refused before anything starts")
    func capBelowProjection() throws {
        let projected = try #require(BenchCloudTarget.projectedRunDollars(provider: .anthropic, model: "claude-opus-5-5"))
        #expect(projected > 0.05 && projected < 0.2, "opus projects \(projected)")
        var a = Self.opus; a[a.firstIndex(of: "--max-dollars")! + 1] = "0.01"
        #expect(try Self.refusal(a)?.contains("not started") == true)
    }

    @Test("projection: flash is cheaper than opus, both from the price list, and an unlisted model has no projection")
    func projection() throws {
        let flash = try #require(BenchCloudTarget.projectedRunDollars(provider: .gemini, model: "gemini-3.8-flash"))
        let opus = try #require(BenchCloudTarget.projectedRunDollars(provider: .anthropic, model: "claude-opus-5-5"))
        #expect(flash > 0.01 && flash < 0.05, "flash projects \(flash)")
        #expect(opus > flash)
        #expect(BenchCloudTarget.projectedRunDollars(provider: .gemini, model: "no-such-model") == nil)
    }

    @Test("reported dollars come from the usage each call reported; none reported is nil, not zero")
    func reported() {
        func call(_ p: Int?, _ o: Int?) -> ModelCallRecord {
            ModelCallRecord(round: 1, model: "m", latencyMs: 1, promptTokens: p, outputTokens: o, returnedToolCalls: false)
        }
        let rates = EvalCost.rates(provider: .gemini, model: "gemini-3.8-flash")
        let expected = EvalCost.dollars(EvalCost.Tokens(input: 30_000, output: 300, thought: 0, calls: 2), rates: rates)
        #expect(BenchCloudTarget.reportedDollars([call(10_000, 100), call(20_000, 200)], provider: .gemini, model: "gemini-3.8-flash") == expected)
        #expect(BenchCloudTarget.reportedDollars([call(nil, nil)], provider: .gemini, model: "gemini-3.8-flash") == nil)
        #expect(BenchCloudTarget.reportedDollars([], provider: .gemini, model: "gemini-3.8-flash") == nil)
    }

    @Test("the ledger refuses a reserve that would pass the cap, across runs that share the file")
    func ledgerCap() throws {
        let path = NSTemporaryDirectory() + "iris-bench-ledger-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let projected = try #require(BenchCloudTarget.projectedRunDollars(provider: .anthropic, model: "claude-opus-5-5"))
        let cap = projected * 2.5
        var held: [UUID] = []
        for n in 1...5 {
            let ledger = try SpendLedger(path: path, arm: "run\(n)", cap: cap)   // one ledger object per process, one file
            if let id = try ledger.reserve(projected) { held.append(id) }
        }
        #expect(held.count == 2, "a 2.5-run cap must admit exactly 2 runs, got \(held.count)")
    }

    @Test("apply points the provider, every tier and the canary; the key stays in memory")
    @MainActor
    func applyCloud() throws {
        let name = "iris-benchcloud-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let keychain = KeychainManager(serviceSuffix: ".benchcloud", inMemory: true)
        let config = ConfigManager(store: store, guardedSecrets: keychain)

        BenchCloudTarget(provider: .anthropic, model: "claude-opus-5-5", canary: .gguf("g.gguf"), maxDollars: 11, ledgerPath: "l")
            .apply(to: config, key: "sk-test")
        #expect(config.primaryProvider == LLMProvider.anthropic.rawValue)
        #expect(config.anthropicAPIKey == "sk-test")
        for tier in [ModelTier.easy, .medium, .hard] { #expect(config.getModel(for: tier) == "claude-opus-5-5") }
        #expect(config.promptGuardEngine == AuxiliaryEngineType.llamaCPP.rawValue)
        #expect(config.promptGuardModel == "g.gguf")
        #expect(config.enableAdvancedPromptInjectionProtection)
        #expect(config.enableSandboxing)

        BenchCloudTarget(provider: .gemini, model: "gemini-3.8-flash", canary: .bypassed, maxDollars: 3, ledgerPath: "l")
            .apply(to: config, key: "g-test")
        #expect(config.primaryProvider == LLMProvider.gemini.rawValue)
        #expect(config.geminiAPIKey == "g-test")
        #expect(!config.enableAdvancedPromptInjectionProtection, "--bypass-guard must switch the injection guard off")
    }

    @Test("the header records the machine's own guard settings, the tier-2 state and, bypassed, says so")
    @MainActor
    func header() throws {
        let name = "iris-benchcloudhdr-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store, guardedSecrets: KeychainManager(serviceSuffix: ".benchcloudhdr", inMemory: true))
        config.promptGuardEngine = "cloud"
        config.promptGuardModel = "vertex-guard-model"
        let bypassed = BenchCloudTarget(provider: .gemini, model: "gemini-3.8-flash", canary: .bypassed, maxDollars: 3, ledgerPath: "l")
        let text = BenchCloudTarget.header(for: bypassed, settings: config, tier2: .unprovisioned(modelName: "deberta.onnx"))
        #expect(text.contains("tier-3 engine cloud, model vertex-guard-model"), "the would-be guard must be recorded: \(text)")
        #expect(text.contains("NOT downloaded (deberta.onnx)"))
        #expect(text.contains("Bench guard: BYPASSED - replaying pre-passed rows"))
        #expect(text.contains("DRIVER compliance, not the guard"))
        let pinned = BenchCloudTarget(provider: .gemini, model: "gemini-3.8-flash", canary: .ollama("gemma4:12b"), maxDollars: 3, ledgerPath: "l")
        #expect(!BenchCloudTarget.header(for: pinned, settings: config, tier2: .notConfigured).contains("BYPASSED"))
    }

    @Test("a cloud target asks for the in-memory Keychain first, then the volatile defaults, then applies it")
    func prepareOrder() throws {
        let o = try Self.opts(Self.opus)
        let target = try #require(BenchCloudTarget.target(o))
        var steps: [String] = []
        BenchCLI.prepareSettings(o, requestBypass: { steps.append("bypass") }, useVolatile: { steps.append("volatile") },
                                 apply: { _ in steps.append("local") }, cloud: target, applyCloud: { _ in steps.append("cloud") })
        #expect(steps == ["bypass", "volatile", "cloud"])
    }
}
