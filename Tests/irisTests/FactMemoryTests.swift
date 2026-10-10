import Testing
import Foundation
import GRDB
@testable import IrisKit

// #415 / #416: fact-store write dedup, the createdAt split and its migrations, BM25 relevance,
// pre-injection dedup, age in the prompt, no reinforcement on retrieval, and JIT only on user turns.
// Every store here is in-memory or under a temp directory; nothing reads FactStoreManager.shared.

private func tempPaths(_ label: String) throws -> (IrisPaths, URL) {
    let root = URL(fileURLWithPath: NSTemporaryDirectory())
        .appendingPathComponent("iris-factmem-\(label)-\(UUID().uuidString)")
    let paths = IrisPaths(root: root)
    try paths.ensureDirectories()
    return (paths, root)
}

/// A second connection onto an on-disk store, for asserting on the schema and raw rows. A write
/// transaction because FTS5's integrity-check is issued as an INSERT.
private func readStore<T>(_ paths: IrisPaths, _ body: (Database) throws -> T) throws -> T {
    let queue = try DatabaseQueue(path: paths.factStoreDB.path)
    defer { try? queue.close() }
    return try queue.write(body)
}

private func activeCount(_ s: FactStoreManager) throws -> Int {
    try s.listFacts(includeInactive: false, limit: 500).count
}

/// Inserts a row straight into `facts`, bypassing addFact's dedup, as an old store would hold it.
private func rawInsert(_ db: Database, id: String, content: String, daysAgo: Int = 0,
                       status: String = "active", retrievals: Int = 0, helpful: Int = 0,
                       trust: Double = 1.0, supersededBy: String? = nil, entity: String? = nil) throws {
    try db.execute(sql: """
        INSERT INTO facts (id, content, category, trustScore, timestamp, status, retrievalCount, helpfulCount, supersededBy, entity)
        VALUES (?, ?, 'general', ?, datetime('now', ?), ?, ?, ?, ?, ?)
        """, arguments: [id, content, trust, "-\(daysAgo) days", status, retrievals, helpful, supersededBy, entity])
}

@Suite("Fact write dedup (#416)", .timeLimit(.minutes(1)))
struct FactWriteDedupTests {
    @Test("the same fact saved twice, differing only in case, spacing and a trailing period, is one row")
    func normalisedDuplicateReturnsExisting() throws {
        let s = try FactStoreManager(inMemory: true)
        let first = try s.saveFact(content: "The sky is blue")
        let second = try s.saveFact(content: "  the SKY   is\nblue. ")
        #expect(first.isNew)
        #expect(!second.isNew)
        #expect(second.fact.id == first.fact.id)
        #expect(try activeCount(s) == 1)
    }

    @Test("dedup ignores category but not entity: the same text about two entities is two facts")
    func dedupKeysOnEntity() throws {
        let s = try FactStoreManager(inMemory: true)
        let a = try s.addFact(content: "Brian lives in Seattle", category: "general")
        let b = try s.addFact(content: "Brian lives in Seattle", category: "user_pref")
        #expect(a.id == b.id)
        let alice = try s.addFact(content: "Prefers dark mode.", entity: "Alice")
        let bob = try s.addFact(content: "Prefers dark mode.", entity: "Bob")
        let alice2 = try s.addFact(content: "prefers dark mode", entity: " alice ")
        #expect(alice.id != bob.id)
        #expect(alice2.id == alice.id)
        #expect(try activeCount(s) == 3)
    }

    @Test("different content is still a new fact, and a retracted copy does not block a re-save")
    func distinctAndRetractedAreNew() throws {
        let s = try FactStoreManager(inMemory: true)
        let a = try s.addFact(content: "The sky is blue")
        let b = try s.addFact(content: "The sky is grey")
        #expect(a.id != b.id)
        try s.retractFact(id: a.id)
        let c = try s.saveFact(content: "The sky is blue")
        #expect(c.isNew)
        #expect(c.fact.id != a.id)
    }

    @Test("a duplicate that supersedes another fact points the lineage at the existing row")
    func duplicateWithSupersedes() throws {
        let s = try FactStoreManager(inMemory: true)
        let old = try s.addFact(content: "Release is on Friday")
        let kept = try s.addFact(content: "Release is on Monday")
        let again = try s.saveFact(content: "release is on monday", supersedes: old.id)
        #expect(!again.isNew)
        #expect(again.fact.id == kept.id)
        let oldRow = try #require(try s.listFacts(includeInactive: true, limit: 10).first { $0.id == old.id })
        #expect(oldRow.status == FactStatus.superseded.rawValue)
        #expect(oldRow.supersededBy == kept.id)
    }
}

