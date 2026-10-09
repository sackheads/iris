import Foundation
import LlamaSwift

enum LlamaError: Error {
    case initializationFailed
    case modelLoadFailed
    case contextCreationFailed
    case tokenizationFailed
    case decodingFailed
}

final class LlamaCPPEngine: AuxiliaryInferenceEngine, @unchecked Sendable {
    private var model: OpaquePointer?
    private var vocab: OpaquePointer?
    
    init() async throws {
        llama_backend_init()
    }
    
    func loadModel(config: AuxiliaryModelConfig) async throws {
        let modelParams = llama_model_default_params()
        
        let path = IrisPaths.default.modelsDir.appendingPathComponent(config.modelPathOrName).path
        guard let loadedModel = llama_model_load_from_file(path, modelParams) else {
            throw LlamaError.modelLoadFailed
        }
        self.model = loadedModel
        self.vocab = llama_model_get_vocab(loadedModel)
        
        print("LlamaCPPEngine loaded model at \(path)")
    }
    
    func unloadModel() async {
        if let m = model {
            llama_model_free(m)
            model = nil
        }
        vocab = nil
    }
    
    func generate(prompt: String, jsonSchema: String?) async throws -> String {
        guard let m = model, let v = vocab else {
            throw LlamaError.modelLoadFailed
        }
        
        let utf8Count = prompt.utf8.count
        let maxTokenCount = utf8Count + 2
        var tokens = [llama_token](repeating: 0, count: maxTokenCount)
        
        let tokenCount = llama_tokenize(v, prompt, Int32(utf8Count), &tokens, Int32(maxTokenCount), true, true)
        guard tokenCount > 0 else { throw LlamaError.tokenizationFailed }
        
        var contextParams = llama_context_default_params()
        let requiredCtx = UInt32(tokenCount + 256)
        contextParams.n_ctx = requiredCtx > 2048 ? requiredCtx : 2048
        let requiredBatch = UInt32(tokenCount)
        contextParams.n_batch = requiredBatch > 512 ? requiredBatch : 512
        
        guard let ctx = llama_init_from_model(m, contextParams) else {
            throw LlamaError.contextCreationFailed
        }
        defer { llama_free(ctx) }
        
        var promptTokens = Array(tokens.prefix(Int(tokenCount)))
        let batch = llama_batch_get_one(&promptTokens, Int32(promptTokens.count))
        
        guard llama_decode(ctx, batch) == 0 else { throw LlamaError.decodingFailed }
        
        var generatedText = ""
        
        for _ in 0..<128 { // Max tokens to generate
            guard let logits = llama_get_logits_ith(ctx, -1) else { throw LlamaError.decodingFailed }
            
            let vocabSize = llama_vocab_n_tokens(v)
            var maxLogit = logits[0]
            var nextToken: llama_token = 0
            
            for i in 1..<Int(vocabSize) {
                if logits[i] > maxLogit {
                    maxLogit = logits[i]
                    nextToken = llama_token(i)
                }
            }
            
            if nextToken == llama_vocab_eos(v) { break }
            
            var buffer = [CChar](repeating: 0, count: 16)
            let length = llama_token_to_piece(v, nextToken, &buffer, Int32(buffer.count), 0, false)
            if length > 0 {
                let nullTruncated = buffer.prefix(while: { $0 != 0 }).map { UInt8(bitPattern: $0) }
                generatedText += String(decoding: nullTruncated, as: UTF8.self)
            }
            
            var tokenArr = [nextToken]
            let singleBatch = llama_batch_get_one(&tokenArr, 1)
            
            guard llama_decode(ctx, singleBatch) == 0 else { throw LlamaError.decodingFailed }
        }
        
        return generatedText
    }
}
