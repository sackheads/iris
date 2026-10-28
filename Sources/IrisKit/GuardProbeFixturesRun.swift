import Foundation

extension GuardProbeFixtures {
    /// Writes one JSON object per line to the arm's rows file, flushed as it goes, so a run cut
    /// short keeps what it judged.
    final class Rows: @unchecked Sendable {
        private let handle: FileHandle
        private let lock = NSLock()
        init(_ url: URL) throws {
            FileManager.default.createFile(atPath: url.path, contents: nil)
            handle = try FileHandle(forWritingTo: url)
        }
        func write(_ object: [String: Any]) {
            guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]) else { return }
            lock.withLock { handle.write(data + Data("\n".utf8)) }
        }
        deinit { try? handle.close() }
    }

    static func say(_ text: String) { print("guard-probe: \(text)") }

    static func run(_ o: Options) async -> Int32 {
        guard let runtime = Runtime(o.model) else {
            FileHandle.standardError.write(Data("iris --guard-probe: --model is ollama:<name> or cloud:gemini/<id>\n".utf8))
            return 64
        }
        if case .gemini = runtime, !o.allowPaid {
            FileHandle.standardError.write(Data("iris --guard-probe: a cloud arm makes paid calls; pass --allow-paid (and --max-dollars)\n".utf8))
            return 64
        }
        // Before anything touches the Keychain or the settings: ADC's token comes from gcloud's
        // files, so the run needs no secret and must not prompt for one. Settings go to a copy
        // that dies with the process.
        if o.geminiAuth != "key" { KeychainManager.requestHeadlessBypass() }
        IrisDefaults.useVolatileCopyOfStandard()

        let fixtures: (items: [Item], sha: [String: String])
        do { fixtures = try load(URL(fileURLWithPath: (o.dir as NSString).expandingTildeInPath)) } catch {
            FileHandle.standardError.write(Data("iris --guard-probe: can't read fixtures in \(o.dir): \(error)\n".utf8))
            return 1
        }
        let all = fixtures.items + (o.joins ? joins(fixtures.items) : [])
        let outDir = URL(fileURLWithPath: (o.out as NSString).expandingTildeInPath)
        try? FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)

        // The engine, as the product builds it for the canary.
        let engine: any AuxiliaryInferenceEngine
        var header: [String: Any] = [:]
        var rates: TokenRates?
        switch runtime {
        case .ollama(let name):
            let ollama = OllamaEngine(tracker: ModelLoadTracker(log: { _ in }), suppressThinking: o.thinkOff)
            try? await ollama.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: name))
            if let preload = await ollama.pendingPreload { await preload.value }
            engine = ollama
            header["runtime"] = "ollama"
            header["model_fingerprint"] = await ollamaDigest(name) ?? "unknown"
            header["model_thinks"] = await ollamaThinks(name) ?? "unknown"
            // Quantisation, size and the parent build: a pre-release tag shows here (#783's e4b).
            header["model_details"] = await ollamaJSON("show", body: ["model": name])?["details"] ?? "unknown"
            header["think_sent"] = o.thinkOff ? "false (if the model thinks)" : "none (today's request)"
        case .gemini(let id):
            let config = ConfigManager.shared
            config.primaryProvider = LLMProvider.gemini.rawValue
            config.geminiAuthMode = o.geminiAuth == "key" ? GeminiAuthMode.apiKey.rawValue : GeminiAuthMode.adc.rawValue
            let level = o.thinkingLevel
            var cloud = CloudAuxiliaryEngine()
            cloud.role = "canary"
            cloud.model = { id }
            cloud.notice = { say($0) }
            cloud.send = { request, model in
                // The arm's model, named on every call: the product's default would be the easy tier's.
                let used = model ?? id
                GuardProbeFixtures.call?.sent(model: used)
                var url = try await LLMClient().makeGeminiURLRequest(request: request, modelName: used, streaming: false)
                if let level, let body = url.httpBody { url.httpBody = try withThinkingLevel(body, level: level) }
                let (data, response) = try await URLSession.shared.data(for: url)
                let status = (response as? HTTPURLResponse)?.statusCode ?? 0
                guard status == 200 else {
                    throw APIError(message: "Gemini HTTP \(status): \(String(decoding: data.prefix(400), as: UTF8.self))", statusCode: status, provider: "Gemini")
                }
                let usage = (try? JSONSerialization.jsonObject(with: data) as? [String: Any])?["usageMetadata"] as? [String: Any] ?? [:]
                GuardProbeFixtures.call?.used(input: usage["promptTokenCount"] as? Int ?? 0,
                                              output: usage["candidatesTokenCount"] as? Int ?? 0,
                                              thought: usage["thoughtsTokenCount"] as? Int ?? 0)
                return try JSONDecoder().decode(GeminiResponse.self, from: data)
            }
            engine = cloud
            rates = ModelPricing.resolve(family: "gemini", model: id, side: .delegated, fetched: nil).rates
            header["runtime"] = "cloud:gemini"
            header["model_fingerprint"] = "\(id) \(ISO8601DateFormatter().string(from: Date()))"
            header["thinking_level"] = level ?? "provider default"
            header["auth"] = o.geminiAuth
        }

        // A paid run says what it expects to spend before its first call, and stops at the cap.
        // Planned calls: the first pass, the repeats, the latency calls, and flips at a guessed 10%.
        let repeatSet = o.agreementSample > 0 ? agreementSample(fixtures.items, count: o.agreementSample) : all
        let planned = all + Array(repeating: repeatSet, count: max(0, o.repeats - 1)).flatMap { $0 }
            + Array(repeating: Item(id: "latency", category: "latency", text: GuardProbeCLI.defaultText, payload: nil), count: o.latency ? 15 : 0)
        if let rates {
            // Input as bytes/4 plus the prompt's ~150 tokens (capped at the 32 KB cap); 600 thinking and output tokens.
            let estimate = planned.reduce(0.0) { sum, item in
                sum + dollars((input: min(item.text.utf8.count, 32 * 1024) / 4 + 150, output: 0, thought: 600), rates: rates)
            } * (o.baseline == nil ? 1 : 1 + 0.1 * Double(o.flipRepeats))
            say(String(format: "PAID: about %d calls, about $%.2f at $%.2f/M in and $%.2f/M out (thinking billed as output); stops at $%.2f%@",
                       planned.count, estimate, rates.input * 1e6, rates.output * 1e6, o.maxDollars,
                       o.spendLedger == nil ? "" : " across every arm on the ledger"))
        }
        // Dollars already spent by the arms sharing the ledger, and this arm's own.
        let ledger = o.spendLedger.map { URL(fileURLWithPath: ($0 as NSString).expandingTildeInPath) }
        let before = ledger.flatMap { try? String(contentsOf: $0, encoding: .utf8) }
            .flatMap { Double($0.trimmingCharacters(in: .whitespacesAndNewlines)) } ?? 0
        if rates != nil, ledger != nil { say(String(format: "spent so far by arms on this ledger: $%.4f of $%.2f", before, o.maxDollars)) }
        if o.estimateOnly { return 0 }
        // Created only now, so an estimate never truncates an arm's earlier rows.
        let rows: Rows
        do { rows = try Rows(outDir.appendingPathComponent("\(o.arm).jsonl")) } catch {
            FileHandle.standardError.write(Data("iris --guard-probe: can't write \(o.out): \(error)\n".utf8))
            return 1
        }
        var spent = 0.0
        func overBudget() -> Bool { rates != nil && before + spent >= o.maxDollars }

        header.merge(["type": "header", "arm": o.arm, "task": "injection.verdict", "configuration": "tier 1 + 3",
                      "model": o.model, "dataset_family": "injection", "dataset_path": o.dir, "dataset_sha256": fixtures.sha,
                      "joins": o.joins, "repeats": o.repeats, "agreement_sample": o.agreementSample,
                      "environment": environment()]) { a, _ in a }
        rows.write(header)
        say("arm \(o.arm): \(all.count) texts, \(o.model)")

        func record(_ item: Item, _ j: Judgement, phase: String, pass: Int) {
            let cost = rates.map { dollars(j.tokens, rates: $0) } ?? 0
            spent += cost
            if cost > 0, let ledger { try? String(format: "%.6f", before + spent).write(to: ledger, atomically: true, encoding: .utf8) }
            var row: [String: Any] = ["type": "verdict", "arm": o.arm, "phase": phase, "pass": pass, "id": item.id,
                                      "category": item.category, "label": item.label, "bytes": item.text.utf8.count,
                                      "outcome": j.outcome, "seconds": (j.seconds * 1000).rounded() / 1000]
            if item.payload != nil { row["caught"] = caught(j.outcome) }
            if let e = j.error { row["error"] = String(e.prefix(300)) }
            if rates != nil {
                row["tokens_in"] = j.tokens.input; row["tokens_out"] = j.tokens.output; row["tokens_thought"] = j.tokens.thought
                row["dollars"] = cost
                row["model_used"] = j.model ?? "none"
            }
            rows.write(row)
        }

        // Latency first, from cold: an Ollama model is unloaded, then judged once, five times
        // warm, and three rounds of three at once (tool calls in one turn run in parallel).
        if o.latency {
            let probe = Item(id: "latency", category: "latency", text: GuardProbeCLI.defaultText, payload: nil)
            if case .ollama = runtime { await engine.unloadModel(); await waitUnloaded(runtime) }
            record(probe, await judge(probe.text, engine: engine), phase: "latency-cold", pass: 0)
            for _ in 0..<5 where !overBudget() { record(probe, await judge(probe.text, engine: engine), phase: "latency-warm", pass: 0) }
            for round in 1...3 where !overBudget() {
                let start = UptimeClock.live.now()
                let results = await withTaskGroup(of: Judgement.self) { group in
                    for _ in 0..<3 { group.addTask { await judge(probe.text, engine: engine) } }
                    return await group.reduce(into: []) { $0.append($1) }
                }
                for r in results { record(probe, r, phase: "latency-concurrent", pass: round) }
                rows.write(["type": "concurrent-round", "arm": o.arm, "round": round,
                            "seconds": (UptimeClock.live.seconds(since: start) * 1000).rounded() / 1000])
            }
            if case .ollama(let name) = runtime, let memory = await ollamaResident(name) {
                rows.write(["type": "memory", "arm": o.arm, "size_bytes": memory.size, "size_vram_bytes": memory.vram])
            }
        }

        var first: [String: String] = [:]
        for (n, item) in all.enumerated() {
            if overBudget() { say(String(format: "stopped at $%.2f, the cap", spent)); break }
            let j = await judge(item.text, engine: engine)
            first[item.id] = j.outcome
            record(item, j, phase: "pass", pass: 1)
            if (n + 1) % 25 == 0 { say("pass 1: \(n + 1)/\(all.count)") }
        }
        if o.repeats > 1 {
            for pass in 2...o.repeats {
                for item in repeatSet where !overBudget() { record(item, await judge(item.text, engine: engine), phase: "pass", pass: pass) }
                say("pass \(pass) done")
            }
        }
        if let path = o.baseline, let base = try? baselineOutcomes(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) {
            let flips = all.filter { first[$0.id] != nil && base[$0.id] != nil && first[$0.id] != base[$0.id] }
            say("\(flips.count) texts differ from the baseline; judging each \(o.flipRepeats) more times")
            for item in flips {
                for k in 1...max(1, o.flipRepeats) where !overBudget() {
                    record(item, await judge(item.text, engine: engine), phase: "flip", pass: k)
                }
            }
        }
        if rates != nil { say(String(format: "spent $%.4f", spent)) }
        say("rows in \(outDir.appendingPathComponent("\(o.arm).jsonl").path)")
        return 0
    }

    static func baselineOutcomes(_ url: URL) throws -> [String: String] {
        var out: [String: String] = [:]
        for line in try String(contentsOf: url, encoding: .utf8).split(separator: "\n") {
            guard let row = try JSONSerialization.jsonObject(with: Data(line.utf8)) as? [String: Any],
                  row["type"] as? String == "verdict", row["phase"] as? String == "pass", row["pass"] as? Int == 1,
                  let id = row["id"] as? String, let outcome = row["outcome"] as? String else { continue }
            out[id] = outcome
        }
        return out
    }

    // MARK: - Ollama and the machine

    private static func ollamaJSON(_ endpoint: String, body: [String: Any]? = nil) async -> [String: Any]? {
        guard let url = URL(string: "http://localhost:11434/api/\(endpoint)") else { return nil }
        var req = URLRequest(url: url)
        req.timeoutInterval = 10
        if let body {
            req.httpMethod = "POST"
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = try? JSONSerialization.data(withJSONObject: body)
        }
        guard let (data, _) = try? await URLSession.shared.data(for: req) else { return nil }
        return try? JSONSerialization.jsonObject(with: data) as? [String: Any]
    }

    static func ollamaDigest(_ name: String) async -> String? {
        let models = await ollamaJSON("tags")?["models"] as? [[String: Any]] ?? []
        return models.first { ($0["name"] as? String) == name }?["digest"] as? String
    }

    static func ollamaThinks(_ name: String) async -> Bool? {
        guard let caps = await ollamaJSON("show", body: ["model": name])?["capabilities"] as? [String] else { return nil }
        return caps.contains("thinking")
    }

    static func ollamaResident(_ name: String) async -> (size: Int, vram: Int)? {
        let models = await ollamaJSON("ps")?["models"] as? [[String: Any]] ?? []
        guard let m = models.first(where: { ($0["name"] as? String) == name }) else { return nil }
        return (m["size"] as? Int ?? 0, m["size_vram"] as? Int ?? 0)
    }

    private static func waitUnloaded(_ runtime: Runtime) async {
        guard case .ollama(let name) = runtime else { return }
        for _ in 0..<40 {
            let models = await ollamaJSON("ps")?["models"] as? [[String: Any]] ?? []
            if !models.contains(where: { ($0["name"] as? String) == name }) { return }
            try? await Task.sleep(for: .milliseconds(250))
        }
    }

    static func environment() -> [String: Any] {
        func sysctl(_ name: String) -> String? {
            var size = 0
            guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
            var buffer = [CChar](repeating: 0, count: size)
            guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
            return String(decoding: buffer.prefix { $0 != 0 }.map { UInt8(bitPattern: $0) }, as: UTF8.self)
        }
        let env = ProcessInfo.processInfo.environment
        return ["chip": sysctl("machdep.cpu.brand_string") ?? sysctl("hw.model") ?? "unknown",
                "memory_bytes": ProcessInfo.processInfo.physicalMemory,
                "macos": ProcessInfo.processInfo.operatingSystemVersionString,
                "iris_commit": env["IRIS_COMMIT"] ?? "unknown",
                "date": ISO8601DateFormatter().string(from: Date())]
    }
}
