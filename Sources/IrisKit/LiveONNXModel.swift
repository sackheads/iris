import Foundation

// ONNX Runtime path for the Tier 2 prompt-injection guard.
//
// This is the recommended runtime for the accurate DeBERTa-v3 classifier: coremltools
// cannot convert DeBERTa without extensive, brittle op surgery, whereas the model exports
// to ONNX cleanly and runs identically to PyTorch on CPU (~6 ms). See
// docs/prompt_guard_coreml.md for the full investigation.
//
// The Swift module vended by microsoft/onnxruntime-swift-package-manager is imported
// below. Tokenization reuses swift-transformers exactly like LiveCoreMLModel.
#if canImport(OnnxRuntimeBindings) && canImport(Tokenizers)
import OnnxRuntimeBindings
import Tokenizers

public final class LiveONNXModel: CoreMLModelProtocol, @unchecked Sendable {
    private let env: ORTEnv
    private let session: ORTSession
    private let tokenizer: any Tokenizer
    private let maxSequenceLength: Int
    private let injectionIndex: Int

    public init(modelURL: URL, tokenizerConfigURL: URL, maxSequenceLength: Int = 512) async throws {
        self.env = try ORTEnv(loggingLevel: ORTLoggingLevel.warning)
        self.session = try ORTSession(env: env, modelPath: modelURL.path, sessionOptions: nil)
        self.tokenizer = try await AutoTokenizer.from(modelFolder: tokenizerConfigURL)
        self.maxSequenceLength = maxSequenceLength
        
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
        // Empty/whitespace-only input is trivially safe (mirrors LiveCoreMLModel).
        if text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
            return 0.0
        }

        // Defensively truncate the raw text to prevent massive CPU spikes during tokenization
        // if the input is a massive string (e.g. 10MB of scraped web HTML).
        // 2000 characters is plenty to reach 512 tokens.
        let safeText = String(text.prefix(2000))
        
        // The tokenizer already inserts [CLS]/[SEP]. The ONNX graph has dynamic sequence
        // length, so we feed the real token count (capped) with no padding.
        var inputIds = tokenizer.encode(text: safeText).map { Int64($0) }
        if inputIds.count > maxSequenceLength {
            inputIds = Array(inputIds.prefix(maxSequenceLength))
        }
        let attentionMask = [Int64](repeating: 1, count: inputIds.count)
        let shape: [NSNumber] = [1, NSNumber(value: inputIds.count)]

        let idsData = NSMutableData(bytes: inputIds, length: inputIds.count * MemoryLayout<Int64>.stride)
        let maskData = NSMutableData(bytes: attentionMask, length: attentionMask.count * MemoryLayout<Int64>.stride)

        let idsValue = try ORTValue(tensorData: idsData, elementType: ORTTensorElementDataType.int64, shape: shape)
        let maskValue = try ORTValue(tensorData: maskData, elementType: ORTTensorElementDataType.int64, shape: shape)

        let outputs = try session.run(
            withInputs: ["input_ids": idsValue, "attention_mask": maskValue],
            outputNames: ["logits"],
            runOptions: nil
        )

        guard let logitsValue = outputs["logits"] else { return 0.0 }
        let data = try logitsValue.tensorData() as Data
        let logits = data.withUnsafeBytes { raw in
            Array(raw.bindMemory(to: Float.self))
        }
        guard !logits.isEmpty, injectionIndex < logits.count else { return 0.0 }
        
        let maxLogit = Double(logits.max() ?? 0.0)
        let exps = logits.map { exp(Double($0) - maxLogit) }
        let sumExps = exps.reduce(0.0, +)
        
        return sumExps > 0 ? (exps[injectionIndex] / sumExps) : 0.0
    }
}
#endif
