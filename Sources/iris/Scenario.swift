import Foundation

/// A headless benchmark scenario: what to run, which client, and (for the fake client) the
/// scripted model responses. Decoded from JSON so runs can be authored/tweaked without
/// recompiling. Optional fields default so a minimal scenario is just a name + turns.
struct Scenario: Codable, Sendable {
    enum ClientMode: String, Codable, Sendable { case fake, real }

    /// Subsystems to enable for the run. All default off so a fake run measures pure harness
    /// overhead — guards/hooks/sandbox pull in local models and external state that add noise.
    struct Toggles: Codable, Sendable {
        var guards: Bool
        var hooks: Bool
        var sandbox: Bool

        init(guards: Bool = false, hooks: Bool = false, sandbox: Bool = false) {
            self.guards = guards; self.hooks = hooks; self.sandbox = sandbox
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            guards = try c.decodeIfPresent(Bool.self, forKey: .guards) ?? false
            hooks = try c.decodeIfPresent(Bool.self, forKey: .hooks) ?? false
            sandbox = try c.decodeIfPresent(Bool.self, forKey: .sandbox) ?? false
        }
    }

    /// A single scripted model turn, mapped into a `GeminiResponse`.
    struct ScriptedResponse: Codable, Sendable {
        enum Kind: String, Codable, Sendable { case text, toolCalls }
        var kind: Kind
        var text: String?
        var calls: [ScriptedCall]?

        /// Build the `GeminiResponse` the engine would receive for this scripted turn.
        func asGeminiResponse() -> GeminiResponse {
            let parts: [Part]
            switch kind {
            case .text:
                parts = [Part(text: text ?? "", functionCall: nil, functionResponse: nil,
                              thought_signature: nil, thoughtSignature: nil)]
            case .toolCalls:
                parts = (calls ?? []).map { call in
                    Part(text: nil,
                         functionCall: FunctionCall(name: call.name, args: call.args),
                         functionResponse: nil, thought_signature: nil, thoughtSignature: nil)
                }
            }
            return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: parts))],
                                  usageMetadata: nil)
        }
    }

    struct ScriptedCall: Codable, Sendable {
        var name: String
        var args: [String: JSONValue]
    }

    /// A finished job run written into the run's own job ledger (5b). Only harness-owned fields:
    /// the briefing reads name and status, and `outcome` reaches the model only through an event
    /// card's history line.
    struct LedgerRun: Codable, Sendable, Equatable {
        var name: String
        var status: JobRun.Status
        var outcome: String?

        init(name: String, status: JobRun.Status, outcome: String? = nil) {
            self.name = name; self.status = status; self.outcome = outcome
        }
    }

    struct Turn: Codable, Sendable {
        var prompt: String
        var source: String
        /// Runs added to the ledger just before this turn starts, so the pinned conversation's
        /// briefing (built at turn start) sees them. Nil means none.
        var ledgerRuns: [LedgerRun]?
        /// A run whose event card is delivered while this turn is in flight: at the start of its
        /// second model round, so the line is drained into the turn's own history mid-turn. A turn
        /// with only one round gets the card right after it ends instead. Nil means none.
        var eventCard: LedgerRun?

        init(prompt: String, source: String = "User", ledgerRuns: [LedgerRun]? = nil, eventCard: LedgerRun? = nil) {
            self.prompt = prompt; self.source = source
            self.ledgerRuns = ledgerRuns; self.eventCard = eventCard
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            prompt = try c.decode(String.self, forKey: .prompt)
            source = try c.decodeIfPresent(String.self, forKey: .source) ?? "User"
            ledgerRuns = try c.decodeIfPresent([LedgerRun].self, forKey: .ledgerRuns)
            eventCard = try c.decodeIfPresent(LedgerRun.self, forKey: .eventCard)
        }
    }

    var name: String
    var clientMode: ClientMode
    var tier: ModelTier
    var toggles: Toggles
    var latencyMs: FakeLLMClient.Latency?
    var turns: [Turn]
    var scriptedResponses: [ScriptedResponse]
    /// Tools this prompt warrants. `[]` means none (a bait prompt); nil means unscored.
    var expectedTools: [String]?
    /// Facts seeded into a fresh in-memory store before turn 1 — never `FactStoreManager.shared`,
    /// fake lane or real — so a scenario that depends on the fact-store block appearing/
    /// disappearing (e.g. `caching`) is deterministic. Nil means none (5a).
    var seedFacts: [String]?
    /// Run the turns in the pinned conversation (`AppState.activityConversationId()`) instead of
    /// a fresh unpinned one, so pinned-only turn context and tools apply (5b).
    var pinned: Bool

    /// True when the run writes to its `AppState`'s store (the ledger, the pin's meta key), which
    /// must then be an explicit in-memory one.
    var usesOwnStore: Bool {
        pinned || turns.contains { $0.ledgerRuns?.isEmpty == false || $0.eventCard != nil }
    }

    init(name: String, clientMode: ClientMode = .fake, tier: ModelTier = .medium,
         toggles: Toggles = Toggles(), latencyMs: FakeLLMClient.Latency? = nil,
         turns: [Turn], scriptedResponses: [ScriptedResponse] = [], expectedTools: [String]? = nil,
         seedFacts: [String]? = nil, pinned: Bool = false) {
        self.name = name; self.clientMode = clientMode; self.tier = tier
        self.toggles = toggles; self.latencyMs = latencyMs
        self.turns = turns; self.scriptedResponses = scriptedResponses; self.expectedTools = expectedTools
        self.seedFacts = seedFacts
        self.pinned = pinned
    }

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        name = try c.decode(String.self, forKey: .name)
        clientMode = try c.decodeIfPresent(ClientMode.self, forKey: .clientMode) ?? .fake
        tier = try c.decodeIfPresent(ModelTier.self, forKey: .tier) ?? .medium
        toggles = try c.decodeIfPresent(Toggles.self, forKey: .toggles) ?? Toggles()
        latencyMs = try c.decodeIfPresent(FakeLLMClient.Latency.self, forKey: .latencyMs)
        turns = try c.decode([Turn].self, forKey: .turns)
        scriptedResponses = try c.decodeIfPresent([ScriptedResponse].self, forKey: .scriptedResponses) ?? []
        expectedTools = try c.decodeIfPresent([String].self, forKey: .expectedTools)
        seedFacts = try c.decodeIfPresent([String].self, forKey: .seedFacts)
        pinned = try c.decodeIfPresent(Bool.self, forKey: .pinned) ?? false
    }

    static func decode(from data: Data) throws -> Scenario {
        try JSONDecoder().decode(Scenario.self, from: data)
    }

    static func load(at path: String) throws -> Scenario {
        let data = try Data(contentsOf: URL(fileURLWithPath: path))
        return try decode(from: data)
    }
}
