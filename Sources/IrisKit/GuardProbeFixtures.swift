import Foundation
import CryptoKit

/// `iris --guard-probe --fixtures DIR`: #783's tier-3 bake-off. Every text in a fixtures folder
/// (#785's `benign.jsonl` and `attacks.jsonl`) goes through the product's guard path with tier 2
/// passing everything, so each verdict is the canary's alone, on one model per run ("arm"). Rows go
/// to `<out>/<arm>.jsonl`; `--compare` turns a folder of them into one table. Interim, and minimal on
/// purpose: #788's `iris --eval run injection.verdict` replaces it. Field names follow #788's
/// `EvalResult` (outcome, caught, seconds; key and environment in the header).
///
/// The only thing it changes about a request is a cloud arm's `--thinking-level`, added here to the
/// body the product built; the product's own request never carries one (#783, pinned by a test).
enum GuardProbeFixtures {
    struct Options: Equatable {
        var dir = ""
        var model = ""
        var arm = ""
        var out = ""
        var thinkOff = false
        var thinkingLevel: String?
        var repeats = 1
        /// Passes after the first run over this many fixed texts; 0 means the whole set.
        var agreementSample = 0
        /// Another arm's rows: texts whose first-pass outcome differs from it are re-judged.
        var baseline: String?
        var flipRepeats = 3
        var joins = false
        var latency = false
        var allowPaid = false
        var maxDollars = 5.0
        /// "adc" keeps the run off the Keychain (gcloud's ADC needs no secret); "key" reads it.
        var geminiAuth = "adc"
        /// A file holding the dollars spent so far by every arm that shares it, so one
        /// `--max-dollars` caps several cloud arms together.
        var spendLedger: String?
        /// Print the estimate and make no call.
        var estimateOnly = false
        /// Only the latency calls: re-times an arm without judging the fixtures again.
        var latencyOnly = false
    }

    enum Runtime: Equatable {
        case ollama(String)
        case gemini(String)

        /// `ollama:<name>` or `cloud:gemini/<id>`, split on the first colon (Ollama names have them).
        init?(_ spec: String) {
            guard let colon = spec.firstIndex(of: ":") else { return nil }
            let rest = String(spec[spec.index(after: colon)...])
            switch spec[..<colon] {
            case "ollama" where !rest.isEmpty: self = .ollama(rest)
            case "cloud" where rest.hasPrefix("gemini/") && rest.count > "gemini/".count:
                self = .gemini(String(rest.dropFirst("gemini/".count)))
            default: return nil
            }
        }
    }

    struct Sample: Decodable {
        let id: String
        let category: String
        let text: String
        let payload: String?
    }

    /// One text to judge: a fixture, or a category's texts joined to 8 or 32 KB (#785's joins).
    struct Item {
        let id: String
        let category: String
        let text: String
        let payload: String?
        var label: String { payload == nil ? "benign" : "attack" }
    }

    /// What one canary call did, filled in by `Recording` and the cloud send.
    final class Call: @unchecked Sendable {
        private let lock = NSLock()
        private var _error: String?, _response: String?, _model: String?
        private var _tokens = (input: 0, output: 0, thought: 0)
        var error: String? { lock.withLock { _error } }
        var response: String? { lock.withLock { _response } }
        /// The model the request actually named (a cloud arm's; CloudAuxiliaryEngine can fall back).
        var model: String? { lock.withLock { _model } }
        func sent(model: String) { lock.withLock { _model = model } }
        var tokens: (input: Int, output: Int, thought: Int) { lock.withLock { _tokens } }
        func failed(_ e: String) { lock.withLock { _error = e } }
        func answered(_ r: String) { lock.withLock { _response = r } }
        func used(input: Int, output: Int, thought: Int) {
            lock.withLock { _tokens = (_tokens.input + input, _tokens.output + output, _tokens.thought + thought) }
        }
    }

    @TaskLocal static var call: Call?

    /// The canary engine, recording what it answered or threw for the call in scope.
    struct Recording: AuxiliaryInferenceEngine {
        let inner: any AuxiliaryInferenceEngine
        func loadModel(config: AuxiliaryModelConfig) async throws { try await inner.loadModel(config: config) }
        func unloadModel() async { await inner.unloadModel() }
        func generate(prompt: String, jsonSchema: String?) async throws -> String {
            do {
                let response = try await inner.generate(prompt: prompt, jsonSchema: jsonSchema)
                GuardProbeFixtures.call?.answered(response)
                return response
            } catch {
                GuardProbeFixtures.call?.failed("\(error)")
                throw error
            }
        }
    }

    /// Tier 2 that passes everything, so the verdict is the canary's.
    struct PassingTier2: CoreMLModelProtocol {
        func evaluate(text: String) async throws -> Double { 0 }
        func tokenCount(_ text: String) -> Int { max(1, text.utf8.count / 4) }
    }

