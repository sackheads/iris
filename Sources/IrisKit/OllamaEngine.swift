import Foundation

actor OllamaEngine: AuxiliaryInferenceEngine {
    private var modelName: String = ""
    private var purpose: ModelLoadPurpose = .other("ollama")
    private var generates = 0
    private let tracker: ModelLoadTracker
    private let transport: Transport
    /// The preload in flight, if any: at most one per engine, so a cold call never shows twice.
    private var preload: Task<Void, Never>?
    /// Ask a thinking model not to think (#783): gemma4 otherwise writes 150-570 hidden tokens
    /// before a one-word verdict, about 90% of each call's time. `AuxiliaryModelManager` sets it
    /// for tier 3's canary only (`suppressesThinking(role:)`), and `--guard-probe --think off`.
    let suppressThinking: Bool
    /// Whether the model reports the `thinking` capability, once `/api/show` has said; `think` is
    /// sent only to a model that has it, so a non-thinking model's request is unchanged.
    private var thinks: Bool?

    init(tracker: ModelLoadTracker = .shared, transport: Transport = .live, suppressThinking: Bool = false) {
        self.tracker = tracker
        self.transport = transport
        self.suppressThinking = suppressThinking
    }
    
    private static let baseURL = "http://localhost:11434"

    /// The two requests a load decision rests on (#778), injectable so a test stands in for the
    /// server. `ps` is `/api/ps`'s body, nil when it didn't answer 200; `preload` posts a
    /// `/api/generate` body and returns the status and body.
    struct Transport: Sendable {
        var ps: @Sendable () async -> Data?
        var preload: @Sendable (Data) async throws -> (status: Int, data: Data)
        /// A `/api/generate` request (#779 review): through here so a test drives `generate`.
        var generate: @Sendable (Data) async throws -> (status: Int, data: Data) = { try await Transport.post("generate", $0) }
        /// `/api/show`'s body for a model, nil when it didn't answer 200 (#783).
        var show: @Sendable (Data) async -> Data? = { body in
            guard let (status, data) = try? await Transport.post("show", body, timeout: 5), status == 200 else { return nil }
            return data
        }

        /// POSTs `body` to `/api/<endpoint>`. The shape #794 shares, adding its own endpoints.
        static func post(_ endpoint: String, _ body: Data, timeout: TimeInterval? = nil) async throws -> (status: Int, data: Data) {
            var req = URLRequest(url: URL(string: "\(OllamaEngine.baseURL)/api/\(endpoint)")!)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            if let timeout { req.timeoutInterval = timeout }
            req.httpBody = body
            let (data, response) = try await URLSession.shared.data(for: req)
            return ((response as? HTTPURLResponse)?.statusCode ?? 0, data)
        }

        static let live = Transport(
            ps: {
                guard let url = URL(string: "\(OllamaEngine.baseURL)/api/ps") else { return nil }
                var req = URLRequest(url: url)
                req.httpMethod = "GET"
                req.timeoutInterval = 3
                guard let (data, response) = try? await URLSession.shared.data(for: req),
                      (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
                return data
            },
            preload: { try await post("generate", $0) })
    }

    func loadModel(config: AuxiliaryModelConfig) async throws {
        self.modelName = config.modelPathOrName
        self.purpose = ModelLoadPurpose(role: config.role)
        // Warm the model on init so the first Vibecop call doesn't hit a cold-start timeout
        startPreload()
    }
    
    func unloadModel() async {
        let url = URL(string: "\(Self.baseURL)/api/generate")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = [
            "model": modelName,
            "keep_alive": 0
        ]
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        _ = try? await URLSession.shared.data(for: req)
    }
    
    /// Checks whether the model is currently loaded in Ollama's VRAM/RAM
    /// by querying the /api/ps endpoint.
    func isModelLoaded() async -> Bool {
        await psListsModel() ?? false
    }

    /// Whether `/api/ps` lists this engine's model; nil when it didn't answer, which decides nothing.
    private func psListsModel() async -> Bool? {
        guard !modelName.isEmpty, let data = await transport.ps() else { return nil }
        return Self.modelIsInPSList(modelName, models: Self.parsePSModels(from: data))
    }

    /// Before each generate (#779): a model Ollama has unloaded (keep_alive ran out, or Ollama
    /// restarted) is loaded again by that call, so the preload is re-sent beside it, and its reply,
    /// not the generate's, ends the load. A `/api/ps` that doesn't answer shows nothing rather
    /// than guess.
    ///
    /// Never awaited by the generate it serves (#779 review): a busy server is slow to answer ps,
    /// and Vibecop's verdict is bounded. Skipped while a reply came within keep_alive, since the
    /// model is still loaded then.
    func prepareForGenerate(now: Double = MonotonicClock.nowMs()) async {
        if let last = lastReplyAt, now - last < Self.recentReplyMs { return }
        guard preload == nil, await psListsModel() == false, preload == nil else { return }
        startPreload()
    }

    /// Under keep_alive's 5 minutes, with margin: a reply this recent means the model is loaded.
    static let recentReplyMs: Double = 4.5 * 60 * 1000
    /// When Ollama last answered a preload or generate with 200, in uptime ms.
    private var lastReplyAt: Double?
    /// The cold-model check beside the generate in flight, for a test to await.
    private(set) var pendingColdCheck: Task<Void, Never>?
    
    // MARK: - Parsing (pure functions — testable without network)
    
    /// Parses model names from an Ollama /api/tags JSON response body.
    /// Returns a sorted array of model name strings, or [] on parse failure.
    static func parseModelNames(from data: Data) -> [String] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models.compactMap { $0["name"] as? String }.sorted()
    }
    
    /// Parses the status field from an Ollama /api/pull JSON response body.
    /// Returns the status string, or nil on parse failure.
    static func parsePullStatus(from data: Data) -> String? {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let status = json["status"] as? String else { return nil }
        return status
    }
    
    /// Parses the "models" array from an Ollama /api/ps JSON response body.
    /// Returns the raw model dictionaries, or [] on parse failure.
    static func parsePSModels(from data: Data) -> [[String: Any]] {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let models = json["models"] as? [[String: Any]] else { return [] }
        return models
    }
    
    /// Checks whether a model name appears in the ps model list,
    /// matching exactly or by colon-prefix (Ollama's tag separator).
    static func modelIsInPSList(_ name: String, models: [[String: Any]]) -> Bool {
        models.contains { model in
            guard let modelName = model["name"] as? String else { return false }
            return modelName == name || modelName.hasPrefix(name + ":")
        }
    }
    
    // MARK: - Static helpers for model discovery & pull
    
    /// Quick check whether the Ollama daemon is reachable at localhost:11434.
    /// Uses a short timeout so the UI doesn't hang.
    static func isDaemonReachable() async -> Bool {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return false }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 3
        do {
            let (_, response) = try await URLSession.shared.data(for: req)
            return (response as? HTTPURLResponse)?.statusCode == 200
        } catch {
            return false
        }
    }
    
    /// Probes the local Ollama daemon for installed models via GET /api/tags.
    /// Returns an array of model name strings (e.g. ["gemma4:12b", "qwen3.5:latest"]),
    /// or an empty array if the daemon is unreachable or returns an error.
    static func listInstalledModels() async -> [String] {
        guard let url = URL(string: "\(baseURL)/api/tags") else { return [] }
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        req.timeoutInterval = 5
        
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return [] }
            return parseModelNames(from: data)
        } catch {
            return []
        }
    }
    
    /// Pulls a model from Ollama's registry. Reports progress via the callback
    /// with real incremental status (uses stream:true and parses NDJSON lines).
    static func pullModel(name: String, onProgress: @escaping @Sendable (String) -> Void) async throws {
        guard let url = URL(string: "\(baseURL)/api/pull") else {
            throw NSError(domain: "OllamaEngine", code: 3, userInfo: [NSLocalizedDescriptionKey: "Invalid base URL"])
        }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        let body: [String: Any] = ["name": name, "stream": true]
        req.httpBody = try JSONSerialization.data(withJSONObject: body)
        req.timeoutInterval = 600
        
        onProgress("Starting pull of \(name)…")
        
        let (bytes, response) = try await URLSession.shared.bytes(for: req)
        guard let httpResponse = response as? HTTPURLResponse else {
            throw NSError(domain: "OllamaEngine", code: 4, userInfo: [NSLocalizedDescriptionKey: "No HTTP response"])
        }
        
        if httpResponse.statusCode != 200 {
            // Read error body
            var errorBody = ""
            for try await line in bytes.lines {
                errorBody += line
            }
            throw NSError(domain: "OllamaEngine", code: 5,
                          userInfo: [NSLocalizedDescriptionKey: "Pull failed (HTTP \(httpResponse.statusCode)): \(errorBody)"])
        }
        
        // Parse NDJSON stream — each line is a JSON object with a "status" field
        var lastStatus = ""
        for try await line in bytes.lines {
            guard let lineData = line.data(using: .utf8),
                  let status = parsePullStatus(from: lineData) else { continue }
            lastStatus = status
            onProgress(status)
        }
        
        // If the stream ended without an explicit "success", check the last status
        if lastStatus != "success" {
            // Some Ollama versions don't send a final "success" line;
            // treat any non-error terminal state as done.
            onProgress("done")
        }
    }
    
    /// Ollama's timings from a `/api/generate` reply, in ms, for #778's log: `load_duration` is
    /// the model load the request waited on. Ollama reports durations in nanoseconds. Empty when
    /// the body has none.
    static func timings(from data: Data) -> String {
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return "" }
        return ["load_duration", "prompt_eval_duration", "eval_duration", "total_duration"].compactMap { key in
            guard let ns = (json[key] as? NSNumber)?.doubleValue else { return nil }
            return "\(key)_ms=\(Int((ns / 1_000_000).rounded()))"
        }.joined(separator: " ")
    }

    /// The preload in flight, for a test to await.
    var pendingPreload: Task<Void, Never>? { preload }

    /// Fires a non-blocking warmup request to keep the model alive.
    /// Ollama's default keep_alive is ~5m, so this extends the window.
    /// Tracked as a load from send to reply (#778): Ollama answers it only once the model is
    /// resident, so the load ends on that reply and never on a guess.
    @discardableResult
    func startPreload() -> Task<Void, Never>? {
        guard !modelName.isEmpty else { return nil }
        if let preload { return preload }
        let body = (try? JSONSerialization.data(withJSONObject: [
            "model": modelName,
            "prompt": "",
            "keep_alive": "5m"
        ] as [String: Any])) ?? Data()
        let load = tracker.begin(purpose, name: modelName)
        let task = Task {
            do {
                let (status, data) = try await transport.preload(body)
                if status == 200 {
                    lastReplyAt = MonotonicClock.nowMs()
                    tracker.end(load, .loaded, detail: Self.timings(from: data))
                } else {
                    tracker.end(load, .failed("HTTP \(status)"))
                }
            } catch {
                tracker.end(load, .failed("\(error.localizedDescription)"))
            }
            preload = nil
        }
        preload = task
        return task
    }

    func generate(prompt: String, jsonSchema: String?) async throws -> String {
        try await generate(prompt: prompt, jsonSchema: jsonSchema, images: nil)
    }

    /// Whether `/api/show` lists `thinking` for this model. nil when it didn't answer, and asked
    /// again next time: only a definite answer is kept.
    private func modelThinks() async -> Bool? {
        if let thinks { return thinks }
        guard let body = try? JSONSerialization.data(withJSONObject: ["model": modelName]),
              let data = await transport.show(body),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { return nil }
        let answer = (json["capabilities"] as? [String])?.contains("thinking") ?? false
        thinks = answer
        return answer
    }

    func generate(prompt: String, jsonSchema: String?, images: [String]? = nil) async throws -> String {
        var body: [String: Any] = [
            "model": modelName,
            "prompt": prompt,
            "stream": false
        ]
        
        if jsonSchema != nil {
            body["format"] = "json"
        }
        
        if let images, !images.isEmpty {
            body["images"] = images
        }

        // Only to a model that thinks: a model without the capability gets today's request.
        if suppressThinking, await modelThinks() == true {
            body["think"] = false
        }
        
        let requestBody = (try? JSONSerialization.data(withJSONObject: body)) ?? Data()
        
        // Beside the request, not before it (#779 review): it only decides whether a load shows.
        pendingColdCheck = Task { await self.prepareForGenerate() }
        generates += 1
        let call = "ollama.generate purpose=\"\(purpose.label)\" model=\(modelName) n=\(generates)"
        // stream:false, so the first byte is the whole reply: one line for both (#778).
        PerformanceProfiler.event("\(call) sent")
        let sentAt = MonotonicClock.nowMs()
        let status: Int
        let data: Data
        do {
            (status, data) = try await transport.generate(requestBody)
        } catch {
            PerformanceProfiler.event("\(call) failed ms=\(Int(MonotonicClock.nowMs() - sentAt)) error=\"\(error.localizedDescription)\"")
            throw error
        }
        PerformanceProfiler.event("\(call) complete ms=\(Int(MonotonicClock.nowMs() - sentAt)) status=\(status) \(Self.timings(from: data))")
        
        guard status == 200 else {
            let errString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OllamaEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ollama Error: \(errString)"])
        }
        lastReplyAt = MonotonicClock.nowMs()
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let responseText = json["response"] as? String {
            return responseText
        }
        
        throw NSError(domain: "OllamaEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama JSON response"])
    }

}
