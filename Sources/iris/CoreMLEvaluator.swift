import Foundation
import CoreML

public protocol CoreMLModelProtocol: Sendable {
    func evaluate(text: String) async throws -> Double
}

public final class CoreMLEvaluator: @unchecked Sendable {
    public static let shared = CoreMLEvaluator()
    
    private var model: CoreMLModelProtocol?
    private let lock = NSLock()

    /// A model scoped to the current task tree, taking precedence over the installed one.
    ///
    /// `setModel` writes process-global state, and `swift test` runs suites in parallel, so a
    /// suite that installed a malicious-probability mock decided the verdict for every other
    /// suite sanitising at the same moment — assertions failed against content that was never
    /// the problem (#237). A task-local is visible only inside the `withValue` body and the
    /// tasks it spawns, so two suites can hold different models at once without racing.
    /// Production never sets it.
    ///
    /// Wrapped rather than a bare optional so a scope can say "explicitly no model" — which is a
    /// different thing from "no scope set", and is what the fail-open tests need.
    public struct ScopedModel: Sendable {
        let model: CoreMLModelProtocol?
        public init(_ model: CoreMLModelProtocol?) { self.model = model }
    }
    @TaskLocal public static var scopedModel: ScopedModel?

    /// The task-scoped model when a scope is active — including when that scope says none —
    /// otherwise the installed one.
    private var effectiveModel: CoreMLModelProtocol? {
        if let scoped = Self.scopedModel { return scoped.model }
        return lock.withLock { model }
    }

    private init() {}
    
    /// `nil` clears the loaded model (#210 fix round 1) — the test seam for forcing
    /// `hasModelLoaded` back to `false` regardless of what an earlier test in the process
    /// installed. Source-compatible with every existing non-nil caller.
    public func setModel(_ newModel: CoreMLModelProtocol?) {
        lock.withLock {
            model = newModel
        }
    }
    
    public var hasModelLoaded: Bool {
        effectiveModel != nil
    }
    
    public func loadModelIfNeeded() async throws {
        if hasModelLoaded { return }
        let coreMLPathStr = ConfigManager.shared.promptGuardCoreMLModel
        if coreMLPathStr.isEmpty { return }
        
        // #210: resolved via the shared helper so this can never disagree with
        // `InjectionGuard.tier2Provisioning` or `ModelLEDBar.tier2State` about what "downloaded"
        // means.
        let modelDirName = ModelDownloader.resolvedCoreMLDirectoryName(for: coreMLPathStr)

        let basePath = IrisPaths.default.modelsDir.path
        let fullPath = URL(fileURLWithPath: basePath).appendingPathComponent(modelDirName)
        
        if FileManager.default.fileExists(atPath: fullPath.path) {
            #if canImport(Tokenizers)
            do {
                // An ONNX bundle unzips to a directory containing `model.onnx` alongside the
                // tokenizer files; a CoreML bundle is the `.mlmodelc` directory itself.
                let onnxURL = fullPath.appendingPathComponent("model.onnx")
                if FileManager.default.fileExists(atPath: onnxURL.path) {
                    #if canImport(OnnxRuntimeBindings)
                    let liveModel = try await LiveONNXModel(modelURL: onnxURL, tokenizerConfigURL: fullPath)
                    setModel(liveModel)
                    #else
                    throw NSError(domain: "CoreMLEvaluator", code: -1, userInfo: [NSLocalizedDescriptionKey: "ONNX model found but ONNX Runtime is not available in this build."])
                    #endif
                } else {
                    let liveModel = try await LiveCoreMLModel(modelURL: fullPath, tokenizerConfigURL: fullPath)
                    setModel(liveModel)
                }
            } catch {
                print("[CoreMLEvaluator] Failed to load model: \(error)")
                throw error
            }
            #else
            print("[CoreMLEvaluator] Tokenizers framework not available. Cannot load model.")
            throw NSError(domain: "CoreMLEvaluator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Tokenizers framework not available."])
            #endif
        } else {
            throw NSError(domain: "CoreMLEvaluator", code: -1, userInfo: [NSLocalizedDescriptionKey: "Model directory does not exist at \(fullPath.path)"])
        }
    }
    
    public func evaluate(text: String) async throws -> Double {
        let currentModel = effectiveModel
        guard let m = currentModel else {
            // If no model is loaded (e.g. BYOM not yet downloaded), we fail open (assume safe) 
            // so we don't break the user's workflow just because they haven't set up Tier 2 yet.
            print("[CoreMLEvaluator] No model loaded. Defaulting to 0.0 (safe).")
            return 0.0
        }
        
        return try await m.evaluate(text: text)
    }
}

