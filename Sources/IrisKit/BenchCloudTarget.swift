import Foundation

/// #854: a paid cloud model as the primary of a `--bench --real` run, so a capable driver's compliance with a
/// planted request can be measured on the rows a local guard already passed. Bench-only, like
/// `BenchLocalTarget`: the flags exist in `BenchCLI.parse` and nowhere in the app. Every piece of it is a
/// refusal: only the two models below, only with `--real --allow-paid`, only under a dollar cap whose
/// projection is checked BEFORE the run starts, with a spend ledger shared by every run that names the same file,
/// and with the tier-3 canary pinned on the command line (or the guard said to be bypassed), never inherited
/// from the settings of whatever machine runs it. The key comes from the environment, so the run neither reads
/// nor writes the Keychain and cannot prompt.
struct BenchCloudTarget: Equatable, Sendable {
    /// What stands in front of the primary: the injection guard's tier-3 canary, or nothing.
    enum Canary: Equatable, Sendable {
        /// An Ollama model (`--local-canary`), as the #854 gemma arm used.
        case ollama(String)
        /// A llama.cpp model file in the dev home's models folder (`--canary-gguf`).
        case gguf(String)
        /// `--bypass-guard`: rows a guard already passed are replayed, so the prompt-injection guard is off.
        case bypassed
    }

    /// The only models this path will call, each with the provider that serves it. A new one is a code
    /// change with a price row, not a flag typo.
    static let allowed: [String: LLMProvider] = ["gemini-3.8-flash": .gemini, "claude-opus-5-5": .anthropic]

    /// The `--max-dollars` ceiling, so a typo (`500`) cannot become the cap.
    static let maxCapDollars = 50.0

    /// Where the credentials come from. The key is never read from the Keychain.
    enum Auth: Equatable, Sendable {
        /// `GEMINI_API_KEY` / `ANTHROPIC_API_KEY` in the environment.
        case env
        /// gcloud Application Default Credentials, as the app's Vertex modes use them. Gemini rides the ADC quota
        /// project; Claude names its project (sent as `x-goog-user-project`) and a location.
        case vertexADC(project: String?, location: String)
    }

    static let defaultVertexLocation = ConfigManager.defaultVertexLocation

    var provider: LLMProvider
    var model: String
    var canary: Canary
    var maxDollars: Double
    var ledgerPath: String
    var auth: Auth = .env

    /// The environment variable the key is read from.
    static func keyVariable(for provider: LLMProvider) -> String {
        provider == .anthropic ? "ANTHROPIC_API_KEY" : "GEMINI_API_KEY"
    }

    /// `provider:model` as typed, or nil. The pair must be one of `allowed` exactly.
    static func parse(spec: String) -> (provider: LLMProvider, model: String)? {
        let parts = spec.split(separator: ":", maxSplits: 1, omittingEmptySubsequences: false).map(String.init)
        guard parts.count == 2, let provider = allowed[parts[1]],
              parts[0] == provider.rawValue.lowercased() else { return nil }
        return (provider, parts[1])
    }

    /// The in-run bound (#916 review): once the turn's reported usage reaches this many weighted tokens (an input token
    /// is 1, an output or thinking token 5, a cache read its discount), no further model round starts. A normal run is
    /// two rounds of about 11k.
    static let budgetWeightedTokens = 40_000
    /// A run that has stopped responding ends here.
    static let budgetSeconds = 900.0
    /// The most one round can add past the budget beyond what the budget lets it spend: its own input. The budget
    /// caps a request's output to what is left, so the round that crosses it cannot overshoot on output; its prompt
    /// (the 10.5k-token request, plus a few capped tool results) is assumed to stay under this.
    static let roundInputAllowanceTokens = 40_000
    /// That allowance in weighted tokens: a prompt written to a one-hour cache weighs up to 2x its tokens, so the bound
    /// takes twice the plain figure.
    static let roundAllowanceWeighted = 2 * roundInputAllowanceTokens
    /// One attempt per call: a retry is a second bill the budget cannot see.
    static let retryDelays: [TimeInterval] = []
    /// The default of every other run.
    static let defaultRetryDelays: [TimeInterval] = [2, 4, 8]

