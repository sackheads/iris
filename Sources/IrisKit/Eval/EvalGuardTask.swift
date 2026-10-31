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
    }

    static func canary(_ spec: EvalModelSpec, think: Think) async throws -> Canary {
        guard spec.runtime == .ollama else {
            throw EvalError.unsupported("\(spec.runtime.rawValue): canaries aren't scored yet (#815); this slice runs ollama:<name>")
        }
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

    /// The guard's configuration for a run: protection on, the canary provisioned, and tier 2
    /// provisioned (the scoped model) or not configured (skipped, as an install without one).
    static func guardConfig(canary: EvalModelSpec, tier2: Bool) -> InjectionGuard.GuardConfigFingerprint {
        .init(protectionEnabled: true, promptGuardEngine: "ollama", promptGuardModel: canary.name,
              promptGuardCoreMLModel: tier2 ? "eval" : "", tier3CloudModel: "", tier2ModelsDir: "", tier3ModelsDir: "",
              tier2Provisioning: tier2 ? .provisioned : .notConfigured, tier3Provisioning: .provisioned)
    }

    /// What one canary call did.
    final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var _answer: String?, _error: Error?
        var answer: String? { lock.withLock { _answer } }
        var error: Error? { lock.withLock { _error } }
        func answered(_ a: String) { lock.withLock { _answer = a } }
        func failed(_ e: Error) { lock.withLock { _error = e } }
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
                        tier2: CoreMLEvaluator.ScopedModel) async -> (outcome: EvalMetrics.Outcome, shown: String, parseFailure: Bool, trace: Trace) {
        let call = Call()
        let (outcome, cacheable, tier2Verdict) = await $call.withValue(call) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": Recording(inner: canary)]) {
                await CoreMLEvaluator.$scopedModel.withValue(tier2) {
                    await InjectionGuard.classifyUntrustedTraced(OutputCap.cap(text), contextTag: EvalClassifierTask.contextTag,
                                                                  maxTier: .tier3_canary, protectionEnabled: true, config: config)
                }
            }
        }
        let trace = Trace.of(outcome: outcome, tier2: tier2Verdict)
        switch outcome {
        case .passed(let clean):
            return (clean.contains(EvalClassifierTask.withheldMarker) ? .withheld : .passed, clean, false, trace)
        case .blocked(let marker):
            if let error = call.error { return (isInfra(error) ? .infra : .failClosed, marker, false, trace) }
            if !cacheable { return (.failClosed, marker, false, trace) }
            // Tier 3 answered: the product blocks an answer with no clear verdict too (fail-closed).
            if marker.contains("TIER 3"), let answer = call.answer, InjectionGuard.canaryVerdict(answer) == .unreadable {
                return (.failClosed, marker, true, trace)
            }
            return (.blocked, marker, false, trace)
        }
    }

    static func score(_ sample: EvalSample, repeatIndex: Int, canary: any AuxiliaryInferenceEngine,
                      config: InjectionGuard.GuardConfigFingerprint, tier2: CoreMLEvaluator.ScopedModel) async -> EvalMetrics.Scored {
        let start = MonotonicClock.nowMs()
        let (outcome, shown, parse, trace) = await product(sample.text, canary: canary, config: config, tier2: tier2)
        let seconds = (MonotonicClock.nowMs() - start) / 1000
        let caught = sample.payload.map { EvalMetrics.caught(outcome, shown: shown, payload: $0) }
        return EvalMetrics.Scored(sample: sample, outcome: outcome, rawScore: nil, seconds: seconds, caught: caught,
                                  repeatIndex: repeatIndex, parseFailure: parse, trace: trace)
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
        var repeats: Int = EvalGuardTask.defaultRepeats
        var split: String = "test"
        var sample: Int?
        /// As given on the command line; relative ones resolve against the repository.
        var datasetDir: String?
        var outDir: String?
    }

    static func runGuard(_ run: GuardRun, repoRoot: URL, now: Date = Date(),
                         canaryFor: (EvalModelSpec, EvalGuardTask.Think) async throws -> EvalGuardTask.Canary = { try await EvalGuardTask.canary($0, think: $1) },
                         loadTier2: (EvalModelSpec) async throws -> CoreMLModelProtocol = { try await EvalClassifierTask.loadModel($0) }) async throws -> URL {
        let dataset = try EvalDataset.load(from: run.datasetDir.map { EvalCLI.resolve($0, repoRoot) } ?? defaultDataset(repoRoot))
        let texts = dataset.select(split: run.split, sample: run.sample)
        let canary = try await canaryFor(run.canary, run.think)

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
        let config = EvalGuardTask.guardConfig(canary: run.canary, tier2: run.stack != .tier13)

        let model = [run.tier2?.displayName, canary.spec.displayName].compactMap { $0 }.joined(separator: " + ")
        let fingerprint = [tier2Fingerprint, canary.fingerprint].compactMap { $0 }.joined(separator: " + ")
        let runtime = [run.tier2.map { $0.runtime.rawValue }, canary.spec.runtime.rawValue].compactMap { $0 }.joined(separator: "+")
        let taskDir = (run.outDir.map { EvalCLI.resolve($0, repoRoot) } ?? resultsRoot(repoRoot)).appendingPathComponent(run.task)
        let previous = try? EvalTable.load(taskDir.deletingLastPathComponent())
            .filter { $0.result.key.task == run.task && $0.result.key.model == model }
            .max { $0.result.date < $1.result.date }
        var changed: Bool?
        if let previous, previous.result.key.modelFingerprint != fingerprint {
            print("MODEL CHANGED: \(previous.result.key.modelFingerprint) → \(fingerprint) (last result \(previous.file))")
            changed = true
        }

        let configuration = run.stack?.configuration ?? EvalGuardTask.verdictConfiguration
        print("eval: \(run.task) [\(configuration)] \(model), think \(canary.think), dataset \(dataset.manifest.family) v\(dataset.manifest.version) \(run.split)"
              + (run.sample.map { ", sample \($0)" } ?? ", full") + ": \(texts.count) texts × \(run.repeats)")
        var scored: [EvalMetrics.Scored] = []
        for r in 0..<run.repeats {
            for (n, sample) in texts.enumerated() {
                scored.append(await EvalGuardTask.score(sample, repeatIndex: r, canary: canary.engine, config: config, tier2: scope))
                if (n + 1) % 25 == 0 { print("eval: repeat \(r + 1), \(n + 1)/\(texts.count)") }
            }
        }
        var metrics = EvalMetrics.metrics(scored, fullTestSplit: run.split == "test" && run.sample == nil, canary: true)
        metrics.costPerThousandUsd = 0   // local: measured as free; energy isn't measured

        var settings = canary.details
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
            verdicts: scored.map { .init(id: $0.sample.id, outcome: $0.outcome.rawValue, caught: $0.caught,
                                         rawScore: nil, seconds: $0.seconds, repeatIndex: $0.repeatIndex,
                                         blockedBy: run.stack == nil ? nil : $0.trace?.blockedBy,
                                         tier2Verdict: run.stack == nil ? nil : $0.trace?.tier2Verdict) })
        try FileManager.default.createDirectory(at: taskDir, withIntermediateDirectories: true)
        let base = "\(day)-\(run.stack.map { "stack\($0.rawValue.replacingOccurrences(of: "+", with: ""))-" } ?? "")"
            + "\(canary.spec.slug)-think\(canary.think)-v\(dataset.manifest.version)-\(run.split)" + (run.sample.map { "-s\($0)" } ?? "-full")
        let url = freshFile(in: taskDir, base: base)
        try result.encoded().write(to: url, options: .withoutOverwriting)
        print(EvalCompare.summary(result))
        return url
    }
}
