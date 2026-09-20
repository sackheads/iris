import Foundation

public enum VisionRouter {
    public static func isVisionCapable(modelName: String) -> Bool {
        let name = modelName.lowercased()
        if name.contains("gemini") { return true }
        if name.contains("gpt-4o") || name.contains("gpt-4.5") || name.contains("gpt-4-turbo") || name.contains("gpt-4-vision") { return true }
        if name.contains("claude-3") || name.contains("claude-4") || name.contains("claude-sonnet") || name.contains("claude-haiku") || name.contains("claude-opus") { return true }
        if (name.contains("o1") || name.contains("o3")) && !name.contains("mini") { return true }
        if name.contains("vision") || name.contains("llava") || name.contains("qwen-vl") || name.contains("pixtral") || name.contains("paligemma") || name.contains("minicpm") { return true }
        return false
    }

    /// `config` is injectable so a test can drive the auxiliary-vision-configured/unconfigured
    /// paths over its own `ConfigManager(store:)` suite rather than mutating `ConfigManager.shared`
    /// (invariant 7, #215). Not `public` (unlike `isVisionCapable`) because `ConfigManager` itself
    /// is internal, and its only caller (`AppState`) is in this module.
    static func processTextOnlyImages(attachments: [FileAttachment], config: ConfigManager = .shared) async -> (descriptionText: String, warnings: [String]) {
        let images = attachments.filter { $0.category == .image }
        guard !images.isEmpty else { return ("", []) }

        let auxEngineType = config.auxiliaryVisionEngine
        let auxModelName = config.auxiliaryVisionModel

        if auxEngineType.isEmpty || auxModelName.isEmpty {
            let primaryModel = config.getModel(for: .medium)
            return ("", ["Active model '\(primaryModel)' does not support vision and no auxiliary vision model is configured in Settings."])
        }

        guard let engineType = AuxiliaryEngineType(rawValue: auxEngineType) else {
            let primaryModel = config.getModel(for: .medium)
            return ("", ["Active model '\(primaryModel)' does not support vision and no auxiliary vision model is configured in Settings."])
        }

        var descriptions: [String] = []
        var warnings: [String] = []

        let auxConfig = AuxiliaryModelConfig(role: "vision", engineType: engineType, modelPathOrName: auxModelName)

        for img in images {
            do {
                let imgData = try Data(contentsOf: img.fileURL)
                let base64 = imgData.base64EncodedString()
                let prompt = "Describe this image in detail, including text, structure, and visual content, for an AI coding assistant."
                
                let auxiliaryEngine = try await AuxiliaryModelManager.shared.getEngine(for: "vision", config: auxConfig)
                let description = try await auxiliaryEngine.generate(prompt: prompt, jsonSchema: nil, images: [base64])
                
                descriptions.append("<image_description file=\"\(img.filename)\">\n\(description)\n</image_description>")
            } catch {
                warnings.append("Auxiliary vision model failed for \(img.filename): \(error.localizedDescription)")
            }
        }

        return (descriptions.joined(separator: "\n\n"), warnings)
    }
}