    /// `body` with Gemini's `generationConfig.thinkingConfig.thinkingLevel` set: the probe's own
    /// run option, never the product's.
    static func withThinkingLevel(_ body: Data, level: String) throws -> Data {
        guard var json = try JSONSerialization.jsonObject(with: body) as? [String: Any] else { return body }
        var generation = json["generationConfig"] as? [String: Any] ?? [:]
        generation["thinkingConfig"] = ["thinkingLevel": level]
        json["generationConfig"] = generation
        return try JSONSerialization.data(withJSONObject: json)
    }

    struct Judgement {
        let outcome: String
        let seconds: Double
        let error: String?
        let tokens: (input: Int, output: Int, thought: Int)
        var model: String? = nil
        /// The canary's raw answer, for reading reply shapes (#821); nil when it threw.
        var reply: String? = nil
    }

    /// One text through tier 1, a passing tier 2, then the canary: the product's path. Both seams
    /// are task-scoped.
    static func judge(_ text: String, engine: any AuxiliaryInferenceEngine) async -> Judgement {
        let call = Call()
        let start = UptimeClock.live.now()
        let outcome = await $call.withValue(call) {
            await AuxiliaryModelManager.$scopedEngines.withValue(["canary": Recording(inner: engine)]) {
                await CoreMLEvaluator.$scopedModel.withValue(.init(PassingTier2())) {
                    await InjectionGuard.classifyUntrusted(OutputCap.cap(text), contextTag: "tool_output_run_command",
                                                           maxTier: .tier3_canary, protectionEnabled: true)
                }
            }
        }
        let seconds = UptimeClock.live.seconds(since: start)
        let name: String
        switch outcome {
        case .passed: name = "passed"
        case .blocked:
            // The product blocks on an error and on a reply with no clear verdict (#821): both fail closed.
            let answer = call.response ?? ""
            name = call.error != nil || InjectionGuard.canaryVerdict(answer) == .unreadable ? "fail-closed" : "blocked"
        }
        return Judgement(outcome: name, seconds: seconds, error: call.error, tokens: call.tokens, model: call.model,
                         reply: call.response)
    }

    static func load(_ dir: URL) throws -> (items: [Item], sha: [String: String]) {
        var items: [Item] = [], sha: [String: String] = [:]
        for file in ["benign.jsonl", "attacks.jsonl"] {
            let data = try Data(contentsOf: dir.appendingPathComponent(file))
            sha[file] = SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
            for line in String(decoding: data, as: UTF8.self).split(separator: "\n") {
                let s = try JSONDecoder().decode(Sample.self, from: Data(line.utf8))
                items.append(Item(id: s.id, category: s.category, text: s.text, payload: s.payload))
            }
        }
        return (items, sha)
    }

    /// Each benign category's texts joined to 8 and 32 KB, as #785's report builds them.
    static func joins(_ items: [Item]) -> [Item] {
        let benign = items.filter { $0.payload == nil }
        return Set(benign.map(\.category)).sorted().flatMap { category in
            let parts = benign.filter { $0.category == category }.map(\.text)
            return [8, 32].map { kb in
                var text = "", i = 0
                while text.utf8.count < kb * 1024 { text += (text.isEmpty ? "" : "\n\n") + parts[i % parts.count]; i += 1 }
                return Item(id: "join-\(category)-\(kb)KB", category: category, text: text, payload: nil)
            }
        }
    }

    /// A fixed sample: a third attacks, the rest benign, each in sha256-of-id order, so every arm
    /// and every run takes the same texts.
    static func agreementSample(_ items: [Item], count: Int) -> [Item] {
        func key(_ i: Item) -> String { SHA256.hash(data: Data(i.id.utf8)).map { String(format: "%02x", $0) }.joined() }
        let attacks = items.filter { $0.payload != nil }.sorted { key($0) < key($1) }
        let benign = items.filter { $0.payload == nil }.sorted { key($0) < key($1) }
        let a = min(attacks.count, count / 3)
        return Array(attacks.prefix(a)) + Array(benign.prefix(count - a))
    }

    /// Whether the payload was kept from the model: the text blocked whole, or fail-closed.
    static func caught(_ outcome: String) -> Bool { outcome != "passed" }

    /// The input tokens a call is expected to cost: the capped text at 4 bytes a token, plus the
    /// canary prompt's ~150. Calibration scales it by what the provider reported.
    static func predictedInput(_ item: Item) -> Int { min(item.text.utf8.count, 32 * 1024) / 4 + 150 }

    static func dollars(_ t: (input: Int, output: Int, thought: Int), rates: TokenRates) -> Double {
        Double(t.input) * rates.input + Double(t.output + t.thought) * rates.output
    }
}
