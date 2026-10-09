import XCTest
import GRDB
@testable import IrisKit

final class FactStoreTests: XCTestCase {
    
    var factStore: FactStoreManager!
    
    override func setUpWithError() throws {
        // Initialize an in-memory database for fresh tests every time
        factStore = try FactStoreManager(inMemory: true)
    }

    override func tearDownWithError() throws {
        factStore = nil
    }

    func testFactStorageAndRetrieval() throws {
        let fact1 = "My favorite language is Swift because of its safety."
        let fact2 = "The capital of France is Paris."
        let fact3 = "Swift runs natively on Apple Silicon."
        
        try factStore.addFact(content: fact1, category: "user_pref", entity: "Swift")
        try factStore.addFact(content: fact2, category: "general", entity: "France")
        try factStore.addFact(content: fact3, category: "infrastructure", entity: "Apple Silicon")
        
        let results = try factStore.search(query: "Swift", limit: 5)
        
        XCTAssertEqual(results.count, 2, "Should find 2 facts mentioning Swift")
        guard results.count >= 2 else { return }
        
        XCTAssertTrue(results[0].content.contains("Swift"))
        XCTAssertTrue(results[1].content.contains("Swift"))
    }

    func testEntityProbe() throws {
        try factStore.addFact(content: "Brian prefers dry and concise AI responses.", category: "user_pref", entity: "Brian")
        try factStore.addFact(content: "Brian works on GKE.", category: "project", entity: "Brian")
        try factStore.addFact(content: "Paris is in France.", category: "general", entity: "France")

        let brianFacts = try factStore.probe(entity: "Brian")
        XCTAssertEqual(brianFacts.count, 2)
        XCTAssertTrue(brianFacts.allSatisfy { $0.content.contains("Brian") || $0.entity == "Brian" })
    }
    
    func testSearchDoesNotRaiseTrust() throws {
        // #415: retrieval used to add 0.1 trust per hit, which let any hit win again next turn.
        try factStore.addFact(content: "My favorite language is Swift because of its safety.")

        let results1 = try factStore.search(query: "Swift", limit: 1)
        XCTAssertEqual(results1.count, 1)
        let results2 = try factStore.search(query: "Swift", limit: 1)
        XCTAssertEqual(results2.count, 1)
        XCTAssertEqual(results2[0].trustScore, results1[0].trustScore)
    }
    
    func testEvictOldFacts() throws {
        let writer: GRDB.DatabaseWriter = factStore.dbQueue!
        
        // Add a fact with old timestamp
        try writer.write { db in
            let factId = UUID().uuidString
            let sql = """
                INSERT INTO facts (id, content, category, trustScore, timestamp)
                VALUES (?, 'Old fact', 'general', 1.0, datetime('now', '-40 days'))
                """
            try db.execute(sql: sql, arguments: [factId])
        }
        
        try factStore.evictOldFacts()
        
        let results = try factStore.search(query: "Old", limit: 1)
        XCTAssertEqual(results.count, 0, "Old fact should be evicted")
    }
    
    func testTimeDecayRanking() throws {
        let writer: GRDB.DatabaseWriter = factStore.dbQueue!
        
        try writer.write { db in
            let sql1 = """
                INSERT INTO facts (id, content, category, trustScore, timestamp)
                VALUES (?, 'Time decay test fact, older', 'general', 1.0, datetime('now', '-10 days'))
                """
            try db.execute(sql: sql1, arguments: [UUID().uuidString])
            
            let sql2 = """
                INSERT INTO facts (id, content, category, trustScore, timestamp)
                VALUES (?, 'Time decay test fact, newer', 'general', 1.0, datetime('now'))
                """
            try db.execute(sql: sql2, arguments: [UUID().uuidString])
        }
        
        let results = try factStore.search(query: "decay", limit: 2)
        XCTAssertEqual(results.count, 2)
        
        // The newer one should be ranked first due to decay
        let age0 = Date().timeIntervalSince(results[0].timestamp)
        let age1 = Date().timeIntervalSince(results[1].timestamp)
        XCTAssertLessThan(age0, age1, "Newer fact should be ranked higher")
    }

    func testLegacyHolographicMigration() async throws {
        try await withTempDirectory(prefix: "iris-test-migrator") { tempDir in
            let paths = IrisPaths(root: tempDir)
            try paths.ensureDirectories()

            // Create legacy holographic database
            let legacyQueue = try DatabaseQueue(path: paths.holographicDB.path)
            try legacyQueue.write { db in
                try db.execute(sql: """
                    CREATE TABLE facts (
                        id TEXT PRIMARY KEY,
                        content TEXT NOT NULL,
                        hrrVectorData BLOB NOT NULL,
                        trustScore DOUBLE NOT NULL DEFAULT 1.0,
                        timestamp DATETIME NOT NULL DEFAULT CURRENT_TIMESTAMP
                    );
                    INSERT INTO facts (id, content, hrrVectorData) VALUES ('legacy-1', 'Legacy Holographic Fact', X'0000');
                """)
            }

            // Initialize FactStoreManager pointing at test paths
            let mgr = try FactStoreManager(paths: paths)
            let facts = try mgr.search(query: "Legacy")
            XCTAssertEqual(facts.count, 1)
            XCTAssertEqual(facts.first?.content, "Legacy Holographic Fact")
        }
    }
}
