import Foundation
import GRDB

/// Lifecycle state of a fact. Stored as TEXT to match the hermes-memory schema.
enum FactStatus: String, Codable, Sendable {
    case active
    case retracted
    case superseded
}

/// Failures the fact store reports to its callers so a tool handler can say what went wrong.
enum FactStoreError: Error, Equatable {
    case notFound(id: String)
    case selfSupersession
    case cycle
    case emptyContent
}

/// A structured fact stored in the SQLite Fact Store.
struct Fact: Identifiable, Codable, FetchableRecord, PersistableRecord, Sendable, Equatable {
    var id: String
    var content: String
    var category: String
    var entity: String?
    var tags: String?
    var trustScore: Double
    /// Legacy time column. Written once at insert since #416; before that JIT reinforcement
    /// rewrote it on every hit, so on an old row it may be a retrieval time. Read `createdAt`.
    var timestamp: Date
    /// `FactStatus` raw value. Rows written before the v2 migration read back as `active`.
    var status: String
    var retrievalCount: Int
    var helpfulCount: Int
    var supersededBy: String?
    var supersededAt: Date?
    /// When the fact was saved. Written once, never by retrieval (#416). Rows from before the v3
    /// migration carry their `timestamp`, the best time known for them.
    var createdAt: Date
    /// The last time a search or probe returned the fact as a retrieval (#416).
    var lastRetrievedAt: Date?

    /// What write-time dedup and pre-injection dedup compare. Computed, not stored: a stored key
    /// would be empty on any row written by raw SQL, and the FTS index already narrows the lookup.
    var contentKey: String { FactStoreManager.contentKey(content) }

    /// What write-time dedup and the merge migration compare: the same text about two different
    /// entities ("Prefers dark mode." for Alice and for Bob) is two facts. Nil and empty entity
    /// are the same. Pre-injection dedup uses it too; the rendered line names the entity.
    struct DedupKey: Hashable { let content: String; let entity: String }
    var dedupKey: DedupKey { DedupKey(content: contentKey, entity: FactStoreManager.contentKey(entity ?? "")) }

    static let databaseTableName = "facts"

    var isActive: Bool { status == FactStatus.active.rawValue }

    init(
        id: String = UUID().uuidString,
        content: String,
        category: String = "general",
        entity: String? = nil,
        tags: String? = nil,
        trustScore: Double = 1.0,
        timestamp: Date = Date(),
        status: String = FactStatus.active.rawValue,
        retrievalCount: Int = 0,
        helpfulCount: Int = 0,
        supersededBy: String? = nil,
        supersededAt: Date? = nil,
        createdAt: Date? = nil,
        lastRetrievedAt: Date? = nil
    ) {
        self.id = id
        self.content = content
        self.category = category
        self.entity = entity
        self.tags = tags
        self.trustScore = trustScore
        self.timestamp = timestamp
        self.status = status
        self.retrievalCount = retrievalCount
        self.helpfulCount = helpfulCount
        self.supersededBy = supersededBy
        self.supersededAt = supersededAt
        self.createdAt = createdAt ?? timestamp
        self.lastRetrievedAt = lastRetrievedAt
    }

    // Invariant 1: the #416 fields are decoded if present, so a row read before (or without) the
    // v3 migration still decodes.
    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        id = try c.decode(String.self, forKey: .id)
        content = try c.decode(String.self, forKey: .content)
        category = try c.decodeIfPresent(String.self, forKey: .category) ?? "general"
        entity = try c.decodeIfPresent(String.self, forKey: .entity)
        tags = try c.decodeIfPresent(String.self, forKey: .tags)
        trustScore = try c.decodeIfPresent(Double.self, forKey: .trustScore) ?? 1.0
        timestamp = try c.decodeIfPresent(Date.self, forKey: .timestamp) ?? Date()
        status = try c.decodeIfPresent(String.self, forKey: .status) ?? FactStatus.active.rawValue
        retrievalCount = try c.decodeIfPresent(Int.self, forKey: .retrievalCount) ?? 0
        helpfulCount = try c.decodeIfPresent(Int.self, forKey: .helpfulCount) ?? 0
        supersededBy = try c.decodeIfPresent(String.self, forKey: .supersededBy)
        supersededAt = try c.decodeIfPresent(Date.self, forKey: .supersededAt)
        createdAt = try c.decodeIfPresent(Date.self, forKey: .createdAt) ?? timestamp
        lastRetrievedAt = try c.decodeIfPresent(Date.self, forKey: .lastRetrievedAt)
    }
}