    /// The turn budget a cloud run carries.
    func turnBudget() -> TurnBudget {
        TurnBudget(maxTokens: Self.budgetWeightedTokens, seconds: Self.budgetSeconds,
                   provider: provider.rawValue.lowercased(), model: model)
    }

    /// The most one run can cost under its budget, in dollars: the budget plus one round's input, every weighted token
    /// priced at the input rate (the weights are the price ratios). nil when the price list has no rate. This is what a
    /// run reserves in the ledger.
    static func boundDollars(provider: LLMProvider, model: String) -> Double? {
        guard let rates = EvalCost.rates(provider: provider, model: model) else { return nil }
        return Double(budgetWeightedTokens + roundAllowanceWeighted) * rates.input
    }

    /// What a run is booked at: the dollars of the weighted tokens its turns reported, never above what it reserved
    /// (the budget is what keeps them under it) and never below the typical-run projection when it reported nothing.
    static func bookedDollars(weightedTokens: Int?, bound: Double, provider: LLMProvider, model: String) -> Double {
        guard let weightedTokens, let rates = EvalCost.rates(provider: provider, model: model) else { return bound }
        return Double(weightedTokens) * rates.input
    }

    enum ReserveOutcome: Equatable {
        case reserved(UUID, Double)
        case refused(String)
    }

    /// The reserve-or-refuse decision of a run, pulled out of `run()` so it can be tested: reserve the run's bound in the
    /// ledger, or say why not. A reserve of zero would let every run through, so the amount is the bound or nothing.
    static func reserveRun(_ target: BenchCloudTarget, in ledger: SpendLedger) throws -> ReserveOutcome {
        guard let bound = boundDollars(provider: target.provider, model: target.model) else {
            return .refused("no listed price for \(target.model); not started")
        }
        guard let id = try ledger.reserve(bound) else {
            let spent = (try? ledger.total()) ?? 0
            return .refused(String(format: "one run is bounded at $%.3f and the ledger holds $%.3f of the $%.2f cap: not started",
                                   bound, spent, target.maxDollars))
        }
        return .reserved(id, bound)
    }

