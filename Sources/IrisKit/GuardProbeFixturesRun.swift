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
        // The spend ledger, opened before anything else: a damaged one stops the run here.
        let ledger: SpendLedger?
        if case .gemini = runtime {
            do { ledger = try SpendLedger(path: o.spendLedger, arm: o.arm, cap: o.maxDollars) } catch {
                FileHandle.standardError.write(Data("iris --guard-probe: \(error.localizedDescription)\n".utf8))
                return 1
            }
        } else {
            ledger = nil
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
        if let rates, let ledger {
            say(String(format: "spent so far on this ledger: $%.4f of $%.2f", (try? ledger.total()) ?? 0, o.maxDollars))
            // --estimate-only calibrates on three real calls (the smallest, median and largest
            // fixture), counted in the ledger: thinking varies by model and level, so a flat guess
            // would put every level at one price. A full run states its assumption instead.
            var inRatio = 1.0, outPerCall = 600.0
            var basis = "uncalibrated: 600 output and thinking tokens per call assumed; --estimate-only calibrates"
            if o.estimateOnly {
                let bySize = fixtures.items.sorted { $0.text.utf8.count < $1.text.utf8.count }
                let probes = [bySize.first!, bySize[bySize.count / 2], bySize.last!]
                var predicted = 0, measuredIn = 0, measuredOut = 0, cost = 0.0
                for item in probes {
                    guard let j = await paidJudge(item, engine: engine, ledger: ledger, rates: rates) else {
                        say("the ledger is at the cap: no calibration calls"); return 1
                    }
                    predicted += predictedInput(item)
                    measuredIn += j.tokens.input
                    measuredOut += j.tokens.output + j.tokens.thought
                    cost += dollars(j.tokens, rates: rates)
                    if let e = j.error { say("calibration call failed: \(e.prefix(200))") }
                }
                if measuredIn > 0 {
                    inRatio = Double(measuredIn) / Double(max(1, predicted))
                    outPerCall = Double(measuredOut) / Double(probes.count)
                }
                basis = String(format: "calibrated on %d calls ($%.4f): %.0f output and thinking tokens per call, input %.2fx bytes/4+150",
                               probes.count, cost, outPerCall, inRatio)
            }
            let flipShare = o.baseline == nil ? 0 : 0.1 * Double(o.flipRepeats)
            let base = planned.reduce(0.0) { $0 + Double(predictedInput($1)) * inRatio * rates.input + outPerCall * rates.output }
            say(String(format: "PAID: about %d calls, about $%.2f, plus up to $%.2f if 10%% of texts differ from the baseline (re-run %d times); "
                       + "at $%.2f/M in and $%.2f/M out (thinking billed as output); stops at $%.2f%@",
                       planned.count, base, base * flipShare, o.flipRepeats, rates.input * 1e6, rates.output * 1e6, o.maxDollars,
                       o.spendLedger == nil ? "" : " across every arm on this ledger"))
            say(basis)
        }
        if o.estimateOnly { return 0 }
        // Created only now, so an estimate never truncates an arm's earlier rows.
        let rows: Rows
        do { rows = try Rows(outDir.appendingPathComponent("\(o.arm).jsonl")) } catch {
            FileHandle.standardError.write(Data("iris --guard-probe: can't write \(o.out): \(error)\n".utf8))
            return 1
        }
        var spent = 0.0, stopped = false
        /// One judgement, paid for through the ledger; nil once the cap is reached.
        func next(_ item: Item) async -> Judgement? {
            guard !stopped else { return nil }
            guard let j = await paidJudge(item, engine: engine, ledger: ledger, rates: rates) else {
                stopped = true
                say(String(format: "stopped at the cap: this arm spent $%.4f", spent))
                return nil
            }
            return j
        }

        header.merge(["type": "header", "arm": o.arm, "task": "injection.verdict", "configuration": "tier 1 + 3",
                      "model": o.model, "dataset_family": "injection", "dataset_path": o.dir, "dataset_sha256": fixtures.sha,
                      "joins": o.joins, "repeats": o.repeats, "agreement_sample": o.agreementSample,
                      "environment": environment()]) { a, _ in a }
        rows.write(header)
        say("arm \(o.arm): \(all.count) texts, \(o.model)")

        func record(_ item: Item, _ j: Judgement, phase: String, pass: Int) {
            let cost = rates.map { dollars(j.tokens, rates: $0) } ?? 0
            spent += cost
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
            if let j = await next(probe) { record(probe, j, phase: "latency-cold", pass: 0) }
            for _ in 0..<5 { if let j = await next(probe) { record(probe, j, phase: "latency-warm", pass: 0) } }
            for round in 1...3 where !stopped {
                let start = UptimeClock.live.now()
                let results = await withTaskGroup(of: Judgement?.self) { group in
                    let paidRates = rates
                    for _ in 0..<3 { group.addTask { await paidJudge(probe, engine: engine, ledger: ledger, rates: paidRates) } }
                    return await group.reduce(into: [Judgement]()) { if let j = $1 { $0.append(j) } }
                }
                if results.count < 3 { stopped = true }
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
            guard let j = await next(item) else { break }
            first[item.id] = j.outcome
            record(item, j, phase: "pass", pass: 1)
            if (n + 1) % 25 == 0 { say("pass 1: \(n + 1)/\(all.count)") }
        }
        if o.repeats > 1 {
            for pass in 2...o.repeats {
                for item in repeatSet { if let j = await next(item) { record(item, j, phase: "pass", pass: pass) } }
                say("pass \(pass) done")
            }
        }
        if let path = o.baseline, let base = try? baselineOutcomes(URL(fileURLWithPath: (path as NSString).expandingTildeInPath)) {
            let flips = all.filter { first[$0.id] != nil && base[$0.id] != nil && first[$0.id] != base[$0.id] }
            say("\(flips.count) texts differ from the baseline; judging each \(o.flipRepeats) more times")
            for item in flips {
                for k in 1...max(1, o.flipRepeats) { if let j = await next(item) { record(item, j, phase: "flip", pass: k) } }
            }
        }
        if rates != nil { say(String(format: "spent $%.4f", spent)) }
        say("rows in \(outDir.appendingPathComponent("\(o.arm).jsonl").path)")
        return 0
    }

    /// The most one call could cost: twice its expected input and 25,000 output and thinking
    /// tokens, about Gemini Flash's largest thinking budget. Reserved before the call, so arms
    /// running together can't all pass the cap at once.
    static func bound(_ item: Item, rates: TokenRates) -> Double {
        Double(predictedInput(item) * 2) * rates.input + 25_000 * rates.output
    }

    /// One judgement. A paid one reserves its bound in the ledger first and settles what it cost
    /// after; nil when the reserve would pass the cap, or the ledger fails.
    static func paidJudge(_ item: Item, engine: any AuxiliaryInferenceEngine, ledger: SpendLedger?, rates: TokenRates?) async -> Judgement? {
        guard let ledger, let rates else { return await judge(item.text, engine: engine) }
        let id: UUID
        do {
            guard let reserved = try ledger.reserve(bound(item, rates: rates)) else { return nil }
            id = reserved
        } catch {
            say(error.localizedDescription)
            return nil
        }
        let j = await judge(item.text, engine: engine)
        do { try ledger.settle(id, dollars: dollars(j.tokens, rates: rates), tokens: j.tokens) } catch { say(error.localizedDescription) }
        return j
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
