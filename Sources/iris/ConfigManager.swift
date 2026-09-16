import Foundation
import SwiftUI

public enum LLMProvider: String, CaseIterable, Identifiable, Sendable {
    case gemini = "Gemini"
    case anthropic = "Anthropic"
    case openai = "OpenAI"
    
    public var id: String { rawValue }
}

public enum GeminiAuthMode: String, CaseIterable, Identifiable, Sendable {
    case apiKey = "API Key"
    case adc = "Application Default Credentials (ADC)"
    
    public var id: String { rawValue }
}

@Observable
class ConfigManager: @unchecked Sendable {
    @ObservationIgnored static let shared = ConfigManager()

    /// The backing store for every setting.
    ///
    /// Under `swift test` this is a volatile, per-process suite rather than the user's real
    /// defaults. ConfigManager persists every setter through `didSet`, so a test that flips a flag
    /// would otherwise write it to disk and change the STARTING STATE of the next run — and because
    /// the save/mutate/restore idiom cannot be correct under parallel execution, the value written
    /// back is not always the right one. That is the cross-run half of #109: a suite that passes or
    /// fails depending on what the previous run happened to leave behind.
    ///
    /// XCTest is only linked into the test bundle, never the shipping app, so its presence is a
    /// reliable "running under tests" signal — the same test `KeychainManager` uses to switch to an
    /// in-memory secret store.
    @ObservationIgnored nonisolated(unsafe) static let store: UserDefaults = {
        guard NSClassFromString("XCTestCase") != nil else { return .standard }
        let suiteName = "iris-tests-\(ProcessInfo.processInfo.processIdentifier)"
        guard let suite = UserDefaults(suiteName: suiteName) else { return .standard }
        suite.removePersistentDomain(forName: suiteName)   // every test process starts from defaults
        return suite
    }()
    
    var appearanceTheme: String {
        didSet { ConfigManager.store.set(appearanceTheme, forKey: "APPEARANCE_THEME") }
    }
    
    var copyChatsAsMarkdown: Bool {
        didSet { ConfigManager.store.set(copyChatsAsMarkdown, forKey: "COPY_CHATS_AS_MARKDOWN") }
    }

    var defaultEmojiSkinTone: Int {
        didSet { ConfigManager.store.set(defaultEmojiSkinTone, forKey: "DEFAULT_EMOJI_SKIN_TONE") }
    }

    var primaryProvider: String {
        didSet { ConfigManager.store.set(primaryProvider, forKey: "PRIMARY_PROVIDER") }
    }
    
    var geminiAuthMode: String {
        didSet { ConfigManager.store.set(geminiAuthMode, forKey: "GEMINI_AUTH_MODE") }
    }
    
    var geminiAPIKey: String {
        didSet { updateSecret(key: "GEMINI_API_KEY", value: geminiAPIKey) }
    }
    
    var geminiBaseURL: String {
        didSet { ConfigManager.store.set(geminiBaseURL, forKey: "GEMINI_BASE_URL") }
    }
    
    var anthropicAPIKey: String {
        didSet { updateSecret(key: "ANTHROPIC_API_KEY", value: anthropicAPIKey) }
    }
    
    var anthropicBaseURL: String {
        didSet { ConfigManager.store.set(anthropicBaseURL, forKey: "ANTHROPIC_BASE_URL") }
    }
    
    var openAIAPIKey: String {
        didSet { updateSecret(key: "OPENAI_API_KEY", value: openAIAPIKey) }
    }
    
    var openAIBaseURL: String {
        didSet { ConfigManager.store.set(openAIBaseURL, forKey: "OPENAI_BASE_URL") }
    }
    
    var geminiModelEasy: String {
        didSet { ConfigManager.store.set(geminiModelEasy, forKey: "GEMINI_MODEL_EASY") }
    }
    var geminiModelMedium: String {
        didSet { ConfigManager.store.set(geminiModelMedium, forKey: "GEMINI_MODEL_MEDIUM") }
    }
    var geminiModelHard: String {
        didSet { ConfigManager.store.set(geminiModelHard, forKey: "GEMINI_MODEL_HARD") }
    }
    