/// A relational edge connecting two facts in the Fact Store.
struct FactRelation: Codable, FetchableRecord, PersistableRecord, Sendable {
    var sourceId: String
    var targetId: String
    var relationType: String
    var weight: Double

    static let databaseTableName = "fact_relations"
}

/// Pure SQLite & FTS5 fact store replacing the legacy HRR vector implementation.
final class FactStoreManager: @unchecked Sendable {
    /// Trust deltas mirror hermes-memory: a helpful rating nudges up, an unhelpful one costs twice
    /// as much, so one bad answer outweighs one good one.
    static let helpfulDelta = 0.05
    static let unhelpfulDelta = -0.10
    /// Hop cap when walking a supersession chain; a corrupt chain fails closed as a cycle.
    private static let maxChainHops = 50

    /// The outcome of `restoreFact`. Restoring a mid-chain fact leaves its successor active and
    /// detached by design; naming it lets the caller retract it if it is stale.
    struct RestoreResult {
        let fact: Fact
        let stillActiveSuccessor: Fact?
    }

    /// A unit run gets its own in-memory store. Before #304 `IrisPaths.default` was the
    /// developer's real `~/.iris` under `swift test`, so touching `.shared` would open, v2-migrate
    /// and write retrieval counts into the machine's own fact store (#121). It is a per-process
    /// temp home now, but in-memory stays: no file to create, nothing to leave behind. Tests that
    /// want a real on-disk store build one with `FactStoreManager(paths:)` against a temp directory.
    static let shared: FactStoreManager = {
        if NSClassFromString("XCTestCase") != nil {
            return try! FactStoreManager(inMemory: true)
        }
        do {
            return try FactStoreManager()
        } catch {
            print("WARNING: FactStoreManager failed to initialize on disk. Falling back to in-memory mode. Error: \(error)")
            return try! FactStoreManager(inMemory: true)
        }
    }()

    private let dbPool: DatabasePool?
    let dbQueue: DatabaseQueue?

    private var writer: DatabaseWriter { dbQueue ?? dbPool! }
    private var reader: DatabaseReader { dbQueue ?? dbPool! }

    init(inMemory: Bool = false, paths: IrisPaths = .default) throws {
        var configuration = Configuration()
        configuration.prepareDatabase { db in
            db.trace { _ in } // Suppress logs by default
        }

        if inMemory {
            dbPool = nil
            dbQueue = try DatabaseQueue(configuration: configuration)
            try Self.migrator.migrate(dbQueue!)
        } else {
            try? paths.ensureDirectories()
            let dbPath = paths.factStoreDB.path
            dbPool = try DatabasePool(path: dbPath, configuration: configuration)
            dbQueue = nil
            try Self.migrator.migrate(dbPool!)
            try migrateLegacyHolographicFacts(paths: paths)
        }
    }

