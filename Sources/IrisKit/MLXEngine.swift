import Foundation
import MLX
import MLXLLM
import MLXLMCommon
import MLXHuggingFace
import HuggingFace
import Tokenizers

public final class MLXEngine: AuxiliaryInferenceEngine, @unchecked Sendable {
    public static let shared = MLXEngine()
    
    private var container: ModelContainer?
    private let lock = NSLock()
    
    /// A canary only says SAFE or MALICIOUS. Without a cap a tiny or looping model babbled for minutes
    /// (309 s and 406 s measured, #845); `LlamaCPPEngine` stops at the same 128.
    static let maxTokens = 128

    static var generateParameters: GenerateParameters { GenerateParameters(maxTokens: maxTokens) }

    /// Runs one prompt under the given parameters. A test replaces it; the product never does.
    typealias Respond = @Sendable (_ prompt: String, _ parameters: GenerateParameters) async throws -> String
    private let respondOverride: Respond?

    /// `shared` is the product's. An eval builds its own so a canary it scores is its alone (#815).
    init(respond: Respond? = nil) { respondOverride = respond }
    
    func loadModel(config: AuxiliaryModelConfig) async throws {
        let modelId = config.modelPathOrName
        let loadedContainer = try await #huggingFaceLoadModelContainer(
            configuration: ModelConfiguration(id: modelId)
        )
        lock.withLock {
            self.container = loadedContainer
        }
    }
    
    func unloadModel() async {
        lock.withLock {
            self.container = nil
        }
    }
    
    func generate(prompt: String, jsonSchema: String?) async throws -> String {
        if let respondOverride { return try await respondOverride(prompt, Self.generateParameters) }
        let currentContainer = lock.withLock { self.container }
        guard let container = currentContainer else {
            throw NSError(domain: "MLXEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        
        // ChatSession handles chat formatting, memory, and generation
        let session = ChatSession(container, generateParameters: Self.generateParameters)
        return try await session.respond(to: prompt)
    }
}
