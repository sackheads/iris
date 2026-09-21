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

    /// The suite this instance was constructed with. `nil` — what `shared` and every production
    /// call site get — means "whatever `IrisDefaults` resolves at the moment of the write".
    @ObservationIgnored private let storeOverride: UserDefaults?

    /// The backing store for every setting — see `IrisDefaults` for why it is volatile under test
    /// and under `--bench`/`--perf`. Per instance, so a test can construct a `ConfigManager` over
    /// its own suite and have the persisting `didSet`s land there instead of the process-global
    /// store, which every parallel suite would otherwise race through (#193). With no override it
    /// is computed, not captured: a headless run's volatile override must apply to every later
    /// write even if `shared` was initialised before the override was set.
    var store: UserDefaults { storeOverride ?? IrisDefaults.store }
    
    var appearanceTheme: String {
        didSet { store.set(appearanceTheme, forKey: "APPEARANCE_THEME") }
    }
    
    var copyChatsAsMarkdown: Bool {
        didSet { store.set(copyChatsAsMarkdown, forKey: "COPY_CHATS_AS_MARKDOWN") }
    }

    /// Show the reply while the model is still writing it (spec §7). Off means whole replies,
    /// the pre-streaming behaviour.
    var streamResponses: Bool {
        didSet { store.set(streamResponses, forKey: "STREAM_RESPONSES") }
    }

    /// Slice D3 — when true (the default), a checkpoint the grader passes cleanly advances without
    /// stopping the human. False forces every checkpoint to pause, which is pre-D3 behaviour.
    var checkpointAutoAdvance: Bool {
        didSet { store.set(checkpointAutoAdvance, forKey: "CHECKPOINT_AUTO_ADVANCE") }
    }

    /// #185 §7 — how many peer-woken turns one user action may cascade into, across the whole
    /// cascade rather than per branch. The right number is empirical; 8 is a starting point.
    var maxSessionCascade: Int {
        didSet { store.set(maxSessionCascade, forKey: "MAX_SESSION_CASCADE") }
    }

    var defaultEmojiSkinTone: Int {
        didSet { store.set(defaultEmojiSkinTone, forKey: "DEFAULT_EMOJI_SKIN_TONE") }
    }

    var primaryProvider: String {
        didSet { store.set(primaryProvider, forKey: "PRIMARY_PROVIDER") }
    }
    
    var geminiAuthMode: String {
        didSet { store.set(geminiAuthMode, forKey: "GEMINI_AUTH_MODE") }
    }
    
    var geminiAPIKey: String {
        didSet { updateSecret(key: "GEMINI_API_KEY", value: geminiAPIKey) }
    }
    
    var geminiBaseURL: String {
        didSet { store.set(geminiBaseURL, forKey: "GEMINI_BASE_URL") }
    }
    
    var anthropicAPIKey: String {
        didSet { updateSecret(key: "ANTHROPIC_API_KEY", value: anthropicAPIKey) }
    }
    
    var anthropicBaseURL: String {
        didSet { store.set(anthropicBaseURL, forKey: "ANTHROPIC_BASE_URL") }
    }
    
    var openAIAPIKey: String {
        didSet { updateSecret(key: "OPENAI_API_KEY", value: openAIAPIKey) }
    }
    
    var openAIBaseURL: String {
        didSet { store.set(openAIBaseURL, forKey: "OPENAI_BASE_URL") }
    }
    
    var geminiModelEasy: String {
        didSet { store.set(geminiModelEasy, forKey: "GEMINI_MODEL_EASY") }
    }
    var geminiModelMedium: String {
        didSet { store.set(geminiModelMedium, forKey: "GEMINI_MODEL_MEDIUM") }
    }
    var geminiModelHard: String {
        didSet { store.set(geminiModelHard, forKey: "GEMINI_MODEL_HARD") }
    }
    
    var anthropicModelEasy: String {
        didSet { store.set(anthropicModelEasy, forKey: "ANTHROPIC_MODEL_EASY") }
    }
    var anthropicModelMedium: String {
        didSet { store.set(anthropicModelMedium, forKey: "ANTHROPIC_MODEL_MEDIUM") }
    }
    var anthropicModelHard: String {
        didSet { store.set(anthropicModelHard, forKey: "ANTHROPIC_MODEL_HARD") }
    }
    
    var openaiModelEasy: String {
        didSet { store.set(openaiModelEasy, forKey: "OPENAI_MODEL_EASY") }
    }
    var openaiModelMedium: String {
        didSet { store.set(openaiModelMedium, forKey: "OPENAI_MODEL_MEDIUM") }
    }
    var openaiModelHard: String {
        didSet { store.set(openaiModelHard, forKey: "OPENAI_MODEL_HARD") }
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
        didSet { store.set(googleTokenExpiry, forKey: "GOOGLE_TOKEN_EXPIRY") }
    }
    
    var enableSandboxing: Bool {
        didSet { store.set(enableSandboxing, forKey: "ENABLE_SANDBOXING") }
    }
    
    var sandboxImage: String {
        didSet { store.set(sandboxImage, forKey: "SANDBOX_IMAGE") }
    }

    var sandboxIdleTimeoutMinutes: Int {
        didSet { store.set(sandboxIdleTimeoutMinutes, forKey: "SANDBOX_IDLE_TIMEOUT_MINUTES") }
    }

    var mainAgentSandboxDefault: SandboxPref {
        didSet { store.set(mainAgentSandboxDefault.rawValue, forKey: "MAIN_AGENT_SANDBOX_DEFAULT") }
    }

    var enableVibecop: Bool {
        didSet { store.set(enableVibecop, forKey: "ENABLE_VIBECOP") }
    }
    
    var vibecopEngine: String {
        didSet { store.set(vibecopEngine, forKey: "VIBECOP_ENGINE") }
    }
    
    var vibecopModel: String {
        didSet { store.set(vibecopModel, forKey: "VIBECOP_MODEL") }
    }

    var maxGoalIterations: Int {
        didSet { store.set(maxGoalIterations, forKey: "MAX_GOAL_ITERATIONS") }
    }
    var maxDoneGateRetries: Int {
        didSet { store.set(maxDoneGateRetries, forKey: "MAX_DONE_GATE_RETRIES") }
    }
    var loopDetectionThreshold: Int {
        didSet { store.set(loopDetectionThreshold, forKey: "LOOP_DETECTION_THRESHOLD") }
    }
    var vibecopTimeoutSeconds: Int {
        didSet { store.set(vibecopTimeoutSeconds, forKey: "VIBECOP_TIMEOUT_SECONDS") }
    }

    // MARK: Unattended jobs (#187 §0.1)
    //
    // The five global numbers a job's `JobPolicy` overrides per job. They are what an unattended
    // run is allowed to cost when nobody set anything: sane, not final. A non-positive value means
    // "no limit" to the runner, which is why `0` here reads back as the default rather than as an
    // instantly-exhausted budget.

    /// Tokens one run may spend before its turn is stopped.
    var jobPerRunTokenBudget: Int {
        didSet { store.set(jobPerRunTokenBudget, forKey: "JOB_PER_RUN_TOKEN_BUDGET") }
    }
    /// Tokens one job may spend across the local calendar day before it pauses.
    var jobDailyTokenBudget: Int {
        didSet { store.set(jobDailyTokenBudget, forKey: "JOB_DAILY_TOKEN_BUDGET") }
    }
    /// Tokens every background run together may spend in a day. A job cannot raise this for
    /// itself — it is the ceiling on the whole unattended system.
    var jobGlobalDailyTokenBudget: Int {
        didSet { store.set(jobGlobalDailyTokenBudget, forKey: "JOB_GLOBAL_DAILY_TOKEN_BUDGET") }
    }
    /// The breaker: this many runs of one job inside an hour pauses it.
    var jobMaxRunsPerHour: Int {
        didSet { store.set(jobMaxRunsPerHour, forKey: "JOB_MAX_RUNS_PER_HOUR") }
    }
    /// Wall-clock seconds one run may take.
    var jobRunTimeoutSeconds: Int {
        didSet { store.set(jobRunTimeoutSeconds, forKey: "JOB_RUN_TIMEOUT_SECONDS") }
    }

    var enableAdvancedPromptInjectionProtection: Bool {
        didSet { store.set(enableAdvancedPromptInjectionProtection, forKey: "ENABLE_PROMPT_INJECTION_PROTECTION") }
    }
    
    var promptGuardEngine: String {
        didSet { store.set(promptGuardEngine, forKey: "PROMPT_GUARD_ENGINE") }
    }
    
    var promptGuardModel: String {
        didSet { store.set(promptGuardModel, forKey: "PROMPT_GUARD_MODEL") }
    }
    
    var promptGuardCoreMLModel: String {
        didSet { store.set(promptGuardCoreMLModel, forKey: "PROMPT_GUARD_COREML_MODEL") }
    }
    
    var auxiliaryVisionEngine: String {
        didSet { store.set(auxiliaryVisionEngine, forKey: "AUXILIARY_VISION_ENGINE") }
    }
    
    var auxiliaryVisionModel: String {
        didSet { store.set(auxiliaryVisionModel, forKey: "AUXILIARY_VISION_MODEL") }
    }
    
    /// - Parameter store: a suite to read and persist through instead of `IrisDefaults.store`.
    ///   A test passes one to get a manager no other suite can see the writes of; production
    ///   passes nothing and follows `IrisDefaults`.
    init(store storeOverride: UserDefaults? = nil) {
        self.storeOverride = storeOverride
        // Bound locally because `self.store` is unreadable until every stored property is
        // initialised; it is the same store the instance property returns from here on.
        let store = storeOverride ?? IrisDefaults.store
        let savedProvider = store.string(forKey: "PRIMARY_PROVIDER") ?? "Gemini"
        self.primaryProvider = savedProvider
        self.geminiAuthMode = store.string(forKey: "GEMINI_AUTH_MODE") ?? GeminiAuthMode.apiKey.rawValue
        
        self.appearanceTheme = store.string(forKey: "APPEARANCE_THEME") ?? "system"
        
        if store.object(forKey: "COPY_CHATS_AS_MARKDOWN") != nil {
            self.copyChatsAsMarkdown = store.bool(forKey: "COPY_CHATS_AS_MARKDOWN")
        } else {
            self.copyChatsAsMarkdown = true
        }

        if store.object(forKey: "STREAM_RESPONSES") != nil {
            self.streamResponses = store.bool(forKey: "STREAM_RESPONSES")
        } else {
            self.streamResponses = true
        }

        if store.object(forKey: "CHECKPOINT_AUTO_ADVANCE") != nil {
            self.checkpointAutoAdvance = store.bool(forKey: "CHECKPOINT_AUTO_ADVANCE")
        } else {
            self.checkpointAutoAdvance = true
        }

        let savedCascade = store.integer(forKey: "MAX_SESSION_CASCADE")
        self.maxSessionCascade = savedCascade == 0 ? 8 : savedCascade

        self.defaultEmojiSkinTone = store.object(forKey: "DEFAULT_EMOJI_SKIN_TONE") as? Int ?? SkinTone.none.rawValue
        
        var keychainSecrets = KeychainManager.shared.loadSecrets()
        var secretsMigrated = false
        
        func migrate(key: String, dest: inout String) {
            if let keychainValue = keychainSecrets[key] {
                dest = keychainValue
            } else if let udValue = store.string(forKey: key), !udValue.isEmpty {
                dest = udValue
                keychainSecrets[key] = udValue
                store.removeObject(forKey: key)
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
        
        geminiBaseURL = store.string(forKey: "GEMINI_BASE_URL") ?? ""
        anthropicBaseURL = store.string(forKey: "ANTHROPIC_BASE_URL") ?? ""
        openAIBaseURL = store.string(forKey: "OPENAI_BASE_URL") ?? ""

        // Try reading old global models first for migration, else fallback to defaults.
        // The old global keys only migrate onto whichever provider was active at the time.
        let oldEasy = store.string(forKey: "MODEL_EASY")
        let oldMedium = store.string(forKey: "MODEL_MEDIUM")
        let oldHard = store.string(forKey: "MODEL_HARD")

        func resolveModel(key: String, provider: String, migrated: String?, fallback: String) -> String {
            if let saved = store.string(forKey: key) {
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
        self.googleTokenExpiry = store.double(forKey: "GOOGLE_TOKEN_EXPIRY")
        self.enableSandboxing = store.bool(forKey: "ENABLE_SANDBOXING")
        self.sandboxImage = store.string(forKey: "SANDBOX_IMAGE") ?? "ubuntu:latest"
        let savedIdle = store.integer(forKey: "SANDBOX_IDLE_TIMEOUT_MINUTES")
        self.sandboxIdleTimeoutMinutes = savedIdle == 0 ? 30 : savedIdle

        if store.object(forKey: "MAIN_AGENT_SANDBOX_DEFAULT") == nil {
            // First run with this key. Preserve the experience of users who already run
            // sandboxed (enableSandboxing on today == sandboxed main agent); fresh installs
            // default to host (the dual-layer model).
            let seeded: SandboxPref = store.bool(forKey: "ENABLE_SANDBOXING") ? .sandboxed : .host
            self.mainAgentSandboxDefault = seeded
            store.set(seeded.rawValue, forKey: "MAIN_AGENT_SANDBOX_DEFAULT")
        } else {
            let raw = store.string(forKey: "MAIN_AGENT_SANDBOX_DEFAULT") ?? "host"
            self.mainAgentSandboxDefault = SandboxPref(rawValue: raw) ?? .host
        }

        self.enableVibecop = store.bool(forKey: "ENABLE_VIBECOP")
        let savedEngine = store.string(forKey: "VIBECOP_ENGINE") ?? ""
        self.vibecopEngine = savedEngine.isEmpty ? "llama_cpp" : savedEngine
        
        let savedVibecop = store.string(forKey: "VIBECOP_MODEL") ?? ""
        self.vibecopModel = savedVibecop.isEmpty ? "gemma-4-E2B-it-Q4_K_M.gguf" : savedVibecop

        let savedMaxIters = store.integer(forKey: "MAX_GOAL_ITERATIONS")
        self.maxGoalIterations = savedMaxIters == 0 ? 50 : savedMaxIters
        let savedLoop = store.integer(forKey: "LOOP_DETECTION_THRESHOLD")
        let savedGateRetries = store.integer(forKey: "MAX_DONE_GATE_RETRIES")
        self.maxDoneGateRetries = savedGateRetries == 0 ? 3 : savedGateRetries
        self.loopDetectionThreshold = savedLoop == 0 ? 5 : savedLoop
        let savedVibecopTO = store.integer(forKey: "VIBECOP_TIMEOUT_SECONDS")
        self.vibecopTimeoutSeconds = savedVibecopTO == 0 ? 5 : savedVibecopTO

        // #187 §0.1. Unset (0) is the default, following the #208 pattern.
        let savedPerRun = store.integer(forKey: "JOB_PER_RUN_TOKEN_BUDGET")
        self.jobPerRunTokenBudget = savedPerRun == 0 ? 200_000 : savedPerRun
        let savedDaily = store.integer(forKey: "JOB_DAILY_TOKEN_BUDGET")
        self.jobDailyTokenBudget = savedDaily == 0 ? 1_000_000 : savedDaily
        let savedGlobalDaily = store.integer(forKey: "JOB_GLOBAL_DAILY_TOKEN_BUDGET")
        self.jobGlobalDailyTokenBudget = savedGlobalDaily == 0 ? 3_000_000 : savedGlobalDaily
        let savedRunsPerHour = store.integer(forKey: "JOB_MAX_RUNS_PER_HOUR")
        self.jobMaxRunsPerHour = savedRunsPerHour == 0 ? 6 : savedRunsPerHour
        let savedRunTimeout = store.integer(forKey: "JOB_RUN_TIMEOUT_SECONDS")
        self.jobRunTimeoutSeconds = savedRunTimeout == 0 ? 600 : savedRunTimeout

        if store.object(forKey: "ENABLE_PROMPT_INJECTION_PROTECTION") != nil {
            self.enableAdvancedPromptInjectionProtection = store.bool(forKey: "ENABLE_PROMPT_INJECTION_PROTECTION")
        } else {
            self.enableAdvancedPromptInjectionProtection = true // Default to true
        }
        
        let savedPromptEngine = store.string(forKey: "PROMPT_GUARD_ENGINE") ?? ""
        self.promptGuardEngine = savedPromptEngine.isEmpty ? "llama_cpp" : savedPromptEngine
        
        let savedPromptModel = store.string(forKey: "PROMPT_GUARD_MODEL") ?? ""
        self.promptGuardModel = savedPromptModel.isEmpty ? "Qwen3.5-2B-Q4_K_M.gguf" : savedPromptModel
        
        // Default to the accurate DeBERTa-v3 ONNX guard. The old distilbert CoreML default
        // over-blocked ordinary tool output; see docs/prompt_guard_coreml.md.
        let savedCoreMLModel = store.string(forKey: "PROMPT_GUARD_COREML_MODEL") ?? ""
        self.promptGuardCoreMLModel = savedCoreMLModel.isEmpty ? "https://luthen.scromp.net/iris/deberta-v3-base-prompt-injection-v2.onnx.zip" : savedCoreMLModel

        self.auxiliaryVisionEngine = store.string(forKey: "AUXILIARY_VISION_ENGINE") ?? ""
        self.auxiliaryVisionModel = store.string(forKey: "AUXILIARY_VISION_MODEL") ?? ""
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
