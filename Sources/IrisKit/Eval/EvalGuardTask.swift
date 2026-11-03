import Foundation

/// `injection.verdict` (#803) and `injection.stack` (#789b): texts judged through the product's
/// guard up to the tier-3 canary (spec, section 2). The canary is built as the product builds it
/// and as `--guard-probe --fixtures` does (#794), task-scoped like the classifier's model, and the
/// guard is handed its configuration rather than reading the home's (#805): the run reads no
/// setting and no Keychain item.
enum EvalGuardTask {
    static let verdict = "injection.verdict"
    static let stack = "injection.stack"
    /// Bump when what a metric means changes (spec, section 9). A stack's rows carry the blocking
    /// tier from 2 on (#830), so older stack results read as having none; the verdict task's
    /// rows are unchanged, and its results keep comparing.
    static func scoringVersion(task: String) -> Int { task == stack ? 2 : 1 }
    /// LLM tasks repeat by default (spec, section 5): 3 catch a collapse, not a slow drift.
    static let defaultRepeats = 3

    /// The canary's thinking: as the product sends it (#801), or forced either way, so a run can
    /// measure thinking on against off (#783).
    enum Think: String, Equatable, Sendable {
        case product, on, off
    }

    /// The tiers a stack result judges with (spec, section 2): #780's retire-tier-2 question.
    enum Stack: String, Equatable, Sendable, CaseIterable {
        case tier13 = "1+3", tier123 = "1+2+3"
        var configuration: String { self == .tier13 ? "tier 1 + 3" : "tier 1 + 2 + 3" }
    }

    /// The verdict task's tiers: tier 2 passes everything (#794's `PassingTier2`), so the verdict
    /// is the canary's.
    static let verdictConfiguration = "tier 1 + 3 (tier 2 passing)"

    /// A canary ready to judge, with what a result records about it.
    struct Canary: Sendable {
        let engine: any AuxiliaryInferenceEngine
        let spec: EvalModelSpec
        let fingerprint: String
        let runtimeVersion: String?
        /// "on", "off", or "none" when the model has no thinking to switch.
        let think: String
        let details: [String: String]
        /// A cloud canary: its calls are paid for, and price and tokens are recorded (#790).
        var paid: Bool = false
        /// The thinking level sent ("low", "medium"), or nil for none; cloud only.
        var thinkingLevel: String? = nil
    }

    static func canary(_ spec: EvalModelSpec, think: Think, thinkingLevel: String? = nil, hedgeAfter: TimeInterval? = nil,
                       credentials: (LLMProvider) -> Bool = { cloudCredentialsConfigured($0) },
                       send: CloudAuxiliaryEngine.Send? = nil, now: Date = Date()) async throws -> Canary {
        if spec.runtime != .cloud, thinkingLevel != nil {
            throw EvalError.unsupported("--thinking-level is for cloud: models; \(spec.runtime.rawValue): has no such setting")
        }
        if spec.runtime != .cloud, hedgeAfter != nil {
            throw EvalError.unsupported("--hedge-after is for cloud: models; \(spec.runtime.rawValue): has no such setting")
        }
        switch spec.runtime {
        case .cloud: return try cloudCanary(spec, think: think, thinkingLevel: thinkingLevel, hedgeAfter: hedgeAfter, credentials: credentials, send: send, now: now)
        case .ollama: return try await ollamaCanary(spec, think: think)
        case .llamacpp: return try await llamaCanary(spec, think: think)
        case .mlx: return try await mlxCanary(spec, think: think)
        case .onnx, .coreml:
            throw EvalError.unsupported("\(spec.runtime.rawValue) models are classifiers, not canaries: use ollama:, llamacpp:, mlx: or cloud:")
        }
    }

    /// Whether the provider's credentials are configured: a key, or for Gemini application default
    /// credentials. Read-only; nothing in the settings is changed.
    static func cloudCredentialsConfigured(_ provider: LLMProvider, config: ConfigManager = .shared) -> Bool {
        switch provider {
        case .gemini: return config.geminiAuthMode == GeminiAuthMode.adc.rawValue || !config.geminiAPIKey.isEmpty
        case .anthropic: return !config.anthropicAPIKey.isEmpty || config.anthropicAuthMode == AnthropicAuthMode.vertex.rawValue
        case .openai: return !config.openAIAPIKey.isEmpty
        }
    }

