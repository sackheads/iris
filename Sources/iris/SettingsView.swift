import SwiftUI
import KeyboardShortcuts

struct SettingsView: View {
    @Bindable private var config = ConfigManager.shared
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
                            let coreMLFilename = config.promptGuardCoreMLModel.starts(with: "http") ? (URL(string: config.promptGuardCoreMLModel)?.lastPathComponent ?? config.promptGuardCoreMLModel) : config.promptGuardCoreMLModel
                            let coreMLNameNoZip = coreMLFilename.hasSuffix(".zip") ? String(coreMLFilename.dropLast(4)) : coreMLFilename
                            let isCoreMLDownloaded = downloader.isModelDownloaded(name: coreMLNameNoZip)
                            
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
}