#if canImport(Tokenizers)
import Tokenizers

public final class LiveCoreMLModel: CoreMLModelProtocol, @unchecked Sendable {
    private let mlModel: MLModel
    private let tokenizer: any Tokenizer
    private let sequenceLength: Int
    private let injectionIndex: Int
    
    public init(modelURL: URL, tokenizerConfigURL: URL, sequenceLength: Int = 512) async throws {
        self.mlModel = try MLModel(contentsOf: modelURL)
        self.tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerConfigURL)
        self.sequenceLength = sequenceLength
        
        var foundIndex = 1
        let configURL = tokenizerConfigURL.appendingPathComponent("config.json")
        if let data = try? Data(contentsOf: configURL),
           let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let id2label = json["id2label"] as? [String: String] {
            for (key, value) in id2label {
                let lower = value.lowercased()
                if lower.contains("inject") || lower.contains("malicious") {
                    if let idx = Int(key) { foundIndex = idx }
                }
            }
        }
        self.injectionIndex = foundIndex
    }
    
    public func evaluate(text: String) async throws -> Double {
        // Empty/whitespace-only input is trivially safe. This also sidesteps a benign
        // tokenizer divergence: swift-transformers' UnigramTokenizer (used for DeBERTa-v3
        // via the XLMRobertaTokenizer relabel) emits a stray metaspace token for empty
        // input where Python emits none. See DebertaV3TokenizerParityTests.
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 0.0
        }

        // Defensively truncate the raw text to prevent massive CPU spikes during tokenization
        // if the input is a massive string (e.g. 10MB of scraped web HTML).
        // 2000 characters is plenty to reach 512 tokens.
        let safeText = String(text.prefix(2000))
        
        let tokens = tokenizer.encode(text: safeText)
        var inputIds = tokens.map { Int32($0) }
        var attentionMask = [Int32](repeating: 1, count: inputIds.count)
        
        // Pad or truncate
        if inputIds.count > sequenceLength {
            inputIds = Array(inputIds.prefix(sequenceLength))
            attentionMask = Array(attentionMask.prefix(sequenceLength))
        } else if inputIds.count < sequenceLength {
            let padCount = sequenceLength - inputIds.count
            inputIds.append(contentsOf: [Int32](repeating: 0, count: padCount))
            attentionMask.append(contentsOf: [Int32](repeating: 0, count: padCount))
        }
        
        guard let inputIdsArray = try? MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32),
              let attentionMaskArray = try? MLMultiArray(shape: [1, NSNumber(value: sequenceLength)], dataType: .int32) else {
            throw NSError(domain: "LiveCoreMLModel", code: 1, userInfo: [NSLocalizedDescriptionKey: "Failed to create MLMultiArray"])
        }
        
        for i in 0..<sequenceLength {
            inputIdsArray[i] = NSNumber(value: inputIds[i])
            attentionMaskArray[i] = NSNumber(value: attentionMask[i])
        }
        
        let featureProvider = try MLDictionaryFeatureProvider(dictionary: [
            "input_ids": inputIdsArray,
            "attention_mask": attentionMaskArray
        ])
        
        let prediction = try await mlModel.prediction(from: featureProvider)
        
        // DeBERTa typically outputs "logits". We need to extract the injection probability.
        // Applies a generalized N-class softmax for robustness.
        if let logitsFeature = prediction.featureValue(for: "logits"),
           let logitsArray = logitsFeature.multiArrayValue, logitsArray.count > injectionIndex {
            
            var maxLogit = -Double.greatestFiniteMagnitude
            
            for i in 0..<logitsArray.count {
                let val = logitsArray[i].doubleValue
                if val > maxLogit { maxLogit = val }
            }
            
            var sumExps = 0.0
            var targetExp = 0.0
            
            for i in 0..<logitsArray.count {
                let e = exp(logitsArray[i].doubleValue - maxLogit)
                sumExps += e
                if i == injectionIndex { targetExp = e }
            }
            
            return sumExps > 0 ? (targetExp / sumExps) : 0.0
        }
        
        return 0.0
    }
}
#endif
