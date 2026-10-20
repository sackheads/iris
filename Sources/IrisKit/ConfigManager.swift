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

/// How the Anthropic provider authenticates (#181). `vertex` calls Claude models hosted in a
/// Google Cloud project through Vertex AI with Application Default Credentials, the same `gcloud`
/// login the Gemini ADC mode uses; the provider, tiers and tools stay Anthropic's.
public enum AnthropicAuthMode: String, CaseIterable, Identifiable, Sendable {
    case apiKey = "API Key"
    case vertex = "Vertex AI (ADC)"

    public var id: String { rawValue }
}

/// Settings' "Notifications" row (D6 decision 7).
enum NotificationMode: String, CaseIterable, Sendable {
    case off, needsAttention
}

@Observable
class ConfigManager: @unchecked Sendable {
    @ObservationIgnored static let shared = ConfigManager()

    /// The suite this instance was constructed with. `nil` — what `shared` and every production
    /// call site get — means "whatever `IrisDefaults` resolves at the moment of the write".
    @ObservationIgnored private let storeOverride: UserDefaults?

    /// Where the guarded settings (#678) live: the secrets item. Nil only for a test's manager
    /// over its own suite that passes no keychain, which keeps them in that suite as before.
    @ObservationIgnored let guardedKeychain: KeychainManager?
    /// What this launch found in the secrets item for the guarded settings.
    @ObservationIgnored var guardedState: GuardedSettings.State = .normal
    /// Launch notices about the guarded settings, taken once by `AppState`.
    @ObservationIgnored var guardedNotices: [String] = []
    /// The secrets item as read once for the subagent providers (#239): every registry, route and
    /// blob read uses it instead of a Keychain read each time. Filled only from the item, never
    /// from defaults; dropped after every write through this manager.
    @ObservationIgnored var secretsCache: [String: String]?

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

    /// #261 — show the model-activity LED bar above the composer. Off hides it and gives the space
    /// back; it does not reserve a gap.
    ///
    /// Hides the LEDs only. The spectrum line above them is the thinking indicator rather than
    /// model status, and it is the only sign a turn is running. A guard tier that is installed but
    /// broken (#218) still announces itself in the conversation with this off — the toggle is
    /// about a status light, not about suppressing a fault.
    var showModelLEDs: Bool {
        didSet { store.set(showModelLEDs, forKey: "SHOW_MODEL_LEDS") }
    }

    /// Slice D3 — when true (the default), a checkpoint the grader passes cleanly advances without
    /// stopping the human. False forces every checkpoint to pause, which is pre-D3 behaviour.
    var checkpointAutoAdvance: Bool {
        didSet { store.set(checkpointAutoAdvance, forKey: "CHECKPOINT_AUTO_ADVANCE") }
    }

    /// D6 decision 7: "Notifications: Off / Needs attention". Needs attention by default.
    var notificationMode: NotificationMode {
        didSet { store.set(notificationMode.rawValue, forKey: "NOTIFICATION_MODE") }
    }

    /// #469 §6 — the maximum hop depth of a chain of session messages: a send carries the
    /// sender's depth + 1 and is refused once that exceeds this limit. The right number is
    /// empirical; 8 is a starting point.
    var maxSessionCascade: Int {
        didSet { persistGuarded(.maxSessionCascade) { $0.set(maxSessionCascade, forKey: "MAX_SESSION_CASCADE") } }
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
        didSet { persistGuarded(.geminiBaseURL) { $0.set(geminiBaseURL, forKey: "GEMINI_BASE_URL") } }
    }
    
    var anthropicAPIKey: String {
        didSet { updateSecret(key: "ANTHROPIC_API_KEY", value: anthropicAPIKey) }
    }
    
    var anthropicBaseURL: String {
        didSet { persistGuarded(.anthropicBaseURL) { $0.set(anthropicBaseURL, forKey: "ANTHROPIC_BASE_URL") } }
    }

