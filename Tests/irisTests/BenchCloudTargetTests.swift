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

    @Test("a cap below one run's bound is refused before anything starts, and one just above it is not")
    func capBelowBound() throws {
        let bound = try #require(BenchCloudTarget.boundDollars(provider: .anthropic, model: "claude-opus-5-5"))
        var a = Self.opus; a[a.firstIndex(of: "--max-dollars")! + 1] = "0.01"
        #expect(try Self.refusal(a)?.contains("not started") == true)
        a[a.firstIndex(of: "--max-dollars")! + 1] = String(bound * 1.01)
        #expect(try Self.refusal(a) == nil)
    }

    @Test("bound: the budget plus one round's input at the input rate; flash is cheaper than opus; an unlisted model has none")
    func bound() throws {
        let flash = try #require(BenchCloudTarget.boundDollars(provider: .gemini, model: "gemini-3.8-flash"))
        let opus = try #require(BenchCloudTarget.boundDollars(provider: .anthropic, model: "claude-opus-5-5"))
        let rate = try #require(EvalCost.rates(provider: .gemini, model: "gemini-3.8-flash")).input
        #expect(flash == Double(40_000 + 80_000) * rate, "the bound is the budget plus twice one round's input allowance")
        #expect(opus > flash)
        #expect(BenchCloudTarget.boundDollars(provider: .gemini, model: "no-such-model") == nil)
    }

    @Test("a run is booked at its reported weighted tokens, and at its bound when it reported nothing")
    func booking() throws {
        let rate = try #require(EvalCost.rates(provider: .gemini, model: "gemini-3.8-flash")).input
        #expect(BenchCloudTarget.bookedDollars(weightedTokens: 30_000, bound: 1, provider: .gemini, model: "gemini-3.8-flash") == 30_000 * rate)
        #expect(BenchCloudTarget.bookedDollars(weightedTokens: nil, bound: 0.5, provider: .gemini, model: "gemini-3.8-flash") == 0.5)
    }

    private func target(_ cap: Double) -> BenchCloudTarget {
        BenchCloudTarget(provider: .gemini, model: "gemini-3.8-flash", canary: .bypassed, maxDollars: cap, ledgerPath: "l")
    }

    @Test("reserveRun reserves the run's bound in the ledger and refuses the run that would pass the cap, across runs that share the file")
    func reserveRunHoldsTheCap() throws {
        let path = NSTemporaryDirectory() + "iris-bench-ledger-\(UUID().uuidString).jsonl"
        defer { try? FileManager.default.removeItem(atPath: path) }
        let bound = try #require(BenchCloudTarget.boundDollars(provider: .gemini, model: "gemini-3.8-flash"))
        let cap = bound * 2.5
        var reserved = 0
        for n in 1...5 {
            let ledger = try SpendLedger(path: path, arm: "run\(n)", cap: cap)   // one ledger object per process, one file
            switch try BenchCloudTarget.reserveRun(target(cap), in: ledger) {
            case .reserved(_, let amount): reserved += 1; #expect(amount == bound)
            case .refused(let why): #expect(why.contains("not started"))
            }
        }
        #expect(reserved == 2, "a 2.5-run cap must admit exactly 2 runs, got \(reserved)")
        let total = try SpendLedger(path: path, arm: "x", cap: cap).total()
        #expect(abs(total - 2 * bound) < 1e-9, "the ledger must hold the bound for each admitted run, not less: \(total)")
    }

    @Test("a settled run frees its reserve: what it reported is booked in its place")
    func settleReplacesReserve() throws {
        let ledger = try SpendLedger(path: nil, arm: "a", cap: 10)
        guard case .reserved(let id, let bound) = try BenchCloudTarget.reserveRun(target(10), in: ledger) else { Issue.record("refused"); return }
        #expect(abs(try ledger.total() - bound) < 1e-12)
        try ledger.settle(id, dollars: 0.01, tokens: (0, 0, 0))
        #expect(abs(try ledger.total() - 0.01) < 1e-12)
    }

    private func probeRound(total: Int) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(
            role: "model", parts: [Part(functionCall: FunctionCall(name: "noop_probe", args: [:]))]))],
                       usageMetadata: UsageMetadata(promptTokenCount: total - 1, candidatesTokenCount: 1, totalTokenCount: total))
    }

    @Test("a looping run stops once its reported usage reaches the budget, and without the budget it does not")
    @MainActor
    func budgetStopsALoopingRun() async throws {
        // Ends in a text answer: a FakeLLMClient repeats its last response for ever, so a list of probes alone never stops.
        let rounds = (0..<4).map { _ in probeRound(total: 30_000) }
            + [GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "done")]))], usageMetadata: nil)]
        let budgeted = FakeLLMClient(responses: rounds)
        let result = await BenchCLI.runScenario(BenchCLI.defaultScenario, clientOverride: budgeted,
                                                cloud: target(3))
        #expect(budgeted.callCount == 2, "30k then 60k against a 40k budget: round three is never asked for, got \(budgeted.callCount)")
        let weighted = try #require(result.weightedTokens)
        #expect(weighted >= BenchCloudTarget.budgetWeightedTokens && weighted < 2 * BenchCloudTarget.budgetWeightedTokens)

        let unbudgeted = FakeLLMClient(responses: rounds)
        _ = await BenchCLI.runScenario(BenchCLI.defaultScenario, clientOverride: unbudgeted)
        #expect(unbudgeted.callCount == 5, "without a budget all four probe rounds and the answer run, got \(unbudgeted.callCount)")
    }

    /// Fails every call with a 503, which the engine retries on its delays; counts the attempts.
    private final class OverloadedClient: LLMClientProtocol, @unchecked Sendable {
        private(set) var calls = 0
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            calls += 1
            throw APIError(message: "overloaded", statusCode: 503)
        }
    }

    @Test("a cloud run makes one attempt per call: a 503 is not retried (a retry is a second bill the budget cannot see)")
    @MainActor
    func oneAttemptPerCall() async {
        let overloaded = OverloadedClient()
        _ = await BenchCLI.runScenario(BenchCLI.defaultScenario, clientOverride: overloaded, cloud: target(3))
        #expect(overloaded.calls == 1, "got \(overloaded.calls) calls")
        #expect(BenchCloudTarget.retryDelays.isEmpty && BenchCloudTarget.defaultRetryDelays == [2, 4, 8])
    }

    @Test("the budget a cloud run carries is the provider's and model's, so thinking and output weigh as they bill")
    func budgetShape() {
        let b = target(3).turnBudget()
        #expect(b.maxTokens == BenchCloudTarget.budgetWeightedTokens && b.provider == "gemini" && b.model == "gemini-3.8-flash")
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

    // MARK: - Vertex ADC (work has no API keys)

    private static let flashAdc = Array(flash.prefix(7)) + ["--bypass-guard", "--cloud-auth", "vertex-adc"]
    private static let opusAdc = Array(opus.prefix(7)) + ["--bypass-guard", "--cloud-auth", "vertex-adc", "--vertex-project", "gke-claude-dev"]

    @Test("vertex-adc needs no key in the environment: Gemini rides the ADC quota project, Claude names its project")
    func vertexAllowed() throws {
        #expect(try Self.refusal(Self.flashAdc, env: [:]) == nil)
        #expect(try Self.refusal(Self.opusAdc, env: [:]) == nil)
        let o = try #require(BenchCloudTarget.target(try Self.opts(Self.opusAdc)))
        #expect(o.auth == .vertexADC(project: "gke-claude-dev", location: "global"))
        let f = try #require(BenchCloudTarget.target(try Self.opts(Self.flashAdc)))
        #expect(f.auth == .vertexADC(project: nil, location: "global"))
    }

    @Test("vertex-adc: Claude needs a valid project and location; Gemini refuses both flags; an unknown mode is refused")
    func vertexRefusals() throws {
        let noProject = Array(Self.opusAdc.dropLast(2))
        #expect(try Self.refusal(noProject, env: [:])?.contains("--vertex-project") == true)
        for bad in ["", "Gke-Claude", "gke_claude", "-gke", "a", "gke-claude-dev-", "x; rm"] {
            let a = Array(Self.opusAdc.dropLast()) + [bad]
            #expect(try Self.refusal(a, env: [:]) != nil, "project \(bad) was allowed")
        }
        for bad in ["Global", "us east5", "../x", "us-east"] {
            #expect(try Self.refusal(Self.opusAdc + ["--vertex-location", bad], env: [:]) != nil, "location \(bad) was allowed")
        }
        for good in ["global", "us", "eu", "us-east5", "europe-west4"] {
            #expect(try Self.refusal(Self.opusAdc + ["--vertex-location", good], env: [:]) == nil, "location \(good) was refused")
        }
        #expect(try Self.refusal(Self.flashAdc + ["--vertex-project", "p-12345"], env: [:])?.contains("quota project") == true)
        #expect(try Self.refusal(Self.opus + ["--cloud-auth", "gcloud"])?.contains("neither") == true)
        #expect(try Self.refusal(Self.opus + ["--vertex-project", "gke-claude-dev"])?.contains("vertex-adc") == true,
                "a Vertex flag without vertex-adc must not be silently ignored")
    }

    @Test("apply with vertex-adc sets the app's own Vertex modes and no key")
    @MainActor
    func applyVertex() throws {
        let name = "iris-benchvertex-\(UUID().uuidString)"
        let store = try #require(UserDefaults(suiteName: name))
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store, guardedSecrets: KeychainManager(serviceSuffix: ".benchvertex", inMemory: true))
        BenchCloudTarget(provider: .anthropic, model: "claude-opus-5-5", canary: .bypassed, maxDollars: 11, ledgerPath: "l",
                         auth: .vertexADC(project: "gke-claude-dev", location: "global")).apply(to: config, key: "")
        #expect(config.anthropicAuthMode == AnthropicAuthMode.vertex.rawValue)
        #expect(config.anthropicVertexProject == "gke-claude-dev")
        #expect(config.effectiveVertexLocation == "global")
        #expect(config.anthropicAPIKey.isEmpty)
        BenchCloudTarget(provider: .gemini, model: "gemini-3.8-flash", canary: .bypassed, maxDollars: 3, ledgerPath: "l",
                         auth: .vertexADC(project: nil, location: "global")).apply(to: config, key: "")
        #expect(config.geminiAuthMode == GeminiAuthMode.adc.rawValue)
        #expect(config.geminiAPIKey.isEmpty)
    }

    @Test("the header says which auth the run used")
    @MainActor
    func headerAuth() throws {
        #expect(BenchCloudTarget.describe(.vertexADC(project: "gke-claude-dev", location: "global")).contains("gke-claude-dev"))
        #expect(BenchCloudTarget.describe(.vertexADC(project: nil, location: "global")).contains("ADC quota project"))
        #expect(BenchCloudTarget.describe(.env) == "environment key")
    }
}