    /// A cloud canary, built the way the product builds a cloud tier 3: `CloudAuxiliaryEngine` for the
    /// canary role, with the model and the thinking level the product reads from tier 3's settings
    /// (#800). Task-scoped: the provider comes from a `ProviderRoute` on this engine's own client, so no
    /// global setting is changed, and the credentials are only read. The fingerprint is the model id
    /// and the run date (cloud models change under one name; spec section 4).
    private static func cloudCanary(_ spec: EvalModelSpec, think: Think, thinkingLevel: String?, hedgeAfter: TimeInterval?,
                                    credentials: (LLMProvider) -> Bool, send: CloudAuxiliaryEngine.Send?, now: Date) throws -> Canary {
        try requireProductThinking(spec, think)
        guard let provider = spec.cloudProvider else {
            throw EvalError.usage("cloud: takes <provider>/<model> with a provider of \(LLMProvider.allCases.map { $0.rawValue.lowercased() }.joined(separator: ", "))")
        }
        if let level = thinkingLevel {
            guard ConfigManager.tier3ThinkingLevels.contains(level) else {
                throw EvalError.usage("--thinking-level is \(ConfigManager.tier3ThinkingLevels.joined(separator: " or "))")
            }
            guard provider == .gemini else {
                throw EvalError.unsupported("only Gemini takes a thinking level; \(provider.rawValue.lowercased()) would ignore --thinking-level \(level)")
            }
        }
        if let delay = hedgeAfter, delay <= 0 {
            throw EvalError.usage("--hedge-after takes a positive number of seconds")
        }
        guard credentials(provider) else {
            throw EvalError.unsupported("no \(provider.rawValue) credentials are configured, so a paid cloud run can't be made")
        }
        let id = spec.cloudModelId
        var engine = CloudAuxiliaryEngine()
        engine.role = CloudAuxiliaryEngine.canaryRole
        engine.model = { id }
        engine.thinkingLevel = { thinkingLevel }
        engine.notice = { print("eval: \($0)") }
        if let send {
            engine.send = send
        } else {
            let client = LLMClient(route: ProviderRoute(providerId: provider.rawValue.lowercased(), target: .builtIn(provider), model: id))
            engine.send = { request, model in try await client.generateContent(request: request, tier: .easy, model: model ?? id) }
        }
        if let delay = hedgeAfter {
            engine.hedgeAfter = delay
            // On its own connection, like the product's canary hedge (#871): a stuck request on a
            // shared pool would carry both legs and the hedge would win nothing. A test double for
            // `send` has no pool to share in the first place, so the two legs reuse it there.
            if send == nil {
                let client = LLMClient(route: ProviderRoute(providerId: provider.rawValue.lowercased(), target: .builtIn(provider), model: id),
                                       providerSession: URLSession(configuration: .ephemeral))
                engine.sendFresh = { request, model in try await client.generateContent(request: request, tier: .easy, model: model ?? id) }
            }
        }
        let date = Date.ISO8601FormatStyle(timeZone: .current).year().month().day().format(now)
        return Canary(engine: engine, spec: spec, fingerprint: "\(spec.name) \(date)",
                      runtimeVersion: "\(provider.rawValue.lowercased()) \(id) \(date)", think: thinkingLevel.map { "level \($0)" } ?? "default",
                      details: ["think_requested": think.rawValue,
                                "think_sent": thinkingLevel.map { "generationConfig.thinkingConfig.thinkingLevel \($0)" } ?? "nothing (the provider's default)",
                                "provider": provider.rawValue.lowercased(), "model_id": id, "run_date": date,
                                "hedge_after_seconds": hedgeAfter.map { "\($0)" } ?? "none (unhedged)"],
                      paid: true, thinkingLevel: thinkingLevel)
    }