    var anthropicModelEasy: String {
        didSet { ConfigManager.store.set(anthropicModelEasy, forKey: "ANTHROPIC_MODEL_EASY") }
    }
    var anthropicModelMedium: String {
        didSet { ConfigManager.store.set(anthropicModelMedium, forKey: "ANTHROPIC_MODEL_MEDIUM") }
    }
    var anthropicModelHard: String {
        didSet { ConfigManager.store.set(anthropicModelHard, forKey: "ANTHROPIC_MODEL_HARD") }
    }
    
    var openaiModelEasy: String {
        didSet { ConfigManager.store.set(openaiModelEasy, forKey: "OPENAI_MODEL_EASY") }
    }
    var openaiModelMedium: String {
        didSet { ConfigManager.store.set(openaiModelMedium, forKey: "OPENAI_MODEL_MEDIUM") }
    }
    var openaiModelHard: String {
        didSet { ConfigManager.store.set(openaiModelHard, forKey: "OPENAI_MODEL_HARD") }
    }
    
    func getModel(for tier: ModelTier) -> String {
        switch primaryProvider {
        case LLMProvider.anthropic.rawValue:
            switch tier {
            case .easy: return anthropicModelEasy
            case .medium: return anthropicModelMedium
            case .hard: return anthropicModelHard
            }
        case LLMProvider.openai.rawValue:
            switch tier {
            case .easy: return openaiModelEasy
            case .medium: return openaiModelMedium
            case .hard: return openaiModelHard
            }
        default:
            switch tier {
            case .easy: return geminiModelEasy
            case .medium: return geminiModelMedium
            case .hard: return geminiModelHard
            }
        }
    }
    
    var googleClientID: String {
        didSet { updateSecret(key: "GOOGLE_CLIENT_ID", value: googleClientID) }
    }
    
    var googleClientSecret: String {
        didSet { updateSecret(key: "GOOGLE_CLIENT_SECRET", value: googleClientSecret) }
    }
    
    var googleAccessToken: String {
        didSet { updateSecret(key: "GOOGLE_ACCESS_TOKEN", value: googleAccessToken) }
    }
    
    var googleRefreshToken: String {
        didSet { updateSecret(key: "GOOGLE_REFRESH_TOKEN", value: googleRefreshToken) }
    }
    
    var googleTokenExpiry: Double {
        didSet { ConfigManager.store.set(googleTokenExpiry, forKey: "GOOGLE_TOKEN_EXPIRY") }
    }
    
    var enableSandboxing: Bool {
        didSet { ConfigManager.store.set(enableSandboxing, forKey: "ENABLE_SANDBOXING") }
    }
    
    var sandboxImage: String {
        didSet { ConfigManager.store.set(sandboxImage, forKey: "SANDBOX_IMAGE") }
    }

    var sandboxIdleTimeoutMinutes: Int {
        didSet { ConfigManager.store.set(sandboxIdleTimeoutMinutes, forKey: "SANDBOX_IDLE_TIMEOUT_MINUTES") }
    }

    var mainAgentSandboxDefault: SandboxPref {
        didSet { ConfigManager.store.set(mainAgentSandboxDefault.rawValue, forKey: "MAIN_AGENT_SANDBOX_DEFAULT") }
    }

    var enableVibecop: Bool {
        didSet { ConfigManager.store.set(enableVibecop, forKey: "ENABLE_VIBECOP") }
    }
    
    var vibecopEngine: String {
        didSet { ConfigManager.store.set(vibecopEngine, forKey: "VIBECOP_ENGINE") }
    }
    
    var vibecopModel: String {
        didSet { ConfigManager.store.set(vibecopModel, forKey: "VIBECOP_MODEL") }
    }

