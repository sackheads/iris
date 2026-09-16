import SwiftUI

struct WizardStepRow: View {
    let step: Int
    let title: String
    let currentStep: Int
    
    var isActive: Bool { currentStep == step }
    var isPast: Bool { currentStep > step }
    
    var body: some View {
        HStack {
            ZStack {
                Circle()
                    .fill(isActive ? Color.accentColor : (isPast ? Color.green : Color.secondary.opacity(0.3)))
                    .frame(width: 24, height: 24)
                if isPast {
                    Image(systemName: "checkmark")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(.white)
                } else {
                    Text("\(step)")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundColor(isActive ? .white : .primary)
                }
            }
            
            Text(title)
                .font(.system(size: 14, weight: isActive ? .bold : .medium))
                .foregroundColor(isActive ? .primary : .secondary)
            
            Spacer()
        }
        .padding(.vertical, 4)
    }
}

struct SetupWizardView: View {
    @State private var currentStep: Int = 1
    @Bindable var config = ConfigManager.shared
    @Environment(\.dismiss) var dismiss
    
    var body: some View {
        HStack(spacing: 0) {
            // Sidebar
            VStack(alignment: .leading, spacing: 16) {
                Text("Iris Setup")
                    .font(.system(size: 24, weight: .bold, design: .rounded))
                    .padding(.bottom, 20)
                
                WizardStepRow(step: 1, title: "Appearance", currentStep: currentStep)
                WizardStepRow(step: 2, title: "Base Model", currentStep: currentStep)
                WizardStepRow(step: 3, title: "Integrations", currentStep: currentStep)
                WizardStepRow(step: 4, title: "Vibecop", currentStep: currentStep)
                WizardStepRow(step: 5, title: "Security", currentStep: currentStep)
                WizardStepRow(step: 6, title: "Sandboxing", currentStep: currentStep)
                
                Spacer()
            }
            .frame(width: 220)
            .padding(30)
            .background(Color(NSColor.controlBackgroundColor).opacity(0.8))
            
            Divider()
            
            // Main Content
            VStack(alignment: .leading) {
                switch currentStep {
                case 1: AppearanceStepView(currentStep: $currentStep)
                case 2: BaseModelStepView(currentStep: $currentStep)
                case 3: IntegrationsStepView(currentStep: $currentStep)
                case 4: VibecopStepView(currentStep: $currentStep)
                case 5: SecurityStepView(currentStep: $currentStep)
                case 6: SandboxingStepView(currentStep: $currentStep, onFinish: finishSetup)
                default: EmptyView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding(40)
            .background(Color(NSColor.windowBackgroundColor))
        }
        .frame(width: 850, height: 600)
    }
    
    private func finishSetup() {
        // Force creation of memory DB and USER.md immediately
        _ = MemoryManager.shared
        _ = FactStoreManager.shared
        
        IrisDefaults.store.set(true, forKey: "HAS_COMPLETED_SETUP")
        dismiss()
    }
}

// MARK: - Steps

struct AppearanceStepView: View {
    @Binding var currentStep: Int
    @Bindable var config = ConfigManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Appearance")
                .font(.system(size: 32, weight: .bold))
            
            Text("Choose how Iris looks and feels. Iris features full Markdown rendering for beautiful chat transcripts and code blocks.")
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Theme")
                    .font(.headline)
                Picker("Theme", selection: $config.appearanceTheme) {
                    Text("Light").tag("light")
                    Text("Dark").tag("dark")
                    Text("Auto").tag("system")
                }
                .pickerStyle(.segmented)
            }
            .padding(.top, 10)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Chat Formatting")
                    .font(.headline)
                Toggle("Copy Chats as Markdown", isOn: $config.copyChatsAsMarkdown)
                Text("When enabled, copying messages will preserve their Markdown formatting (bold, code blocks, lists).")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
            .padding(.top, 10)
            
            Spacer()
            
            HStack {
                Spacer()
                Button("Next") { currentStep += 1 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

struct BaseModelStepView: View {
    @Binding var currentStep: Int
    @Bindable var config = ConfigManager.shared
    @State private var testStatus: String?
    @State private var isTesting = false
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Base Model")
                .font(.system(size: 32, weight: .bold))
            
            Text("Iris needs a primary brain. Choose a provider and enter your API credentials. You can change this anytime in Settings.")
                .foregroundColor(.secondary)
            
            Picker("Provider", selection: $config.primaryProvider) {
                ForEach(LLMProvider.allCases) { provider in
                    Text(provider.rawValue).tag(provider.rawValue)
                }
            }
            .pickerStyle(.segmented)
            .padding(.top, 10)
            
            VStack(alignment: .leading, spacing: 12) {
                if config.primaryProvider == LLMProvider.gemini.rawValue {
                    Picker("Authentication", selection: $config.geminiAuthMode) {
                        ForEach(GeminiAuthMode.allCases) { mode in
                            Text(mode.rawValue).tag(mode.rawValue)
                        }
                    }
                    .pickerStyle(.radioGroup)
                    
                    if config.geminiAuthMode == GeminiAuthMode.apiKey.rawValue {
                        SecureField("Gemini API Key", text: $config.geminiAPIKey)
                            .textFieldStyle(.roundedBorder)
                    }
                } else if config.primaryProvider == LLMProvider.anthropic.rawValue {
                    SecureField("Anthropic API Key", text: $config.anthropicAPIKey)
                        .textFieldStyle(.roundedBorder)
                } else if config.primaryProvider == LLMProvider.openai.rawValue {
                    SecureField("OpenAI API Key", text: $config.openAIAPIKey)
                        .textFieldStyle(.roundedBorder)
                }
                
                HStack {
                    Button(isTesting ? "Testing..." : "Test Connection") {
                        Task {
                            isTesting = true
                            testStatus = nil
                            do {
                                let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "Respond with exactly one word: Hello", functionCall: nil, functionResponse: nil)])], systemInstruction: nil, tools: nil)
                                _ = try await LLMClient().generateContent(request: request)
                                testStatus = "✅ Connection successful!"
                            } catch {
                                testStatus = "❌ Failed: \(error.localizedDescription)"
                            }
                            isTesting = false
                        }
                    }
                    .disabled(isTesting || !config.isConfigured)
                    
                    if let status = testStatus {
                        Text(status)
                            .font(.caption)
                            .foregroundColor(status.starts(with: "✅") ? .green : .red)
                    }
                }
                .padding(.top, 8)
            }
            
            Spacer()
            
            HStack {
                Button("Back") { currentStep -= 1 }
                Spacer()
                Button("Next") { currentStep += 1 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
                    .disabled(!config.isConfigured)
            }
        }
    }
}