    private static func ollamaCanary(_ spec: EvalModelSpec, think: Think) async throws -> Canary {
        let suppress: Bool
        switch think {
        case .product: suppress = AuxiliaryModelManager.suppressesThinking(role: "canary")
        case .off: suppress = true
        case .on: suppress = false
        }
        guard let digest = await GuardProbeFixtures.ollamaDigest(spec.name) else {
            throw EvalError.modelMissing("ollama:\(spec.name): not in Ollama's /api/tags (is Ollama running, and the model pulled?)")
        }
        let engine = OllamaEngine(tracker: ModelLoadTracker(log: { _ in }), suppressThinking: suppress)
        try await engine.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: spec.name))
        if let preload = await engine.pendingPreload { await preload.value }
        let thinks = await GuardProbeFixtures.ollamaThinks(spec.name)
        let sent = thinks == true ? (suppress ? "off" : "on") : "none"
        return Canary(engine: engine, spec: spec, fingerprint: digest, runtimeVersion: await GuardProbeFixtures.ollamaVersion(),
                      think: sent, details: ["model_thinks": thinks.map { "\($0)" } ?? "unknown",
                                             "think_requested": think.rawValue,
                                             "think_sent": suppress ? "false, to a model that thinks" : "nothing (the model's default)"])
    }

    /// `--think` switches Ollama's thinking; llama.cpp and MLX have no such switch to turn.
    private static func requireProductThinking(_ spec: EvalModelSpec, _ think: Think) throws {
        guard think == .product else {
            throw EvalError.unsupported("\(spec.runtime.rawValue): the engine has no thinking switch, so --think \(think.rawValue) can't apply")
        }
    }

    /// A GGUF file, loaded as the product loads the canary (greedy argmax, `LlamaCPPEngine`), its
    /// sha256 as the fingerprint.
    private static func llamaCanary(_ spec: EvalModelSpec, think: Think) async throws -> Canary {
        try requireProductThinking(spec, think)
        guard let url = spec.url else { throw EvalError.unsupported("llamacpp needs a file path") }
        let files = try EvalFingerprint.files(at: url)
        guard files.count == 1 else { throw EvalError.modelMissing("\(url.path): llamacpp: takes one GGUF file, not a folder") }
        let engine = try await LlamaCPPEngine(modelsDir: url.deletingLastPathComponent())
        try await engine.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .llamaCPP, modelPathOrName: url.lastPathComponent))
        return Canary(engine: engine, spec: spec, fingerprint: EvalFingerprint.digest(files),
                      runtimeVersion: dependencyVersion("llama.swift"), think: "none",
                      details: ["think_requested": think.rawValue, "think_sent": "nothing (no thinking switch)"])
    }

    /// A Hugging Face id, loaded as the product loads it, its local snapshot's files as the fingerprint.
    /// Loading first: the first load downloads it into the cache.
    private static func mlxCanary(_ spec: EvalModelSpec, think: Think) async throws -> Canary {
        try requireProductThinking(spec, think)
        let engine = MLXEngine()
        try await engine.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .mlx, modelPathOrName: spec.name))
        let snapshot = try mlxSnapshot(id: spec.name)
        let files = try EvalFingerprint.files(at: snapshot, followLinks: true)
        guard !files.isEmpty else { throw EvalError.modelMissing("mlx:\(spec.name): the snapshot at \(snapshot.path) holds no files") }
        return Canary(engine: engine, spec: spec, fingerprint: EvalFingerprint.digest(files),
                      runtimeVersion: dependencyVersion("mlx-swift"), think: "none",
                      details: ["think_requested": think.rawValue, "think_sent": "nothing (no thinking switch)",
                                "mlx_snapshot": snapshot.lastPathComponent])
    }

    /// The Hugging Face cache's snapshot of `id` (`org/name`), as `HubClient` lays it out:
    /// `<hub cache>/models--org--name/snapshots/<revision>`, the revision being `refs/main`'s. The
    /// cache is `HF_HUB_CACHE`, else `HF_HOME/hub`, else `~/.cache/huggingface/hub`.
    static func mlxSnapshot(id: String, environment: [String: String] = ProcessInfo.processInfo.environment,
                            home: URL = FileManager.default.homeDirectoryForCurrentUser) throws -> URL {
        let hub: URL
        if let c = environment["HF_HUB_CACHE"], !c.isEmpty { hub = URL(fileURLWithPath: c) }
        else if let h = environment["HF_HOME"], !h.isEmpty { hub = URL(fileURLWithPath: h).appendingPathComponent("hub") }
        else { hub = home.appendingPathComponent(".cache/huggingface/hub") }
        let repo = hub.appendingPathComponent("models--" + id.replacingOccurrences(of: "/", with: "--"))
        let snapshots = repo.appendingPathComponent("snapshots")
        if let ref = try? String(contentsOf: repo.appendingPathComponent("refs/main"), encoding: .utf8) {
            let dir = snapshots.appendingPathComponent(ref.trimmingCharacters(in: .whitespacesAndNewlines))
            if FileManager.default.fileExists(atPath: dir.path) { return dir }
        }
        let all = (try? FileManager.default.contentsOfDirectory(atPath: snapshots.path)) ?? []
        guard all.count == 1 else {
            throw EvalError.modelMissing("mlx:\(id): \(all.isEmpty ? "no snapshot" : "\(all.count) snapshots and no refs/main") under \(repo.path)")
        }
        return snapshots.appendingPathComponent(all[0])
    }

    /// The version of a package this checkout pins (its tag, else the first 12 characters of the
    /// revision), read from `Package.resolved`: the engine compiled into a dev build is that one.
    /// Nil when the file or the pin is missing: absent, never a guess.
    static func dependencyVersion(_ identity: String, resolved: Data? = nil) -> String? {
        let data = resolved ?? (try? Data(contentsOf: PerfPaths.repoRoot().appendingPathComponent("Package.resolved")))
        guard let data, let root = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let pins = root["pins"] as? [[String: Any]],
              let pin = pins.first(where: { ($0["identity"] as? String) == identity }),
              let state = pin["state"] as? [String: Any] else { return nil }
        if let version = state["version"] as? String { return "\(identity) \(version)" }
        return (state["revision"] as? String).map { "\(identity) \($0.prefix(12))" }
    }

    /// The guard's configuration for a run: protection on, the canary provisioned, and tier 2
    /// provisioned (the scoped model) or not configured (skipped, as an install without one).
    static func guardConfig(canary: EvalModelSpec, tier2: Bool, thinkingLevel: String? = nil) -> InjectionGuard.GuardConfigFingerprint {
        .init(protectionEnabled: true, promptGuardEngine: engineName(canary.runtime), promptGuardModel: canary.name,
              promptGuardCoreMLModel: tier2 ? "eval" : "", tier3CloudModel: canary.runtime == .cloud ? canary.name : "",
              tier3ThinkingLevel: thinkingLevel ?? "", tier2ModelsDir: "", tier3ModelsDir: "",
              tier2Provisioning: tier2 ? .provisioned : .notConfigured, tier3Provisioning: .provisioned)
    }

    /// The product's engine name for a canary runtime (`AuxiliaryEngineType`).
    static func engineName(_ runtime: EvalModelSpec.Runtime) -> String {
        switch runtime {
        case .llamacpp: return AuxiliaryEngineType.llamaCPP.rawValue
        case .mlx: return AuxiliaryEngineType.mlx.rawValue
        case .cloud: return AuxiliaryEngineType.cloud.rawValue
        default: return AuxiliaryEngineType.ollama.rawValue
        }
    }

    /// What one canary call did.
    final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var _answer: String?, _error: Error?, _usage: EvalCost.Tokens?
        var answer: String? { lock.withLock { _answer } }
        var error: Error? { lock.withLock { _error } }
        /// A cloud canary's reported usage for this text, summed over the calls it took.
        var usage: EvalCost.Tokens? { lock.withLock { _usage } }
        func answered(_ a: String) { lock.withLock { _answer = a } }
        func failed(_ e: Error) { lock.withLock { _error = e } }
        func used(_ u: UsageMetadata) {
            guard let t = EvalCost.Tokens(u) else { return }   // a partial report counts as none
            lock.withLock { _usage = (_usage ?? .zero) + t }
        }
    }

    @TaskLocal static var call: Call?

    /// The canary, recording its answer or error for the call in scope.
    struct Recording: AuxiliaryInferenceEngine {
        let inner: any AuxiliaryInferenceEngine
        func loadModel(config: AuxiliaryModelConfig) async throws { try await inner.loadModel(config: config) }
        func unloadModel() async { await inner.unloadModel() }
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            do {
                let answer = try await inner.generate(prompt: prompt, jsonSchema: jsonSchema)
                EvalGuardTask.call?.answered(answer)
                return answer
            } catch {
                EvalGuardTask.call?.failed(error)
                throw error
            }
        }
    }

    /// An engine that can't be reached, as opposed to one that timed out or failed: the text gets
    /// no result (infra) rather than the product's fail-closed block (spec, section 9).
    static func isInfra(_ error: Error) -> Bool {
        let e = error as NSError
        return e.domain == NSURLErrorDomain && [NSURLErrorCannotConnectToHost, NSURLErrorCannotFindHost,
                                                NSURLErrorNetworkConnectionLost, NSURLErrorNotConnectedToInternet,
                                                NSURLErrorDNSLookupFailed].contains(e.code)
    }

    /// Which tier blocked a text and what tier 2 said, from the product's own result for that call
    /// (#830): concurrent judgements each keep their own.
    struct Trace: Equatable, Sendable {
        var blockedBy: String
        var tier2Verdict: String?

        static func of(outcome: InjectionGuard.GuardOutcome, tier2: String?) -> Trace {
            switch outcome {
            case .passed: return Trace(blockedBy: "none", tier2Verdict: tier2)
            case .blocked(let marker):
                if marker.contains("TIER 2") { return Trace(blockedBy: "tier2", tier2Verdict: tier2) }
                return Trace(blockedBy: tier2 == "partial" ? "tier3_after_partial" : "tier3", tier2Verdict: tier2)
            }
        }
    }

    /// One text through the product up to tier 3. `tier2` nil: the verdict task, tier 2 passing
    /// everything. `stack`: tier 2 as given, or skipped for 1+3.
    static func product(_ text: String, canary: any AuxiliaryInferenceEngine, config: InjectionGuard.GuardConfigFingerprint,
                        tier2: CoreMLEvaluator.ScopedModel) async -> (outcome: EvalMetrics.Outcome, shown: String, parseFailure: Bool, trace: Trace, usage: EvalCost.Tokens?) {
        let call = Call()
        // The product reports a cloud guard call's usage through `GuardUsage`; bound here, it lands on
        // this text's call and nowhere else.
        let sink = GuardUsage.Sink(record: { call.used($0) })
        let (outcome, cacheable, tier2Verdict) = await $call.withValue(call) {
            await GuardUsage.$sink.withValue(sink) {
                await AuxiliaryModelManager.$scopedEngines.withValue(["canary": Recording(inner: canary)]) {
                    await CoreMLEvaluator.$scopedModel.withValue(tier2) {
                        await InjectionGuard.classifyUntrustedTraced(OutputCap.cap(text), contextTag: EvalClassifierTask.contextTag,
                                                                      maxTier: .tier3_canary, protectionEnabled: true, config: config)
                    }
                }
            }
        }
        let trace = Trace.of(outcome: outcome, tier2: tier2Verdict)
        switch outcome {
        case .passed(let clean):
            return (clean.contains(EvalClassifierTask.withheldMarker) ? .withheld : .passed, clean, false, trace, call.usage)
        case .blocked(let marker):
            if let error = call.error { return (isInfra(error) ? .infra : .failClosed, marker, false, trace, call.usage) }
            if !cacheable { return (.failClosed, marker, false, trace, call.usage) }
            // Tier 3 answered: the product blocks an answer with no clear verdict too (fail-closed).
            if marker.contains("TIER 3"), let answer = call.answer, InjectionGuard.canaryVerdict(answer) == .unreadable {
                return (.failClosed, marker, true, trace, call.usage)
            }
            return (.blocked, marker, false, trace, call.usage)
        }
    }

    static func score(_ sample: EvalSample, repeatIndex: Int, canary: any AuxiliaryInferenceEngine,
                      config: InjectionGuard.GuardConfigFingerprint, tier2: CoreMLEvaluator.ScopedModel) async -> EvalMetrics.Scored {
        let start = MonotonicClock.nowMs()
        let (outcome, shown, parse, trace, usage) = await product(sample.text, canary: canary, config: config, tier2: tier2)
        let seconds = (MonotonicClock.nowMs() - start) / 1000
        let caught = sample.payload.map { EvalMetrics.caught(outcome, shown: shown, payload: $0) }
        return EvalMetrics.Scored(sample: sample, outcome: outcome, rawScore: nil, seconds: seconds, caught: caught,
                                  repeatIndex: repeatIndex, parseFailure: parse, trace: trace, usage: usage)
    }
}

