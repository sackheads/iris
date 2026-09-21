import Testing
import Foundation
@testable import iris

@MainActor
@Suite("Subagent write ledger")
struct SubagentWriteLedgerTests {
    @Test("records deduped writes for a subagent conversation and drains once")
    func recordsAndDrains() {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        app.recordSubagentWrite(conversationId: id, path: "a.swift")
        app.recordSubagentWrite(conversationId: id, path: "a.swift")   // dup
        app.recordSubagentWrite(conversationId: id, path: "b.swift")
        #expect(app.drainSubagentWrites(for: id) == ["a.swift", "b.swift"])
        #expect(app.drainSubagentWrites(for: id) == [])                 // cleared
    }

    @Test("ignores writes for a non-subagent conversation")
    func ignoresMainAgent() {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id)                               // isSubagent == false
        app.recordSubagentWrite(conversationId: id, path: "a.swift")
        #expect(app.drainSubagentWrites(for: id) == [])
    }

    @Test("finishSession clears the ledger entry")
    func finishClears() {
        let app = AppState(); let id = UUID()
        app.createNewConversation(id: id, isSubagent: true)
        app.recordSubagentWrite(conversationId: id, path: "a.swift")
        app.finishSession(id: id, status: "completed")
        #expect(app.drainSubagentWrites(for: id) == [])
    }
}
