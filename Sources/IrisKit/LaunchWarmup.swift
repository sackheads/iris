import Foundation

/// Builds the local guard engines at launch, so the first prompt doesn't pay the model's cold load
/// (#792, #778's option C). For Ollama, building the engine sends its preload, whose load #779's
/// status line shows. Fire-and-forget: launch never waits on it.
///
/// What it costs, as Brian accepted it: the model is resident from launch even if nothing is ever
/// guarded, and Ollama still unloads it after five idle minutes (keep_alive is unchanged).
enum LaunchWarmup {
    /// The engines to build now: tier 3's canary when protection is on and its engine is local
    /// and provisioned, and Vibecop's when it's on and local. Cloud engines have nothing to load.
    /// A llama.cpp model file that isn't there is skipped, as the guard itself skips it (#202).
    /// MLX is left to first use: its load fetches the model from Hugging Face when it isn't
    /// cached, and launch mustn't start a multi-gigabyte download nobody asked for (#795 review).
    static func engines(config: ConfigManager, modelsDir: URL) -> [AuxiliaryModelConfig] {
        var out: [AuxiliaryModelConfig] = []
        if config.enableAdvancedPromptInjectionProtection,
           let type = localEngine(config.promptGuardEngine),
           InjectionGuard.tier3Provisioning(engine: config.promptGuardEngine, modelName: config.promptGuardModel,
                                            modelsDir: modelsDir) == .provisioned {
            out.append(.init(role: "canary", engineType: type, modelPathOrName: config.promptGuardModel))
        }
        if config.enableVibecop, let type = localEngine(config.vibecopEngine),
           type != .llamaCPP || FileManager.default.fileExists(
               atPath: modelsDir.appendingPathComponent(ModelDownloader.resolvedFilename(for: config.vibecopModel)).path) {
            out.append(.init(role: "vibecop", engineType: type, modelPathOrName: config.vibecopModel))
        }
        return out
    }

    /// The engine type to warm for a setting, or nil for none (cloud, and MLX, above). The guard
    /// reads an unknown value as llama.cpp (`executeTier3Canary`), and so does this.
    static func localEngine(_ setting: String) -> AuxiliaryEngineType? {
        switch setting {
        case "cloud", "mlx": return nil
        case "ollama": return .ollama
        default: return .llamaCPP
        }
    }

    /// Starts building each engine and returns at once. `build` is `getEngine`; a failure is the
    /// guard's to report when it next runs (the LEDs, #218), so it's only logged here. A llama.cpp
    /// load is a synchronous C call that holds one pool thread while the file maps in: the hold the
    /// first guarded call used to take, moved to launch at utility priority (#795 review).
    @discardableResult
    static func start(_ engines: [AuxiliaryModelConfig],
                      build: @escaping @Sendable (AuxiliaryModelConfig) async throws -> Void = { config in
                          _ = try await AuxiliaryModelManager.shared.getEngine(for: config.role, config: config)
                      }) -> Task<Void, Never>? {
        guard !engines.isEmpty else { return nil }
        return Task.detached(priority: .utility) {
            await withTaskGroup(of: Void.self) { group in
                for config in engines {
                    group.addTask {
                        do { try await build(config) } catch {
                            print("[LaunchWarmup] \(config.role) (\(config.modelPathOrName)) did not load: \(error)")
                        }
                    }
                }
            }
        }
    }
}