    var maxGoalIterations: Int {
        didSet { ConfigManager.store.set(maxGoalIterations, forKey: "MAX_GOAL_ITERATIONS") }
    }
    var maxDoneGateRetries: Int {
        didSet { ConfigManager.store.set(maxDoneGateRetries, forKey: "MAX_DONE_GATE_RETRIES") }
    }
    var loopDetectionThreshold: Int {
        didSet { ConfigManager.store.set(loopDetectionThreshold, forKey: "LOOP_DETECTION_THRESHOLD") }
    }
    var vibecopTimeoutSeconds: Int {
        didSet { ConfigManager.store.set(vibecopTimeoutSeconds, forKey: "VIBECOP_TIMEOUT_SECONDS") }
    }

    var enableAdvancedPromptInjectionProtection: Bool {
        didSet { ConfigManager.store.set(enableAdvancedPromptInjectionProtection, forKey: "ENABLE_PROMPT_INJECTION_PROTECTION") }
    }
    
    var promptGuardEngine: String {
        didSet { ConfigManager.store.set(promptGuardEngine, forKey: "PROMPT_GUARD_ENGINE") }
    }
    
    var promptGuardModel: String {
        didSet { ConfigManager.store.set(promptGuardModel, forKey: "PROMPT_GUARD_MODEL") }
    }
    
    var promptGuardCoreMLModel: String {
        didSet { ConfigManager.store.set(promptGuardCoreMLModel, forKey: "PROMPT_GUARD_COREML_MODEL") }
    }
    
    var auxiliaryVisionEngine: String {
        didSet { ConfigManager.store.set(auxiliaryVisionEngine, forKey: "AUXILIARY_VISION_ENGINE") }
    }
    
    var auxiliaryVisionModel: String {
        didSet { ConfigManager.store.set(auxiliaryVisionModel, forKey: "AUXILIARY_VISION_MODEL") }
    }
    
