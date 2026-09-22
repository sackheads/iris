import SwiftUI
import KeyboardShortcuts

/// The five global numbers an unattended job is bounded by (#187 §0.1, §9), as one value type so
/// Settings renders five identical steppers from a list and a test can drive the clamp, the label
/// and the round trip through `ConfigManager` without SwiftUI.
///
/// Zero is the resting state, not a hole: `JobLimits.resolve` reads a non-positive global back as
/// the built-in default, so a stepper wound down to zero means "use the figure Iris ships with"
/// rather than "no budget". A job's own `JobPolicy` is where zero means unlimited, and that is not
/// settable from here — the one ceiling that matters most is the one nobody edits by accident.
enum JobLimitSetting: String, CaseIterable, Sendable {
    case perRunTokens, dailyTokens, globalDailyTokens, maxRunsPerHour, runTimeoutSeconds

    var configKey: String {
        switch self {
        case .perRunTokens: return "JOB_PER_RUN_TOKEN_BUDGET"
        case .dailyTokens: return "JOB_DAILY_TOKEN_BUDGET"
        case .globalDailyTokens: return "JOB_GLOBAL_DAILY_TOKEN_BUDGET"
        case .maxRunsPerHour: return "JOB_MAX_RUNS_PER_HOUR"
        case .runTimeoutSeconds: return "JOB_RUN_TIMEOUT_SECONDS"
        }
    }

    var title: String {
        switch self {
        case .perRunTokens: return "Tokens one run may spend"
        case .dailyTokens: return "Tokens one job may spend a day"
        case .globalDailyTokens: return "Tokens all jobs may spend a day"
        case .maxRunsPerHour: return "Runs per job per hour"
        case .runTimeoutSeconds: return "Wall clock one run may take"
        }
    }

    var help: String {
        switch self {
        case .perRunTokens:
            return "A run that reaches this is stopped between model rounds and its card says so."
        case .dailyTokens:
            return "A job whose spend for the local day has reached this pauses instead of firing."
        case .globalDailyTokens:
            return "The ceiling on every background run together. A job cannot raise it for itself."
        case .maxRunsPerHour:
            return "The breaker: a job that has already run this many times in the last hour pauses instead of firing again."
        case .runTimeoutSeconds:
            return "A run still going at this deadline is closed as failed and the Mac is let go back to sleep."
        }
    }

    var defaultValue: Int {
        switch self {
        case .perRunTokens: return ConfigManager.JobDefaults.perRunTokenBudget
        case .dailyTokens: return ConfigManager.JobDefaults.dailyTokenBudget
        case .globalDailyTokens: return ConfigManager.JobDefaults.globalDailyTokenBudget
        case .maxRunsPerHour: return ConfigManager.JobDefaults.maxRunsPerHour
        case .runTimeoutSeconds: return ConfigManager.JobDefaults.runTimeoutSeconds
        }
    }

    /// How far one click moves the number — a click has to be worth making on figures this large,
    /// and worth trusting on figures this small.
    var step: Int {
        switch self {
        case .perRunTokens: return 50_000
        case .dailyTokens, .globalDailyTokens: return 100_000
        case .maxRunsPerHour: return 1
        case .runTimeoutSeconds: return 60
        }
    }

    var range: ClosedRange<Int> {
        switch self {
        case .perRunTokens: return 0...10_000_000
        case .dailyTokens: return 0...50_000_000
        case .globalDailyTokens: return 0...100_000_000
        case .maxRunsPerHour: return 0...1_000
        case .runTimeoutSeconds: return 0...86_400
        }
    }

    func value(in config: ConfigManager) -> Int {
        switch self {
        case .perRunTokens: return config.jobPerRunTokenBudget
        case .dailyTokens: return config.jobDailyTokenBudget
        case .globalDailyTokens: return config.jobGlobalDailyTokenBudget
        case .maxRunsPerHour: return config.jobMaxRunsPerHour
        case .runTimeoutSeconds: return config.jobRunTimeoutSeconds
        }
    }

    /// What the stepper *steps from*, which is not always what is held. A 0 means "use the figure
    /// Iris ships with", and the row says so — so one click on "+" beside
    /// "Runs per job per hour: default (6)" has to produce 7, not 1. Stepping from the 0 instead
    /// tightened every limit by an order of magnitude with a gesture that reads as loosening it:
    /// 6 → 1, 200,000 tokens → 50,000, a ten-minute run → sixty seconds. (`ConfigManager.init`
    /// substitutes the default for a stored 0 at launch, so the row a session *starts* on shows
    /// a real figure; the 0 is what winding one all the way down leaves behind.)
    ///
    /// Downwards it reaches `default - step`, and the range's own floor of 0 is the way back:
    /// stepping down past the smallest real setting lands on 0, which reads as "default" again
    /// and is exactly what `JobLimits.resolve` treats as unset. That is the reset affordance, and
    /// it costs no extra control.
    func effectiveValue(in config: ConfigManager) -> Int {
        let stored = value(in: config)
        return stored > 0 ? stored : defaultValue
    }

    /// Clamped at zero on the way in. A negative figure is never a third answer — nobody writes -1
    /// to mean unlimited — and storing one would only have `JobLimits.resolve` read it back as the
    /// default anyway, from a stepper that claimed otherwise.
    func set(_ newValue: Int, in config: ConfigManager) {
        let clamped = max(0, newValue)
        switch self {
        case .perRunTokens: config.jobPerRunTokenBudget = clamped
        case .dailyTokens: config.jobDailyTokenBudget = clamped
        case .globalDailyTokens: config.jobGlobalDailyTokenBudget = clamped
        case .maxRunsPerHour: config.jobMaxRunsPerHour = clamped
        case .runTimeoutSeconds: config.jobRunTimeoutSeconds = clamped
        }
    }

    /// What the stepper reads. Zero says which figure it will actually use, because a row saying
    /// "Runs per job per hour: 0" otherwise reads as a job that can never run.
    func label(_ value: Int) -> String {
        guard value > 0 else { return "\(title): default (\(grouped(defaultValue))\(unit))" }
        return "\(title): \(grouped(value))\(unit)"
    }

    private var unit: String { self == .runTimeoutSeconds ? " s" : "" }

    /// Grouped in the user's own locale, like every other figure in Settings.
    private func grouped(_ value: Int) -> String {
        let formatter = NumberFormatter()
        formatter.numberStyle = .decimal
        return formatter.string(from: NSNumber(value: value)) ?? "\(value)"
    }
}

struct SettingsView: View {
    @Bindable private var config = ConfigManager.shared
    @State private var state = AppState.shared
    @State private var isInstallingContainer = false
    @State private var installError: String?
    @State private var downloader = ModelDownloader.shared
    @State private var showingDownloadError = false
    
    @State private var availableUpdate: ReleaseInfo?
    @State private var isCheckingForUpdates = false
    @State private var updateCheckStatusMessage: String?
    
    @State private var vibecopTestStatus: String?
    @State private var isTestingVibecopModel = false
    @State private var tier2TestStatus: String?
    @State private var tier3TestStatus: String?