@Suite("Fact createdAt migration (#416)", .timeLimit(.minutes(1)))
struct FactCreatedAtMigrationTests {
    @Test("a v2 store upgrades in place: old rows get createdAt from timestamp, and the FTS index still works")
    func v2RowsBackfillCreatedAt() throws {
        let (paths, root) = try tempPaths("v2")
        defer { try? FileManager.default.removeItem(at: root) }
        var stamps: [String: Date] = [:]
        do {
            let queue = try DatabaseQueue(path: paths.factStoreDB.path)
            try FactStoreManager.migrator.migrate(queue, upTo: "v2_fact_lifecycle")
            try queue.write { db in
                try rawInsert(db, id: "old-1", content: "Brian ships Swift on Friday", daysAgo: 21)
                try rawInsert(db, id: "old-2", content: "The build machine is named Zeus", daysAgo: 3)
                for row in try Row.fetchAll(db, sql: "SELECT id, timestamp FROM facts") {
                    stamps[row["id"]] = row["timestamp"]
                }
            }
            try queue.close()
        }

        let mgr = try FactStoreManager(paths: paths)
        let facts = try mgr.listFacts(includeInactive: true, limit: 10)
        #expect(facts.count == 2)
        for fact in facts {
            let stamp = try #require(stamps[fact.id])
            #expect(abs(fact.createdAt.timeIntervalSince(stamp)) < 1, "\(fact.id)")
            #expect(fact.lastRetrievedAt == nil)
        }
        // The column is really there and populated, not just the decode fallback.
        let nulls = try readStore(paths) { db in
            try Int.fetchOne(db, sql: "SELECT count(*) FROM facts WHERE createdAt IS NULL") ?? -1
        }
        #expect(nulls == 0)
        #expect(try mgr.search(query: "Zeus").map(\.id) == ["old-2"])
    }

    @Test("retrieval sets lastRetrievedAt and the count, and never moves createdAt, timestamp or trust")
    func retrievalLeavesCreationAlone() throws {
        let s = try FactStoreManager(inMemory: true)
        try s.dbQueue!.write { db in try rawInsert(db, id: "f", content: "Brian lives in Seattle", daysAgo: 30) }
        let before = try #require(try s.listFacts(limit: 5).first)
        _ = try s.search(query: "Seattle")
        _ = try s.search(query: "Seattle")
        let after = try #require(try s.listFacts(limit: 5).first)
        #expect(after.retrievalCount == before.retrievalCount + 2)
        #expect(after.lastRetrievedAt != nil)
        #expect(after.createdAt == before.createdAt)
        #expect(after.timestamp == before.timestamp)
        #expect(after.trustScore == before.trustScore)
    }
}

@Suite("Fact dedup migration (#416)", .timeLimit(.minutes(1)))
struct FactDedupMigrationTests {
    @Test("duplicates merge into the oldest, with summed counts, re-pointed lineage and a consistent index")
    func mergesDuplicates() throws {
        let (paths, root) = try tempPaths("v3")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let queue = try DatabaseQueue(path: paths.factStoreDB.path)
            try FactStoreManager.migrator.migrate(queue, upTo: "v3_fact_created_at")
            try queue.write { db in
                try rawInsert(db, id: "sky-new", content: "the sky is  blue", daysAgo: 1, retrievals: 4, helpful: 1, trust: 1.4)
                try rawInsert(db, id: "sky-old", content: "The sky is blue", daysAgo: 60, retrievals: 2, helpful: 0)
                try rawInsert(db, id: "sky-mid", content: "The sky is blue.", daysAgo: 20, retrievals: 1, helpful: 2)
                // Inactive copies are lineage and are left alone; one points at a copy being deleted.
                try rawInsert(db, id: "sky-retracted", content: "The sky is blue", daysAgo: 90, status: "retracted")
                try rawInsert(db, id: "sky-was-green", content: "The sky is green", daysAgo: 70,
                              status: "superseded", supersededBy: "sky-mid")
                try rawInsert(db, id: "other", content: "Brian lives in Seattle", daysAgo: 5)
                // Same text, different entities: not duplicates of each other.
                try rawInsert(db, id: "dark-alice", content: "Prefers dark mode.", daysAgo: 9, entity: "Alice")
                try rawInsert(db, id: "dark-bob", content: "Prefers dark mode.", daysAgo: 8, entity: "Bob")
                // v3 ran before these rows existed, so give them the createdAt it would have.
                try db.execute(sql: "UPDATE facts SET createdAt = timestamp")
                try db.execute(sql: "INSERT INTO fact_relations (sourceId, targetId, relationType) VALUES ('other', 'sky-new', 'related')")
            }
            try queue.close()
        }