    /// Internal so a test can build a v1-era database (`migrate(_:upTo:)`) and then upgrade it.
    static var migrator: DatabaseMigrator {
        var migrator = DatabaseMigrator()

        migrator.registerMigration("v1_fact_store") { db in
            try db.create(table: "facts") { t in
                t.column("id", .text).primaryKey()
                t.column("content", .text).notNull()
                t.column("category", .text).notNull().defaults(to: "general")
                t.column("entity", .text)
                t.column("tags", .text)
                t.column("trustScore", .double).notNull().defaults(to: 1.0)
                t.column("timestamp", .datetime).notNull().defaults(sql: "CURRENT_TIMESTAMP")
            }

            try db.create(virtualTable: "facts_fts", using: FTS5()) { t in
                t.synchronize(withTable: "facts")
                t.column("content")
                t.column("category")
                t.column("entity")
                t.column("tags")
            }

            try db.create(table: "fact_relations") { t in
                t.column("sourceId", .text).references("facts", column: "id", onDelete: .cascade)
                t.column("targetId", .text).references("facts", column: "id", onDelete: .cascade)
                t.column("relationType", .text)
                t.column("weight", .double).notNull().defaults(to: 1.0)
                t.primaryKey(["sourceId", "targetId"])
            }
        }

        // Retraction lifecycle and usage/feedback trust signals (#168). Added as columns on the
        // live table so an existing fact_store.sqlite keeps its rows; every column has a default
        // so v1 rows read back as active and unused.
        migrator.registerMigration("v2_fact_lifecycle") { db in
            try db.execute(sql: """
                ALTER TABLE facts ADD COLUMN status TEXT NOT NULL DEFAULT 'active'
                CHECK (status IN ('active','retracted','superseded'))
                """)
            try db.execute(sql: "ALTER TABLE facts ADD COLUMN retrievalCount INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE facts ADD COLUMN helpfulCount INTEGER NOT NULL DEFAULT 0")
            try db.execute(sql: "ALTER TABLE facts ADD COLUMN supersededBy TEXT")
            try db.execute(sql: "ALTER TABLE facts ADD COLUMN supersededAt DATETIME")
        }

        // #416: `timestamp` was the only time column and JIT reinforcement rewrote it on every hit.
        // `createdAt` is written once; `lastRetrievedAt` takes the retrieval time. An existing row's
        // creation time is unknown, so it gets its `timestamp`, the best time on record.
        migrator.registerMigration("v3_fact_created_at") { db in
            try db.execute(sql: "ALTER TABLE facts ADD COLUMN createdAt DATETIME")
            try db.execute(sql: "ALTER TABLE facts ADD COLUMN lastRetrievedAt DATETIME")
            try db.execute(sql: "UPDATE facts SET createdAt = timestamp WHERE createdAt IS NULL")
        }

        // #416: one-time merge of the exact duplicates (by `contentKey`) that write-time dedup now
        // prevents. Runs after v3 so "oldest" is decided by `createdAt`.
        migrator.registerMigration("v4_fact_dedup") { db in
            try mergeDuplicateActiveFacts(db)
        }

        // #415 review: the porter stemmer, so "use" finds "uses" and "preferences" finds "prefers".
        // Recreating the synchronized table rebuilds the index from `facts` (GRDB issues the
        // FTS5 'rebuild'); the triggers are recreated with it.
        migrator.registerMigration("v5_fact_fts_porter") { db in
            try db.dropFTS5SynchronizationTriggers(forTable: "facts_fts")
            try db.drop(table: "facts_fts")
            try db.create(virtualTable: "facts_fts", using: FTS5()) { t in
                t.synchronize(withTable: "facts")
                t.tokenizer = .porter(wrapping: .unicode61())
                t.column("content")
                t.column("category")
                t.column("entity")
                t.column("tags")
            }
        }

        return migrator
    }

    /// Adds a fact to the SQLite Fact Store. When `supersedes` names an existing fact, the insert
    /// and the supersession share one transaction: a rejected supersession inserts nothing.
    ///
    /// Dedup (#416): when an active fact already has the same `dedupKey` (content key plus
    /// normalised entity; category is ignored), nothing is inserted and that fact is returned unchanged (no trust bump: parallel
    /// `save_fact` calls in one turn are how duplicates arose, and they are not evidence). A
    /// `supersedes` on that call then points at the existing fact.
    @discardableResult
    func addFact(
        content: String,
        category: String = "general",
        entity: String? = nil,
        tags: String? = nil,
        trustScore: Double = 1.0,
        supersedes: String? = nil
    ) throws -> Fact {
        try saveFact(content: content, category: category, entity: entity, tags: tags,
                     trustScore: trustScore, supersedes: supersedes).fact
    }

    /// `addFact`, also saying whether a row was inserted or an existing duplicate returned, so
    /// `save_fact` can tell the model the truth.
    func saveFact(
        content: String,
        category: String = "general",
        entity: String? = nil,
        tags: String? = nil,
        trustScore: Double = 1.0,
        supersedes: String? = nil
    ) throws -> (fact: Fact, isNew: Bool) {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FactStoreError.emptyContent }

