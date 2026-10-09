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
    
    private init() {}
    
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
        let currentContainer = lock.withLock { self.container }
        guard let container = currentContainer else {
            throw NSError(domain: "MLXEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Model not loaded"])
        }
        
        // ChatSession handles chat formatting, memory, and generation
        let session = ChatSession(container)
        return try await session.respond(to: prompt)
    }
}
