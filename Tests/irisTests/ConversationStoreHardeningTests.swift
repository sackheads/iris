import Testing
import Foundation
import GRDB
@testable import iris

/// #189: integer columns read through GRDB's trapping subscript (`row["ordinal"]`,
/// `row["position"]`, etc.) crash the whole load on a non-NULL value SQLite cannot convert to
/// `Int`, and a failing repair write used to fail the whole `loadAll`. Each test pokes an
/// unconvertible value into a column via raw SQL — the way `ConversationStoreTests`'s corrupted-row
/// tests poke bad JSON into a payload — and asserts the documented ruling instead of a crash.
@Suite("Conversation store hardening (#189)")
struct ConversationStoreHardeningTests {
    private func sample(id: UUID = UUID(), title: String = "t") -> Conversation {
        var c = Conversation(id: id, title: title, workspacePath: "/tmp/w")
        c.messages = [ChatMessage(role: .user, content: "m0"), ChatMessage(role: .agent, content: "m1")]
        c.history = [Content(role: "user", parts: [Part(text: "h0")])]
        return c
    }

    private func created(_ c: Conversation) -> ConversationWrite {
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0)); s.add(.historyAppended(from: 0))
        return ConversationWrite(id: c.id, snapshot: c, changes: s)
    }

    // MARK: ordinal on messages/history

    @Test("an unreadable ordinal on a messages row quarantines that row (keyed by rowid, ordinal NULL) and renumbers the survivor")
    func unreadableMessageOrdinalIsQuarantined() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        c.messages = [
            ChatMessage(role: .user, content: "m0"),
            ChatMessage(role: .agent, content: "m1"),
            ChatMessage(role: .agent, content: "m2"),
        ]
        try store.apply([created(c)])
        let corrupted = c.messages[1].id.uuidString
        try store.rawWrite("UPDATE messages SET ordinal = 'not-an-int' WHERE conversationId = ? AND id = ?",
                           arguments: [c.id.uuidString, corrupted])

        let loaded = try store.loadAll()  // must not trap
        let back = try #require(loaded.conversations.first)
        #expect(back.messages.map(\.content) == ["m0", "m2"])
        #expect(loaded.skipped.contains { $0.table == "messages" && $0.reason == "unreadable ordinal" && $0.ordinal == nil })
        #expect(try store.counts(for: c.id).messages == 2)
        #expect(try store.quarantineCount(for: c.id) == 1)
        let rows = try store.quarantinedRows(for: c.id)
        #expect(rows.count == 1)
        #expect(rows.first?.table == "messages")
        #expect(rows.first?.ordinal == nil)
        #expect(rows.first?.reason == "unreadable ordinal")
        #expect(loaded.repairFailed.isEmpty)

        // A second load is clean: the bad row and its ordinal are gone, survivors renumbered.
        #expect(try store.loadAll().skipped.isEmpty)
    }

    @Test("an unreadable ordinal on a history row quarantines that row the same way")
    func unreadableHistoryOrdinalIsQuarantined() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        c.history = [
            Content(role: "user", parts: [Part(text: "h0")]),
            Content(role: "model", parts: [Part(text: "h1")]),
            Content(role: "user", parts: [Part(text: "h2")]),
        ]
        try store.apply([created(c)])
        try store.rawWrite("UPDATE history SET ordinal = 'not-an-int' WHERE conversationId = ? AND ordinal = 1",
                           arguments: [c.id.uuidString])

        let loaded = try store.loadAll()
        let back = try #require(loaded.conversations.first)
        #expect(back.history.map { $0.parts.first?.text } == ["h0", "h2"])
        #expect(loaded.skipped.contains { $0.table == "history" && $0.reason == "unreadable ordinal" && $0.ordinal == nil })
        #expect(try store.quarantineCount(for: c.id) == 1)
        let rows = try store.quarantinedRows(for: c.id)
        #expect(rows.first?.ordinal == nil)
        #expect(rows.first?.reason == "unreadable ordinal")
    }

    // MARK: position on conversations

    @Test("an unreadable position skips the conversation, same as an unreadable text metadata column")
    func unreadablePositionSkipsTheConversation() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a"), b = sample(title: "b")
        try store.apply([created(a), created(b)])
        try store.rawWrite("UPDATE conversations SET position = 'not-an-int' WHERE id = ?", arguments: [a.id.uuidString])

        let loaded = try store.loadAll()  // must not trap
        #expect(loaded.conversations.map(\.title) == ["b"])
        #expect(loaded.skipped.contains { $0.conversationId == a.id && $0.reason == "unreadable position" })
    }

    // MARK: messageCountSinceReflection / goalIterationCount

    @Test("an unreadable messageCountSinceReflection defaults to 0 rather than dropping the conversation")
    func unreadableMessageCountDefaultsToZero() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a")
        try store.apply([created(a)])
        try store.rawWrite("UPDATE conversations SET messageCountSinceReflection = 'not-an-int' WHERE id = ?", arguments: [a.id.uuidString])

        let loaded = try store.loadAll()  // must not trap
        let back = try #require(loaded.conversations.first)
        #expect(back.title == "a")
        #expect(back.messageCountSinceReflection == 0)
        #expect(back.messages.count == 2)
        #expect(loaded.skipped.isEmpty)
    }

    @Test("an unreadable goalIterationCount defaults to 0 rather than dropping the conversation")
    func unreadableGoalIterationCountDefaultsToZero() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a")
        try store.apply([created(a)])
        try store.rawWrite("UPDATE conversations SET goalIterationCount = 'not-an-int' WHERE id = ?", arguments: [a.id.uuidString])

        let loaded = try store.loadAll()  // must not trap
        let back = try #require(loaded.conversations.first)
        #expect(back.goalIterationCount == 0)
        #expect(loaded.skipped.isEmpty)
    }

    // MARK: a failing repair write does not fail the whole load

    @Test("a repair write that fails excludes only the damaged conversation and reports it in repairFailed")
    func failingRepairExcludesOnlyTheDamagedConversation() throws {
        let store = try ConversationStore.inMemory()
        let healthy = sample(title: "healthy")
        var damaged = sample(title: "damaged")
        damaged.messages = [ChatMessage(role: .user, content: "d0"), ChatMessage(role: .agent, content: "d1")]
        try store.apply([created(healthy), created(damaged)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ? AND ordinal = 0",
                           arguments: [damaged.id.uuidString])

        // Make the repair transaction fail deterministically. A real failure mode (a read-only
        // database, a full disk) can't be triggered on demand, so `failInjection` — the same seam
        // `apply(_:)`'s partial-failure handling is exercised through — stands in for one.
        let damagedId = damaged.id
        store.failInjection = { $0 == damagedId }

        let loaded = try store.loadAll()  // must not throw
        #expect(loaded.conversations.map(\.title) == ["healthy"])
        #expect(loaded.repairFailed == [damaged.id])

        // Nothing on disk was touched: the bad row is still there, untouched and unquarantined,
        // so the repair can be retried at the next launch.
        store.failInjection = nil
        #expect(try store.counts(for: damaged.id).messages == 2)
        #expect(try store.quarantineCount(for: damaged.id) == 0)
    }

    // MARK: lastGoalEvaluation / lastGoalCompletionReport (#191)

    @Test("an undecodable lastGoalEvaluation degrades to nil and keeps the conversation (#191)")
    func corruptLastGoalEvaluationDegradesToNil() throws {
        let store = try ConversationStore.inMemory()
        let c = ConversationStoreTests.sample()
        try store.apply([ConversationStoreTests.created(c)])
        try store.rawWrite("UPDATE conversations SET lastGoalEvaluation = '{not json', lastGoalCompletionReport = '[oops' WHERE id = ?",
                           arguments: [c.id.uuidString])
        let loaded = try store.loadAll()
        let back = try #require(loaded.conversations.first { $0.id == c.id })
        #expect(back.lastGoalEvaluation == nil && back.lastGoalCompletionReport == nil)
        #expect(back.messages.count == c.messages.count, "the conversation itself survives")
        #expect(loaded.skipped.contains { $0.conversationId == c.id && $0.reason.hasPrefix("unreadable lastGoalEvaluation") })
        #expect(loaded.skipped.contains { $0.conversationId == c.id && $0.reason.hasPrefix("unreadable lastGoalCompletionReport") })
    }
}