    // #206 "Test Models" — probes every configured primary-provider tier at once.
    @State private var isTestingModels = false
    @State private var hasRunModelTest = false
    @State private var modelTestTargets: [(label: String, model: String)] = []
    @State private var modelTestResultsByLabel: [String: ModelProbeResult] = [:]
    @State private var modelTestTask: Task<Void, Never>?

    // #207 "List Available Models…" — what the configured account can reach.
    @State private var showModelListSheet = false
    @State private var isListingModels = false
    @State private var modelListResults: [ModelInfo] = []
    @State private var modelListError: String?
    @State private var modelListTask: Task<Void, Never>?
    
    // Ollama model discovery state
    @State private var ollamaDaemonRunning: Bool? = nil  // nil = unchecked
    @State private var ollamaInstalledModels: [String] = []
    @State private var isProbingOllama = false
    @State private var isPullingOllamaModel = false
    @State private var ollamaPullProgress: String?
    @State private var ollamaPullError: String?
    
    // Google Workspace / gcloud state
    @State private var gcloudAvailable = false
    @State private var gcloudAccount: String?
    @State private var gcloudProject: String?
    @State private var workspaceAPIs: [GCloudHelper.APIInfo] = GCloudHelper.requiredAPIs
    @State private var isCheckingAPIs = false
    @State private var showSetupGuide = false
    