    var anthropicAuthMode: String {
        didSet { store.set(anthropicAuthMode, forKey: "ANTHROPIC_AUTH_MODE") }
    }
    /// The Google Cloud project whose Vertex AI serves Claude. Required in Vertex mode: it is
    /// prefilled from the ADC quota project in Settings but never substituted silently, because
    /// the two are routinely different projects (#181).
    var anthropicVertexProject: String {
        didSet { store.set(anthropicVertexProject, forKey: "ANTHROPIC_VERTEX_PROJECT") }
    }
    /// `global`, `us`, `eu`, or a region. A blank value reads back as `global`, so an emptied
    /// field never produces an empty path segment.
    var anthropicVertexLocation: String {
        didSet { store.set(anthropicVertexLocation, forKey: "ANTHROPIC_VERTEX_LOCATION") }
    }
    static let defaultVertexLocation = "global"
    /// `anthropicVertexLocation` as the request path needs it: trimmed, `global` when blank.
    var effectiveVertexLocation: String {
        let trimmed = anthropicVertexLocation.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? Self.defaultVertexLocation : trimmed
    }
    
    var openAIAPIKey: String {
        didSet { updateSecret(key: "OPENAI_API_KEY", value: openAIAPIKey) }
    }
    
    var openAIBaseURL: String {
        didSet { persistGuarded(.openAIBaseURL) { $0.set(openAIBaseURL, forKey: "OPENAI_BASE_URL") } }
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

    /// #314 Phase 1 — whether a later request in the same turn resends this turn's own earlier
    /// signed thinking blocks (Anthropic only; gates `IrisEngine.replaysThinking`). Default off:
    /// a paid measurement (PR #405) found replay costs about 18% more per task on Opus 5.5 with
    /// no fewer rounds, and both arms succeeded every time, so whether it improves reasoning
    /// quality is still unmeasured. `store.bool(forKey:)` reads back false when nothing was ever
    /// written, which is exactly the off default this needs.
    var replayThinkingWithinTurn: Bool {
        didSet { store.set(replayThinkingWithinTurn, forKey: "REPLAY_THINKING_WITHIN_TURN") }
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
        didSet { persistGuarded(.enableSandboxing) { $0.set(enableSandboxing, forKey: "ENABLE_SANDBOXING") } }
    }
    
    var sandboxImage: String {
        didSet { store.set(sandboxImage, forKey: "SANDBOX_IMAGE") }
    }

    /// The session-attachment exchange's ceiling in megabytes (#469 §7.6 J). Disk, not spend,
    /// egress or safety, so it lives in defaults (§7.6 H).
    var artifactExchangeCapMB: Int {
        didSet { store.set(artifactExchangeCapMB, forKey: "ARTIFACT_EXCHANGE_CAP_MB") }
    }

    var sandboxIdleTimeoutMinutes: Int {
        didSet { store.set(sandboxIdleTimeoutMinutes, forKey: "SANDBOX_IDLE_TIMEOUT_MINUTES") }
    }

    var mainAgentSandboxDefault: SandboxPref {
        didSet { persistGuarded(.mainAgentSandboxDefault) { $0.set(mainAgentSandboxDefault.rawValue, forKey: "MAIN_AGENT_SANDBOX_DEFAULT") } }
    }

    var enableVibecop: Bool {
        didSet { persistGuarded(.enableVibecop) { $0.set(enableVibecop, forKey: "ENABLE_VIBECOP") } }
    }
    
    var vibecopEngine: String {
        didSet { store.set(vibecopEngine, forKey: "VIBECOP_ENGINE") }
    }
    
    var vibecopModel: String {
        didSet { store.set(vibecopModel, forKey: "VIBECOP_MODEL") }
    }

    /// The model Vibecop's cloud engine asks (#620), on the primary provider. Empty, the default,
    /// is the easy tier's model, which is all the cloud engine ever used before. Its own key:
    /// `vibecopModel` is shared with the local engines and holds a GGUF file or an Ollama tag.
    var vibecopCloudModel: String {
        didSet { store.set(vibecopCloudModel, forKey: "VIBECOP_CLOUD_MODEL") }
    }

    static let defaultMaxSubagentIterations = 10
    /// Longer than `run_command`'s 10-minute default, so one long command fits in a turn (#402).
    static let defaultSubagentTurnTimeoutSeconds = 900

    var maxGoalIterations: Int {
        didSet { persistGuarded(.maxGoalIterations) { $0.set(maxGoalIterations, forKey: "MAX_GOAL_ITERATIONS") } }
    }
    /// The most turns a subagent's goal loop runs before it ends `failed` without `goal_complete`
    /// (#399). Separate from `maxGoalIterations`: a delegated unit is meant to be small, and each
    /// reprompt is a full model round charged to whoever delegated it.
    var maxSubagentIterations: Int {
        didSet { persistGuarded(.maxSubagentIterations) { $0.set(maxSubagentIterations, forKey: "MAX_SUBAGENT_ITERATIONS") } }
    }
    /// How many ticks a `/loop` runs before it stops (#190): its spend bound, since every tick
    /// resends the whole conversation. Re-running `/loop` renews it.
    var loopTickCap: Int {
        didSet { persistGuarded(.loopTickCap) { $0.set(loopTickCap, forKey: "LOOP_TICK_CAP") } }
    }
    static let defaultLoopTickCap = 50
    /// The most seconds one subagent turn may run before the subagent ends `timedOut` (#402). Per
    /// turn, reset on each reprompt: the whole subagent is bounded by this times its iteration cap,
    /// and in a job run by the run's own deadline.
    var subagentTurnTimeoutSeconds: Int {
        didSet { persistGuarded(.subagentTurnTimeoutSeconds) { $0.set(subagentTurnTimeoutSeconds, forKey: "SUBAGENT_TURN_TIMEOUT_SECONDS") } }
    }
    var maxDoneGateRetries: Int {
        didSet { persistGuarded(.maxDoneGateRetries) { $0.set(maxDoneGateRetries, forKey: "MAX_DONE_GATE_RETRIES") } }
    }
    var loopDetectionThreshold: Int {
        didSet { store.set(loopDetectionThreshold, forKey: "LOOP_DETECTION_THRESHOLD") }
    }
    var vibecopTimeoutSeconds: Int {
        didSet { persistGuarded(.vibecopTimeoutSeconds) { $0.set(vibecopTimeoutSeconds, forKey: "VIBECOP_TIMEOUT_SECONDS") } }
    }

    // MARK: Unattended jobs (#187 §0.1)
    //
    // The five global numbers a job's `JobPolicy` overrides per job. They are what an unattended
    // run is allowed to cost when nobody set anything: sane, not final. A *stored* value of 0 —
    // or, since nobody means "unlimited" by -1, anything below it — is "unset", and reads back as
    // the default below rather than as an instantly-exhausted budget or an unbounded one.

    /// The spec's figures (#187 §0.1), named because `JobLimits.resolve` falls back to them too:
    /// a number nobody set, a stored 0 and a stored negative must all land on the same limit.
    enum JobDefaults {
        static let perRunTokenBudget = 200_000
        static let dailyTokenBudget = 1_000_000
        static let globalDailyTokenBudget = 3_000_000
        static let maxRunsPerHour = 6

        /// The breaker floor for a watch (#283). Six an hour was sized for a schedule, where six
        /// fires is a lot; a watch fires once per save-burst, so ordinary editing paused it inside
        /// twenty minutes. Thirty is one run every two minutes sustained, which covers an editing
        /// session with headroom while still bounding a self-write loop the filter cannot see —
        /// finite is the property #282 leans on, not any particular figure. Deliberately below the
        /// 120 a watch firing at its 30-second ceiling for a whole hour could reach: the breaker is
        /// a backstop, not a rate limit that never fires.
        static let maxRunsPerHourForWatch = 30
        static let runTimeoutSeconds = 600
    }

    /// Tokens one run may spend before its turn is stopped.
    var jobPerRunTokenBudget: Int {
        didSet { persistGuarded(.jobPerRunTokenBudget) { $0.set(jobPerRunTokenBudget, forKey: "JOB_PER_RUN_TOKEN_BUDGET") } }
    }
    /// Tokens one job may spend across the local calendar day before it pauses.
    var jobDailyTokenBudget: Int {
        didSet { persistGuarded(.jobDailyTokenBudget) { $0.set(jobDailyTokenBudget, forKey: "JOB_DAILY_TOKEN_BUDGET") } }
    }
    /// Tokens every background run together may spend in a day. A job cannot raise this for
    /// itself — it is the ceiling on the whole unattended system.
    var jobGlobalDailyTokenBudget: Int {
        didSet { persistGuarded(.jobGlobalDailyTokenBudget) { $0.set(jobGlobalDailyTokenBudget, forKey: "JOB_GLOBAL_DAILY_TOKEN_BUDGET") } }
    }
    /// The breaker: this many runs of one job inside an hour pauses it.
    /// A watch's breaker, separately settable (#283). Per kind rather than per job, so that the
    /// figure a person chooses binds every watch — the ones created before the default changed
    /// included — and so the scheduled stepper stays honest about what it governs.
    var jobMaxRunsPerHourForWatch: Int {
        didSet { persistGuarded(.jobMaxRunsPerHourWatch) { $0.set(jobMaxRunsPerHourForWatch, forKey: "JOB_MAX_RUNS_PER_HOUR_WATCH") } }
    }

    var jobMaxRunsPerHour: Int {
        didSet { persistGuarded(.jobMaxRunsPerHour) { $0.set(jobMaxRunsPerHour, forKey: "JOB_MAX_RUNS_PER_HOUR") } }
    }
    /// Wall-clock seconds one run may take.
    var jobRunTimeoutSeconds: Int {
        didSet { persistGuarded(.jobRunTimeoutSeconds) { $0.set(jobRunTimeoutSeconds, forKey: "JOB_RUN_TIMEOUT_SECONDS") } }
    }

    var enableAdvancedPromptInjectionProtection: Bool {
        didSet { persistGuarded(.enablePromptInjectionProtection) { $0.set(enableAdvancedPromptInjectionProtection, forKey: "ENABLE_PROMPT_INJECTION_PROTECTION") } }
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
    /// - Parameter guardedSecrets: where the guarded settings live (#678). Production passes
    ///   nothing and gets `KeychainManager.shared`; a test passes its own in-memory manager.
    /// - Parameter guardedMayChange: whether this process may complete the guarded upgrade and
    ///   tidy defaults. Nil decides by role: only the app (and a test) does, since only the app
    ///   announces what it did.
    init(store storeOverride: UserDefaults? = nil, guardedSecrets: KeychainManager? = nil, guardedMayChange: Bool? = nil) {
        self.storeOverride = storeOverride
        // Bound locally because `self.store` is unreadable until every stored property is
        // initialised; it is the same store the instance property returns from here on.
        let store = storeOverride ?? IrisDefaults.store
        // Every read below comes from one snapshot: each `store` read can be a synchronous
        // round trip to cfprefsd, and ~60 of them per manager, on the main actor in hundreds of
        // tests, held every main-actor test in the parallel suite for seconds (#401).
        let saved = DefaultsSnapshot(store)

        // #678: the guarded settings come from the secrets item, read once here, and that read
        // also supplies the API keys below so a denied prompt is asked only once.
        let keychain = guardedSecrets ?? (storeOverride == nil ? KeychainManager.shared : nil)
        self.guardedKeychain = keychain
        var secretsRead: [String: String]?
        var guarded: [GuardedKey: String]?
        var guardedWrite: [String: String]?
        if let keychain {
            let read: GuardedSettings.ItemRead
            do { read = .read(try keychain.secretsOrThrow(service: KeychainManager.legacyService)) }
            catch KeychainManager.SecretsError.status(let status) { read = .unreadable(status) }
            catch { read = .unreadable(errSecInternalError) }
            if case .unreadable = read { keychain.blockWrites() }
            let mayChange = guardedMayChange
                ?? (ProcessRole.current == .app || NSClassFromString("XCTestCase") != nil)
            let decision = GuardedSettings.load(item: read, defaults: GuardedSettings.defaultsValues(store),
                                                defaultsMarker: store.bool(forKey: GuardedSettings.markerKey),
                                                mayChange: mayChange)
            for key in decision.removeFromDefaults { store.removeObject(forKey: key) }
            if decision.setDefaultsMarker { store.set(true, forKey: GuardedSettings.markerKey) }
            guarded = decision.values
            guardedWrite = decision.write
            self.guardedState = decision.state
            self.guardedNotices = decision.notices
            if case .read(let dict) = read { secretsRead = dict } else { secretsRead = [:] }
        }
        func guardedInt(_ key: GuardedKey, _ legacy: String) -> Int {
            guarded.map { Int($0[key] ?? "") ?? 0 } ?? saved.integer(forKey: legacy)
        }
        func guardedBool(_ key: GuardedKey, _ legacy: String) -> Bool {
            guarded.map { $0[key] == "true" } ?? saved.bool(forKey: legacy)
        }
        func guardedString(_ key: GuardedKey, _ legacy: String) -> String? {
            guarded.map { $0[key] ?? "" } ?? saved.string(forKey: legacy)
        }

        let savedProvider = saved.string(forKey: "PRIMARY_PROVIDER") ?? "Gemini"
        self.primaryProvider = savedProvider
        self.geminiAuthMode = saved.string(forKey: "GEMINI_AUTH_MODE") ?? GeminiAuthMode.apiKey.rawValue
        self.anthropicAuthMode = saved.string(forKey: "ANTHROPIC_AUTH_MODE") ?? AnthropicAuthMode.apiKey.rawValue
        self.anthropicVertexProject = saved.string(forKey: "ANTHROPIC_VERTEX_PROJECT") ?? ""
        let savedLocation = (saved.string(forKey: "ANTHROPIC_VERTEX_LOCATION") ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        self.anthropicVertexLocation = savedLocation.isEmpty ? Self.defaultVertexLocation : savedLocation
        
        self.appearanceTheme = saved.string(forKey: "APPEARANCE_THEME") ?? "system"
        
        if saved.object(forKey: "COPY_CHATS_AS_MARKDOWN") != nil {
            self.copyChatsAsMarkdown = saved.bool(forKey: "COPY_CHATS_AS_MARKDOWN")
        } else {
            self.copyChatsAsMarkdown = true
        }

        // Defaults on: the LEDs are what the window has always had, so an existing install keeps
        // them without touching Settings.
        if saved.object(forKey: "SHOW_MODEL_LEDS") != nil {
            self.showModelLEDs = saved.bool(forKey: "SHOW_MODEL_LEDS")
        } else {
            self.showModelLEDs = true
        }
        if saved.object(forKey: "STREAM_RESPONSES") != nil {
            self.streamResponses = saved.bool(forKey: "STREAM_RESPONSES")
        } else {
            self.streamResponses = true
        }

        if saved.object(forKey: "CHECKPOINT_AUTO_ADVANCE") != nil {
            self.checkpointAutoAdvance = saved.bool(forKey: "CHECKPOINT_AUTO_ADVANCE")
        } else {
            self.checkpointAutoAdvance = true
        }
        self.notificationMode = NotificationMode(rawValue: saved.string(forKey: "NOTIFICATION_MODE") ?? "")
            ?? .needsAttention

        let savedCascade = guardedInt(.maxSessionCascade, "MAX_SESSION_CASCADE")
        self.maxSessionCascade = savedCascade == 0 ? 8 : savedCascade

        self.defaultEmojiSkinTone = saved.object(forKey: "DEFAULT_EMOJI_SKIN_TONE") as? Int ?? SkinTone.none.rawValue
        
        var keychainSecrets = guardedWrite ?? secretsRead ?? KeychainManager.shared.loadSecrets()
        var secretsMigrated = guardedWrite != nil
        
        func migrate(key: String, dest: inout String) {
            if let keychainValue = keychainSecrets[key] {
                dest = keychainValue
            } else if let udValue = saved.string(forKey: key), !udValue.isEmpty {
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
        
        geminiBaseURL = guardedString(.geminiBaseURL, "GEMINI_BASE_URL") ?? ""
        anthropicBaseURL = guardedString(.anthropicBaseURL, "ANTHROPIC_BASE_URL") ?? ""
        openAIBaseURL = guardedString(.openAIBaseURL, "OPENAI_BASE_URL") ?? ""

        // Try reading old global models first for migration, else fallback to defaults.
        // The old global keys only migrate onto whichever provider was active at the time.
        let oldEasy = saved.string(forKey: "MODEL_EASY")
        let oldMedium = saved.string(forKey: "MODEL_MEDIUM")
        let oldHard = saved.string(forKey: "MODEL_HARD")

        func resolveModel(key: String, provider: String, migrated: String?, fallback: String) -> String {
            if let value = saved.string(forKey: key) {
                return value
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

        self.replayThinkingWithinTurn = saved.bool(forKey: "REPLAY_THINKING_WITHIN_TURN")

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
            (keychain ?? KeychainManager.shared).saveSecrets(keychainSecrets)
        }
        self.googleTokenExpiry = saved.double(forKey: "GOOGLE_TOKEN_EXPIRY")
        self.enableSandboxing = guardedBool(.enableSandboxing, "ENABLE_SANDBOXING")
        self.sandboxImage = saved.string(forKey: "SANDBOX_IMAGE") ?? "ubuntu:latest"
        let savedExchangeCap = saved.integer(forKey: "ARTIFACT_EXCHANGE_CAP_MB")
        self.artifactExchangeCapMB = savedExchangeCap <= 0 ? ArtifactLimits.defaultExchangeCapMB : savedExchangeCap
        let savedIdle = saved.integer(forKey: "SANDBOX_IDLE_TIMEOUT_MINUTES")
        self.sandboxIdleTimeoutMinutes = savedIdle == 0 ? 30 : savedIdle

        if let guarded {
            self.mainAgentSandboxDefault = SandboxPref(rawValue: guarded[.mainAgentSandboxDefault] ?? "") ?? .sandboxed
        } else if saved.object(forKey: "MAIN_AGENT_SANDBOX_DEFAULT") == nil {
            // First run with this key. Preserve the experience of users who already run
            // sandboxed (enableSandboxing on today == sandboxed main agent); fresh installs
            // default to host (the dual-layer model).
            let seeded: SandboxPref = saved.bool(forKey: "ENABLE_SANDBOXING") ? .sandboxed : .host
            self.mainAgentSandboxDefault = seeded
            store.set(seeded.rawValue, forKey: "MAIN_AGENT_SANDBOX_DEFAULT")
        } else {
            let raw = saved.string(forKey: "MAIN_AGENT_SANDBOX_DEFAULT") ?? "host"
            self.mainAgentSandboxDefault = SandboxPref(rawValue: raw) ?? .host
        }

        self.enableVibecop = guardedBool(.enableVibecop, "ENABLE_VIBECOP")
        let savedEngine = saved.string(forKey: "VIBECOP_ENGINE") ?? ""
        self.vibecopEngine = savedEngine.isEmpty ? "llama_cpp" : savedEngine
        
        let savedVibecop = saved.string(forKey: "VIBECOP_MODEL") ?? ""
        self.vibecopModel = savedVibecop.isEmpty ? "gemma-4-E2B-it-Q4_K_M.gguf" : savedVibecop
        self.vibecopCloudModel = saved.string(forKey: "VIBECOP_CLOUD_MODEL") ?? ""

        let savedMaxIters = guardedInt(.maxGoalIterations, "MAX_GOAL_ITERATIONS")
        self.maxGoalIterations = savedMaxIters == 0 ? 50 : savedMaxIters
        // Unset (0) or a hand-edited negative is the default, as for the job limits.
        let savedSubagentIters = guardedInt(.maxSubagentIterations, "MAX_SUBAGENT_ITERATIONS")
        self.maxSubagentIterations = savedSubagentIters <= 0 ? Self.defaultMaxSubagentIterations : savedSubagentIters
        let savedLoopCap = guardedInt(.loopTickCap, "LOOP_TICK_CAP")
        self.loopTickCap = savedLoopCap <= 0 ? Self.defaultLoopTickCap : savedLoopCap
        let savedTurnTimeout = guardedInt(.subagentTurnTimeoutSeconds, "SUBAGENT_TURN_TIMEOUT_SECONDS")
        self.subagentTurnTimeoutSeconds = savedTurnTimeout <= 0 ? Self.defaultSubagentTurnTimeoutSeconds : savedTurnTimeout
        let savedLoop = saved.integer(forKey: "LOOP_DETECTION_THRESHOLD")
        let savedGateRetries = guardedInt(.maxDoneGateRetries, "MAX_DONE_GATE_RETRIES")
        self.maxDoneGateRetries = savedGateRetries == 0 ? 3 : savedGateRetries
        self.loopDetectionThreshold = savedLoop == 0 ? 5 : savedLoop
        let savedVibecopTO = guardedInt(.vibecopTimeoutSeconds, "VIBECOP_TIMEOUT_SECONDS")
        self.vibecopTimeoutSeconds = savedVibecopTO == 0 ? 5 : savedVibecopTO

        // #187 §0.1. Unset (0) is the default, following the #208 pattern — and so is a negative,
        // which is a typo rather than a way to ask for no limit at all (a hand-edited plist, a
        // stepper driven past zero). Reading -1 as "unbounded" would take the ceiling off the
        // whole unattended system.
        let savedPerRun = guardedInt(.jobPerRunTokenBudget, "JOB_PER_RUN_TOKEN_BUDGET")
        self.jobPerRunTokenBudget = savedPerRun <= 0 ? JobDefaults.perRunTokenBudget : savedPerRun
        let savedDaily = guardedInt(.jobDailyTokenBudget, "JOB_DAILY_TOKEN_BUDGET")
        self.jobDailyTokenBudget = savedDaily <= 0 ? JobDefaults.dailyTokenBudget : savedDaily
        let savedGlobalDaily = guardedInt(.jobGlobalDailyTokenBudget, "JOB_GLOBAL_DAILY_TOKEN_BUDGET")
        self.jobGlobalDailyTokenBudget = savedGlobalDaily <= 0 ? JobDefaults.globalDailyTokenBudget : savedGlobalDaily
        let savedRunsPerHour = guardedInt(.jobMaxRunsPerHour, "JOB_MAX_RUNS_PER_HOUR")
        self.jobMaxRunsPerHour = savedRunsPerHour <= 0 ? JobDefaults.maxRunsPerHour : savedRunsPerHour
        let savedWatchRuns = guardedInt(.jobMaxRunsPerHourWatch, "JOB_MAX_RUNS_PER_HOUR_WATCH")
        self.jobMaxRunsPerHourForWatch = savedWatchRuns <= 0
            ? JobDefaults.maxRunsPerHourForWatch : savedWatchRuns
        let savedRunTimeout = guardedInt(.jobRunTimeoutSeconds, "JOB_RUN_TIMEOUT_SECONDS")
        self.jobRunTimeoutSeconds = savedRunTimeout <= 0 ? JobDefaults.runTimeoutSeconds : savedRunTimeout

        if let guarded {
            self.enableAdvancedPromptInjectionProtection = guarded[.enablePromptInjectionProtection] == "true"
        } else if saved.object(forKey: "ENABLE_PROMPT_INJECTION_PROTECTION") != nil {
            self.enableAdvancedPromptInjectionProtection = saved.bool(forKey: "ENABLE_PROMPT_INJECTION_PROTECTION")
        } else {
            self.enableAdvancedPromptInjectionProtection = true // Default to true
        }
        
        let savedPromptEngine = saved.string(forKey: "PROMPT_GUARD_ENGINE") ?? ""
        self.promptGuardEngine = savedPromptEngine.isEmpty ? "llama_cpp" : savedPromptEngine
        
        let savedPromptModel = saved.string(forKey: "PROMPT_GUARD_MODEL") ?? ""
        self.promptGuardModel = savedPromptModel.isEmpty ? "Qwen3.5-2B-Q4_K_M.gguf" : savedPromptModel
        
        // Default to the accurate DeBERTa-v3 ONNX guard. The old distilbert CoreML default
        // over-blocked ordinary tool output; see docs/prompt_guard_coreml.md.
        let savedCoreMLModel = saved.string(forKey: "PROMPT_GUARD_COREML_MODEL") ?? ""
        self.promptGuardCoreMLModel = savedCoreMLModel.isEmpty ? "https://luthen.scromp.net/iris/deberta-v3-base-prompt-injection-v2.onnx.zip" : savedCoreMLModel

        self.auxiliaryVisionEngine = saved.string(forKey: "AUXILIARY_VISION_ENGINE") ?? ""
        self.auxiliaryVisionModel = saved.string(forKey: "AUXILIARY_VISION_MODEL") ?? ""
    }
    
    var isConfigured: Bool {
        Self.isConfigured(provider: primaryProvider, geminiAuthMode: geminiAuthMode, geminiAPIKey: geminiAPIKey,
                          anthropicAuthMode: anthropicAuthMode, anthropicAPIKey: anthropicAPIKey,
                          anthropicVertexProject: anthropicVertexProject, openAIAPIKey: openAIAPIKey)
    }

    /// The pure rule behind `isConfigured`, so a test can state every branch with literals and
    /// never write a key into the process-global Keychain store (invariant 7).
    static func isConfigured(provider: String, geminiAuthMode: String, geminiAPIKey: String,
                             anthropicAuthMode: String, anthropicAPIKey: String, anthropicVertexProject: String,
                             openAIAPIKey: String) -> Bool {
        func present(_ s: String) -> Bool { !s.trimmingCharacters(in: .whitespaces).isEmpty }
        switch provider {
        case LLMProvider.anthropic.rawValue:
            if anthropicAuthMode == AnthropicAuthMode.vertex.rawValue { return present(anthropicVertexProject) }
            return present(anthropicAPIKey)
        case LLMProvider.openai.rawValue:
            return present(openAIAPIKey)
        default:
            if geminiAuthMode == GeminiAuthMode.adc.rawValue { return true }
            return present(geminiAPIKey)
        }
    }
    
    private func updateSecret(key: String, value: String) {
        var secrets = KeychainManager.shared.loadSecrets()
        secrets[key] = value
        KeychainManager.shared.saveSecrets(secrets)
        secretsCache = nil
    }
}

/// One `dictionaryRepresentation()` of a store, read with `UserDefaults`' own coercions, so that
/// `ConfigManager.init` asks cfprefsd once rather than once per key (#401). The representation
/// covers the same search list `object(forKey:)` does: arguments, the suite, the global domain and
/// registered defaults.
struct DefaultsSnapshot {
    private let values: [String: Any]

    init(_ store: UserDefaults) { values = store.dictionaryRepresentation() }

    func object(forKey key: String) -> Any? { values[key] }

    func string(forKey key: String) -> String? {
        switch values[key] {
        case let s as String: return s
        case let n as NSNumber: return n.stringValue
        default: return nil
        }
    }

    func integer(forKey key: String) -> Int {
        switch values[key] {
        case let n as NSNumber: return n.intValue
        // Strict, as UserDefaults is: leading space and a sign, then digits to the end ("7 " is 0).
        case let s as String: return Int(s.drop { $0 == " " || $0 == "\t" }) ?? 0
        default: return 0
        }
    }

    func double(forKey key: String) -> Double {
        switch values[key] {
        case let n as NSNumber: return n.doubleValue
        case let s as String: return (s as NSString).doubleValue
        default: return 0
        }
    }

    func bool(forKey key: String) -> Bool {
        switch values[key] {
        case let n as NSNumber: return n.boolValue
        // Only "yes", "true" (any case) and "1": UserDefaults reads "2" or "-1" as false.
        case let s as String:
            let lowered = s.lowercased()
            return lowered == "yes" || lowered == "true" || s == "1"
        default: return false
        }
    }
}