        let mgr = try FactStoreManager(paths: paths)
        let all = try mgr.listFacts(includeInactive: true, limit: 50)
        let ids = Set(all.map(\.id))
        #expect(ids == ["sky-old", "sky-retracted", "sky-was-green", "other", "dark-alice", "dark-bob"])

        let keeper = try #require(all.first { $0.id == "sky-old" })
        #expect(keeper.retrievalCount == 7)
        #expect(keeper.helpfulCount == 3)
        #expect(keeper.trustScore == 1.4)
        #expect(all.first { $0.id == "sky-was-green" }?.supersededBy == "sky-old")

        try readStore(paths) { db in
            let rel = try Row.fetchAll(db, sql: "SELECT sourceId, targetId FROM fact_relations")
            #expect(rel.count == 1)
            #expect(rel.first?["targetId"] == "sky-old")
            // The external-content index matches the table after the deletes.
            try db.execute(sql: "INSERT INTO facts_fts(facts_fts) VALUES('integrity-check')")
            // It is kept in sync by the triggers GRDB's synchronize(withTable:) created.
            let triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
            #expect(triggers == ["__facts_fts_ad", "__facts_fts_ai", "__facts_fts_au"])
        }
        #expect(try mgr.search(query: "sky blue").map(\.id) == ["sky-old"])
    }

    @Test("v5 rebuilds the index with the porter stemmer, keeping existing rows searchable")
    func porterMigration() throws {
        let (paths, root) = try tempPaths("v4")
        defer { try? FileManager.default.removeItem(at: root) }
        do {
            let queue = try DatabaseQueue(path: paths.factStoreDB.path)
            try FactStoreManager.migrator.migrate(queue, upTo: "v4_fact_dedup")
            try queue.write { db in
                try rawInsert(db, id: "a2", content: "The Iris project uses Swift and GRDB.")
                try db.execute(sql: "UPDATE facts SET createdAt = timestamp")
            }
            try queue.close()
        }
        let mgr = try FactStoreManager(paths: paths)
        #expect(try mgr.search(query: "use").map(\.id) == ["a2"])
        try readStore(paths) { db in
            let sql = try String.fetchOne(db, sql: "SELECT sql FROM sqlite_master WHERE name = 'facts_fts'") ?? ""
            #expect(sql.contains("porter"))
            try db.execute(sql: "INSERT INTO facts_fts(facts_fts) VALUES('integrity-check')")
            let triggers = try String.fetchAll(db, sql: "SELECT name FROM sqlite_master WHERE type = 'trigger' ORDER BY name")
            #expect(triggers == ["__facts_fts_ad", "__facts_fts_ai", "__facts_fts_au"])
        }
    }

    @Test("a legacy HRR import with duplicates lands deduplicated")
    func legacyImportDedups() throws {
        let (paths, root) = try tempPaths("hrr")
        defer { try? FileManager.default.removeItem(at: root) }
        let legacy = try DatabaseQueue(path: paths.holographicDB.path)
        try legacy.write { db in
            try db.execute(sql: """
                CREATE TABLE facts (id TEXT PRIMARY KEY, content TEXT NOT NULL, hrrVectorData BLOB NOT NULL,
                    trustScore DOUBLE NOT NULL DEFAULT 1.0, timestamp DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP);
                INSERT INTO facts (id, content, hrrVectorData) VALUES ('h1', 'The sky is blue', X'00');
                INSERT INTO facts (id, content, hrrVectorData) VALUES ('h2', 'The sky is blue', X'00');
                INSERT INTO facts (id, content, hrrVectorData) VALUES ('h3', 'The sky is blue', X'00');
                """)
        }
        try legacy.close()
        let mgr = try FactStoreManager(paths: paths)
        #expect(try activeCount(mgr) == 1)
    }
}