        let now = Date()
        let candidate = Fact(
            content: trimmed,
            category: category,
            entity: entity,
            tags: tags,
            trustScore: trustScore,
            timestamp: now,
            createdAt: now
        )
        let (fact, inserted) = try writer.write { db -> (Fact, Bool) in
            let existing = try Self.activeFact(db, matching: candidate.dedupKey, content: trimmed)
            let fact = existing ?? candidate
            if existing == nil { try fact.insert(db) }
            if let supersedes {
                try Self.markSuperseded(db, id: supersedes, by: fact.id)
            }
            return (fact, existing == nil)
        }
        if inserted { try? evictOldFacts() }
        return (fact, inserted)
    }

    /// The dedup key: trimmed, whitespace runs collapsed to one space, case-folded, and trailing
    /// sentence punctuation dropped, so "The sky is blue." and "the sky  is blue" are one fact.
    static func contentKey(_ content: String) -> String {
        let words = content
            .folding(options: [.caseInsensitive], locale: nil)
            .split(whereSeparator: { $0.isWhitespace || $0.isNewline })
        var key = words.joined(separator: " ")
        while let last = key.last, ".!;:,".contains(last) { key.removeLast() }
        return key
    }

    /// The oldest active fact with this `dedupKey`. The FTS index narrows the scan to rows holding
    /// every token of `content` (a superset of key equality: the tokenizer folds case and
    /// diacritics and stems); content with no tokens at all falls back to a scan of the active rows.
    private static func activeFact(_ db: Database, matching key: Fact.DedupKey, content: String) throws -> Fact? {
        let candidates: [Fact]
        if let pattern = FTS5Pattern(matchingAllTokensIn: content) {
            candidates = try Fact.fetchAll(db, sql: """
                SELECT facts.* FROM facts JOIN facts_fts ON facts_fts.rowid = facts.rowid
                WHERE facts_fts MATCH ? AND facts.status = 'active'
                ORDER BY COALESCE(facts.createdAt, facts.timestamp) ASC, facts.rowid ASC
                """, arguments: [pattern])
        } else {
            candidates = try Fact.fetchAll(db, sql: """
                SELECT * FROM facts WHERE status = 'active'
                ORDER BY COALESCE(createdAt, timestamp) ASC, rowid ASC
                """)
        }
        return candidates.first { $0.dedupKey == key }
    }

    /// v4_fact_dedup's body. Per `dedupKey` (content and entity) among active facts: keep the oldest, give it the summed
    /// `retrievalCount` and `helpfulCount`, the highest trust (so a helpful rating on a copy is not
    /// lost) and the latest `lastRetrievedAt`; re-point lineage and relations at it; delete the
    /// rest. Deletes go through the `facts_fts` sync triggers; the rebuild afterwards is a
    /// belt-and-braces resync of the external-content index.
    static func mergeDuplicateActiveFacts(_ db: Database) throws {
        let active = try Fact.fetchAll(db, sql: """
            SELECT * FROM facts WHERE status = 'active'
            ORDER BY COALESCE(createdAt, timestamp) ASC, rowid ASC
            """)
        var groups: [Fact.DedupKey: [Fact]] = [:]
        var order: [Fact.DedupKey] = []
        for fact in active {
            let key = fact.dedupKey
            if groups[key] == nil { order.append(key) }
            groups[key, default: []].append(fact)
        }
        var merged = false
        for key in order {
            guard let group = groups[key], group.count > 1, let keeper = group.first else { continue }
            let dupes = Array(group.dropFirst())
            let lastRetrieved = group.compactMap(\.lastRetrievedAt).max()
            try db.execute(sql: """
                UPDATE facts SET retrievalCount = ?, helpfulCount = ?, trustScore = ?, lastRetrievedAt = ?
                WHERE id = ?
                """, arguments: [group.map(\.retrievalCount).reduce(0, +), group.map(\.helpfulCount).reduce(0, +),
                                 group.map(\.trustScore).max() ?? keeper.trustScore, lastRetrieved, keeper.id])
            for dupe in dupes {
                try db.execute(sql: "UPDATE facts SET supersededBy = ? WHERE supersededBy = ?", arguments: [keeper.id, dupe.id])
                try db.execute(sql: "UPDATE OR IGNORE fact_relations SET sourceId = ? WHERE sourceId = ?", arguments: [keeper.id, dupe.id])
                try db.execute(sql: "UPDATE OR IGNORE fact_relations SET targetId = ? WHERE targetId = ?", arguments: [keeper.id, dupe.id])
                try db.execute(sql: "DELETE FROM fact_relations WHERE sourceId = ? OR targetId = ?", arguments: [dupe.id, dupe.id])
                try db.execute(sql: "DELETE FROM facts WHERE id = ?", arguments: [dupe.id])
            }
            merged = true
        }
        if merged {
            try db.execute(sql: "INSERT INTO facts_fts(facts_fts) VALUES('rebuild')")
        }
    }

    /// JIT's relevance floor (#415): a fact is injected unasked only if it shares a
    /// *discriminating* query term with the query, one found in fewer than this fraction of the
    /// active facts, or the query names its entity. A word in half the store (the user's name, the
    /// project's name) says nothing about which of those facts is meant. Counted over active rows
    /// in Swift, not read off bm25(): FTS5's IDF counts every indexed row, superseded ones included.
    static let discriminatingTermFraction = 0.5
    /// Below this many active facts the floor is off and any content-word match counts: injecting
    /// a few facts from a store this small costs little, and its document frequencies are noise.
    static let minActiveFactsForRelevanceFloor = 20

    /// Searches active facts with FTS5 (porter-stemmed), ranked by BM25 relevance with a mild
    /// trust/recency adjustment. The query's stopwords are dropped first (`FactQueryTerms`); a
    /// query that is nothing but stopwords matches nothing. An empty query browses by trust instead.
    ///
    /// `applyRelevanceFloor` keeps only matches that pass `passesRelevanceFloor`. JIT sets it; an
    /// explicit search (search_memory, /facts) does not, since asking for a term already says it
    /// matters. Results are deduped by `contentKey`.
    ///
    /// `countsAsRetrieval` is the usage signal that keeps a fact alive through eviction, so browse
    /// paths (`/facts`, the journey scan) pass `false`: a human reading the store is not a retrieval.
    /// A retrieval bumps only `retrievalCount` and `lastRetrievedAt`, never trust or `createdAt`.
    func search(
        query: String,
        category: String? = nil,
        entity: String? = nil,
        limit: Int = 5,
        applyRelevanceFloor: Bool = false,
        countsAsRetrieval: Bool = true
    ) throws -> [Fact] {
        let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
        let results = try reader.read { db -> [Fact] in
            if trimmedQuery.isEmpty {
                let browse = try Fact.fetchAll(
                    db,
                    sql: "SELECT * FROM facts WHERE status = 'active' ORDER BY trustScore DESC, COALESCE(createdAt, timestamp) DESC LIMIT ?",
                    arguments: [limit * 2]
                )
                return Array(Self.dedupe(browse).prefix(limit))
            }

            let terms = FactQueryTerms.contentTerms(in: trimmedQuery)
            guard !terms.isEmpty else { return [] }
            // Matched against content, entity and tags only: every row's category is a word like
            // "general", which would otherwise match any query that happens to contain it.
            let match = "{content entity tags} : (" + terms.map { "\"\($0)\"" }.joined(separator: " OR ") + ")"
            var sql = """
                SELECT facts.rowid AS factRowid, facts.*, -bm25(facts_fts) AS relevance
                FROM facts_fts
                JOIN facts ON facts.rowid = facts_fts.rowid
                WHERE facts_fts MATCH ? AND facts.status = 'active'
                """
            var args: [DatabaseValueConvertible?] = [match]
            if let category {
                sql += " AND facts.category = ?"
                args.append(category)
            }
            if let entity {
                sql += " AND facts.entity = ?"
                args.append(entity)
            }
            sql += " ORDER BY relevance DESC LIMIT ?"
            args.append(max(limit * 4, 20))

            let rows = try Row.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            let floor = applyRelevanceFloor ? try Self.relevanceFloor(db, terms: terms) : nil

            let now = Date()
            let scored = try rows.compactMap { row -> (Fact, Double)? in
                let relevance: Double = row["relevance"] ?? 0
                let fact = try Fact(row: row)
                if let floor, !floor.passes(rowid: row["factRowid"], fact: fact) { return nil }
                return (fact, relevance * Self.rankAdjustment(for: fact, now: now))
            }
            let ranked = scored.sorted { $0.1 > $1.1 }.map(\.0)
            return Array(Self.dedupe(ranked).prefix(limit))
        }
        if countsAsRetrieval { try? incrementRetrievals(ids: results.map(\.id)) }
        return results
    }

    /// The floor's per-query statistics: the active rows holding at least one discriminating term,
    /// and the query's terms for the entity bypass. Nil when the store is under the size threshold.
    struct RelevanceFloor {
        let discriminatingRows: Set<Int64>
        let terms: Set<String>

        func passes(rowid: Int64?, fact: Fact) -> Bool {
            if let rowid, discriminatingRows.contains(rowid) { return true }
            // The query names the fact's entity ("remind me about Brian", entity Brian).
            let entityTerms = FactQueryTerms.contentTerms(in: fact.entity ?? "")
            return !entityTerms.isEmpty && entityTerms.allSatisfy(terms.contains)
        }
    }

    private static func relevanceFloor(_ db: Database, terms: [String]) throws -> RelevanceFloor? {
        let active = try Int.fetchOne(db, sql: "SELECT count(*) FROM facts WHERE status = 'active'") ?? 0
        guard active >= minActiveFactsForRelevanceFloor else { return nil }
        var rows: Set<Int64> = []
        for term in terms.prefix(64) {
            let matching = try Int64.fetchAll(db, sql: """
                SELECT facts.rowid FROM facts_fts JOIN facts ON facts.rowid = facts_fts.rowid
                WHERE facts_fts MATCH ? AND facts.status = 'active'
                """, arguments: ["{content entity tags} : \"\(term)\""])
            if Double(matching.count) < discriminatingTermFraction * Double(active) {
                rows.formUnion(matching)
            }
        }
        return RelevanceFloor(discriminatingRows: rows, terms: Set(terms))
    }

    /// Ranking only, never a filter: trust earned through explicit feedback lifts a fact a little,
    /// and age lowers it by at most half (a year-old standing fact is still worth showing).
    private static func rankAdjustment(for fact: Fact, now: Date) -> Double {
        let ageInDays = max(0, now.timeIntervalSince(fact.createdAt) / 86400.0)
        let recency = max(0.5, exp(-ageInDays / 365.0))
        return (1.0 + fact.trustScore * 0.1) * recency
    }

    /// First occurrence wins, so pass facts already in rank order.
    static func dedupe(_ facts: [Fact]) -> [Fact] {
        var seen: Set<Fact.DedupKey> = []
        return facts.filter { seen.insert($0.dedupKey).inserted }
    }

    /// Retrieves active facts associated with a specific entity (probe).
    func probe(entity: String, limit: Int = 10, countsAsRetrieval: Bool = true) throws -> [Fact] {
        let results = try reader.read { db in
            let sql = """
                SELECT * FROM facts
                WHERE status = 'active' AND (entity = ? OR content LIKE ?)
                ORDER BY trustScore DESC, COALESCE(createdAt, timestamp) DESC LIMIT ?
                """
            return Self.dedupe(try Fact.fetchAll(db, sql: sql, arguments: [entity, "%\(entity)%", limit]))
        }
        if countsAsRetrieval { try? incrementRetrievals(ids: results.map(\.id)) }
        return results
    }

    /// The active facts among `ids`, in the order given. Not a retrieval: a goal run's carried
    /// facts were counted when they were found.
    func activeFacts(ids: [String]) throws -> [Fact] {
        guard !ids.isEmpty else { return [] }
        let rows = try reader.read { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            return try Fact.fetchAll(db, sql: "SELECT * FROM facts WHERE status = 'active' AND id IN (\(placeholders))",
                                     arguments: StatementArguments(ids))
        }
        let byId = Dictionary(rows.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return ids.compactMap { byId[$0] }
    }

    /// Browses facts by trust, newest first. Inactive rows carry their status and lineage.
    func listFacts(includeInactive: Bool = false, limit: Int = 50) throws -> [Fact] {
        try reader.read { db in
            let statusClause = includeInactive ? "" : "WHERE status = 'active'"
            let sql = """
                SELECT * FROM facts \(statusClause)
                ORDER BY trustScore DESC, COALESCE(createdAt, timestamp) DESC LIMIT ?
                """
            return try Fact.fetchAll(db, sql: sql, arguments: [limit])
        }
    }

    /// Marks a fact as no longer true, with no replacement.
    func retractFact(id: String) throws {
        try writer.write { db in
            guard try Fact.exists(db, key: id) else { throw FactStoreError.notFound(id: id) }
            try db.execute(sql: """
                UPDATE facts SET status = 'retracted', supersededBy = NULL, supersededAt = CURRENT_TIMESTAMP
                WHERE id = ?
                """, arguments: [id])
        }
    }

    /// Marks `id` superseded by `by`, recording the lineage.
    func supersedeFact(id: String, by: String) throws {
        try writer.write { db in
            try Self.markSuperseded(db, id: id, by: by)
        }
    }

    /// Re-activates a retracted or superseded fact and clears its lineage. Reports the fact's
    /// former successor when that successor is itself still active, so the caller can judge it.
    func restoreFact(id: String) throws -> RestoreResult {
        try writer.write { db in
            guard let existing = try Fact.fetchOne(db, key: id) else { throw FactStoreError.notFound(id: id) }
            let formerSuccessor = existing.supersededBy
            try db.execute(sql: """
                UPDATE facts SET status = 'active', supersededBy = NULL, supersededAt = NULL
                WHERE id = ?
                """, arguments: [id])

            var restored = existing
            restored.status = FactStatus.active.rawValue
            restored.supersededBy = nil
            restored.supersededAt = nil

            var successor: Fact?
            if let formerSuccessor, let row = try Fact.fetchOne(db, key: formerSuccessor), row.isActive {
                successor = row
            }
            return RestoreResult(fact: restored, stillActiveSuccessor: successor)
        }
    }

    /// Records a helpful/unhelpful rating and moves trust asymmetrically. Trust floors at zero.
    @discardableResult
    func recordFeedback(id: String, helpful: Bool) throws -> Fact {
        try writer.write { db in
            guard var fact = try Fact.fetchOne(db, key: id) else { throw FactStoreError.notFound(id: id) }
            fact.trustScore = max(0.0, fact.trustScore + (helpful ? Self.helpfulDelta : Self.unhelpfulDelta))
            if helpful { fact.helpfulCount += 1 }
            try db.execute(sql: "UPDATE facts SET trustScore = ?, helpfulCount = ? WHERE id = ?",
                           arguments: [fact.trustScore, fact.helpfulCount, id])
            return fact
        }
    }

    /// Removes a fact by ID.
    func removeFact(id: String) throws {
        try writer.write { db in
            _ = try Fact.deleteOne(db, key: id)
        }
    }

    /// Evicts old facts that have not been reinforced. A fact that was ever retrieved or rated is
    /// kept regardless of age, and retracted/superseded rows are kept because they are lineage.
    func evictOldFacts() throws {
        try writer.write { db in
            let sql = """
                DELETE FROM facts
                WHERE status = 'active' AND retrievalCount = 0 AND helpfulCount = 0
                AND (((julianday('now') - julianday(COALESCE(createdAt, timestamp))) > 30 AND trustScore < 1.2)
                     OR ((julianday('now') - julianday(COALESCE(createdAt, timestamp))) > 90))
                """
            try db.execute(sql: sql)
        }
    }

    /// Counts a retrieval against every fact a search or probe just returned: `retrievalCount` and
    /// `lastRetrievedAt` only. Trust moves solely on explicit feedback (`recordFeedback`), and
    /// `createdAt`/`timestamp` are never touched, so retrieval cannot feed itself (#415). Each UPDATE also
    /// fires the FTS5 after-update trigger, so the index is rewritten for those rows; that churn is
    /// acceptable at a result set of five to ten facts.
    private func incrementRetrievals(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            try db.execute(sql: "UPDATE facts SET retrievalCount = retrievalCount + 1, lastRetrievedAt = ? WHERE id IN (\(placeholders))",
                           arguments: StatementArguments([Date()] + ids))
        }
    }

    /// Supersession inside a caller-controlled transaction, so `addFact(supersedes:)` is atomic.
    private static func markSuperseded(_ db: Database, id: String, by: String) throws {
        guard id != by else { throw FactStoreError.selfSupersession }
        guard try Fact.exists(db, key: id) else { throw FactStoreError.notFound(id: id) }
        guard try Fact.exists(db, key: by) else { throw FactStoreError.notFound(id: by) }
        guard try !chainReaches(db, from: by, to: id) else { throw FactStoreError.cycle }
        try db.execute(sql: """
            UPDATE facts SET status = 'superseded', supersededBy = ?, supersededAt = CURRENT_TIMESTAMP
            WHERE id = ?
            """, arguments: [by, id])
    }

    /// Walks `supersededBy` forward from `start`; true when `target` is reachable. Bounded by a
    /// hop cap and a visited set so an already-corrupt chain fails closed instead of looping.
    private static func chainReaches(_ db: Database, from start: String, to target: String) throws -> Bool {
        var visited: Set<String> = []
        var current = start
        for _ in 0..<maxChainHops {
            if current == target { return true }
            if visited.contains(current) { return false }
            visited.insert(current)
            guard let next = try String.fetchOne(db, sql: "SELECT supersededBy FROM facts WHERE id = ?",
                                                 arguments: [current]) else { return false }
            current = next
        }
        return true // exceeded the hop cap: treat as a cycle anomaly
    }

    /// Migrate legacy facts from holographic_memory.sqlite if present.
    private func migrateLegacyHolographicFacts(paths: IrisPaths) throws {
        let fm = FileManager.default
        let legacyDBPath = paths.holographicDB.path
        guard fm.fileExists(atPath: legacyDBPath) else { return }

        let hasFacts = try writer.read { db in
            try Fact.fetchCount(db) > 0
        }
        guard !hasFacts else { return }

        if let legacyQueue = try? DatabaseQueue(path: legacyDBPath) {
            try legacyQueue.read { legacyDB in
                if try legacyDB.tableExists("facts") {
                    let rows = try Row.fetchAll(legacyDB, sql: "SELECT id, content, trustScore, timestamp FROM facts")
                    try writer.write { db in
                        for row in rows {
                            if let id: String = row["id"], let content: String = row["content"] {
                                let trustScore: Double = row["trustScore"] ?? 1.0
                                let timestamp: Date = row["timestamp"] ?? Date()
                                let fact = Fact(id: id, content: content, category: "general", trustScore: trustScore, timestamp: timestamp)
                                try fact.insert(db)
                            }
                        }
                        // The HRR store had no dedup either, and this runs after v4 did its merge.
                        try Self.mergeDuplicateActiveFacts(db)
                    }
                }
            }
        }
    }

}

