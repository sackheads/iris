import Foundation

final class AuxiliaryModelManager: @unchecked Sendable {
    static let shared = AuxiliaryModelManager()
    
    // In-memory engine loading tasks mapped by role
    private var loadingTasks: [String: Task<AuxiliaryInferenceEngine, Error>] = [:]
    private let lock = NSLock()
    
    private let modelsDir: String
    private let registryPath: String

    /// Engines scoped to the current task tree, by role, taking precedence over registered ones.
    ///
    /// `setMockEngine` writes process-global state and `swift test` runs suites in parallel, so a
    /// suite that registered a hijacking canary decided tier 3's verdict for every other suite
    /// sanitising at that moment — failing assertions against content that was never the problem
    /// (#237). A task-local is visible only inside the `withValue` body and the tasks it spawns.
    /// Production never sets it.
    @TaskLocal static var scopedEngines: [String: AuxiliaryInferenceEngine]?
    
    /// Where this manager's loads are tracked (#778); a test passes its own.
    private let tracker: ModelLoadTracker
    /// How its Ollama engines reach the server; a test stands in for it.
    private let ollamaTransport: OllamaEngine.Transport

    init(tracker: ModelLoadTracker = .shared, ollamaTransport: OllamaEngine.Transport = .live) {
        self.tracker = tracker
        self.ollamaTransport = ollamaTransport
        self.modelsDir = IrisPaths.default.modelsDir.path
        self.registryPath = "\(modelsDir)/models.json"

        if !FileManager.default.fileExists(atPath: modelsDir) {
            try? FileManager.default.createDirectory(atPath: modelsDir, withIntermediateDirectories: true)
        }
    }
    
    func getEngine(for role: String, config: AuxiliaryModelConfig) async throws -> AuxiliaryInferenceEngine {
        // A task-scoped engine wins, and is never cached into `loadingTasks` — caching it would
        // outlive the scope and put us back where #237 started.
        if let scoped = Self.scopedEngines?[role] { return scoped }
        let task: Task<AuxiliaryInferenceEngine, Error> = lock.withLock {
            if let existing = loadingTasks[role] {
                return existing
            } else {
                let newTask = Task<AuxiliaryInferenceEngine, Error> {
                    let engine: AuxiliaryInferenceEngine
                    switch config.engineType {
                    case .llamaCPP:
                        // The load is the file read into memory, so it is tracked here (#778).
                        engine = try await tracker.track(ModelLoadPurpose(role: role), name: config.modelPathOrName) {
                            let llama = try await LlamaCPPEngine()
                            try await llama.loadModel(config: config)
                            return llama
                        }
                        return engine
                    case .ollama:
                        // Ollama's load happens in its server; the engine tracks its own preload.
                        // Tier 3 asks a thinking model not to think (#783); Vibecop keeps today's request (#798).
                        engine = OllamaEngine(tracker: tracker, transport: ollamaTransport,
                                              suppressThinking: Self.suppressesThinking(role: role))
                    case .mlx:
                        try await tracker.track(ModelLoadPurpose(role: role), name: config.modelPathOrName) {
                            try await MLXEngine.shared.loadModel(config: config)
                        }
                        return MLXEngine.shared
                    case .cloud:
                        // Nothing local to load.
                        var cloud = CloudAuxiliaryEngine()
                        cloud.role = role
                        engine = cloud
                    }
                    
                    try await engine.loadModel(config: config)
                    return engine
                }
                loadingTasks[role] = newTask
                return newTask
            }
        }
        
        do {
            return try await task.value
        } catch {
            _ = lock.withLock { loadingTasks.removeValue(forKey: role) }
            throw error
        }
    }
    
    /// Whether an Ollama engine for `role` asks a thinking model not to think (#783): tier 3 only.
    /// On #785's fixtures gemma4:12b's canary took about 1.2 s a check instead of about 10, and
    /// missed none of the 70 attacks it blocked every time with thinking in #783's bake-off; a later
    /// 3-repeat run (#803) caught two of those 2 of 3 times each. Vibecop is unmeasured.
    static func suppressesThinking(role: String) -> Bool {
        ModelLoadPurpose(role: role) == .guardTier3
    }

    /// True once a load has been started for `role` — successfully loaded, still in flight, or a
    /// test's mock via `setMockEngine`. A failed load removes its task (see `getEngine`'s catch),
    /// so this only stays true once something is actually available to hand back. Used by
    /// `InjectionGuard.executeTier3Canary` (#202 fix round 2) so a registered engine counts as
    /// provisioned regardless of what the filesystem says.
    func hasEngine(for role: String) -> Bool {
        if Self.scopedEngines?[role] != nil { return true }
        return lock.withLock { loadingTasks[role] != nil }
    }

    func unloadEngine(for role: String) async {
        let task = lock.withLock { loadingTasks.removeValue(forKey: role) }
        if let engine = try? await task?.value {
            await engine.unloadModel()
        }
    }
    
    func setMockEngine(_ engine: AuxiliaryInferenceEngine, for role: String) {
        lock.withLock { 
            loadingTasks[role] = Task { return engine }
        }
    }
}