@Suite("Fact relevance (#415)", .timeLimit(.minutes(1)))
struct FactRelevanceTests {
    /// The review's store: three active facts and three superseded ones about the same people and
    /// project, so "brian" and "iris" are in half the rows or more.
    private func reviewStore() throws -> FactStoreManager {
        let s = try FactStoreManager(inMemory: true)
        try s.dbQueue!.write { db in
            try rawInsert(db, id: "a1", content: "Brian is building Iris, a macOS assistant.", daysAgo: 30)
            try rawInsert(db, id: "a2", content: "The Iris project uses Swift and GRDB.", daysAgo: 20)
            try rawInsert(db, id: "a3", content: "Brian prefers terse commit messages.", daysAgo: 10)
            try rawInsert(db, id: "s1", content: "Brian is building Iris in Rust.", daysAgo: 60, status: "superseded", supersededBy: "a1")
            try rawInsert(db, id: "s2", content: "The Iris project uses SQLite only.", daysAgo: 50, status: "superseded", supersededBy: "a2")
            try rawInsert(db, id: "s3", content: "Brian prefers verbose commit messages.", daysAgo: 40, status: "superseded", supersededBy: "a3")
            try db.execute(sql: "UPDATE facts SET createdAt = timestamp")
        }
        return s
    }

    private func jit(_ s: FactStoreManager, _ q: String) throws -> [String] {
        try s.search(query: q, limit: IrisEngine.jitFactLimit, applyRelevanceFloor: true).map(\.id)
    }

    @Test("the review's small-store queries find their facts")
    func reviewQueries() throws {
        let s = try reviewStore()
        #expect(Set(try jit(s, "remind me about Brian")) == ["a1", "a3"])
        #expect(try jit(s, "which database does iris use?").first == "a2")
        #expect(Set(try jit(s, "what's the status of my iris project?")) == ["a1", "a2"])
        #expect(try jit(s, "what commit message style do I like?") == ["a3"])
    }

    @Test("porter stemming: use finds uses, preferences finds prefers")
    func stemming() throws {
        let s = try reviewStore()
        #expect(try s.search(query: "use").map(\.id) == ["a2"])
        #expect(try s.search(query: "preferences").map(\.id) == ["a3"])
    }

    @Test("stopwords alone never match: 'how does the release feel' does not retrieve 'The sky is blue'")
    func stopwordsDoNotMatch() throws {
        // A small store, so the floor is off and only the stopword filter stands between
        // "the"/"is" and a match.
        let s = try FactStoreManager(inMemory: true)
        try s.addFact(content: "The sky is blue")
        try s.addFact(content: "Brian lives in Seattle")
        #expect(try jit(s, "how does the release feel").isEmpty)
        #expect(try jit(s, "how is it going?").isEmpty)
        #expect(FactQueryTerms.contentTerms(in: "How does the release feel?") == ["release", "feel"])
    }

    @Test("a query sharing a real term retrieves the relevant fact, and only it")
    func sharedTermRetrieves() throws {
        let s = try FactStoreManager(inMemory: true)
        for c in ["The sky is blue", "Release 0.1.0 shipped on Thursday", "Brian lives in Seattle",
                  "The build uses Swift 6", "Brian prefers terse commit messages"] {
            try s.addFact(content: c)
        }
        let hits = try s.search(query: "how does the release feel", applyRelevanceFloor: true)
        #expect(hits.map(\.content) == ["Release 0.1.0 shipped on Thursday"])
        #expect(try s.search(query: "Tell me about Seattle", applyRelevanceFloor: true).map(\.content) == ["Brian lives in Seattle"])
    }

    /// 24 active facts, 14 of them about Iris.
    private func largeIrisStore() throws -> FactStoreManager {
        let s = try FactStoreManager(inMemory: true)
        for i in 0..<13 { try s.addFact(content: "Iris detail number \(i) is recorded") }
        try s.addFact(content: "Iris release 0.1.0 shipped on Thursday")
        try s.addFact(content: "Prefers oolong tea", entity: "Brian")
        for i in 0..<9 { try s.addFact(content: "Unrelated note \(i) about gardening") }
        return s
    }