    var body: some View {
        TabView {
            // MARK: - General Tab
            Form {
                Section(header: Text("Global Shortcuts").font(.headline)) {
                    KeyboardShortcuts.Recorder("Toggle Iris:", name: .toggleIris)
                }
                .padding(.bottom)
                
                Section(header: Text("Preferences").font(.headline)) {
                    Toggle("Copy chats as Markdown (default)", isOn: $config.copyChatsAsMarkdown)
                        .help("If disabled, copies will default to plain text without markdown formatting.")
                    Toggle("Stream responses as they are generated", isOn: $config.streamResponses)
                        .help("Show Iris's reply while the model is still writing it. Turn off to receive whole replies.")
                    Picker("Default emoji skin tone", selection: $config.defaultEmojiSkinTone) {
                        Text("Default 👋").tag(SkinTone.none.rawValue)
                        Text("Light 👋🏻").tag(SkinTone.light.rawValue)
                        Text("Medium-Light 👋🏼").tag(SkinTone.mediumLight.rawValue)
                        Text("Medium 👋🏽").tag(SkinTone.medium.rawValue)
                        Text("Medium-Dark 👋🏾").tag(SkinTone.mediumDark.rawValue)
                        Text("Dark 👋🏿").tag(SkinTone.dark.rawValue)
                    }
                }
                .padding(.bottom)

                Section(header: Text("Goals").font(.headline)) {
                    Toggle("Auto-advance checkpoints the grader passes cleanly", isOn: $config.checkpointAutoAdvance)
                        .help("A clean grade means the independent grader found nothing wrong, not that you looked — so a grader's mistake advances unseen too. Turn this off to stop at every checkpoint. Takes effect at the next checkpoint.")
                    // 1 rather than 0: a stored 0 is how `maxDoneGateRetries` encodes "unset", and
                    // reads back as the default 3 — so a 0 here would silently not mean zero.
                    Stepper("Retries before a goal finishes without passing: \(config.maxDoneGateRetries)",
                            value: Binding(get: { config.maxDoneGateRetries },
                                           set: { config.maxDoneGateRetries = min(max($0, 1), 10) }), in: 1...10)
                        .help("How many times the done-gate sends Iris back to work after the grader finds a criterion unmet. After this many attempts the goal finishes anyway, labelled as having completed without passing.")
                }
                .padding(.bottom)
            }
            .formStyle(.grouped)
            .padding(20)
            .tabItem {
                Label("General", systemImage: "gearshape")
            }
            
            // MARK: - Models Tab
            Form {
                Section(header: Text("LLM Providers").font(.headline)) {
                    Picker("Primary Provider", selection: $config.primaryProvider) {
                        ForEach(LLMProvider.allCases) { provider in
                            Text(provider.rawValue).tag(provider.rawValue)
                        }
                    }
                    .padding(.bottom)
                    
                    if config.primaryProvider == LLMProvider.gemini.rawValue {
                        Picker("Authentication Method", selection: $config.geminiAuthMode) {
                            ForEach(GeminiAuthMode.allCases) { mode in
                                Text(mode.rawValue).tag(mode.rawValue)
                            }
                        }
                        
                        if config.geminiAuthMode == GeminiAuthMode.adc.rawValue {
                            Text("Using Application Default Credentials (ADC). Authenticate locally via:\n`gcloud auth application-default login --scopes=\"https://www.googleapis.com/auth/cloud-platform,https://www.googleapis.com/auth/generative-language\"`")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        } else {
                            SecureField("Gemini API Key", text: $config.geminiAPIKey)
                                .help("Required for Gemini models to function.")
                        }
                        
                        TextField("Gemini Base URL (Optional)", text: $config.geminiBaseURL)
                            .help("Leave blank for default endpoint")
                        TextField("Easy Subagent Model", text: $config.geminiModelEasy)
                            .help("Used for simple and repetitive tasks.")
                        TextField("Primary / Medium Model", text: $config.geminiModelMedium)
                            .help("Used for standard generation and reasoning.")
                        TextField("Hard Subagent Model", text: $config.geminiModelHard)
                            .help("Used for complex reasoning and evaluation.")
                    } else if config.primaryProvider == LLMProvider.anthropic.rawValue {
                        SecureField("Anthropic API Key", text: $config.anthropicAPIKey)
                            .help("Required for Anthropic Claude models to function.")
                        TextField("Anthropic Base URL (Optional)", text: $config.anthropicBaseURL)
                            .help("Leave blank for default endpoint")
                        TextField("Easy Subagent Model", text: $config.anthropicModelEasy)
                            .help("Used for simple and repetitive tasks.")
                        TextField("Primary / Medium Model", text: $config.anthropicModelMedium)
                            .help("Used for standard generation and reasoning.")
                        TextField("Hard Subagent Model", text: $config.anthropicModelHard)
                            .help("Used for complex reasoning and evaluation.")
                    } else if config.primaryProvider == LLMProvider.openai.rawValue {
                        SecureField("OpenAI API Key", text: $config.openAIAPIKey)
                            .help("Required for OpenAI GPT/o1 models to function.")
                        TextField("OpenAI Base URL (Optional)", text: $config.openAIBaseURL)
                            .help("Overrides the default openai endpoint. Useful for deepseek or local compatible servers.")
                        TextField("Easy Subagent Model", text: $config.openaiModelEasy)
                            .help("Used for simple and repetitive tasks.")
                        TextField("Primary / Medium Model", text: $config.openaiModelMedium)
                            .help("Used for standard generation and reasoning.")
                        TextField("Hard Subagent Model", text: $config.openaiModelHard)
                            .help("Used for complex reasoning and evaluation.")
                    }

                    modelToolsView()
                }
                .padding(.bottom)

                Section(header: Text("Auxiliary Vision Engine").font(.headline)) {
                    Picker("Engine", selection: $config.auxiliaryVisionEngine) {
                        Text("None").tag("")
                        Text("Ollama (Local Daemon)").tag("ollama")
                        Text("Cloud (Primary Provider)").tag("cloud")
                    }
                    
                    if !config.auxiliaryVisionEngine.isEmpty {
                        TextField("Vision Model Name", text: $config.auxiliaryVisionModel)
                            .help("The model to use for vision processing when primary model is non-vision (e.g. llama3.2-vision, gemma4:12b)")
                    }
                    
                    Text("When your active primary model does not support vision, Iris routes image attachments through this auxiliary vision engine to generate descriptive text.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .padding(.bottom)
            }
            .formStyle(.grouped)
            .padding(20)
            .tabItem {
                Label("Models", systemImage: "cpu")
            }
            .sheet(isPresented: $showModelListSheet) {
                ModelListSheet(
                    config: config,
                    provider: LLMProvider(rawValue: config.primaryProvider) ?? .gemini,
                    isLoading: isListingModels,
                    error: modelListError,
                    models: modelListResults,
                    onClose: { showModelListSheet = false },
                    onRetry: { fetchModelList() }
                )
            }
            .onChange(of: showModelListSheet) { _, isShowing in
                // The sheet can be dismissed by Esc/swipe as well as the Close button, and none of
                // those routes run `onClose` — cancel the in-flight listing whichever way it closed.
                if !isShowing { modelListTask?.cancel() }
            }
            .onChange(of: config.primaryProvider) { _, _ in
                // Rows from the old provider's models are meaningless once the provider changes.
                modelTestTask?.cancel()
                isTestingModels = false
                hasRunModelTest = false
                modelTestTargets = []
                modelTestResultsByLabel = [:]
            }
            .onDisappear {
                modelTestTask?.cancel()
                modelListTask?.cancel()
            }

            // MARK: - Vibecop Tab
            Form {
                Section(header: Text("Vibecop Guardian").font(.headline)) {
                    Toggle("Enable Vibecop", isOn: $config.enableVibecop)
                    
                    if config.enableVibecop {
                        Picker("Engine", selection: $config.vibecopEngine) {
                            Text("Llama.cpp (Embedded)").tag("llama_cpp")
                            Text("Ollama (Local Daemon)").tag("ollama")
                            Text("MLX (Apple Silicon)").tag("mlx")
                            Text("Cloud (Primary Provider)").tag("cloud")
                        }
                        
                        if config.vibecopEngine == "llama_cpp" {
                            TextField("GGUF Model", text: $config.vibecopModel)
                                .help("The GGUF model file name (must be in ~/.iris/models/)")
                            
                            let isDownloaded = downloader.isModelDownloaded(name: config.vibecopModel)
                            if !isDownloaded {
                                let isVibecopDownloading = downloader.isDownloading && downloader.currentDownloadName == config.vibecopModel
                                if isVibecopDownloading {
                                    HStack {
                                        ProgressView(value: downloader.progress)
                                            .progressViewStyle(.linear)
                                        Text("\(Int(downloader.progress * 100))%")
                                            .font(.caption)
                                    }
                                } else {
                                    Button("Download Model") {
                                        Task {
                                            await downloader.downloadModel(name: config.vibecopModel, assignResolvedNameTo: \.vibecopModel)
                                        }
                                    }
                                    Text("This will download approx. \(downloader.approximateSize(for: config.vibecopModel)) of weights to your disk.")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                                
                                if let error = downloader.error {
                                    Text("Error: \(error)").foregroundColor(.red).font(.caption)
                                }
                            } else {
                                HStack {
                                    Text("✅ Model is downloaded and ready.")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                    
                                    vibecopTestButton()
                                }
                            }
                        } else if config.vibecopEngine == "ollama" {
                            // Ollama-specific: probe daemon, then list models, offer pull
                            HStack {
                                if isProbingOllama && ollamaDaemonRunning == nil {
                                    ProgressView().scaleEffect(0.6)
                                    Text("Checking Ollama daemon…").font(.caption).foregroundColor(.secondary)
                                } else if ollamaDaemonRunning == false {
                                    Text("Ollama daemon not running").font(.caption).foregroundColor(.red)
                                } else if ollamaInstalledModels.isEmpty {
                                    Text("No models installed").font(.caption).foregroundColor(.secondary)
                                } else {
                                    Picker("Ollama Model", selection: $config.vibecopModel) {
                                        ForEach(ollamaInstalledModels, id: \.self) { name in
                                            Text(name).tag(name)
                                        }
                                    }
                                }
                                
                                Button {
                                    Task { await probeOllamaModels() }
                                } label: {
                                    Image(systemName: "arrow.clockwise")
                                }
                                .buttonStyle(.borderless)
                                .help("Refresh installed Ollama models")
                                .disabled(isProbingOllama)
                            }
                            .onAppear {
                                if ollamaDaemonRunning == nil && !isProbingOllama {
                                    Task { await probeOllamaModels() }
                                }
                            }
                            
                            // Daemon-down banner
                            if ollamaDaemonRunning == false {
                                VStack(alignment: .leading, spacing: 4) {
                                    Text("⚠️ The Ollama daemon is not reachable at localhost:11434.")
                                        .font(.caption).foregroundColor(.orange)
                                    Text("Start it with: ollama serve")
                                        .font(.caption).monospaced().foregroundColor(.secondary)
                                }
                                .padding(.vertical, 4)
                            }
                            
                            // Offer to pull the default model if not installed
                            if ollamaDaemonRunning == true {
                                let defaultModel = "gemma4:12b"
                                if !ollamaInstalledModels.contains(defaultModel) {
                                    HStack {
                                        if isPullingOllamaModel {
                                            ProgressView().scaleEffect(0.6)
                                            if let progress = ollamaPullProgress {
                                                Text(progress).font(.caption).foregroundColor(.secondary)
                                            }
                                        } else {
                                            Button("Pull \(defaultModel)") {
                                                Task { await pullOllamaDefaultModel(defaultModel) }
                                            }
                                            .disabled(isProbingOllama)
                                            Text("Recommended for Vibecop — small, fast, capable.")
                                                .font(.caption).foregroundColor(.secondary)
                                        }
                                    }
                                    
                                    if let error = ollamaPullError {
                                        Text("Error: \(error)").font(.caption).foregroundColor(.red)
                                    }
                                }
                            }
                            
                            HStack {
                                if ollamaDaemonRunning == false {
                                    Text("⏳ Waiting for Ollama daemon…").font(.caption).foregroundColor(.secondary)
                                } else if ollamaInstalledModels.contains(config.vibecopModel) {
                                    Text("✅ Model is available in Ollama.")
                                        .foregroundColor(.green)
                                        .font(.caption)
                                } else if !config.vibecopModel.isEmpty && !ollamaInstalledModels.isEmpty {
                                    Text("⚠️ \"\(config.vibecopModel)\" not found in Ollama.")
                                        .foregroundColor(.orange)
                                        .font(.caption)
                                }
                                
                                if ollamaDaemonRunning == true {
                                    vibecopTestButton()
                                }
                            }
                        } else {
                            TextField("Ollama/Cloud Model", text: $config.vibecopModel)
                                .help("The external model to use for Vibecop background evaluation (e.g. qwen3.5, gemma4:12b)")
                            
                            HStack {
                                Text("✅ Assuming model is ready via external daemon.")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                
                                vibecopTestButton()
                            }
                        }
                        
                        Text("Vibecop runs periodically in the background to evaluate the conversation state.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                .padding(.bottom)
            }
            .formStyle(.grouped)
            .padding(20)
            .tabItem {
                Label("Vibecop", systemImage: "eye.circle")
            }
                       // MARK: - Security Tab
            Form {
                Section(header: Text("General Protection").font(.headline)) {
                    Toggle("Enable Protection (Tier 2 & 3)", isOn: $config.enableAdvancedPromptInjectionProtection)
                    if config.enableAdvancedPromptInjectionProtection {
                        Text("Iris will intercept untrusted data from the web before your main LLM reads it, protecting you from adversarial attacks and hidden instructions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                
                if config.enableAdvancedPromptInjectionProtection {
                    Section(header: Text("Tier 2: Fast Local Classifier").font(.headline)) {
                        Text("Rapidly classifies text as safe or malicious on-device — CoreML (Apple Neural Engine) or ONNX Runtime (CPU).")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        TextField("Model .zip URL or Path", text: $config.promptGuardCoreMLModel)
                            .help("Provide a URL to a .mlmodelc.zip (CoreML) or .onnx.zip (ONNX Runtime) to download and enable the Tier 2 classifier.")
                        
                        if !config.promptGuardCoreMLModel.isEmpty {
                            // #210 fix round 1: routed through the shared helpers so this can
                            // never disagree with InjectionGuard.tier2Provisioning/ModelLEDBar.
                            let coreMLFilename = ModelDownloader.resolvedFilename(for: config.promptGuardCoreMLModel)
                            let isCoreMLDownloaded = downloader.isCoreMLModelDownloaded(name: config.promptGuardCoreMLModel)
                            
                            if !isCoreMLDownloaded {
                                let isTier2Downloading = downloader.isDownloading && downloader.currentDownloadName == coreMLFilename
                                if isTier2Downloading {
                                    HStack {
                                        ProgressView(value: downloader.progress)
                                            .progressViewStyle(.linear)
                                        Text("\(Int(downloader.progress * 100))%")
                                            .font(.caption)
                                    }
                                } else {
                                    Button("Download Model") {
                                        Task {
                                            await downloader.downloadModel(name: config.promptGuardCoreMLModel)
                                        }
                                    }
                                    Text("Downloads and unzips the model to enable Tier 2 locally (~650 MB for the default DeBERTa model).")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                            } else {
                                HStack {
                                    Text("✅ Tier 2 model is present.")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        
                                    Button("Test Model") {
                                        Task {
                                            do {
                                                try await CoreMLEvaluator.shared.loadModelIfNeeded()
                                                if CoreMLEvaluator.shared.hasModelLoaded {
                                                    _ = try await CoreMLEvaluator.shared.evaluate(text: "Hello")
                                                    tier2TestStatus = "✅ Success"
                                                } else {
                                                    tier2TestStatus = "❌ Failed: Model not loaded"
                                                }
                                            } catch {
                                                tier2TestStatus = "❌ Failed: \(error.localizedDescription)"
                                            }
                                        }
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                    
                                    if let status = tier2TestStatus {
                                        Text(status).font(.caption).foregroundColor(status.starts(with: "✅") ? .green : .red)
                                    }
                                }
                            }
                        }
                    }
                    
                    Section(header: Text("Tier 3: Canary Probe").font(.headline)) {
                        Text("This model is used as a sacrificial canary to test untrusted payloads for malicious instructions.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                            
                        Picker("Engine", selection: $config.promptGuardEngine) {
                            Text("Llama.cpp (Embedded)").tag("llama_cpp")
                            Text("Ollama (Local Daemon)").tag("ollama")
                            Text("MLX (Apple Silicon)").tag("mlx")
                            Text("Cloud (Primary Provider)").tag("cloud")
                        }
                        
                        if config.promptGuardEngine == "llama_cpp" {
                            TextField("GGUF Model", text: $config.promptGuardModel)
                                .help("The GGUF model file name for the Tier 3 Canary (must be in ~/.iris/models/)")
                            
                            let isDownloaded = downloader.isModelDownloaded(name: config.promptGuardModel)
                            if !isDownloaded {
                                let isTier3Downloading = downloader.isDownloading && downloader.currentDownloadName == config.promptGuardModel
                                if isTier3Downloading {
                                    HStack {
                                        ProgressView(value: downloader.progress)
                                            .progressViewStyle(.linear)
                                        Text("\(Int(downloader.progress * 100))%")
                                            .font(.caption)
                                    }
                                } else {
                                    Button("Download Model") {
                                        Task {
                                            await downloader.downloadModel(name: config.promptGuardModel, assignResolvedNameTo: \.promptGuardModel)
                                        }
                                    }
                                    Text("This will download approx. \(downloader.approximateSize(for: config.promptGuardModel)) of weights to your disk.")
                                        .font(.caption)
                                        .foregroundColor(.orange)
                                }
                                
                                if let error = downloader.error {
                                    Text("Error: \(error)").foregroundColor(.red).font(.caption)
                                }
                            } else {
                                HStack {
                                    Text("✅ Model is downloaded and ready.")
                                        .font(.caption)
                                        .foregroundColor(.green)
                                        
                                    Button("Test Model") {
                                        Task {
                                            do {
                                                let engineType = AuxiliaryEngineType(rawValue: config.promptGuardEngine) ?? .llamaCPP
                                                let auxConfig = AuxiliaryModelConfig(role: "promptGuard", engineType: engineType, modelPathOrName: config.promptGuardModel)
                                                let engine = try await AuxiliaryModelManager.shared.getEngine(for: "promptGuard", config: auxConfig)
                                                _ = try await engine.generate(prompt: "Hello", jsonSchema: nil)
                                                tier3TestStatus = "✅ Success"
                                            } catch {
                                                tier3TestStatus = "❌ Failed: \(error.localizedDescription)"
                                            }
                                        }
                                    }
                                    .buttonStyle(.link)
                                    .font(.caption)
                                    
                                    if let status = tier3TestStatus {
                                        Text(status).font(.caption).foregroundColor(status.starts(with: "✅") ? .green : .red)
                                    }
                                }
                            }
                        } else {
                            TextField("Model Name", text: $config.promptGuardModel)
                                .help("The model to use for the Tier 3 Canary evaluation")
                                
                            HStack {
                                Text("✅ Assuming model is ready via external daemon.")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                    
                                Button("Test Model") {
                                    Task {
                                        do {
                                            let engineType = AuxiliaryEngineType(rawValue: config.promptGuardEngine) ?? .llamaCPP
                                            let auxConfig = AuxiliaryModelConfig(role: "promptGuard", engineType: engineType, modelPathOrName: config.promptGuardModel)
                                            let engine = try await AuxiliaryModelManager.shared.getEngine(for: "promptGuard", config: auxConfig)
                                            _ = try await engine.generate(prompt: "Hello", jsonSchema: nil)
                                            tier3TestStatus = "✅ Success"
                                        } catch {
                                            tier3TestStatus = "❌ Failed: \(error.localizedDescription)"
                                        }
                                    }
                                }
                                .buttonStyle(.link)
                                .font(.caption)
                                
                                if let status = tier3TestStatus {
                                    Text(status).font(.caption).foregroundColor(status.starts(with: "✅") ? .green : .red)
                                }
                            }
                        }
                    }
                }
            }
            .padding(.bottom)
            .formStyle(.grouped)
            .padding(20)
            .tabItem {
                Label("Security", systemImage: "lock.shield")
            }
            
            // MARK: - Integrations Tab
            Form {
                Section(header: Text("Google Workspace (OAuth)").font(.headline)) {
                    
                    // ── Setup Guide ──
                    DisclosureGroup(isExpanded: $showSetupGuide) {
                        VStack(alignment: .leading, spacing: 12) {
                            
                            // ── gcloud CLI path (primary) ──
                            Group {
                                Text("Option 1: gcloud CLI (recommended)")
                                    .font(.subheadline).fontWeight(.semibold)
                                
                                VStack(alignment: .leading, spacing: 6) {
                                    stepText("1", "Check gcloud is installed & authenticated:")
                                    if gcloudAvailable {
                                        if let account = gcloudAccount {
                                            HStack(spacing: 4) {
                                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                                                Text("Authenticated as \(account)").font(.caption)
                                            }
                                        } else {
                                            HStack(spacing: 4) {
                                                Image(systemName: "xmark.circle.fill").foregroundColor(.orange)
                                                Text("Not authenticated — run gcloud auth login").font(.caption)
                                            }
                                        }
                                        if let project = gcloudProject {
                                            HStack(spacing: 4) {
                                                Image(systemName: "folder.fill").foregroundColor(.secondary)
                                                Text("Project: \(project)").font(.caption).foregroundColor(.secondary)
                                            }
                                        }
                                    } else {
                                        HStack(spacing: 4) {
                                            Image(systemName: "xmark.circle.fill").foregroundColor(.red)
                                            Text("gcloud CLI not found on PATH")
                                                .font(.caption).foregroundColor(.red)
                                        }
                                        Text("Install: brew install google-cloud-sdk")
                                            .font(.caption).monospaced().foregroundColor(.secondary)
                                    }
                                    
                                    stepText("2", "Enable required Google APIs:")
                                    if isCheckingAPIs {
                                        HStack { ProgressView().scaleEffect(0.6); Text("Checking…").font(.caption) }
                                    } else {
                                        ForEach($workspaceAPIs) { $api in
                                            HStack {
                                                Image(systemName: api.enabled ? "checkmark.circle.fill" : "circle")
                                                    .foregroundColor(api.enabled ? .green : .secondary)
                                                Text(api.displayName).font(.caption)
                                                Spacer()
                                                if !api.enabled && gcloudAvailable {
                                                    Button("Enable") {
                                                        Task {
                                                            isCheckingAPIs = true
                                                            await GCloudHelper.enableAPI(api.id)
                                                            await refreshAPIStatus()
                                                            isCheckingAPIs = false
                                                        }
                                                    }
                                                    .buttonStyle(.link).font(.caption)
                                                    .disabled(isCheckingAPIs)
                                                }
                                            }
                                        }
                                        Button("Refresh API status") {
                                            Task { await refreshAPIStatus() }
                                        }
                                        .buttonStyle(.link).font(.caption)
                                        .disabled(isCheckingAPIs)
                                    }
                                    
                                    stepText("3", "Create an OAuth 2.0 Client ID:")
                                    Text("Open the Google Cloud Console, create a Desktop-app OAuth client, then paste the Client ID and Secret below.")
                                        .font(.caption).foregroundColor(.secondary)
                                    
                                    Button {
                                        if let project = gcloudProject {
                                            let url = URL(string: "https://console.cloud.google.com/apis/credentials?project=\(project)")!
                                            NSWorkspace.shared.open(url)
                                        } else {
                                            NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                                        }
                                    } label: {
                                        HStack(spacing: 4) {
                                            Image(systemName: "arrow.up.forward.square")
                                            Text("Open Credentials Page")
                                        }
                                    }
                                    .buttonStyle(.link).font(.caption)
                                    
                                    stepText("4", "Paste the Client ID and Secret below, then tap Connect to Google.")
                                }
                            }
                            
                            Divider()
                            
                            // ── Web Console path (secondary) ──
                            Group {
                                Text("Option 2: Google Cloud Console")
                                    .font(.subheadline).fontWeight(.semibold)
                                
                                VStack(alignment: .leading, spacing: 4) {
                                    bulletText("Go to console.cloud.google.com")
                                    bulletText("Select or create a project")
                                    bulletText("Navigate to APIs & Services → Enabled APIs & Services")
                                    bulletText("Enable: Calendar, Drive, Docs, Sheets, Gmail, Tasks")
                                    bulletText("Go to APIs & Services → Credentials")
                                    bulletText("Create Credentials → OAuth client ID → Desktop app")
                                    bulletText("Copy the Client ID and Client Secret below")
                                }
                                
                                Button {
                                    NSWorkspace.shared.open(URL(string: "https://console.cloud.google.com/apis/credentials")!)
                                } label: {
                                    HStack(spacing: 4) {
                                        Image(systemName: "arrow.up.forward.square")
                                        Text("Open Google Cloud Console")
                                    }
                                }
                                .buttonStyle(.link).font(.caption)
                            }
                        }
                        .padding(.vertical, 8)
                    } label: {
                        HStack(spacing: 6) {
                            Image(systemName: "book.pages.fill").foregroundColor(.irisIndigo)
                            Text("Setup Guide").font(.subheadline)
                            if gcloudAvailable, workspaceAPIs.allSatisfy(\.enabled) {
                                Image(systemName: "checkmark.circle.fill").foregroundColor(.green).font(.caption)
                            }
                        }
                    }
                    .onAppear {
                        Task { await refreshGCloudState() }
                    }
                    .padding(.bottom, 4)
                    
                    // ── Credential fields ──
                    TextField("Client ID", text: $config.googleClientID)
                        .help("From Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client ID")
                    SecureField("Client Secret", text: $config.googleClientSecret)
                        .help("From Google Cloud Console → APIs & Services → Credentials → OAuth 2.0 Client ID")
                    
                    Text("These credentials enable external tools for Google Calendar, Docs, Drive, Sheets, Gmail, and Tasks.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    
                    if !config.googleAccessToken.isEmpty {
                        Text("✅ Connected to Google Workspace")
                            .foregroundColor(.green)
                            .font(.caption)
                    } else {
                        Button("Connect to Google") {
                            Task {
                                do {
                                    try await OAuthManager.shared.startOAuthFlow()
                                } catch {
                                    print("OAuth Error: \(error)")
                                }
                            }
                        }
                        .disabled(config.googleClientID.isEmpty || config.googleClientSecret.isEmpty)
                    }
                }
                .padding(.bottom)
            }
            .formStyle(.grouped)
            .padding(20)
            .tabItem {
                Label("Integrations", systemImage: "link")
            }
            
            // MARK: - Advanced Tab
            Form {
                Section(header: Text("Sandboxing").font(.headline)) {
                    Toggle("Enable sandboxing", isOn: $config.enableSandboxing)
                        .onChange(of: config.enableSandboxing) { _, newValue in
                            if newValue {
                                if !SandboxingManager.shared.isContainerInstalled {
                                    // Turn it back off until installed
                                    config.enableSandboxing = false
                                    isInstallingContainer = true
                                    installError = nil
                                    
                                    SandboxingManager.shared.installContainer { success, error in
                                        isInstallingContainer = false
                                        if success {
                                            config.enableSandboxing = true
                                        } else {
                                            installError = error
                                        }
                                    }
                                } else {
                                    // Container runtime is installed; ensure background services and kernel image are ready
                                    isInstallingContainer = true
                                    installError = nil
                                    Task {
                                        let result = await SandboxingManager.shared.startContainerSystem()
                                        await MainActor.run {
                                            isInstallingContainer = false
                                            if !result.success {
                                                installError = result.message
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    
                    if config.enableSandboxing {
                        Picker("Main agent (default)", selection: $config.mainAgentSandboxDefault) {
                            Text("Host").tag(SandboxPref.host)
                            Text("Sandboxed").tag(SandboxPref.sandboxed)
                        }
                        .help("Where the main agent runs by default. Subagents are always sandboxed. Override per workspace via /sandbox, or per conversation via the sidebar right-click menu.")
                        TextField("Sandbox Image", text: $config.sandboxImage)
                            .help("The Docker/OCI image to use for sandboxed commands (e.g., ubuntu:latest)")
                        Stepper("Sandbox idle timeout: \(config.sandboxIdleTimeoutMinutes) min",
                                value: Binding(
                                    get: { config.sandboxIdleTimeoutMinutes },
                                    set: { config.sandboxIdleTimeoutMinutes = max(1, $0) }),
                                in: 1...240)
                            .help("How long a sandbox container can sit idle before being reclaimed (1–240 minutes).")
                    }
                    
                    if isInstallingContainer {
                        HStack {
                            ProgressView()
                                .scaleEffect(0.5)
                            Text("Downloading and installing Apple container...")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                    
                    if let error = installError {
                        Text("Error: \(error)")
                            .foregroundColor(.red)
                            .font(.caption)
                    }
                    
                    Text("Runs dangerous commands like web searches in lightweight Linux virtual machines on your Mac.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                Section(header: Text("Agent Limits").font(.headline)) {
                    Stepper("Max goal iterations: \(config.maxGoalIterations)",
                            value: Binding(get: { config.maxGoalIterations },
                                           set: { config.maxGoalIterations = max(1, $0) }), in: 1...500)
                        .help("Hard cap on autonomous goal-loop turns before the agent summarizes and stops.")
                    Stepper("Loop-detection threshold: \(config.loopDetectionThreshold)",
                            value: Binding(get: { config.loopDetectionThreshold },
                                           set: { config.loopDetectionThreshold = max(2, $0) }), in: 2...20)
                        .help("Stop early if the agent repeats the exact same tool call this many times in a row.")
                    Stepper("Vibecop timeout: \(config.vibecopTimeoutSeconds)s",
                            value: Binding(get: { config.vibecopTimeoutSeconds },
                                           set: { config.vibecopTimeoutSeconds = max(1, $0) }), in: 1...30)
                        .help("How long to wait for the Vibecop guard before falling back to a manual approval prompt.")
                }

                // #187 §9: the five numbers every unattended run is bounded by. A job's own policy
                // may override any of them except the global daily budget, which is the ceiling on
                // the whole background system.
                Section(header: Text("Job Limits").font(.headline)) {
                    ForEach(JobLimitSetting.allCases, id: \.rawValue) { limit in
                        // The label reads the *stored* figure, so a resting 0 still says
                        // "default (6)"; the binding reads the *effective* one, so a click moves
                        // from the 6 the row is showing rather than from the 0 behind it.
                        Stepper(limit.label(limit.value(in: config)),
                                value: Binding(get: { limit.effectiveValue(in: config) },
                                               set: { limit.set($0, in: config) }),
                                in: limit.range, step: limit.step)
                            .help(limit.help)
                    }
                    Text("A stepper at its default uses the figure Iris ships with, and steps up or down from it; wind one down to zero to go back to the default. `/jobs` shows what each job has spent today against these numbers.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }

                GoalWorkspacesSection(state: state)
            }
            .formStyle(.grouped)
            .padding(20)
            .tabItem {
                Label("Advanced", systemImage: "lock.shield")
            }

            // MARK: - Plugins Tab
            PluginsSettingsView()
            .tabItem {
                Label("Plugins", systemImage: "puzzlepiece.extension")
            }

            // MARK: - Updates Tab
            Form {
                Section(header: Text("Application Updates").font(.headline)) {
                    HStack {
                        Text("Installed Version:")
                        Spacer()
                        Text("v\(Constants.appVersion)")
                            .foregroundColor(.secondary)
                    }
                    
                    if let update = availableUpdate {
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Image(systemName: "arrow.triangle.2.circlepath.circle.fill")
                                    .foregroundColor(.irisIndigo)
                                Text("New Version Available: \(update.tagName)")
                                    .font(.headline)
                            }
                            
                            if !update.body.isEmpty {
                                Text(update.body)
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .lineLimit(4)
                            }
                            
                            Button("Download Update (\(update.tagName))") {
                                UpdateManager.shared.openReleasePage(url: update.htmlUrl)
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        .padding(.vertical, 4)
                    }
                    
                    HStack {
                        Button(action: { checkForUpdates() }) {
                            if isCheckingForUpdates {
                                ProgressView()
                                    .controlSize(.small)
                            } else {
                                Text("Check for Updates")
                            }
                        }
                        .disabled(isCheckingForUpdates)
                        
                        if let msg = updateCheckStatusMessage {
                            Spacer()
                            Text(msg)
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            }
            .formStyle(.grouped)
            .padding(20)
            .tabItem {
                Label("Updates", systemImage: "arrow.triangle.2.circlepath")
            }
        }
        .frame(minWidth: 600, minHeight: 600)
        .onChange(of: downloader.error) { _, newValue in
            if newValue != nil {
                showingDownloadError = true
            }
        }
        .alert("Download Error", isPresented: $showingDownloadError) {
            Button("OK", role: .cancel) { downloader.error = nil }
        } message: {
            Text(downloader.error ?? "An unknown error occurred.")
        }
    }
    
    private func checkForUpdates() {
        isCheckingForUpdates = true
        updateCheckStatusMessage = "Checking for updates..."
        Task {
            let result = await UpdateManager.shared.checkForUpdates()
            await MainActor.run {
                self.isCheckingForUpdates = false
                switch result {
                case .updateAvailable(let release):
                    self.availableUpdate = release
                    self.updateCheckStatusMessage = "Update available: \(release.tagName)"
                case .upToDate:
                    self.availableUpdate = nil
                    self.updateCheckStatusMessage = "Iris is up to date (v\(Constants.appVersion))."
                case .error(let msg):
                    self.updateCheckStatusMessage = "Failed to check for updates: \(msg)"
                }
            }
        }
    }
    
    // MARK: - Ollama Helpers
    
    private func probeOllamaModels() async {
        isProbingOllama = true
        ollamaPullError = nil
        ollamaDaemonRunning = nil  // reset while probing
        
        let reachable = await OllamaEngine.isDaemonReachable()
        await MainActor.run {
            self.ollamaDaemonRunning = reachable
        }
        
        guard reachable else {
            await MainActor.run {
                self.ollamaInstalledModels = []
                self.isProbingOllama = false
            }
            return
        }
        
        let models = await OllamaEngine.listInstalledModels()
        await MainActor.run {
            self.ollamaInstalledModels = models
            self.isProbingOllama = false
        }
    }
    
    private func pullOllamaDefaultModel(_ name: String) async {
        isPullingOllamaModel = true
        ollamaPullError = nil
        ollamaPullProgress = "Starting pull of \(name)…"
        do {
            try await OllamaEngine.pullModel(name: name) { progress in
                Task { @MainActor in
                    self.ollamaPullProgress = progress
                }
            }
            await MainActor.run {
                self.isPullingOllamaModel = false
                self.ollamaPullProgress = nil
                // Refresh the model list after pull
                Task { await probeOllamaModels() }
            }
        } catch {
            await MainActor.run {
                self.isPullingOllamaModel = false
                self.ollamaPullProgress = nil
                self.ollamaPullError = error.localizedDescription
            }
        }
    }
    
    // MARK: - Google Workspace / gcloud Helpers
    
    private func refreshGCloudState() async {
        let available = GCloudHelper.isAvailable
        await MainActor.run { self.gcloudAvailable = available }
        guard available else { return }
        
        let account = await GCloudHelper.activeAccount()
        let project = await GCloudHelper.currentProject()
        await MainActor.run {
            self.gcloudAccount = account
            self.gcloudProject = project
        }
        await refreshAPIStatus()
    }
    
    private func refreshAPIStatus() async {
        guard gcloudAvailable else { return }
        await MainActor.run { isCheckingAPIs = true }
        
        let enabled = await GCloudHelper.enabledServices()
        let updated = GCloudHelper.requiredAPIs.map { api in
            var copy = api
            copy.enabled = enabled.contains(api.id)
            return copy
        }
        
        await MainActor.run {
            self.workspaceAPIs = updated
            self.isCheckingAPIs = false
        }
    }
    
    // MARK: - Setup Guide view helpers
    
    @ViewBuilder
    private func stepText(_ number: String, _ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text(number).font(.caption).fontWeight(.bold)
                .frame(width: 16, alignment: .center)
            Text(text).font(.caption)
        }
    }
    
    @ViewBuilder
    private func bulletText(_ text: String) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Text("•").font(.caption)
            Text(text).font(.caption)
        }
    }
    
    // MARK: - Vibecop test button (shared across engine paths)
    
    @ViewBuilder
    private func vibecopTestButton() -> some View {
        if isTestingVibecopModel {
            ProgressView().scaleEffect(0.6)
            Text("Testing…").font(.caption).foregroundColor(.secondary)
        } else if let status = vibecopTestStatus {
            Text(status).font(.caption)
                .foregroundColor(status.starts(with: "✅") ? .green : .red)
            if status.starts(with: "❌") {
                Button("Retry") { runVibecopTest() }
                    .buttonStyle(.link).font(.caption)
            }
        } else {
            Button("Test Model") { runVibecopTest() }
                .buttonStyle(.link).font(.caption)
        }
    }
    
    private func runVibecopTest() {
        isTestingVibecopModel = true
        vibecopTestStatus = nil
        Task {
            do {
                let engineType = AuxiliaryEngineType(rawValue: config.vibecopEngine) ?? .llamaCPP
                let auxConfig = AuxiliaryModelConfig(role: "vibecop", engineType: engineType, modelPathOrName: config.vibecopModel)
                let engine = try await AuxiliaryModelManager.shared.getEngine(for: "vibecop", config: auxConfig)
                _ = try await engine.generate(prompt: "Hello", jsonSchema: nil)
                vibecopTestStatus = "✅ Model tested successfully"
            } catch {
                vibecopTestStatus = "❌ Failed: \(error.localizedDescription)"
            }
            isTestingVibecopModel = false
        }
    }

    // MARK: - #206 "Test Models" / #207 "List Available Models…"

    /// The primary provider's current credentials, read once per run so a run reflects the
    /// settings at the moment the button was pressed rather than racing an in-flight edit.
    private func currentProviderCredentials() -> (provider: LLMProvider, apiKey: String, baseURL: String, geminiADC: Bool) {
        let provider = LLMProvider(rawValue: config.primaryProvider) ?? .gemini
        switch provider {
        case .anthropic:
            return (provider, config.anthropicAPIKey, config.anthropicBaseURL, false)
        case .openai:
            return (provider, config.openAIAPIKey, config.openAIBaseURL, false)
        case .gemini:
            return (provider, config.geminiAPIKey, config.geminiBaseURL, config.geminiAuthMode == GeminiAuthMode.adc.rawValue)
        }
    }

    @ViewBuilder
    private func modelToolsView() -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 12) {
                Button(isTestingModels ? "Testing…" : "Test Models") { runModelTests() }
                    .disabled(isTestingModels || isListingModels || !config.isConfigured)
                if isTestingModels {
                    ProgressView().scaleEffect(0.6)
                }
                Button("List Available Models…") {
                    showModelListSheet = true
                    fetchModelList()
                }
                .disabled(isTestingModels || isListingModels || !config.isConfigured)
            }

            if !modelTestTargets.isEmpty {
                VStack(alignment: .leading, spacing: 4) {
                    ForEach(Array(modelTestTargets.enumerated()), id: \.offset) { _, target in
                        modelTestRow(target: target)
                    }
                }
                .padding(.top, 4)
            } else if hasRunModelTest {
                Text("No models configured")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .padding(.top, 4)
            }
        }
        .padding(.top, 4)
        .help("Tests every model currently configured for the primary provider — Easy, Primary/Medium, Hard, and Vision when the auxiliary vision engine is set to Cloud.")
    }

    @ViewBuilder
    private func modelTestRow(target: (label: String, model: String)) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(target.label)
                .font(.caption)
                .frame(width: 110, alignment: .leading)
            Text(target.model)
                .font(.caption)
                .foregroundColor(.secondary)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer(minLength: 8)
            if let result = modelTestResultsByLabel[target.label] {
                switch result.outcome {
                case .ok(let latencyMs):
                    Image(systemName: "checkmark.circle.fill").foregroundColor(.green)
                    Text("\(latencyMs) ms").font(.caption).foregroundColor(.secondary)
                case .failed(let message):
                    Image(systemName: "xmark.octagon.fill").foregroundColor(.red)
                    Text(message).font(.caption).foregroundColor(.red).textSelection(.enabled)
                }
            } else {
                ProgressView().scaleEffect(0.5)
            }
        }
    }

    /// #206: probes every configured tier of the primary provider concurrently. A model shared by
    /// two or more tiers is probed once (`ModelCatalog.probeTargets`); Gemini in ADC mode reads the
    /// token and quota project here, once, rather than inside `ModelCatalog`.
    private func runModelTests() {
        guard !isTestingModels else { return }
        modelTestTask?.cancel()
        let (provider, apiKey, baseURL, geminiADC) = currentProviderCredentials()
        let visionModel = config.auxiliaryVisionEngine == "cloud" ? config.auxiliaryVisionModel : nil
        let targets = ModelCatalog.probeTargets(
            easy: config.getModel(for: .easy),
            medium: config.getModel(for: .medium),
            hard: config.getModel(for: .hard),
            vision: visionModel
        )
        hasRunModelTest = true
        modelTestTargets = targets
        modelTestResultsByLabel = [:]
        guard !targets.isEmpty else { return }

        isTestingModels = true

        modelTestTask = Task {
            let adcToken: String?
            let quotaProject: String?
            if geminiADC {
                quotaProject = await ADCCredentialManager.shared.getQuotaProject()
                adcToken = try? await ADCCredentialManager.shared.getAccessToken()
            } else {
                adcToken = nil
                quotaProject = nil
            }
            let catalog = ModelCatalog(provider: provider, apiKey: apiKey, baseURL: baseURL, geminiADC: geminiADC)
            await withTaskGroup(of: ModelProbeResult.self) { group in
                for target in targets {
                    group.addTask {
                        await catalog.probe(model: target.model, label: target.label, adcToken: adcToken, quotaProject: quotaProject)
                    }
                }
                for await result in group {
                    if Task.isCancelled { break }
                    modelTestResultsByLabel[result.label] = result
                }
            }
            isTestingModels = false
        }
    }

    /// #207: lists every model the configured account can reach.
    private func fetchModelList() {
        guard !isListingModels else { return }
        modelListTask?.cancel()
        let (provider, apiKey, baseURL, geminiADC) = currentProviderCredentials()

        isListingModels = true
        modelListError = nil
        modelListResults = []

        modelListTask = Task {
            var adcToken: String?
            var quotaProject: String?
            if geminiADC {
                quotaProject = await ADCCredentialManager.shared.getQuotaProject()
                adcToken = try? await ADCCredentialManager.shared.getAccessToken()
            }
            let catalog = ModelCatalog(provider: provider, apiKey: apiKey, baseURL: baseURL, geminiADC: geminiADC)
            do {
                let models = try await catalog.listModels(adcToken: adcToken, quotaProject: quotaProject)
                if !Task.isCancelled { modelListResults = models }
            } catch is CancellationError {
                // The sheet was closed mid-fetch; nothing to show.
            } catch {
                if !Task.isCancelled { modelListError = error.localizedDescription }
            }
            isListingModels = false
        }
    }
}

/// #207's "List Available Models…" sheet: every model the account can reach, searchable, with a
/// per-row Copy and a "Use as" menu that assigns the id straight into a tier field of the
/// CURRENT primary provider (the amendment to #207). `config` is the same `ConfigManager` instance
/// the Models tab already holds — this view never reaches for `ConfigManager.shared` itself.
private struct ModelListSheet: View {
    let config: ConfigManager
    let provider: LLMProvider
    let isLoading: Bool
    let error: String?
    let models: [ModelInfo]
    let onClose: () -> Void
    let onRetry: () -> Void

    @State private var searchText = ""
    @State private var copiedId: String?
    @State private var confirmations: [String: String] = [:]

    private var filtered: [ModelInfo] {
        guard !searchText.isEmpty else { return models }
        return models.filter {
            $0.id.localizedCaseInsensitiveContains(searchText)
                || ($0.displayName?.localizedCaseInsensitiveContains(searchText) ?? false)
        }
    }

    var body: some View {
        NavigationStack {
            Group {
                if isLoading {
                    ProgressView("Listing available models…")
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if let error {
                    VStack(spacing: 12) {
                        Text(error)
                            .font(.callout)
                            .foregroundColor(.red)
                            .textSelection(.enabled)
                            .multilineTextAlignment(.center)
                            .padding()
                        Button("Retry", action: onRetry)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(filtered) { model in
                        modelRow(model)
                    }
                    .safeAreaInset(edge: .bottom) {
                        HStack {
                            Text("\(filtered.count) of \(models.count) models")
                                .font(.caption)
                                .foregroundColor(.secondary)
                            Spacer()
                        }
                        .padding(.horizontal)
                        .padding(.vertical, 6)
                        .background(.bar)
                    }
                }
            }
            .navigationTitle("Available Models")
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close", action: onClose)
                }
            }
            .searchable(text: $searchText, prompt: "Filter models")
        }
        .frame(minWidth: 480, minHeight: 480)
    }

    @ViewBuilder
    private func modelRow(_ model: ModelInfo) -> some View {
        HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text(model.id)
                    .font(.system(.body, design: .monospaced))
                    .textSelection(.enabled)
                if let displayName = model.displayName, !displayName.isEmpty {
                    Text(displayName)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()

            let assigned = assignedTierNames(for: model.id)
            if !assigned.isEmpty {
                Text(assigned.joined(separator: ", "))
                    .font(.caption2)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.secondary.opacity(0.15))
                    .clipShape(Capsule())
            }

            if let confirmation = confirmations[model.id] {
                Text(confirmation)
                    .font(.caption)
                    .foregroundColor(.green)
            }

            Menu {
                Button(ModelTierField.easy.label) { assign(.easy, model) }
                Button(ModelTierField.medium.label) { assign(.medium, model) }
                Button(ModelTierField.hard.label) { assign(.hard, model) }
                if config.auxiliaryVisionEngine == "cloud" {
                    Button(ModelTierField.vision.label) { assign(.vision, model) }
                }
            } label: {
                Image(systemName: "ellipsis.circle")
            }
            .menuStyle(.borderlessButton)
            .frame(width: 22)
            .help("Use as…")

            Button(copiedId == model.id ? "Copied" : "Copy") { copy(model.id) }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.vertical, 2)
    }

    /// The tier short names of the CURRENT provider already pointing at `modelId`, so a row shows
    /// where it is already assigned before the user picks another slot for it.
    private func assignedTierNames(for modelId: String) -> [String] {
        var tiers: [ModelTierField] = [.easy, .medium, .hard]
        if config.auxiliaryVisionEngine == "cloud" { tiers.append(.vision) }
        return tiers.filter { config[keyPath: ModelTierField.keyPath(provider: provider, tier: $0)] == modelId }
            .map(\.shortLabel)
    }

    /// Writes `model.id` into the tier field for `tier` on the current provider and shows a
    /// transient confirmation — the sheet stays open so several tiers can be assigned in one visit.
    private func assign(_ tier: ModelTierField, _ model: ModelInfo) {
        config[keyPath: ModelTierField.keyPath(provider: provider, tier: tier)] = model.id
        let label = "Set as \(tier.shortLabel)"
        confirmations[model.id] = label
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if confirmations[model.id] == label { confirmations[model.id] = nil }
        }
    }

    private func copy(_ modelId: String) {
        let pasteboard = NSPasteboard.general
        pasteboard.clearContents()
        pasteboard.setString(modelId, forType: .string)
        copiedId = modelId
        Task {
            try? await Task.sleep(nanoseconds: 1_500_000_000)
            if copiedId == modelId { copiedId = nil }
        }
    }
}
