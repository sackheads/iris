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
    var timestamp: Date
    /// `FactStatus` raw value. Rows written before the v2 migration read back as `active`.
    var status: String
    var retrievalCount: Int
    var helpfulCount: Int
    var supersededBy: String?
    var supersededAt: Date?

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
        supersededAt: Date? = nil
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

    /// A unit run gets its own in-memory store. `IrisPaths.default` resolves to the developer's
    /// real `~/.iris` under `swift test`, so touching `.shared` there would open, v2-migrate and
    /// then write retrieval counts into the machine's own fact store — the same isolation rule
    /// `IrisDefaults.processStore` enforces for user defaults (#121). Tests that want a real
    /// on-disk store build one with `FactStoreManager(paths:)` against a temp directory.
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

        return migrator
    }

    /// Adds a fact to the SQLite Fact Store. When `supersedes` names an existing fact, the insert
    /// and the supersession share one transaction: a rejected supersession inserts nothing.
    @discardableResult
    func addFact(
        content: String,
        category: String = "general",
        entity: String? = nil,
        tags: String? = nil,
        trustScore: Double = 1.0,
        supersedes: String? = nil
    ) throws -> Fact {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { throw FactStoreError.emptyContent }

        let fact = Fact(
            content: trimmed,
            category: category,
            entity: entity,
            tags: tags,
            trustScore: trustScore,
            timestamp: Date()
        )
        try writer.write { db in
            try fact.insert(db)
            if let supersedes {
                try Self.markSuperseded(db, id: supersedes, by: fact.id)
            }
        }
        try? evictOldFacts()
        return fact
    }

    /// Searches active facts using FTS5 full-text matching, trust weighting, and exponential time decay.
    /// `countsAsRetrieval` is the usage signal that keeps a fact alive through eviction, so browse
    /// paths (`/facts`, the journey scan) pass `false`: a human reading the store is not a retrieval.
    func search(
        query: String,
        category: String? = nil,
        entity: String? = nil,
        limit: Int = 5,
        threshold: Double = 0.1,
        countsAsRetrieval: Bool = true
    ) throws -> [Fact] {
        let results = try reader.read { db -> [Fact] in
            let trimmedQuery = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let sanitizedQuery = sanitizeFTSQuery(trimmedQuery)

            let candidates: [Fact]
            if sanitizedQuery.isEmpty {
                candidates = try Fact.fetchAll(
                    db,
                    sql: "SELECT * FROM facts WHERE status = 'active' ORDER BY trustScore DESC, timestamp DESC LIMIT ?",
                    arguments: [limit * 2]
                )
            } else {
                // FTS5Pattern, not FTS3Pattern: `facts_fts` is an FTS5 table, tokenized by the
                // same unicode61 tokenizer that built the index (see
                // `ConversationStore.searchConversations`'s comment for the FTS3/FTS5 distinction
                // this mirrors).
                let ftsPattern = FTS5Pattern(matchingAnyTokenIn: sanitizedQuery)
                var sql = """
                    SELECT facts.*
                    FROM facts
                    JOIN facts_fts ON facts_fts.rowid = facts.rowid
                    WHERE facts_fts MATCH ? AND facts.status = 'active'
                    """
                var args: [DatabaseValueConvertible?] = [ftsPattern]

                if let category = category {
                    sql += " AND facts.category = ?"
                    args.append(category)
                }
                if let entity = entity {
                    sql += " AND facts.entity = ?"
                    args.append(entity)
                }

                candidates = try Fact.fetchAll(db, sql: sql, arguments: StatementArguments(args))
            }

            let now = Date()
            let scored = candidates.compactMap { fact -> (Fact, Double)? in
                let ageInSeconds = now.timeIntervalSince(fact.timestamp)
                let ageInDays = max(0, ageInSeconds / 86400.0)
                let decayFactor = exp(-0.05 * ageInDays)
                let baseScore = 1.0 + (fact.trustScore * 0.1)
                let finalScore = baseScore * decayFactor

                if finalScore >= threshold {
                    return (fact, finalScore)
                }
                return nil
            }

            return scored
                .sorted { $0.1 > $1.1 }
                .prefix(limit)
                .map { $0.0 }
        }
        if countsAsRetrieval { try? incrementRetrievals(ids: results.map(\.id)) }
        return results
    }

    /// Retrieves active facts associated with a specific entity (probe).
    func probe(entity: String, limit: Int = 10, countsAsRetrieval: Bool = true) throws -> [Fact] {
        let results = try reader.read { db in
            let sql = """
                SELECT * FROM facts
                WHERE status = 'active' AND (entity = ? OR content LIKE ?)
                ORDER BY trustScore DESC, timestamp DESC LIMIT ?
                """
            return try Fact.fetchAll(db, sql: sql, arguments: [entity, "%\(entity)%", limit])
        }
        if countsAsRetrieval { try? incrementRetrievals(ids: results.map(\.id)) }
        return results
    }

    /// Browses facts by trust, newest first. Inactive rows carry their status and lineage.
    func listFacts(includeInactive: Bool = false, limit: Int = 50) throws -> [Fact] {
        try reader.read { db in
            let statusClause = includeInactive ? "" : "WHERE status = 'active'"
            let sql = """
                SELECT * FROM facts \(statusClause)
                ORDER BY trustScore DESC, timestamp DESC LIMIT ?
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

    /// Reinforces facts by bumping trust score and updating timestamp.
    func reinforceFacts(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            let sql = """
                UPDATE facts
                SET timestamp = CURRENT_TIMESTAMP,
                    trustScore = trustScore + 0.1
                WHERE id IN (\(placeholders))
                """
            try db.execute(sql: sql, arguments: StatementArguments(ids))
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
                AND (((julianday('now') - julianday(timestamp)) > 30 AND trustScore < 1.2)
                     OR ((julianday('now') - julianday(timestamp)) > 90))
                """
            try db.execute(sql: sql)
        }
    }

    /// Counts a retrieval against every fact a search or probe just returned. Each UPDATE also
    /// fires the FTS5 after-update trigger, so the index is rewritten for those rows; that churn is
    /// acceptable at a result set of five to ten facts.
    private func incrementRetrievals(ids: [String]) throws {
        guard !ids.isEmpty else { return }
        try writer.write { db in
            let placeholders = ids.map { _ in "?" }.joined(separator: ", ")
            try db.execute(sql: "UPDATE facts SET retrievalCount = retrievalCount + 1 WHERE id IN (\(placeholders))",
                           arguments: StatementArguments(ids))
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
                    }
                }
            }
        }
    }

    /// Sanitizes FTS query input by replacing special characters.
    private func sanitizeFTSQuery(_ query: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(.whitespaces)
        return query.unicodeScalars
            .filter { allowed.contains($0) }
            .map { String($0) }
            .joined()
    }
}