    @Test("at 20+ active facts the floor drops a fact whose only shared word is in half the store")
    func floorDropsCommonTermOnlyMatch() throws {
        let s = try largeIrisStore()
        #expect(try jit(s, "what about the iris release").count == 1)
        #expect(try s.search(query: "what about the iris release", applyRelevanceFloor: true).first?.content
                == "Iris release 0.1.0 shipped on Thursday")
        // An explicit search (no floor) still finds the common term.
        #expect(try s.search(query: "iris", limit: 20).count == 14)
    }

    @Test("a query naming a fact's entity passes the floor")
    func entityBypassesFloor() throws {
        let s = try largeIrisStore()
        for i in 0..<14 { try s.addFact(content: "Brian note \(i) about the week") }
        // "brian" is now in 14 of 38 rows' content plus the entity row; push it past half.
        for i in 0..<12 { try s.addFact(content: "Brian also said thing \(i)") }
        let hits = try s.search(query: "remind me about Brian", limit: 30, applyRelevanceFloor: true)
        #expect(hits.map(\.content) == ["Prefers oolong tea"])
    }

    @Test("the floor counts active facts only: superseded copies do not make a term common")
    func floorCountsActiveRowsOnly() throws {
        let s = try largeIrisStore()
        try s.addFact(content: "The build machine is named Zeus")
        try s.dbQueue!.write { db in
            for i in 0..<30 {
                try rawInsert(db, id: "old-zeus-\(i)", content: "Zeus was the build machine, version \(i)",
                              status: "superseded")
            }
        }
        #expect(try s.search(query: "zeus", applyRelevanceFloor: true).map(\.content) == ["The build machine is named Zeus"])
    }

    @Test("results are ranked by relevance, and capped at the limit")
    func rankedAndCapped() throws {
        let s = try FactStoreManager(inMemory: true)
        for i in 0..<8 { try s.addFact(content: "Deploy note number \(i) about staging") }
        try s.addFact(content: "The staging deploy runs nightly from the deploy box")
        // Enough other rows that the floor is on and "staging"/"deploy" are in under half.
        for i in 0..<12 { try s.addFact(content: "Unrelated fact \(i)") }
        let hits = try s.search(query: "staging deploy", limit: IrisEngine.jitFactLimit, applyRelevanceFloor: true)
        #expect(hits.count == IrisEngine.jitFactLimit)
        #expect(hits.first?.content == "The staging deploy runs nightly from the deploy box")
    }
}

@Suite("Fact dedup before injection (#415)", .timeLimit(.minutes(1)))
struct FactInjectionDedupTests {
    @Test("duplicate rows already in the store reach the results once")
    func searchDedupes() throws {
        let s = try FactStoreManager(inMemory: true)
        try s.dbQueue!.write { db in
            try rawInsert(db, id: "a", content: "Brian lives in Seattle")
            try rawInsert(db, id: "b", content: "brian lives in  Seattle.")
            try rawInsert(db, id: "c", content: "The build uses Swift 6")
            try rawInsert(db, id: "d", content: "The sky is blue")
            try rawInsert(db, id: "e", content: "Release 0.1.0 shipped on Thursday")
        }
        let hits = try s.search(query: "Seattle", applyRelevanceFloor: true)
        #expect(hits.count == 1)
        #expect(try s.probe(entity: "Seattle").count == 1)
    }
}

@MainActor
@Suite("Fact entity in the prompt (#415)", .timeLimit(.minutes(1)))
struct FactEntityLineTests {
    @Test("the same text about Alice and about Bob is injected twice, each line naming its entity")
    func sameTextTwoEntities() async throws {
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "Prefers dark mode.", entity: "Alice")
        try facts.addFact(content: "Prefers dark mode.", entity: "Bob")
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = FactTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("does anyone want dark mode?", source: "UI", conversationId: id)
        let block = turnContextBlock(try #require(client.requests.first))
        #expect(block.contains("(about Alice; saved today) Prefers dark mode."), "\(block)")
        #expect(block.contains("(about Bob; saved today) Prefers dark mode."), "\(block)")
    }

