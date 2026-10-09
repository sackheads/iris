import Foundation

enum AuxiliaryEngineType: String, Codable {
    case llamaCPP = "llama_cpp"
    case ollama = "ollama"
    case mlx = "mlx"
    case cloud = "cloud"
}

struct AuxiliaryModelConfig: Codable {
    var role: String
    var engineType: AuxiliaryEngineType
    var modelPathOrName: String
}

protocol AuxiliaryInferenceEngine: Sendable {
    /// Loads a model into memory
    func loadModel(config: AuxiliaryModelConfig) async throws
    
    /// Unloads the model from memory to free up resources
    func unloadModel() async
    
    /// Generates a response based on prompt and optional JSON schema.
    func generate(prompt: String, jsonSchema: String?) async throws -> String
    
    /// Generates a response based on prompt, optional JSON schema, and optional base64 image array.
    func generate(prompt: String, jsonSchema: String?, images: [String]?) async throws -> String

    /// Checks whether the engine's model is currently loaded in memory.
    /// Default returns true (assumes always loaded) — engines that can unload
    /// (e.g. Ollama) should implement this to query their runtime state.
    func isModelLoaded() async -> Bool
}

extension AuxiliaryInferenceEngine {
    func isModelLoaded() async -> Bool { true }

    /// Optional 3-parameter overload for vision-capable auxiliary engines.
    /// Default implementation ignores images and calls 2-parameter generate.
    func generate(prompt: String, jsonSchema: String?, images: [String]?) async throws -> String {
        try await generate(prompt: prompt, jsonSchema: jsonSchema)
    }
}

