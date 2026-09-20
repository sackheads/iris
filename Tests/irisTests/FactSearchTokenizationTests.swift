import Testing
import Foundation
@testable import iris

/// #201: `FactStoreManager.search` matched with `FTS3Pattern` against an FTS5 table
/// (`facts_fts`). FTS3Pattern's tokenizer folds ASCII case only and keeps diacritics, so it is the
/// wrong pattern type for an FTS5 MATCH — `ConversationStore.searchConversations` already uses
/// `FTS5Pattern(matchingAnyTokenIn:)` for the same reason (see its comment).
@Suite("Fact search tokenization (#201)")
struct FactSearchTokenizationTests {
    @Test("a case-different query still finds the fact")
    func caseFoldsBothWays() throws {
        let store = try FactStoreManager(inMemory: true)
        try store.addFact(content: "We named the deploy script Cafe Rouge")
        #expect(try store.search(query: "CAFE ROUGE", limit: 5).count == 1)
        #expect(try store.search(query: "cafe rouge", limit: 5).count == 1)
    }

    @Test("a diacritic-bearing query finds a plain-ASCII fact, and vice versa")
    func diacriticsFoldBothWays() throws {
        let store = try FactStoreManager(inMemory: true)
        try store.addFact(content: "We met at the Café Rouge to plan the launch")
        #expect(try store.search(query: "cafe", limit: 5).count == 1)
        #expect(try store.search(query: "Café", limit: 5).count == 1)
    }
}