extension EvalRunner {
    /// What a verdict or stack run is given; all of it explicit, none read from the home.
    struct GuardRun: Equatable, Sendable {
        var task: String
        /// The canary (`--model` for verdict, `--tier3` for a stack).
        var canary: EvalModelSpec
        /// A stack's tier-2 classifier (`--tier2`); required for 1+2+3, refused otherwise.
        var tier2: EvalModelSpec?
        var stack: EvalGuardTask.Stack?
        var think: EvalGuardTask.Think = .product
        /// `--thinking-level` for a cloud canary: "low" or "medium"; nil sends none (#800).
        var thinkingLevel: String?
        /// `--hedge-after` for a cloud canary, in seconds: a second request beside the first if it
        /// has no answer by then (#876). Unhedged by default, so #790's numbers stay comparable —
        /// hedging is opt-in per run, never the eval's own default the way the product's canary hedge is.
        var hedgeAfter: TimeInterval?
        /// `--allow-paid`: without it a cloud run refuses before any call (spec, section 6).
        var allowPaid = false
        /// `--max-dollars`: the most a paid run may spend. Required with `--allow-paid` (#870).
        var maxDollars: Double?
        var repeats: Int = EvalGuardTask.defaultRepeats
        var split: String = "test"
        var sample: Int?
        /// As given on the command line; relative ones resolve against the repository.
        var datasetDir: String?
        var outDir: String?
    }