struct IntegrationsStepView: View {
    @Binding var currentStep: Int
    @Bindable var config = ConfigManager.shared
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Integrations")
                .font(.system(size: 32, weight: .bold))
            
            Text("Connect Iris to your digital life. These connections enable agents to read your calendar, search your drive, and manage your tasks.")
                .foregroundColor(.secondary)
            
            VStack(alignment: .leading, spacing: 12) {
                Text("Google Workspace (OAuth)")
                    .font(.headline)
                
                TextField("Client ID", text: $config.googleClientID)
                    .textFieldStyle(.roundedBorder)
                SecureField("Client Secret", text: $config.googleClientSecret)
                    .textFieldStyle(.roundedBorder)
                
                if !config.googleAccessToken.isEmpty {
                    Text("✅ Connected to Google Workspace")
                        .foregroundColor(.green)
                        .font(.caption)
                } else {
                    Button("Connect") {
                        Task { try? await OAuthManager.shared.startOAuthFlow() }
                    }
                    .disabled(config.googleClientID.isEmpty || config.googleClientSecret.isEmpty)
                }
            }
            .padding()
            .background(Color.secondary.opacity(0.1))
            .cornerRadius(8)
            
            Spacer()
            
            HStack {
                Button("Back") { currentStep -= 1 }
                Spacer()
                Button("Next") { currentStep += 1 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

struct VibecopStepView: View {
    @Binding var currentStep: Int
    @Bindable var config = ConfigManager.shared
    var downloader = ModelDownloader.shared
    @State private var testStatus: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Vibecop")
                .font(.system(size: 32, weight: .bold))
            
            Text("Vibecop is an independent LLM copilot that enables \"smart approvals\" for commands that can be tuned to fit your project specifics.")
                .foregroundColor(.secondary)
            
            Toggle("Enable Vibecop", isOn: $config.enableVibecop)
            
            if config.enableVibecop {
                VStack(alignment: .leading, spacing: 12) {
                    Text("Model Selection")
                        .font(.headline)
                    
                    Picker("Engine", selection: $config.vibecopEngine) {
                        Text("Llama.cpp").tag("llama_cpp")
                        Text("Ollama").tag("ollama")
                        Text("MLX").tag("mlx")
                        Text("Cloud").tag("cloud")
                    }
                    .pickerStyle(.segmented)
                    
                    if config.vibecopEngine == "llama_cpp" {
                        Picker("Model", selection: $config.vibecopModel) {
                            Text("Qwen3.5 2B (Fast, ~\(downloader.approximateSize(for: "Qwen3.5-2B-Q4_K_M.gguf")))").tag("Qwen3.5-2B-Q4_K_M.gguf")
                            Text("Gemma 4 E2B (Fast, ~\(downloader.approximateSize(for: "gemma-4-E2B-it-Q4_K_M.gguf")))").tag("gemma-4-E2B-it-Q4_K_M.gguf")
                            Text("Gemma 4 12B (Heavy, ~\(downloader.approximateSize(for: "gemma-4-12B-it-Q4_K_M.gguf")))").tag("gemma-4-12B-it-Q4_K_M.gguf")
                        }
                        
                        let isDownloaded = downloader.isModelDownloaded(name: config.vibecopModel)
                        
                        if !isDownloaded {
                            if downloader.isDownloading && downloader.currentDownloadName == config.vibecopModel {
                                ProgressView(value: downloader.progress)
                            } else {
                                Button("Download Model") {
                                    Task { await downloader.downloadModel(name: config.vibecopModel, assignResolvedNameTo: \.vibecopModel) }
                                }
                            }
                        } else {
                            HStack {
                                Text("✅ Model ready.")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                    
                                Button("Test Model") {
                                Task {
                                    do {
                                        let engineType = AuxiliaryEngineType(rawValue: config.vibecopEngine) ?? .llamaCPP
                                        let auxConfig = AuxiliaryModelConfig(role: "vibecop", engineType: engineType, modelPathOrName: config.vibecopModel)
                                        let engine = try await AuxiliaryModelManager.shared.getEngine(for: "vibecop", config: auxConfig)
                                        _ = try await engine.generate(prompt: "Hello", jsonSchema: nil)
                                        testStatus = "✅ Success"
                                    } catch {
                                        testStatus = "❌ Failed: \(error.localizedDescription)"
                                    }
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            
                            if let status = testStatus {
                                Text(status).font(.caption).foregroundColor(status.starts(with: "✅") ? .green : .red)
                            }
                            }
                        }
                    } else {
                        TextField("Model Name", text: $config.vibecopModel)
                            .textFieldStyle(.roundedBorder)
                        
                        HStack {
                            Text("✅ Assuming model is ready via external daemon.")
                                .foregroundColor(.green)
                                .font(.caption)
                                
                            Button("Test Model") {
                                Task {
                                    do {
                                        let engineType = AuxiliaryEngineType(rawValue: config.vibecopEngine) ?? .llamaCPP
                                        let auxConfig = AuxiliaryModelConfig(role: "vibecop", engineType: engineType, modelPathOrName: config.vibecopModel)
                                        let engine = try await AuxiliaryModelManager.shared.getEngine(for: "vibecop", config: auxConfig)
                                        _ = try await engine.generate(prompt: "Hello", jsonSchema: nil)
                                        testStatus = "✅ Success"
                                    } catch {
                                        testStatus = "❌ Failed: \(error.localizedDescription)"
                                    }
                                }
                            }
                            .buttonStyle(.link)
                            .font(.caption)
                            
                            if let status = testStatus {
                                Text(status).font(.caption).foregroundColor(status.starts(with: "✅") ? .green : .red)
                            }
                        }
                    }
                }
                .padding()
                .background(Color.secondary.opacity(0.1))
                .cornerRadius(8)
            }
            
            Spacer()
            
            HStack {
                Button("Back") { currentStep -= 1 }
                Spacer()
                Button("Next") { currentStep += 1 }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}

struct SecurityStepView: View {
    @Binding var currentStep: Int
    @Bindable var config = ConfigManager.shared
    var downloader = ModelDownloader.shared
    @State private var tier2TestStatus: String?
    @State private var tier3TestStatus: String?
    
    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 24) {
                Text("Prompt Injection Security")
                    .font(.system(size: 32, weight: .bold))
                
                Text("Iris can intercept untrusted data from the web before your main LLM reads it, protecting you from adversarial attacks and hidden instructions.")
                    .foregroundColor(.secondary)
                
                Toggle("Enable Advanced Protection", isOn: $config.enableAdvancedPromptInjectionProtection)
                
                if config.enableAdvancedPromptInjectionProtection {
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tier 2: Fast Local Classifier")
                            .font(.headline)
                        Text("Rapidly classifies text as safe or malicious on-device — CoreML (Neural Engine) or ONNX Runtime (CPU).")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        let coreMLName = config.promptGuardCoreMLModel.starts(with: "http") ? (URL(string: config.promptGuardCoreMLModel)?.lastPathComponent ?? "") : config.promptGuardCoreMLModel
                        let coreMLNoZip = coreMLName.hasSuffix(".zip") ? String(coreMLName.dropLast(4)) : coreMLName
                        let isDownloaded = downloader.isModelDownloaded(name: coreMLNoZip)
                        
                        if !isDownloaded {
                            if downloader.isDownloading && downloader.currentDownloadName == coreMLName {
                                ProgressView(value: downloader.progress)
                            } else {
                                Button("Download Model (~650 MB)") {
                                    Task { await downloader.downloadModel(name: config.promptGuardCoreMLModel) }
                                }
                            }
                        } else {
                            HStack {
                                Text("✅ Model ready.")
                                    .foregroundColor(.green)
                                    .font(.caption)
                                    
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
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                    
                    Divider()
                        .padding(.vertical, 8)
                    
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Tier 3: Auxiliary LLM (Heuristic)")
                            .font(.headline)
                        Text("A local GGUF model evaluates suspicious payloads using deep logic.")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        
                        Picker("Engine", selection: $config.promptGuardEngine) {
                            Text("Llama.cpp").tag("llama_cpp")
                            Text("Ollama").tag("ollama")
                            Text("MLX").tag("mlx")
                        }
                        .pickerStyle(.segmented)
                        
                        if config.promptGuardEngine == "llama_cpp" {
                            Picker("Model", selection: $config.promptGuardModel) {
                                Text("Qwen3.5 2B (~\(downloader.approximateSize(for: "Qwen3.5-2B-Q4_K_M.gguf")))").tag("Qwen3.5-2B-Q4_K_M.gguf")
                                Text("Gemma 4 E2B (~\(downloader.approximateSize(for: "gemma-4-E2B-it-Q4_K_M.gguf")))").tag("gemma-4-E2B-it-Q4_K_M.gguf")
                                Text("Gemma 4 12B (~\(downloader.approximateSize(for: "gemma-4-12B-it-Q4_K_M.gguf")))").tag("gemma-4-12B-it-Q4_K_M.gguf")
                            }
                            
                            let isTier3Downloaded = downloader.isModelDownloaded(name: config.promptGuardModel)
                            
                            if !isTier3Downloaded {
                                if downloader.isDownloading && downloader.currentDownloadName == config.promptGuardModel {
                                    ProgressView(value: downloader.progress)
                                } else {
                                    Button("Download Model") {
                                        Task { await downloader.downloadModel(name: config.promptGuardModel, assignResolvedNameTo: \.promptGuardModel) }
                                    }
                                }
                            } else {
                                HStack {
                                    Text("✅ Tier 3 Model ready.")
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
                    } else {
                        TextField("Model Name", text: $config.promptGuardModel)
                            .textFieldStyle(.roundedBorder)
                        
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
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                }
                
                Spacer()
                
                HStack {
                    Button("Back") { currentStep -= 1 }
                    Spacer()
                    Button("Next") { currentStep += 1 }
                        .buttonStyle(.borderedProminent)
                        .controlSize(.large)
                }
            }
        }
    }
}

struct SandboxingStepView: View {
    @Binding var currentStep: Int
    var onFinish: () -> Void
    @Bindable var config = ConfigManager.shared
    @State private var isInstalling = false
    @State private var installStatus: String?
    
    var body: some View {
        VStack(alignment: .leading, spacing: 24) {
            Text("Sandboxing")
                .font(.system(size: 32, weight: .bold))
            
            Text("By default, Iris agents can run terminal commands directly on your Mac. Sandboxing forces them to run commands inside an isolated OCI container using macOS's native `apple/container` virtualization.")
                .foregroundColor(.secondary)
            
            Toggle("Enable Container Sandboxing", isOn: $config.enableSandboxing)
            
            if config.enableSandboxing {
                let isInstalled = SandboxingManager.shared.isContainerInstalled
                
                if !isInstalled {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("⚠️ apple/container engine is not installed.")
                            .foregroundColor(.orange)
                            .font(.headline)
                        
                        if isInstalling {
                            ProgressView("Downloading & installing PKG (requires Admin)...")
                        } else {
                            Button("Install Container Engine") {
                                isInstalling = true
                                installStatus = nil
                                SandboxingManager.shared.installContainer { success, error in
                                    isInstalling = false
                                    if success {
                                        installStatus = "✅ Installed successfully!"
                                    } else {
                                        installStatus = "❌ Installation failed: \(error ?? "Unknown error")"
                                    }
                                }
                            }
                            .buttonStyle(.borderedProminent)
                        }
                        
                        if let status = installStatus {
                            Text(status)
                                .font(.caption)
                                .foregroundColor(status.starts(with: "✅") ? .green : .red)
                        }
                    }
                    .padding()
                    .background(Color.secondary.opacity(0.1))
                    .cornerRadius(8)
                } else {
                    Text("✅ Container engine installed and ready.")
                        .foregroundColor(.green)
                        .font(.caption)
                }
            }
            
            Spacer()
            
            HStack {
                Button("Back") { currentStep -= 1 }
                Spacer()
                Button("Finish Setup") { onFinish() }
                    .buttonStyle(.borderedProminent)
                    .controlSize(.large)
            }
        }
    }
}
