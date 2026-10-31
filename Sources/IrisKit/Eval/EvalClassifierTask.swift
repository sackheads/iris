import Foundation
#if canImport(OnnxRuntimeBindings)
import OnnxRuntimeBindings
#endif

/// `injection.classifier`: a tier-2 classifier judged through the product's own path (spec,
/// section 2). Each text goes where `IrisEngine` sends a tool result, stopping after tier 2:
/// `OutputCap.cap`, then tier 1's normalisation and strip, then tier 2's windows, narrowing and
/// threshold. The model is task-scoped, so nothing global changes and the shared verdict cache is
/// never read or written (#237, #375). The raw score is the model alone on the whole text, beside
/// the product verdict, never instead of it.
enum EvalClassifierTask {
    static let name = "injection.classifier"
    static let configuration = "tier 1 + 2"
    /// Bump when what a metric means changes (spec, section 9).
    static let scoringVersion = 1

    /// The product settings a classifier is scored at, recorded with every result.
    static var settings: [String: String] {
        ["flag_threshold": "\(CoreMLEvaluator.flagThreshold)",
         "narrow_trigger": "\(CoreMLEvaluator.narrowTrigger)",
         "window_tokens": "\(CoreMLEvaluator.windowTokens)",
         "overlap_tokens": "\(CoreMLEvaluator.overlapTokens)",
         "output_cap_bytes": "\(OutputCap.limitBytes)",
         "context_tag": contextTag,
         "raw_score": "model alone, max over its 512-token windows, stopping at the first over 0.9"]
    }

    /// The runtime's own version, recorded in the version key: a runtime upgrade can move scores.
    static func runtimeVersion(_ runtime: EvalModelSpec.Runtime) -> String? {
        switch runtime {
        case .onnx:
            #if canImport(OnnxRuntimeBindings)
            return ORTVersion().map { "onnxruntime \($0)" }
            #else
            return nil
            #endif
        case .coreml:
            return "macOS \(ProcessInfo.processInfo.operatingSystemVersionString)"
        case .ollama, .llamacpp, .mlx:
            return nil
        }
    }

    static let contextTag = "tool_output_run_command"
    static let withheldMarker = "withheld by the injection guard"

    static func loadModel(_ spec: EvalModelSpec) async throws -> CoreMLModelProtocol {
        guard let url = spec.url else { throw EvalError.unsupported("\(spec.runtime.rawValue) is not a classifier runtime") }
        switch spec.runtime {
        case .onnx:
            #if canImport(OnnxRuntimeBindings) && canImport(Tokenizers)
            return try await LiveONNXModel(modelURL: url.appendingPathComponent("model.onnx"), tokenizerConfigURL: url)
            #else
            throw EvalError.unsupported("this build has no ONNX Runtime")
            #endif
        case .coreml:
            #if canImport(Tokenizers)
            return try await LiveCoreMLModel(modelURL: url, tokenizerConfigURL: url)
            #else
            throw EvalError.unsupported("this build has no tokenizers")
            #endif
        case .ollama, .llamacpp, .mlx:
            throw EvalError.unsupported("\(spec.runtime.rawValue) models are canaries: injection.verdict and injection.stack (#803)")
        }
    }

    /// The guard configuration a classifier is judged with: protection on and the task-scoped model
    /// provisioned, never the home's settings (#805). Resolving those reads the Keychain secrets
    /// item, and they could make the eval score whatever the home is set to. Tier 3 isn't reached
    /// at `.tier2_coreML`, so its fields hold nothing.
    static var guardConfig: InjectionGuard.GuardConfigFingerprint {
        .init(protectionEnabled: true, promptGuardEngine: "", promptGuardModel: "", promptGuardCoreMLModel: "eval", tier3CloudModel: "",
              tier2ModelsDir: "", tier3ModelsDir: "", tier2Provisioning: .provisioned,
              tier3Provisioning: .unprovisioned(modelName: ""))
    }

    /// One text through the product, stopping after tier 2: the outcome and what was passed on.
    /// #785's report reads this too, so there is one scoring path.
    static func product(_ text: String, model: CoreMLModelProtocol) async -> (outcome: EvalMetrics.Outcome, shown: String) {
        let (outcome, cacheable) = await CoreMLEvaluator.$scopedModel.withValue(.init(model)) {
            await InjectionGuard.classifyUntrustedDetailed(OutputCap.cap(text), contextTag: contextTag,
                                                          maxTier: .tier2_coreML, protectionEnabled: true,
                                                          config: guardConfig)
        }
        switch outcome {
        case .blocked(let marker): return (cacheable ? .blocked : .failClosed, marker)
        case .passed(let clean): return (clean.contains(withheldMarker) ? .withheld : .passed, clean)
        }
    }

    /// One text through the product, then the model alone.
    static func score(_ sample: EvalSample, model: CoreMLModelProtocol) async -> EvalMetrics.Scored {
        let start = MonotonicClock.nowMs()
        let (result, shown) = await product(sample.text, model: model)
        let seconds = (MonotonicClock.nowMs() - start) / 1000
        let raw = try? await model.evaluate(text: sample.text)
        // The model failing alone, with the product passing the text, means no judgement was made.
        let final: EvalMetrics.Outcome = (raw == nil && result == .passed) ? .infra : result
        let caught = sample.payload.map { EvalMetrics.caught(final, shown: shown, payload: $0) }
        return EvalMetrics.Scored(sample: sample, outcome: final, rawScore: raw, seconds: seconds, caught: caught)
    }
}