    /// What a run would make and cost, with no call and no credentials (`--estimate-only`, #790).
    static func estimate(_ run: GuardRun, repoRoot: URL, table: PriceTable = .snapshot) throws -> String {
        let dataset = try EvalDataset.load(from: run.datasetDir.map { EvalCLI.resolve($0, repoRoot) } ?? defaultDataset(repoRoot))
        let texts = dataset.select(split: run.split, sample: run.sample)
        let head = "eval estimate: \(run.task) \(run.canary.description), dataset \(dataset.manifest.family) v\(dataset.manifest.version) \(run.split)"
            + (run.sample.map { ", sample \($0)" } ?? ", full") + ": \(texts.count) texts × \(run.repeats) = \(texts.count * run.repeats) judgements"
        guard run.canary.runtime == .cloud, let provider = run.canary.cloudProvider else {
            return head + "\nlocal model: no paid calls, no cost (energy isn't measured). Nothing was run."
        }
        let rates = EvalCost.rates(provider: provider, model: run.canary.cloudModelId, table: table)
        let e = EvalCost.estimate(textBytes: texts.map { $0.text.utf8.count }, repeats: run.repeats, thinkingLevel: run.thinkingLevel, rates: rates)
        var lines = [head, "PAID: \(e.calls) calls to \(provider.rawValue.lowercased())/\(run.canary.cloudModelId)"
                     + " (~\(e.tokens.input) input, ~\(e.tokens.output + e.tokens.thought) output tokens including thinking)",
                     "estimated cost: \(EvalCost.money(e.dollars)) (\(EvalCost.money(EvalCost.perThousand(e.dollars, judgements: e.calls))) per 1,000 judgements)"
                     + (rates == nil ? "" : ", from the price list as of \(ModelPriceSnapshot.asOf)")]
        lines += e.assumptions.map { "  - \($0)" }
        if let hedgeAfter = run.hedgeAfter {
            lines.append("  - --hedge-after \(hedgeAfter)s: not counted above — only a call still unanswered past the delay doubles, and how often that happens is exactly what the run measures")
        }
        lines.append("Nothing was run. The estimate is a guess from the token means above; the result records what the provider reports.")
        return lines.joined(separator: "\n")
    }