    /// Why these options cannot be a cloud-primary run, or nil. `env` and `fileExists` are injectable so a test
    /// needs no key and no file. Judged in the order a person fixes them.
    static func refusal(_ opts: BenchOptions, scenario: Scenario, env: (String) -> String?,
                        modelsDir: URL, isRegularFile: (String) -> Bool) -> String? {
        let named = opts.cloudPrimary != nil || opts.allowPaid || opts.maxDollars != nil || opts.spendLedger != nil
            || opts.canaryGguf != nil || opts.bypassGuard || opts.cloudAuth != nil || opts.vertexProject != nil
            || opts.vertexLocation != nil
        guard named else { return nil }
        guard let spec = opts.cloudPrimary else {
            return "--allow-paid, --max-dollars, --spend-ledger, --canary-gguf, --bypass-guard, --cloud-auth, --vertex-project and --vertex-location need --cloud-primary PROVIDER:MODEL"
        }
        guard let (provider, model) = parse(spec: spec) else {
            let list = allowed.map { "\($0.value.rawValue.lowercased()):\($0.key)" }.sorted().joined(separator: ", ")
            return "--cloud-primary takes one of \(list); \(spec.isEmpty ? "(empty)" : spec) is not"
        }
        if opts.localOpenAI != nil || opts.localModel != nil {
            return "--cloud-primary and --local-openai exclude each other: the primary is one or the other"
        }
        if scenario.clientMode != .real { return "--cloud-primary applies to a real run: add --real" }
        if !opts.allowPaid { return "--cloud-primary makes paid calls: add --allow-paid" }
        guard let raw = opts.maxDollars, let cap = Double(raw), cap.isFinite, cap > 0 else {
            return "--cloud-primary needs --max-dollars N, a positive number"
        }
        if cap > maxCapDollars { return "--max-dollars \(raw) is over the \(Int(maxCapDollars)) dollar ceiling for one bench" }
        guard let ledger = opts.spendLedger, !ledger.isEmpty else {
            return "--cloud-primary needs --spend-ledger FILE, so one cap covers every run that names it"
        }
        let canaries = [opts.localCanary != nil, opts.canaryGguf != nil, opts.bypassGuard].filter { $0 }.count
        if canaries != 1 {
            return "--cloud-primary needs exactly one of --local-canary NAME, --canary-gguf FILE and --bypass-guard: the guard in front of it is never inherited from this machine's settings"
        }
        if let gguf = opts.canaryGguf {
            if gguf.contains("/") || gguf.contains("..") || !gguf.lowercased().hasSuffix(".gguf") {
                return "--canary-gguf takes a .gguf file name in the models folder, not a path: \(gguf)"
            }
            let path = modelsDir.appendingPathComponent(gguf).path
            if !isRegularFile(path) { return "--canary-gguf \(gguf) is not a regular file in \(modelsDir.path)" }
        }
        switch opts.cloudAuth {
        case nil, "env":
            if opts.vertexProject != nil || opts.vertexLocation != nil {
                return "--vertex-project and --vertex-location need --cloud-auth vertex-adc"
            }
            let variable = keyVariable(for: provider)
            if (env(variable) ?? "").trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                return "--cloud-primary reads its key from \(variable), which is not set"
            }
        case "vertex-adc":
            if let why = vertexRefusal(provider: provider, project: opts.vertexProject, location: opts.vertexLocation) { return why }
        default:
            return "--cloud-auth takes env or vertex-adc; \(opts.cloudAuth ?? "") is neither"
        }
        guard let bound = boundDollars(provider: provider, model: model) else {
            return "no listed price for \(model): the cost cannot be bounded, so the run is not started"
        }
        if bound > cap {
            return String(format: "one run is bounded at $%.3f, over --max-dollars %@: not started", bound, raw)
        }
        return nil
    }

    /// The Vertex half of the refusal table. Gemini's project is the ADC quota project, as in the app, so naming one is
    /// refused rather than quietly ignored; Claude needs an explicit project and a valid location.
    static func vertexRefusal(provider: LLMProvider, project: String?, location: String?) -> String? {
        switch provider {
        case .gemini:
            if project != nil || location != nil {
                return "--vertex-project and --vertex-location are for anthropic: a gemini run uses the ADC quota project"
            }
        case .anthropic:
            guard let project, isValidProject(project) else {
                return "--cloud-auth vertex-adc with anthropic needs --vertex-project ID (lowercase letters, digits and hyphens)"
            }
            if let location, !isValidLocation(location) {
                return "--vertex-location \(location) is not valid: use global, us, eu, or a region such as us-east5"
            }
        case .openai:
            return "not an allowed provider"
        }
        return nil
    }

    static func isValidProject(_ s: String) -> Bool {
        s.range(of: "^[a-z][a-z0-9-]{3,28}[a-z0-9]$", options: .regularExpression) != nil
    }

    static func isValidLocation(_ s: String) -> Bool {
        s == "global" || s == "us" || s == "eu" || s.range(of: "^[a-z]+-[a-z]+[0-9]+$", options: .regularExpression) != nil
    }

    /// The target when the options are valid (call after `refusal` returned nil).
    static func target(_ opts: BenchOptions) -> BenchCloudTarget? {
        guard let spec = opts.cloudPrimary, let (provider, model) = parse(spec: spec),
              let raw = opts.maxDollars, let cap = Double(raw), let ledger = opts.spendLedger else { return nil }
        let canary: Canary
        if let gguf = opts.canaryGguf { canary = .gguf(gguf) }
        else if opts.bypassGuard { canary = .bypassed }
        else { canary = .ollama(opts.localCanary ?? BenchLocalTarget.defaultCanaryModel) }
        let auth: Auth = opts.cloudAuth == "vertex-adc"
            ? .vertexADC(project: opts.vertexProject, location: opts.vertexLocation ?? defaultVertexLocation) : .env
        return BenchCloudTarget(provider: provider, model: model, canary: canary, maxDollars: cap, ledgerPath: ledger, auth: auth)
    }

    /// Points a config at the cloud model: the provider on every tier, the key, the canary as pinned, and the
    /// sandbox switch a granted background run relies on. The config must be a volatile copy's, with its
    /// guarded settings in memory (the caller asked for the in-memory Keychain first).
    @MainActor
    func apply(to config: ConfigManager, key: String) {
        config.primaryProvider = provider.rawValue
        switch provider {
        case .anthropic:
            if case .vertexADC(let project, let location) = auth {
                config.anthropicAuthMode = AnthropicAuthMode.vertex.rawValue
                config.anthropicVertexProject = project ?? ""
                config.anthropicVertexLocation = location
            } else {
                config.anthropicAPIKey = key
            }
            config.anthropicModelEasy = model; config.anthropicModelMedium = model; config.anthropicModelHard = model
        case .gemini:
            if case .vertexADC = auth { config.geminiAuthMode = GeminiAuthMode.adc.rawValue } else { config.geminiAPIKey = key }
            config.geminiModelEasy = model; config.geminiModelMedium = model; config.geminiModelHard = model
        case .openai:
            break   // not in `allowed`
        }
        switch canary {
        case .ollama(let name):
            config.promptGuardEngine = AuxiliaryEngineType.ollama.rawValue
            config.promptGuardModel = name
            config.enableAdvancedPromptInjectionProtection = true
        case .gguf(let file):
            config.promptGuardEngine = AuxiliaryEngineType.llamaCPP.rawValue
            config.promptGuardModel = file
            config.enableAdvancedPromptInjectionProtection = true
        case .bypassed:
            config.enableAdvancedPromptInjectionProtection = false
        }
        config.enableSandboxing = true
    }

    /// The header of a cloud-primary run: the guard this machine's settings WOULD have used (read before
    /// `apply` changes them), the tier-2 state, and what the run actually uses. Recorded even when the guard is
    /// bypassed, so a result says what it ran in front of.
    @MainActor
    static func header(for target: BenchCloudTarget, settings config: ConfigManager, tier2: InjectionGuard.Tier2Provisioning) -> String {
        let engine = config.promptGuardEngine, model = config.promptGuardModel
        var lines = [
            "Bench target: cloud primary \(target.provider.rawValue.lowercased()):\(target.model), cap $\(target.maxDollars), ledger \(target.ledgerPath)",
            "Bench settings on this machine (not used): injection guard \(config.enableAdvancedPromptInjectionProtection ? "on" : "off"), tier-3 engine \(engine.isEmpty ? "(none)" : engine), model \(model.isEmpty ? "(none)" : model)",
            "Bench tier 2: \(describe(tier2))",
            "Bench auth: \(describe(target.auth))",
        ]
        switch target.canary {
        case .ollama(let name): lines.append("Bench canary: pinned, ollama \(name) (tier 3)")
        case .gguf(let file): lines.append("Bench canary: pinned, llama.cpp \(file) (tier 3)")
        case .bypassed: lines.append("Bench guard: BYPASSED - replaying pre-passed rows. This run measures DRIVER compliance, not the guard.")
        }
        return lines.joined(separator: "\n")
    }

    static func describe(_ a: Auth) -> String {
        switch a {
        case .env: return "environment key"
        case .vertexADC(let project, let location):
            return "Vertex AI via gcloud ADC, project \(project ?? "(the ADC quota project)"), location \(project == nil ? "global" : location)"
        }
    }

    static func describe(_ t: InjectionGuard.Tier2Provisioning) -> String {
        switch t {
        case .provisioned: return "model present"
        case .unprovisioned(let name): return "NOT downloaded (\(name)), tier 2 passes everything"
        case .notConfigured: return "not configured, tier 2 passes everything"
        }
    }
}