    @Test("an entity already named in the content, or empty, is not repeated")
    func entityOmittedWhenRedundant() {
        let now = Date()
        let named = Fact(id: "f1", content: "Brian prefers terse commits", entity: "brian", timestamp: now)
        let blank = Fact(id: "f2", content: "The sky is blue", entity: "  ", timestamp: now)
        let other = Fact(id: "f3", content: "Prefers oolong", entity: "Brian Naylor", timestamp: now)
        #expect(IrisEngine.renderFactLines([named, blank, other], now: now) == """
            - [f1] (saved today) Brian prefers terse commits
            - [f2] (saved today) The sky is blue
            - [f3] (about Brian Naylor; saved today) Prefers oolong
            """)
    }

    @Test("clearGoal drops the run's carried facts")
    func clearGoalDropsCarry() async throws {
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "The Seattle office moves in March")
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: FactTurnClient(),
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)
        await engine.processInput("kickoff", source: "System", conversationId: id,
                                  goalFacts: .start(objective: "plan the Seattle move"))
        #expect(await engine.goalRunFactIDsForTesting(id)?.count == 1)
        app.clearGoal(for: id)
        let deadline = Date().addingTimeInterval(30)
        while await engine.goalRunFactIDsForTesting(id) != nil, Date() < deadline {
            try await Task.sleep(nanoseconds: 5_000_000)
        }
        #expect(await engine.goalRunFactIDsForTesting(id) == nil)
    }
}

@Suite("Fact age in the prompt (#415)", .timeLimit(.minutes(1)))
struct FactAgeTests {
    @Test("age labels")
    func labels() {
        let now = Date(timeIntervalSince1970: 2_000_000_000)
        func ago(_ days: Double) -> String { FactAge.label(from: now.addingTimeInterval(-days * 86400), now: now) }
        #expect(ago(0.2) == "today")
        #expect(ago(1.5) == "yesterday")
        #expect(ago(5) == "5 days ago")
        #expect(ago(21) == "3 weeks ago")
        #expect(ago(7 * 8) == "8 weeks ago")
        #expect(ago(95) == "3 months ago")
        #expect(ago(800) == "2 years ago")
    }

    @Test("an injected fact line carries its id, its age from createdAt, then its content")
    func lineFormat() {
        let now = Date()
        let fact = Fact(id: "f1", content: "Test D is investigating the flake",
                        timestamp: now, createdAt: now.addingTimeInterval(-21 * 86400))
        #expect(IrisEngine.renderFactLines([fact], now: now) == "- [f1] (saved 3 weeks ago) Test D is investigating the flake")
    }
}

// MARK: - engine turns

private final class FactTurnClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiRequest] = []
    var requests: [GeminiRequest] { lock.withLock { recorded } }
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        lock.withLock { recorded.append(request) }
        return GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))],
                              usageMetadata: nil)
    }
}

private final class ScriptedFactClient: LLMClientProtocol, @unchecked Sendable {
    private let lock = NSLock()
    private var recorded: [GeminiRequest] = []
    private let script: [GeminiResponse]
    init(_ script: [GeminiResponse]) { self.script = script }
    var requests: [GeminiRequest] { lock.withLock { recorded } }
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        let n = lock.withLock { recorded.append(request); return recorded.count }
        return script[min(n - 1, script.count - 1)]
    }
}

private func turnContextBlock(_ r: GeminiRequest) -> String {
    r.contents.flatMap(\.parts).compactMap(\.text).first { $0.hasPrefix("<turn_context>") } ?? ""
}

private let factHeading = "# Mid-Term Fact Store Memory (JIT Context)"

@MainActor
@Suite("JIT on engine turns (#415)", .timeLimit(.minutes(1)))
struct JITEngineTurnTests {
    private struct Outcome {
        let lead: String
        let fact: Fact
    }

    private func turn(_ input: String, source: String, principal: Principal = .main,
                      seed: [String] = ["Brian lives in Seattle"]) async throws -> Outcome {
        let facts = try FactStoreManager(inMemory: true)
        for c in seed { try facts.addFact(content: c) }
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = FactTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: principal, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput(input, source: source, conversationId: id)
        let lead = client.requests.first?.contents.first?.parts.first?.text ?? ""
        let fact = try #require(try facts.listFacts(limit: 10).first { $0.content == seed[0] })
        return Outcome(lead: lead, fact: fact)
    }

    @Test("a user turn injects the matching fact once, with its age, and does not raise its trust")
    func userTurnInjects() async throws {
        let r = try await turn("Tell me about Seattle", source: "UI")
        #expect(r.lead.contains(factHeading))
        #expect(r.lead.contains("(saved today) Brian lives in Seattle"))
        #expect(r.fact.retrievalCount == 1)
        #expect(r.fact.trustScore == 1.0)
        #expect(r.fact.createdAt == r.fact.timestamp)
    }

    @Test("a perf-scenario user turn (Scenario.Turn.userSource) also retrieves")
    func scenarioUserTurnRetrieves() async throws {
        let r = try await turn("Tell me about Seattle", source: Scenario.Turn.userSource)
        #expect(r.lead.contains("(saved today) Brian lives in Seattle"))
    }

    @Test("save_fact tells the model when the fact was already stored")
    func saveFactReportsDuplicate() async throws {
        let facts = try FactStoreManager(inMemory: true)
        let existing = try facts.addFact(content: "Brian lives in Seattle")
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let call = FunctionCall(name: "save_fact", args: ["content": .string("brian lives in seattle.")],
                                id: "c1", thought_signature: nil, thoughtSignature: nil)
        let client = ScriptedFactClient([
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(functionCall: call)]))], usageMetadata: nil),
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ok")]))], usageMetadata: nil),
        ])
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("remember that brian lives in seattle", source: "UI", conversationId: id)
        let results = client.requests.last?.contents.flatMap(\.parts).compactMap { $0.functionResponse } ?? []
        let text = results.map { "\($0.response)" }.joined()
        #expect(text.contains("Already stored as [\(existing.id)]"), "\(text)")
        #expect(try facts.listFacts(limit: 10).count == 1)
    }

    @Test("a user turn about something else injects nothing")
    func unrelatedUserTurn() async throws {
        let r = try await turn("how does the release feel?", source: "UI",
                               seed: ["The sky is blue", "Brian lives in Seattle", "The build uses Swift 6"])
        #expect(!r.lead.contains(factHeading))
    }

    /// Each kind of turn that carries no user query. Every input names Seattle, so a search would
    /// have matched; the fact's untouched retrievalCount shows none ran.
    static let nonUserTurns: [(label: String, input: String, source: String, principal: Principal)] = [
        ("rename trigger", IrisEngine.renameTriggerPrefix + ": title this Seattle chat", "System", .main),
        ("reflection", AppState.reflectionPrompt + " Seattle", "System", .main),
        ("goal draft", IrisEngine.goalDraftTriggerPrefix + ": plan the Seattle move", "System", .main),
        ("goal reprompt", "Continue the Seattle goal. Objective: move to Seattle.", "System", .main),
        ("goal-complete skill check", IrisEngine.goalCompletionSkillCheck + " Seattle", "System", .main),
        ("job", "Check the Seattle weather", "job:weather", .main),
        ("peer message", "What does Brian think of Seattle?", IrisEngine.peerSource, .main),
        ("subagent", "Research Seattle neighbourhoods", "System", .subagent),
        ("subagent given a UI source", "Research Seattle neighbourhoods", "UI", .subagent),
        ("evaluator", "Grade the Seattle work", "GoalEvaluator", .evaluator),
        ("system-event text typed into the UI", "System Event [Rename Trigger]: Seattle", "UI", .main),
    ]

    /// `@Test(arguments:)` is evaluated off the main actor, and `AppState.reflectionPrompt` is not.
    nonisolated static let nonUserTurnCount = 11

    @Test("the argument range covers every non-user turn kind")
    func argumentRangeIsComplete() {
        #expect(Self.nonUserTurns.count == Self.nonUserTurnCount)
    }

    @Test("JIT is skipped on every non-user turn", arguments: 0..<nonUserTurnCount)
    func skippedOnNonUserTurns(_ i: Int) async throws {
        let k = Self.nonUserTurns[i]
        #expect(!IrisEngine.retrievesFacts(source: k.source, principal: k.principal, input: k.input), "\(k.label)")
        let r = try await turn(k.input, source: k.source, principal: k.principal)
        #expect(!r.lead.contains(factHeading), "\(k.label)")
        #expect(r.fact.retrievalCount == 0, "\(k.label)")
        #expect(r.fact.trustScore == 1.0, "\(k.label)")
    }
}


/// Goal runs (#415 review): the kickoff searches its objective, a typed steer searches itself, and
/// reprompts carry what those found without searching again.
@MainActor
@Suite("Facts on a /goal run (#415)", .timeLimit(.minutes(1)))
struct GoalRunFactTests {
    private struct Harness {
        let app: AppState
        let id: UUID
        let client: FactTurnClient
        let facts: FactStoreManager
        let engine: IrisEngine
        /// Request `i`'s turn-context block; it rides that turn's own entry, the last user one.
        func lead(_ i: Int) -> String { turnContextBlock(client.requests[i]) }
        func fact(_ content: String) throws -> Fact {
            try #require(try facts.listFacts(includeInactive: true, limit: 50).first { $0.content == content })
        }
    }

    private func harness() throws -> Harness {
        let facts = try FactStoreManager(inMemory: true)
        for c in ["The Seattle office moves in March", "Portland has the spare servers", "The sky is blue"] {
            try facts.addFact(content: c)
        }
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = FactTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)
        return Harness(app: app, id: id, client: client, facts: facts, engine: engine)
    }

    @Test("kickoff injects the objective's facts; reprompts carry them without a new search")
    func kickoffThenCarry() async throws {
        let h = try harness()
        await h.engine.processInput("GOAL MODE ACTIVATED. Your goal is: plan the Seattle move.", source: "System",
                                    conversationId: h.id, goalFacts: .start(objective: "plan the Seattle move"))
        await h.engine.processInput("Continue working on your goal.", source: "System",
                                    conversationId: h.id, goalFacts: .carry)
        await h.engine.processInput("Continue working on your goal.", source: "System",
                                    conversationId: h.id, goalFacts: .carry)
        for i in 0..<3 {
            #expect(h.lead(i).contains("The Seattle office moves in March"), "turn \(i)")
            #expect(!h.lead(i).contains("sky is blue"), "turn \(i)")
        }
        // One search, at kickoff: the reprompts did not count as retrievals.
        #expect(try h.fact("The Seattle office moves in March").retrievalCount == 1)
    }

    @Test("a steer searches its own text, ahead of what the run already carries")
    func steerAddsFacts() async throws {
        let h = try harness()
        await h.engine.processInput("kickoff", source: "System", conversationId: h.id,
                                    goalFacts: .start(objective: "plan the Seattle move"))
        await h.engine.processInput("resume", source: "System", conversationId: h.id,
                                    goalFacts: .steer("use the Portland servers"))
        await h.engine.processInput("reprompt", source: "System", conversationId: h.id, goalFacts: .carry)
        for i in 1...2 {
            let lead = h.lead(i)
            let portland = try #require(lead.range(of: "Portland has the spare servers"), "turn \(i)")
            let seattle = try #require(lead.range(of: "The Seattle office moves in March"), "turn \(i)")
            #expect(portland.lowerBound < seattle.lowerBound, "turn \(i)")
        }
        #expect(!h.lead(0).contains("Portland"))
    }

    @Test("a fact retracted mid-run drops out of the carried set")
    func retractedDropsOut() async throws {
        let h = try harness()
        await h.engine.processInput("kickoff", source: "System", conversationId: h.id,
                                    goalFacts: .start(objective: "plan the Seattle move"))
        try h.facts.retractFact(id: try h.fact("The Seattle office moves in March").id)
        await h.engine.processInput("reprompt", source: "System", conversationId: h.id, goalFacts: .carry)
        #expect(!h.lead(1).contains("Seattle office"))
    }

    @Test("with nothing carried (a restart mid-run), the first reprompt searches the contract's objective")
    func carryFallsBackToObjective() async throws {
        let h = try harness()
        let idx = try #require(h.app.conversations.firstIndex { $0.id == h.id })
        h.app.conversations[idx].goalContract = GoalContract(objective: "plan the Seattle move", criteria: [])
        await h.engine.processInput("reprompt", source: "System", conversationId: h.id, goalFacts: .carry)
        await h.engine.processInput("reprompt", source: "System", conversationId: h.id, goalFacts: .carry)
        #expect(h.lead(0).contains("The Seattle office moves in March"))
        #expect(h.lead(1).contains("The Seattle office moves in March"))
        #expect(try h.fact("The Seattle office moves in March").retrievalCount == 1)
    }

    @Test("a subagent's goal turns get no facts")
    func subagentGetsNone() async throws {
        let facts = try FactStoreManager(inMemory: true)
        try facts.addFact(content: "The Seattle office moves in March")
        let app = AppState()
        app.conversations.removeAll()
        let id = UUID()
        app.createNewConversation(id: id)
        let client = FactTurnClient()
        let engine = IrisEngine(state: app, tier: .medium, principal: .subagent, client: client,
                                retryDelays: [], streamResponses: false, factStore: facts,
                                protectionEnabled: false, sessionPeerCount: 0)
        await engine.processInput("kickoff", source: "System", conversationId: id,
                                  goalFacts: .start(objective: "plan the Seattle move"))
        let request = try #require(client.requests.first)
        let block = turnContextBlock(request)
        #expect(!block.contains(factHeading))
    }

    @Test("AppState's kickoff and its engine reprompt carry the objective's facts end to end")
    func appStateKickoffWiring() async throws {
        let h = try harness()
        let engine = IrisEngine(state: h.app, tier: .medium, principal: .main, client: h.client,
                                retryDelays: [], streamResponses: false, factStore: h.facts,
                                protectionEnabled: false, sessionPeerCount: 0, repromptDelay: 0.01)
        h.app.installEngine(engine)
        let idx = try #require(h.app.conversations.firstIndex { $0.id == h.id })
        h.app.conversations[idx].goalContract = GoalContract(objective: "plan the Seattle move", criteria: [])
        h.app.setGoal(for: h.id, goal: "plan the Seattle move")
        h.app.sendGoalKickoff(for: h.id)
        // Generous: it returns the moment both requests exist; a loaded host once took over 10 s.
        let deadline = Date().addingTimeInterval(60)
        while h.client.requests.count < 2, Date() < deadline { try await Task.sleep(nanoseconds: 10_000_000) }
        h.app.clearGoal(for: h.id)
        try #require(h.client.requests.count >= 2)
        #expect(h.lead(0).contains("The Seattle office moves in March"), "kickoff")
        #expect(h.lead(1).contains("The Seattle office moves in March"), "engine reprompt")
        #expect(try h.fact("The Seattle office moves in March").retrievalCount == 1)
    }
}