    static func runGuard(_ run: GuardRun, repoRoot: URL, now: Date = Date(),
                         canaryFor: ((EvalModelSpec, EvalGuardTask.Think, String?, TimeInterval?) async throws -> EvalGuardTask.Canary)? = nil,
                         prices: PriceTable = .snapshot,
                         loadTier2: (EvalModelSpec) async throws -> CoreMLModelProtocol = { try await EvalClassifierTask.loadModel($0) }) async throws -> URL {
        let dataset = try EvalDataset.load(from: run.datasetDir.map { EvalCLI.resolve($0, repoRoot) } ?? defaultDataset(repoRoot))
        let texts = dataset.select(split: run.split, sample: run.sample)
        // A paid run refuses before anything is built or called, and says what it would cost.
        if run.canary.runtime == .cloud, !run.allowPaid {
            throw EvalError.usage("this run makes paid calls to \(run.canary.name): add --allow-paid to make them. "
                                  + "--estimate-only prints the call count and the expected cost without making any.\n"
                                  + ((try? estimate(run, repoRoot: repoRoot, table: prices)) ?? ""))
        }
        // The cap is worked from the estimate's per-call mean, so it needs a listed price to mean anything.
        var spendCap: EvalCost.SpendCap?
        if run.canary.runtime == .cloud {
            guard let cap = run.maxDollars else {
                throw EvalError.usage("a paid run needs --max-dollars N, the most it may spend; --estimate-only prints the expected cost without one")
            }
            guard let provider = run.canary.cloudProvider, let rates = EvalCost.rates(provider: provider, model: run.canary.cloudModelId, table: prices) else {
                throw EvalError.usage("no listed price for \(run.canary.name): --max-dollars can't be enforced without one, so the run is refused. "
                                      + "The price list (Sources/IrisKit/ModelPriceSnapshot.swift, a snapshot of LiteLLM's table) has no row for it. The file is generated, not edited: move the pin in scripts/gen-model-prices.py (--commit <sha> --as-of <date>) to a LiteLLM commit that has the model and rerun it.")
            }
            let e = EvalCost.estimate(textBytes: texts.map { $0.text.utf8.count }, repeats: run.repeats, thinkingLevel: run.thinkingLevel, rates: rates)
            if e.calls > 0, let dollars = e.dollars { spendCap = .init(cap: cap, perCall: dollars / Double(e.calls)) }
            print("eval: PAID RUN: \(texts.count * run.repeats) calls to \(run.canary.name) (--allow-paid given), capped at \(EvalCost.money(cap)) (estimated \(EvalCost.money(e.dollars)))"
                  + ((e.dollars ?? 0) > cap ? "; the estimate is over the cap, so the run will stop partway" : ""))
        }
        let canary = try await (canaryFor ?? { spec, think, level, hedge in try await EvalGuardTask.canary(spec, think: think, thinkingLevel: level, hedgeAfter: hedge) })(run.canary, run.think, run.thinkingLevel, run.hedgeAfter)

        // A stack's tier 2, with its files' digests: the bundle path and sha256s go in the result,
        // since the folder may be renamed to switch the tier off on the machine that ran it.
        var tier2Model: CoreMLModelProtocol?
        var tier2Files: [EvalModelFile] = []
        if run.stack == .tier123, let spec = run.tier2, let url = spec.url {
            tier2Files = try EvalFingerprint.files(at: url)
            tier2Model = try await loadTier2(spec)
        }
        let tier2Fingerprint = tier2Files.isEmpty ? nil : EvalFingerprint.digest(tier2Files)
        let scope: CoreMLEvaluator.ScopedModel = run.stack == nil ? .init(GuardProbeFixtures.PassingTier2()) : .init(tier2Model)
        let config = EvalGuardTask.guardConfig(canary: run.canary, tier2: run.stack != .tier13, thinkingLevel: canary.thinkingLevel)

        let model = [run.tier2?.displayName, canary.spec.displayName].compactMap { $0 }.joined(separator: " + ")
        let fingerprint = [tier2Fingerprint, canary.fingerprint].compactMap { $0 }.joined(separator: " + ")
        let runtime = [run.tier2.map { $0.runtime.rawValue }, canary.spec.runtime.rawValue].compactMap { $0 }.joined(separator: "+")
        let taskDir = (run.outDir.map { EvalCLI.resolve($0, repoRoot) } ?? resultsRoot(repoRoot)).appendingPathComponent(run.task)
        let previous = try? EvalTable.load(taskDir.deletingLastPathComponent())
            .filter { $0.result.key.task == run.task && $0.result.key.model == model }
            .max { $0.result.date < $1.result.date }
        var changed: Bool?
        // A cloud model's fingerprint holds the run date, so it always differs from the last result's.
        if !canary.paid, let previous, previous.result.key.modelFingerprint != fingerprint {
            print("MODEL CHANGED: \(previous.result.key.modelFingerprint) → \(fingerprint) (last result \(previous.file))")
            changed = true
        }

        let configuration = run.stack?.configuration ?? EvalGuardTask.verdictConfiguration
        print("eval: \(run.task) [\(configuration)] \(model), think \(canary.think), dataset \(dataset.manifest.family) v\(dataset.manifest.version) \(run.split)"
              + (run.sample.map { ", sample \($0)" } ?? ", full") + ": \(texts.count) texts × \(run.repeats)")
        var scored: [EvalMetrics.Scored] = []
        var cappedAt: String?
        let rates = run.canary.cloudProvider.flatMap { EvalCost.rates(provider: $0, model: run.canary.cloudModelId, table: prices) }
        runLoop: for r in 0..<run.repeats {
            for (n, sample) in texts.enumerated() {
                if let cap = spendCap, !cap.allowsNextCall() {
                    cappedAt = "stopped by --max-dollars \(EvalCost.money(cap.cap)) before judgement \(scored.count + 1) of \(texts.count * run.repeats): "
                        + "\(EvalCost.money(cap.committed)) charged (reported \(EvalCost.money(cap.reported)) plus \(cap.unreportedCalls) call(s) with no usage at the estimate's \(EvalCost.money(cap.perCall)) each)"
                    break runLoop
                }
                let row = await EvalGuardTask.score(sample, repeatIndex: r, canary: canary.engine, config: config, tier2: scope)
                scored.append(row)
                // An infra failure never reached the provider; any other call is charged.
                if row.outcome != .infra { spendCap?.record(dollars: row.usage.flatMap { EvalCost.dollars($0, rates: rates) }) }
                if (n + 1) % 25 == 0 { print("eval: repeat \(r + 1), \(n + 1)/\(texts.count)") }
            }
        }
        // An engine in this process is freed before it exits: llama.cpp's Metal backend asserts at
        // exit while a model is still resident (#815), after the result was written. Ollama's is
        // the person's own server, and unloading would evict their model (keep_alive 0).
        if run.canary.runtime != .ollama, !canary.paid { await canary.engine.unloadModel() }
        var metrics = EvalMetrics.metrics(scored, fullTestSplit: run.split == "test" && run.sample == nil, canary: true)
        // Local: measured as free (energy isn't measured). Paid: the tokens the provider reported at the
        // price list's rate, per 1,000 judgements; absent when either is missing, never zero.
        var tokens: EvalCost.Tokens?
        var priceNote: String?
        var coverage: String?
        var partialCost: (reported: Double, extrapolated: Double)?
        if canary.paid {
            // Per 1,000 judgements actually made, so the denominator is every judgement that reached the
            // provider (infra ones never did), and the cost is absent unless every one of them reported
            // its usage: a partial sum over the calls that did would be a smaller number passing for the
            // whole (#860 review). What was reported is still recorded, with its coverage.
            let judged = scored.filter { $0.outcome != .infra }
            let reported = judged.compactMap(\.usage)
            tokens = reported.isEmpty ? nil : reported.reduce(.zero, +)
            // Absent only when nothing reported usage or the list has no price. With some usage, the
            // cost is the mean over the judgements that reported it, and the reported total is
            // recorded beside it as a lower bound (#870): a smaller number must not pass for the whole.
            if let t = tokens, let reportedDollars = EvalCost.dollars(t, rates: rates) {
                metrics.costPerThousandUsd = EvalCost.perThousand(reportedDollars, judgements: reported.count)
                if reported.count < judged.count {
                    partialCost = (reportedDollars, reportedDollars / Double(reported.count) * Double(judged.count))
                }
            }
            coverage = "\(reported.count) of \(judged.count) judgements reported usage"
            priceNote = rates.map { "snapshot \(ModelPriceSnapshot.asOf); input \($0.input * 1_000_000) and output \($0.output * 1_000_000) dollars per million tokens" }
        } else {
            metrics.costPerThousandUsd = 0
        }

        var settings = canary.details
        if let coverage { settings["usage_coverage"] = coverage }
        if let partialCost {
            settings["cost_reported_usd"] = String(format: "%.4f", partialCost.reported)
            settings["cost_extrapolated_usd"] = String(format: "%.4f", partialCost.extrapolated)
        }
        if let cappedAt, let spendCap {
            settings["capped"] = cappedAt
            settings["max_dollars"] = String(format: "%.4f", spendCap.cap)
        }
        settings["canary"] = canary.spec.description
        settings["context_tag"] = EvalClassifierTask.contextTag
        settings["output_cap_bytes"] = "\(OutputCap.limitBytes)"
        if run.stack == .tier123, let spec = run.tier2 {
            settings.merge(EvalClassifierTask.settings) { a, _ in a }
            settings["tier2_bundle"] = spec.url?.path
            settings["tier2_fingerprint"] = tier2Fingerprint
        }
        let day = Self.day(now)
        let result = EvalResult(
            key: .init(task: run.task, configuration: configuration,
                       datasetFamily: dataset.manifest.family, datasetVersion: dataset.manifest.version,
                       datasetSha256: dataset.sha256s, split: run.split, sample: run.sample,
                       runtime: runtime, runtimeVersion: canary.runtimeVersion, model: model, modelFingerprint: fingerprint,
                       scoringVersion: EvalGuardTask.scoringVersion(task: run.task), think: canary.think, repeats: run.repeats),
            date: day,
            model: .init(spec: [run.tier2?.description, canary.spec.description].compactMap { $0 }.joined(separator: " + "),
                         files: tier2Files.isEmpty ? nil : tier2Files,
                         bytesOnDisk: tier2Files.isEmpty ? nil : tier2Files.reduce(0) { $0 + $1.bytes }),
            environment: await EvalEnvironment.capture(repoRoot: repoRoot),
            settings: settings,
            contaminated: contamination(dataset, texts),
            modelChanged: changed, previousFingerprint: changed == true ? previous?.result.key.modelFingerprint : nil,
            metrics: metrics,
            paid: canary.paid ? true : nil, tokens: tokens, priceList: priceNote,
            verdicts: scored.map { .init(id: $0.sample.id, outcome: $0.outcome.rawValue, caught: $0.caught,
                                         rawScore: nil, seconds: $0.seconds, repeatIndex: $0.repeatIndex,
                                         blockedBy: run.stack == nil ? nil : $0.trace?.blockedBy,
                                         tier2Verdict: run.stack == nil ? nil : $0.trace?.tier2Verdict,
                                         tokens: $0.usage, usageMissing: canary.paid && $0.outcome != .infra && $0.usage == nil ? true : nil) })
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let base = "\(day)-\(run.stack.map { "stack\($0.rawValue.replacingOccurrences(of: "+", with: ""))-" } ?? "")"
            + "\(canary.spec.slug)-think\(canary.think.replacingOccurrences(of: " ", with: "-"))-v\(dataset.manifest.version)-\(run.split)" + (run.sample.map { "-s\($0)" } ?? "-full")
            + (cappedAt != nil ? "-capped" : "")
        let url = freshFile(in: taskDir, base: base)
        try result.encoded().write(to: url, options: .withoutOverwriting)
        print(EvalCompare.summary(result))
        if let cappedAt { throw EvalError.capped(file: url.path, why: cappedAt) }
        return url
    }
}
