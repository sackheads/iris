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

    /// #1356 (Brian, 11-26: "2: e"): whether a block can be judged again with the model thinking, for the second
    /// stage of a message channel's verdict. Default false: only an Ollama model that thinks, asked not to by
    /// default, has a different answer to give.
    func canRejudgeThinking() async -> Bool
}

extension AuxiliaryInferenceEngine {
    func isModelLoaded() async -> Bool { true }
    func canRejudgeThinking() async -> Bool { false }

    /// Optional 3-parameter overload for vision-capable auxiliary engines.
    /// Default implementation ignores images and calls 2-parameter generate.
    func generate(prompt: String, jsonSchema: String?, images: [String]?) async throws -> String {
        try await generate(prompt: prompt, jsonSchema: jsonSchema)
    }
}

