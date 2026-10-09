import Foundation

actor OllamaEngine: AuxiliaryInferenceEngine {
    private var modelName: String = ""
    
    private static let baseURL = "http://localhost:11434"

    func loadModel(config: AuxiliaryModelConfig) async throws {
        self.modelName = config.modelPathOrName
        // Warm the model on init so the first Vibecop call doesn't hit a cold-start timeout
        preloadModel()
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
        guard !modelName.isEmpty,
              let url = URL(string: "\(Self.baseURL)/api/ps") else { return false }
        
        var req = URLRequest(url: url)
        req.httpMethod = "GET"
        
        do {
            let (data, response) = try await URLSession.shared.data(for: req)
            guard let httpResponse = response as? HTTPURLResponse,
                  httpResponse.statusCode == 200 else { return false }
            
            let models = Self.parsePSModels(from: data)
            return Self.modelIsInPSList(modelName, models: models)
        } catch {
            return false
        }
    }
    
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
    
    /// Fires a non-blocking warmup request to keep the model alive.
    /// Ollama's default keep_alive is ~5m, so this extends the window.
    private func preloadModel() {
        Task {
            guard !modelName.isEmpty,
                  let url = URL(string: "\(Self.baseURL)/api/generate") else { return }
            var req = URLRequest(url: url)
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            let body: [String: Any] = [
                "model": modelName,
                "prompt": "",
                "keep_alive": "5m"
            ]
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
            _ = try? await URLSession.shared.data(for: req)
        }
    }
    func generate(prompt: String, jsonSchema: String?) async throws -> String {
        try await generate(prompt: prompt, jsonSchema: jsonSchema, images: nil)
    }

    func generate(prompt: String, jsonSchema: String?, images: [String]? = nil) async throws -> String {
        let url = URL(string: "http://localhost:11434/api/generate")!
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        
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
        
        req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        
        let (data, response) = try await URLSession.shared.data(for: req)
        
        guard let httpResponse = response as? HTTPURLResponse, httpResponse.statusCode == 200 else {
            let errString = String(data: data, encoding: .utf8) ?? "Unknown error"
            throw NSError(domain: "OllamaEngine", code: 1, userInfo: [NSLocalizedDescriptionKey: "Ollama Error: \(errString)"])
        }
        
        if let json = try JSONSerialization.jsonObject(with: data) as? [String: Any],
           let responseText = json["response"] as? String {
            return responseText
        }
        
        throw NSError(domain: "OllamaEngine", code: 2, userInfo: [NSLocalizedDescriptionKey: "Invalid Ollama JSON response"])
    }
}
