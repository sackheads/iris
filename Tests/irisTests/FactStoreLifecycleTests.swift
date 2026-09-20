import Testing
import Foundation
import GRDB
@testable import iris

/// #168: the fact store gained the hermes-memory lifecycle (retract / supersede / restore),
/// usage and feedback trust signals, and the `manage_fact` tool surface.
@Suite("fact store lifecycle (#168)")
struct FactStoreLifecycleTests {

    private func store() throws -> FactStoreManager { try FactStoreManager(inMemory: true) }

    // MARK: 1 — migration

    @Test("a v1 database migrates to v2 in place, defaulting the lifecycle columns")
    func v1UpgradesInPlace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-factstore-v1-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try paths.ensureDirectories()
        defer { try? FileManager.default.removeItem(at: root) }

        // Build a v1-era database: the shipped migrator stopped at v1_fact_store.
        do {
            let queue = try DatabaseQueue(path: paths.factStoreDB.path)
            try FactStoreManager.migrator.migrate(queue, upTo: "v1_fact_store")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO facts (id, content, category, trustScore, timestamp)
                    VALUES ('v1-row', 'Brian ships Swift on Friday', 'general', 1.0, datetime('now'))
                    """)
            }
            try queue.close()
        }

        let mgr = try FactStoreManager(paths: paths)
        let fact = try #require(try mgr.listFacts(includeInactive: true, limit: 10).first)
        #expect(fact.id == "v1-row")
        #expect(fact.status == FactStatus.active.rawValue)
        #expect(fact.retrievalCount == 0)
        #expect(fact.helpfulCount == 0)
        #expect(fact.supersededBy == nil)
        #expect(fact.supersededAt == nil)
        #expect(try mgr.search(query: "Swift").count == 1)
    }

    // MARK: 2 — retract

    @Test("a retracted fact leaves search and probe but stays in the store")
    func retractHides() throws {
        let s = try store()
        let fact = try s.addFact(content: "Brian lives in Seattle", entity: "Brian")

        try s.retractFact(id: fact.id)

        #expect(try s.search(query: "Seattle").isEmpty)
        #expect(try s.probe(entity: "Brian").isEmpty)
        let kept = try #require(try s.listFacts(includeInactive: true, limit: 10).first)
        #expect(kept.id == fact.id)
        #expect(kept.status == FactStatus.retracted.rawValue)
        #expect(kept.supersededBy == nil)
        #expect(kept.supersededAt != nil)
        #expect(try s.listFacts(includeInactive: false, limit: 10).isEmpty)
    }

    @Test("retracting an unknown id throws notFound")
    func retractUnknown() throws {
        let s = try store()
        #expect(throws: FactStoreError.notFound(id: "nope")) { try s.retractFact(id: "nope") }
    }

    // MARK: 3 — supersede

    @Test("supersede hides the old fact, keeps the new one, and records lineage")
    func supersedeRecordsLineage() throws {
        let s = try store()
        let old = try s.addFact(content: "Brian lives in Seattle", entity: "Brian")
        let new = try s.addFact(content: "Brian lives in Portland", entity: "Brian")

        try s.supersedeFact(id: old.id, by: new.id)

        let active = try s.search(query: "Brian lives")
        #expect(active.count == 1)
        #expect(active.first?.id == new.id)

        let all = try s.listFacts(includeInactive: true, limit: 10)
        let stored = try #require(all.first { $0.id == old.id })
        #expect(stored.status == FactStatus.superseded.rawValue)
        #expect(stored.supersededBy == new.id)
        #expect(stored.supersededAt != nil)
    }

    @Test("supersede refuses self-supersession, unknown ids, and cycles")
    func supersedeRefusesInvalid() throws {
        let s = try store()
        let a = try s.addFact(content: "alpha fact")
        let b = try s.addFact(content: "bravo fact")

        #expect(throws: FactStoreError.selfSupersession) { try s.supersedeFact(id: a.id, by: a.id) }
        #expect(throws: FactStoreError.notFound(id: "ghost")) { try s.supersedeFact(id: "ghost", by: a.id) }
        #expect(throws: FactStoreError.notFound(id: "ghost")) { try s.supersedeFact(id: a.id, by: "ghost") }

        try s.supersedeFact(id: a.id, by: b.id)
        #expect(throws: FactStoreError.cycle) { try s.supersedeFact(id: b.id, by: a.id) }
    }

    // MARK: 4 — addFact(supersedes:)

    @Test("addFact(supersedes:) marks the old fact in the same write")
    func addWithSupersedes() throws {
        let s = try store()
        let old = try s.addFact(content: "Brian uses Vim")

        let new = try s.addFact(content: "Brian uses Xcode", supersedes: old.id)

        let all = try s.listFacts(includeInactive: true, limit: 10)
        #expect(all.first { $0.id == old.id }?.status == FactStatus.superseded.rawValue)
        #expect(all.first { $0.id == old.id }?.supersededBy == new.id)
        #expect(all.first { $0.id == new.id }?.status == FactStatus.active.rawValue)
    }

    @Test("addFact(supersedes:) with a bad id inserts nothing")
    func addWithSupersedesIsAtomic() throws {
        let s = try store()
        _ = try s.addFact(content: "Brian uses Vim")
        let before = try s.listFacts(includeInactive: true, limit: 50).count

        #expect(throws: FactStoreError.notFound(id: "ghost")) {
            _ = try s.addFact(content: "Brian uses Xcode", supersedes: "ghost")
        }

        #expect(try s.listFacts(includeInactive: true, limit: 50).count == before)
    }

    // MARK: 5 — restore

    @Test("restore reactivates a retracted fact and clears its lineage")
    func restoreRetracted() throws {
        let s = try store()
        let fact = try s.addFact(content: "Brian lives in Seattle")
        try s.retractFact(id: fact.id)

        let result = try s.restoreFact(id: fact.id)

        #expect(result.fact.status == FactStatus.active.rawValue)
        #expect(result.fact.supersededAt == nil)
        #expect(result.stillActiveSuccessor == nil)
        #expect(try s.search(query: "Seattle").count == 1)
    }

    @Test("restoring a superseded fact names a successor that is still active")
    func restoreNamesStillActiveSuccessor() throws {
        let s = try store()
        let old = try s.addFact(content: "Brian lives in Seattle")
        let new = try s.addFact(content: "Brian lives in Portland", supersedes: old.id)

        let result = try s.restoreFact(id: old.id)

        #expect(result.fact.supersededBy == nil)
        #expect(result.stillActiveSuccessor?.id == new.id)
        #expect(try s.search(query: "Brian lives").count == 2)

        // A successor that is itself retracted is not reported.
        try s.supersedeFact(id: old.id, by: new.id)
        try s.retractFact(id: new.id)
        #expect(try s.restoreFact(id: old.id).stillActiveSuccessor == nil)
    }

    @Test("restoring an unknown id throws notFound")
    func restoreUnknown() throws {
        let s = try store()
        #expect(throws: FactStoreError.notFound(id: "nope")) { _ = try s.restoreFact(id: "nope") }
    }

    // MARK: 6 — retrieval counts

    @Test("search and probe bump retrievalCount for the facts they return only")
    func retrievalCounts() throws {
        let s = try store()
        let hit = try s.addFact(content: "Kubernetes autoscaling notes", entity: "Kubernetes")
        let miss = try s.addFact(content: "Sourdough starter schedule", entity: "Bread")

        #expect(try s.search(query: "Kubernetes").count == 1)
        #expect(try s.probe(entity: "Kubernetes").count == 1)

        let all = try s.listFacts(includeInactive: true, limit: 10)
        #expect(all.first { $0.id == hit.id }?.retrievalCount == 2)
        #expect(all.first { $0.id == miss.id }?.retrievalCount == 0)
    }

    @Test("a browse read leaves the retrieval count alone")
    func browseDoesNotCountAsRetrieval() throws {
        let s = try store()
        let fact = try s.addFact(content: "Kubernetes autoscaling notes", entity: "Kubernetes")

        _ = try s.search(query: "Kubernetes", countsAsRetrieval: false)
        _ = try s.probe(entity: "Kubernetes", countsAsRetrieval: false)
        #expect(try s.listFacts(includeInactive: true, limit: 10).first { $0.id == fact.id }?.retrievalCount == 0)

        _ = try s.search(query: "Kubernetes")
        #expect(try s.listFacts(includeInactive: true, limit: 10).first { $0.id == fact.id }?.retrievalCount == 1)
    }

    // MARK: 7 — feedback

    @Test("helpful feedback raises trust and the helpful count; unhelpful lowers trust only")
    func feedbackAdjustsTrust() throws {
        let s = try store()
        let fact = try s.addFact(content: "Iris uses GRDB for the fact store")

        let up = try s.recordFeedback(id: fact.id, helpful: true)
        #expect(abs(up.trustScore - 1.05) < 0.0001)
        #expect(up.helpfulCount == 1)

        let down = try s.recordFeedback(id: fact.id, helpful: false)
        #expect(abs(down.trustScore - 0.95) < 0.0001)
        #expect(down.helpfulCount == 1)
    }

    @Test("repeated unhelpful feedback floors trust at zero")
    func feedbackFloorsAtZero() throws {
        let s = try store()
        let fact = try s.addFact(content: "Iris uses GRDB for the fact store")
        var last = fact
        for _ in 0..<40 { last = try s.recordFeedback(id: fact.id, helpful: false) }
        #expect(last.trustScore == 0.0)
    }

    @Test("feedback on an unknown id throws notFound")
    func feedbackUnknown() throws {
        let s = try store()
        #expect(throws: FactStoreError.notFound(id: "nope")) { _ = try s.recordFeedback(id: "nope", helpful: true) }
    }

    // MARK: 8 — eviction

    @Test("eviction spares facts that were ever retrieved, and never deletes lineage")
    func evictionRespectsUsageAndLifecycle() throws {
        let s = try store()
        func insertOld(_ id: String, status: String, retrievals: Int) throws {
            try s.dbQueue!.write { db in
                try db.execute(sql: """
                    INSERT INTO facts (id, content, category, trustScore, timestamp, status, retrievalCount, helpfulCount)
                    VALUES (?, 'aging fact', 'general', 1.0, datetime('now', '-40 days'), ?, ?, 0)
                    """, arguments: [id, status, retrievals])
            }
        }
        try insertOld("used", status: "active", retrievals: 1)
        try insertOld("retracted", status: "retracted", retrievals: 0)
        try insertOld("cold", status: "active", retrievals: 0)

        try s.evictOldFacts()

        let ids = Set(try s.listFacts(includeInactive: true, limit: 50).map(\.id))
        #expect(ids.contains("used"))
        #expect(ids.contains("retracted"))
        #expect(!ids.contains("cold"))
    }

    @Test("empty content is refused")
    func emptyContentRefused() throws {
        let s = try store()
        #expect(throws: FactStoreError.emptyContent) { _ = try s.addFact(content: "   ") }
    }

    // MARK: test isolation

    @MainActor
    @Test("under test the shared store is in-memory and building an engine never opens the real one")
    func sharedStoreIsIsolatedFromTheRealHome() {
        #expect(FactStoreManager.shared.dbQueue != nil, "the shared store must be in-memory under XCTest")

        let realPath = IrisPaths.default.factStoreDB.path
        let existedBefore = FileManager.default.fileExists(atPath: realPath)
        let app = AppState()
        _ = IrisEngine(state: app, tier: .medium, principal: .main,
                       client: CapturingLLMClient(reply: "ok"), retryDelays: [])
        #expect(FileManager.default.fileExists(atPath: realPath) == existedBefore)
    }

    // MARK: /facts rendering

    @MainActor
    @Test("/facts renders ids, and `all` labels the inactive rows")
    func factLineRendering() {
        let active = Fact(id: "a", content: "still true")
        let retracted = Fact(id: "b", content: "was wrong", status: FactStatus.retracted.rawValue)
        let superseded = Fact(id: "c", content: "out of date",
                              status: FactStatus.superseded.rawValue, supersededBy: "a")

        #expect(AppState.factLine(active) == "- [a] still true")
        #expect(AppState.factLine(retracted) == "- [b] was wrong (retracted)")
        #expect(AppState.factLine(superseded) == "- [c] out of date (superseded \u{2192} [a])")
    }
}

// MARK: - tool surface

private func call(_ name: String, _ args: [String: JSONValue]) -> GeminiResponse {
    let fc = FunctionCall(name: name, args: args, id: nil, thought_signature: nil, thoughtSignature: nil)
    let part = Part(text: nil, functionCall: fc, functionResponse: nil,
                    thought_signature: nil, thoughtSignature: nil)
    return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [part]))],
                          usageMetadata: nil)
}

@MainActor
@Suite("fact lifecycle tools (#168)", .serialized)
struct FactLifecycleToolTests {

    /// Drive one turn whose model reply is `call`, against an isolated in-memory fact store,
    /// and return every tool result the turn recorded.
    ///
    /// Structural (tier 1) guarding only: since #177 the `search_memory` result goes through the
    /// injection guard like any other tool output, and the model-backed tiers fail closed when no
    /// prompt-guard model is provisioned — which is the case under `swift test`, where a blocked
    /// result carries no fact ids to assert on. Pinned per-call rather than on
    /// `ConfigManager.shared`, which parallel suites race on (#109).
    private func results(of response: GeminiResponse, store: FactStoreManager) async -> [String] {
        let app = AppState()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                client: FakeLLMClient(responses: [response, textReply()]),
                                retryDelays: [], factStore: store, protectionEnabled: false)
        await engine.processInput("go", source: "User", conversationId: id)
        let history = app.conversations.first { $0.id == id }?.history ?? []
        return history.flatMap { $0.parts }.compactMap { $0.functionResponse?.response["result"]?.stringValue }
    }

    private func textReply() -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [
            Part(text: "done", functionCall: nil, functionResponse: nil,
                 thought_signature: nil, thoughtSignature: nil)
        ]))], usageMetadata: nil)
    }

    @Test("search_memory renders fact ids so the model can act on them")
    func searchRendersIds() async throws {
        let store = try FactStoreManager(inMemory: true)
        let fact = try store.addFact(content: "Brian lives in Seattle")
        let out = await results(of: call("search_memory", ["query": .string("Seattle")]), store: store)
        #expect(out.contains { $0.contains("[\(fact.id)]") && $0.contains("Seattle") })
    }

    @Test("manage_fact retract hides the fact and names it in the result")
    func manageRetract() async throws {
        let store = try FactStoreManager(inMemory: true)
        let fact = try store.addFact(content: "Brian lives in Seattle")
        let out = await results(of: call("manage_fact", ["action": .string("retract"), "fact_id": .string(fact.id)]),
                                store: store)
        #expect(out.contains { $0.contains(fact.id) && $0.contains("retracted") })
        #expect(try store.search(query: "Seattle").isEmpty)
    }

    @Test("manage_fact with an unknown action returns an error result")
    func manageBadAction() async throws {
        let store = try FactStoreManager(inMemory: true)
        let fact = try store.addFact(content: "Brian lives in Seattle")
        let out = await results(of: call("manage_fact", ["action": .string("obliterate"), "fact_id": .string(fact.id)]),
                                store: store)
        #expect(out.contains { $0.lowercased().contains("unknown action") })
        #expect(try store.search(query: "Seattle").count == 1)
    }

    @Test("manage_fact on an unknown id reports why instead of claiming success")
    func manageUnknownId() async throws {
        let store = try FactStoreManager(inMemory: true)
        let out = await results(of: call("manage_fact", ["action": .string("retract"), "fact_id": .string("ghost")]),
                                store: store)
        #expect(out.contains { $0.lowercased().contains("unknown fact id") })
    }

    @Test("save_fact treats an empty supersedes as absent")
    func saveFactEmptySupersedes() async throws {
        let store = try FactStoreManager(inMemory: true)
        let out = await results(of: call("save_fact", ["content": .string("Brian lives in Portland"),
                                                       "supersedes": .string("")]),
                                store: store)
        #expect(out.contains { $0.contains("Fact saved to fact store") })
        #expect(out.allSatisfy { !$0.contains("superseded") })
        #expect(try store.search(query: "Portland").count == 1)
    }

    @Test("save_fact with supersedes marks the old fact superseded")
    func saveFactSupersedes() async throws {
        let store = try FactStoreManager(inMemory: true)
        let old = try store.addFact(content: "Brian lives in Seattle")
        _ = await results(of: call("save_fact", ["content": .string("Brian lives in Portland"),
                                                 "supersedes": .string(old.id)]),
                          store: store)
        let all = try store.listFacts(includeInactive: true, limit: 10)
        #expect(all.first { $0.id == old.id }?.status == FactStatus.superseded.rawValue)
        #expect(all.contains { $0.content.contains("Portland") && $0.status == FactStatus.active.rawValue })
    }
}