    init() {
        let savedProvider = ConfigManager.store.string(forKey: "PRIMARY_PROVIDER") ?? "Gemini"
        self.primaryProvider = savedProvider
        self.geminiAuthMode = ConfigManager.store.string(forKey: "GEMINI_AUTH_MODE") ?? GeminiAuthMode.apiKey.rawValue
        
        self.appearanceTheme = ConfigManager.store.string(forKey: "APPEARANCE_THEME") ?? "system"
        
        if ConfigManager.store.object(forKey: "COPY_CHATS_AS_MARKDOWN") != nil {
            self.copyChatsAsMarkdown = ConfigManager.store.bool(forKey: "COPY_CHATS_AS_MARKDOWN")
        } else {
            self.copyChatsAsMarkdown = true
        }

        self.defaultEmojiSkinTone = ConfigManager.store.object(forKey: "DEFAULT_EMOJI_SKIN_TONE") as? Int ?? SkinTone.none.rawValue
        
        var keychainSecrets = KeychainManager.shared.loadSecrets()
        var secretsMigrated = false
        
        func migrate(key: String, dest: inout String) {
            if let keychainValue = keychainSecrets[key] {
                dest = keychainValue
            } else if let udValue = ConfigManager.store.string(forKey: key), !udValue.isEmpty {
                dest = udValue
                keychainSecrets[key] = udValue
                ConfigManager.store.removeObject(forKey: key)
                secretsMigrated = true
            } else {
                dest = ""
            }
        }
        
        var geminiKey = ""
        migrate(key: "GEMINI_API_KEY", dest: &geminiKey)
        self.geminiAPIKey = geminiKey
        
        var anthropicKey = ""
        migrate(key: "ANTHROPIC_API_KEY", dest: &anthropicKey)
        self.anthropicAPIKey = anthropicKey
        
        var openaiKey = ""
        migrate(key: "OPENAI_API_KEY", dest: &openaiKey)
        self.openAIAPIKey = openaiKey
        
        geminiBaseURL = ConfigManager.store.string(forKey: "GEMINI_BASE_URL") ?? ""
        anthropicBaseURL = ConfigManager.store.string(forKey: "ANTHROPIC_BASE_URL") ?? ""
        openAIBaseURL = ConfigManager.store.string(forKey: "OPENAI_BASE_URL") ?? ""

        // Try reading old global models first for migration, else fallback to defaults.
        // The old global keys only migrate onto whichever provider was active at the time.
        let oldEasy = ConfigManager.store.string(forKey: "MODEL_EASY")
        let oldMedium = ConfigManager.store.string(forKey: "MODEL_MEDIUM")
        let oldHard = ConfigManager.store.string(forKey: "MODEL_HARD")

        func resolveModel(key: String, provider: String, migrated: String?, fallback: String) -> String {
            if let saved = ConfigManager.store.string(forKey: key) {
                return saved
            }
            if savedProvider == provider, let migrated {
                return migrated
            }
            return fallback
        }

        self.geminiModelEasy = resolveModel(key: "GEMINI_MODEL_EASY", provider: "Gemini", migrated: oldEasy, fallback: "gemini-3.1-flash-lite")
        self.geminiModelMedium = resolveModel(key: "GEMINI_MODEL_MEDIUM", provider: "Gemini", migrated: oldMedium, fallback: "gemini-3.5-flash")
        self.geminiModelHard = resolveModel(key: "GEMINI_MODEL_HARD", provider: "Gemini", migrated: oldHard, fallback: "gemini-3.1-pro-preview")

        self.anthropicModelEasy = resolveModel(key: "ANTHROPIC_MODEL_EASY", provider: "Anthropic", migrated: oldEasy, fallback: "claude-haiku-4-5-20251001")
        self.anthropicModelMedium = resolveModel(key: "ANTHROPIC_MODEL_MEDIUM", provider: "Anthropic", migrated: oldMedium, fallback: "claude-sonnet-5")
        self.anthropicModelHard = resolveModel(key: "ANTHROPIC_MODEL_HARD", provider: "Anthropic", migrated: oldHard, fallback: "claude-fable-5")

        self.openaiModelEasy = resolveModel(key: "OPENAI_MODEL_EASY", provider: "OpenAI", migrated: oldEasy, fallback: "gpt-5.6-luna")
        self.openaiModelMedium = resolveModel(key: "OPENAI_MODEL_MEDIUM", provider: "OpenAI", migrated: oldMedium, fallback: "gpt-5.6-terra")
        self.openaiModelHard = resolveModel(key: "OPENAI_MODEL_HARD", provider: "OpenAI", migrated: oldHard, fallback: "gpt-5.6-sol")
        
        var gClientId = ""
        migrate(key: "GOOGLE_CLIENT_ID", dest: &gClientId)
        self.googleClientID = gClientId
        
        var gClientSecret = ""
        migrate(key: "GOOGLE_CLIENT_SECRET", dest: &gClientSecret)
        self.googleClientSecret = gClientSecret
        
        var gAccessToken = ""
        migrate(key: "GOOGLE_ACCESS_TOKEN", dest: &gAccessToken)
        self.googleAccessToken = gAccessToken
        
        var gRefreshToken = ""
        migrate(key: "GOOGLE_REFRESH_TOKEN", dest: &gRefreshToken)
        self.googleRefreshToken = gRefreshToken
        
        if secretsMigrated {
            KeychainManager.shared.saveSecrets(keychainSecrets)
        }
        self.googleTokenExpiry = ConfigManager.store.double(forKey: "GOOGLE_TOKEN_EXPIRY")
        self.enableSandboxing = ConfigManager.store.bool(forKey: "ENABLE_SANDBOXING")
        self.sandboxImage = ConfigManager.store.string(forKey: "SANDBOX_IMAGE") ?? "ubuntu:latest"
        let savedIdle = ConfigManager.store.integer(forKey: "SANDBOX_IDLE_TIMEOUT_MINUTES")
        self.sandboxIdleTimeoutMinutes = savedIdle == 0 ? 30 : savedIdle

        if ConfigManager.store.object(forKey: "MAIN_AGENT_SANDBOX_DEFAULT") == nil {
            // First run with this key. Preserve the experience of users who already run
            // sandboxed (enableSandboxing on today == sandboxed main agent); fresh installs
            // default to host (the dual-layer model).
            let seeded: SandboxPref = ConfigManager.store.bool(forKey: "ENABLE_SANDBOXING") ? .sandboxed : .host
            self.mainAgentSandboxDefault = seeded
            ConfigManager.store.set(seeded.rawValue, forKey: "MAIN_AGENT_SANDBOX_DEFAULT")
        } else {
            let raw = ConfigManager.store.string(forKey: "MAIN_AGENT_SANDBOX_DEFAULT") ?? "host"
            self.mainAgentSandboxDefault = SandboxPref(rawValue: raw) ?? .host
        }

        self.enableVibecop = ConfigManager.store.bool(forKey: "ENABLE_VIBECOP")
        let savedEngine = ConfigManager.store.string(forKey: "VIBECOP_ENGINE") ?? ""
        self.vibecopEngine = savedEngine.isEmpty ? "llama_cpp" : savedEngine
        
        let savedVibecop = ConfigManager.store.string(forKey: "VIBECOP_MODEL") ?? ""
        self.vibecopModel = savedVibecop.isEmpty ? "gemma-4-E2B-it-Q4_K_M.gguf" : savedVibecop

        let savedMaxIters = ConfigManager.store.integer(forKey: "MAX_GOAL_ITERATIONS")
        self.maxGoalIterations = savedMaxIters == 0 ? 50 : savedMaxIters
        let savedLoop = ConfigManager.store.integer(forKey: "LOOP_DETECTION_THRESHOLD")
        let savedGateRetries = ConfigManager.store.integer(forKey: "MAX_DONE_GATE_RETRIES")
        self.maxDoneGateRetries = savedGateRetries == 0 ? 3 : savedGateRetries
        self.loopDetectionThreshold = savedLoop == 0 ? 5 : savedLoop
        let savedVibecopTO = ConfigManager.store.integer(forKey: "VIBECOP_TIMEOUT_SECONDS")
        self.vibecopTimeoutSeconds = savedVibecopTO == 0 ? 5 : savedVibecopTO

        if ConfigManager.store.object(forKey: "ENABLE_PROMPT_INJECTION_PROTECTION") != nil {
            self.enableAdvancedPromptInjectionProtection = ConfigManager.store.bool(forKey: "ENABLE_PROMPT_INJECTION_PROTECTION")
        } else {
            self.enableAdvancedPromptInjectionProtection = true // Default to true
        }
        
        let savedPromptEngine = ConfigManager.store.string(forKey: "PROMPT_GUARD_ENGINE") ?? ""
        self.promptGuardEngine = savedPromptEngine.isEmpty ? "llama_cpp" : savedPromptEngine
        
        let savedPromptModel = ConfigManager.store.string(forKey: "PROMPT_GUARD_MODEL") ?? ""
        self.promptGuardModel = savedPromptModel.isEmpty ? "Qwen3.5-2B-Q4_K_M.gguf" : savedPromptModel
        
        // Default to the accurate DeBERTa-v3 ONNX guard. The old distilbert CoreML default
        // over-blocked ordinary tool output; see docs/prompt_guard_coreml.md.
        let savedCoreMLModel = ConfigManager.store.string(forKey: "PROMPT_GUARD_COREML_MODEL") ?? ""
        self.promptGuardCoreMLModel = savedCoreMLModel.isEmpty ? "https://luthen.scromp.net/iris/deberta-v3-base-prompt-injection-v2.onnx.zip" : savedCoreMLModel

        self.auxiliaryVisionEngine = ConfigManager.store.string(forKey: "AUXILIARY_VISION_ENGINE") ?? ""
        self.auxiliaryVisionModel = ConfigManager.store.string(forKey: "AUXILIARY_VISION_MODEL") ?? ""
    }
    
    var isConfigured: Bool {
        switch primaryProvider {
        case LLMProvider.anthropic.rawValue:
            return !anthropicAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
        case LLMProvider.openai.rawValue:
            return !openAIAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
        default:
            if geminiAuthMode == GeminiAuthMode.adc.rawValue {
                return true
            }
            return !geminiAPIKey.trimmingCharacters(in: .whitespaces).isEmpty
        }
    }
    
    private func updateSecret(key: String, value: String) {
        var secrets = KeychainManager.shared.loadSecrets()
        secrets[key] = value
        KeychainManager.shared.saveSecrets(secrets)
    }
}