/// Query-side tokenization for fact search (#415): lowercased, diacritic-folded alphanumeric
/// words of two or more characters, minus a small English stopword list, deduped in order.
enum FactQueryTerms {
    /// Function words plus the conversational filler a prompt is made of ("can you help me…").
    /// Small on purpose: a content word missing from here only costs a weak match, which the BM25
    /// floor then judges; a content word wrongly listed here can never match at all.
    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "also", "am", "an", "and", "any", "are", "as",
        "at", "be", "because", "been", "before", "being", "below", "between", "both", "but", "by",
        "can", "could", "did", "do", "does", "doing", "done", "down", "during", "each", "else", "etc",
        "ever", "few", "for", "from", "further", "get", "gets", "got", "had", "has", "have", "having",
        "he", "help", "her", "here", "hers", "herself", "him", "himself", "his", "how", "however", "i", "if",
        "in", "into", "is", "it", "its", "itself", "just", "know", "let", "like", "may", "me", "might", "more",
        "most", "much", "must", "my", "myself", "no", "nor", "not", "now", "of", "off", "ok", "okay",
        "on", "once", "only", "or", "other", "our", "ours", "ourselves", "out", "over", "own",
        "please", "same", "shall", "she", "should", "so", "some", "such", "sure", "tell", "than",
        "thank", "thanks", "that", "the", "their", "theirs", "them", "themselves", "then", "there",
        "these", "they", "think", "this", "those", "through", "to", "too", "under", "until", "up", "us", "very",
        "want", "was", "we", "were", "what", "when", "where", "which", "while", "who", "whom", "why",
        "will", "with", "would", "yeah", "yes", "yet", "you", "your", "yours", "yourself",
        "yourselves",
        // contraction remnants once the apostrophe splits the word
        "ll", "re", "ve", "don", "doesn", "didn", "isn", "aren", "wasn",
    ]

    static func contentTerms(in query: String) -> [String] {
        let folded = query.folding(options: [.caseInsensitive, .diacriticInsensitive], locale: nil)
        var seen: Set<String> = []
        var terms: [String] = []
        for word in folded.split(whereSeparator: { !($0.isLetter || $0.isNumber) }) {
            let term = String(word)
            guard term.count >= 2, !stopwords.contains(term), seen.insert(term).inserted else { continue }
            terms.append(term)
        }
        return terms
    }
}

/// A coarse, locale-independent age for a fact ("today", "3 weeks ago"), so the prompt bytes for a
/// given age are the same on every machine.
enum FactAge {
    static func label(from date: Date, now: Date) -> String {
        let days = Int(max(0, now.timeIntervalSince(date)) / 86400)
        func unit(_ n: Int, _ name: String) -> String { "\(n) \(name)\(n == 1 ? "" : "s") ago" }
        switch days {
        case 0: return "today"
        case 1: return "yesterday"
        case ..<14: return unit(days, "day")
        case ..<61: return unit(days / 7, "week")
        case ..<730: return unit(days / 30, "month")
        default: return unit(days / 365, "year")
        }
    }
}
