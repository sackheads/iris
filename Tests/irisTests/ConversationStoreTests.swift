import Testing
import Foundation
import GRDB
@testable import iris

@Suite("Conversation store")
struct ConversationStoreTests {
    private func sample(id: UUID = UUID(), title: String = "t") -> Conversation {
        var c = Conversation(id: id, title: title, workspacePath: "/tmp/w")
        c.messages = [ChatMessage(role: .user, content: "hi", attachments: [
            FileAttachment(id: UUID(), filename: "a.txt", fileURL: URL(fileURLWithPath: "/tmp/a.txt"), mimeType: "text/plain", fileSize: 3, category: .text)
        ]), ChatMessage(role: .agent, content: "hello")]
        c.history = [Content(role: "user", parts: [Part(text: "hi")]), Content(role: "model", parts: [Part(text: "hello")])]
        c.tokenUsage = TokenUsage(promptTokenCount: 3, candidatesTokenCount: 4, totalTokenCount: 7)
        c.mainAgentSandbox = .sandboxed
        var contract = GoalContract(objective: "ship", criteria: [Criterion(text: "tests pass", kind: .executable, check: "swift test")])
        contract.lock()
        c.goalContract = contract
        c.activeGoal = "ship"
        c.goalIterationCount = 2
        c.messageCountSinceReflection = 5
        return c
    }
    private func created(_ c: Conversation) -> ConversationWrite {
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0)); s.add(.historyAppended(from: 0))
        return ConversationWrite(id: c.id, snapshot: c, changes: s)
    }
    private func write(_ c: Conversation, _ changes: ConversationChange...) -> ConversationWrite {
        var s = ChangeSet(); changes.forEach { s.add($0) }
        return ConversationWrite(id: c.id, snapshot: c, changes: s)
    }

    @Test("ChangeSet coalesces: smallest append ordinal wins, replaced absorbs appended, ids accumulate")
    func changeSetCoalescing() {
        var s = ChangeSet()
        #expect(s.isEmpty)
        s.add(.messagesAppended(from: 7)); s.add(.messagesAppended(from: 3)); s.add(.messageUpdated(id: UUID()))
        s.add(.historyAppended(from: 2)); s.add(.historyReplaced); s.add(.metadata)
        #expect(s.messagesFrom == 3)
        #expect(s.updatedMessageIds.count == 1)
        #expect(s.historyReplaced && s.historyFrom == nil)
        #expect(s.metadata)
        var other = ChangeSet(); other.add(.messagesAppended(from: 1)); other.add(.deleted)
        s.merge(other)
        #expect(s.messagesFrom == 1 && s.deleted)
        // A merged-in replace absorbs any pending append on either side.
        var replaced = ChangeSet(); replaced.add(.messagesReplaced)
        s.merge(replaced)
        #expect(s.messagesReplaced && s.messagesFrom == nil)
    }

    @Test("a conversation round-trips through the store with every stored field")
    func roundTrip() throws {
        let store = try ConversationStore.inMemory()
        let c = sample()
        try store.apply([created(c)])
        let loaded = try store.loadAll()
        #expect(loaded.skipped.isEmpty)
        let back = try #require(loaded.conversations.first)
        #expect(back.id == c.id && back.title == "t" && back.workspacePath == "/tmp/w")
        #expect(back.messages == c.messages)
        #expect(back.history.map(\.parts.first?.text) == ["hi", "hello"])
        #expect(back.tokenUsage == c.tokenUsage)
        #expect(back.mainAgentSandbox == .sandboxed)
        #expect(back.goalContract?.isLocked == true && back.goalContract?.criteria.count == 1)
        #expect(back.activeGoal == "ship" && back.goalIterationCount == 2 && back.messageCountSinceReflection == 5)
        #expect(back.isSubagent == false && back.lastGoalEvaluation == nil && back.lastGoalCompletionReport == nil)
    }

    @Test("appending writes only the new rows")
    func appendIsIncremental() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        try store.apply([created(c)])
        c.messages.append(ChatMessage(role: .agent, content: "third"))
        c.history.append(Content(role: "model", parts: [Part(text: "third")]))
        try store.apply([write(c, .messagesAppended(from: 2), .historyAppended(from: 2))])
        let counts = try store.counts(for: c.id)
        #expect(counts.messages == 3 && counts.history == 3)
        #expect(try store.loadAll().conversations.first?.messages.last?.content == "third")
        // Replaying the same batch changes nothing (idempotent by ordinal).
        try store.apply([write(c, .messagesAppended(from: 2), .historyAppended(from: 2))])
        #expect(try store.counts(for: c.id).messages == 3)
    }

    @Test("a message is updated in place by id; history can be replaced wholesale; messages can be cleared")
    func updateReplaceClear() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        try store.apply([created(c)])
        c.messages[1].content = "hello, edited"
        try store.apply([write(c, .messageUpdated(id: c.messages[1].id))])
        #expect(try store.loadAll().conversations.first?.messages[1].content == "hello, edited")
        c.history = [Content(role: "user", parts: [Part(text: "only")])]
        try store.apply([write(c, .historyReplaced)])
        #expect(try store.counts(for: c.id).history == 1)
        c.messages.removeAll()
        try store.apply([write(c, .messagesReplaced)])
        #expect(try store.counts(for: c.id).messages == 0)
        #expect(try store.loadAll().conversations.first?.history.first?.parts.first?.text == "only")
    }

    @Test("metadata-only writes update the row without touching message rows")
    func metadataOnly() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        try store.apply([created(c)])
        c.title = "renamed"; c.tokenUsage.totalTokenCount = 99
        c.messages.append(ChatMessage(role: .agent, content: "not written"))   // deliberately not marked
        try store.apply([write(c, .metadata)])
        let back = try store.loadAll().conversations.first
        #expect(back?.title == "renamed" && back?.tokenUsage.totalTokenCount == 99)
        #expect(back?.messages.count == 2)
    }

    @Test("delete cascades to message and history rows; created-then-deleted leaves nothing")
    func deleteCascades() throws {
        let store = try ConversationStore.inMemory()
        let c = sample()
        try store.apply([created(c)])
        try store.apply([ConversationWrite(id: c.id, snapshot: nil, changes: { var s = ChangeSet(); s.add(.deleted); return s }())])
        #expect(try store.counts(for: c.id) == (0, 0))
        #expect(try store.isEmpty())
        let d = sample()
        try store.apply([ConversationWrite(id: d.id, snapshot: d, changes: { var s = ChangeSet(); s.add(.created); s.add(.deleted); return s }())])
        #expect(try store.isEmpty())
    }

    @Test("positions preserve creation order across loads")
    func ordering() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a"), b = sample(title: "b"), c = sample(title: "c")
        try store.apply([created(a), created(b), created(c)])
        try store.apply([ConversationWrite(id: b.id, snapshot: nil, changes: { var s = ChangeSet(); s.add(.deleted); return s }())])
        let d = sample(title: "d")
        try store.apply([created(d)])
        #expect(try store.loadAll().conversations.map(\.title) == ["a", "c", "d"])
        let positions = try store.positions()
        #expect(Set([positions[a.id], positions[c.id], positions[d.id]].compactMap { $0 }).count == 3)
    }

    @Test("a corrupted message row is skipped and reported; the conversation and its neighbours still load")
    func corruptedMessageRowIsIsolated() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a"), b = sample(title: "b")
        try store.apply([created(a), created(b)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ? AND ordinal = 0", arguments: [a.id.uuidString])
        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["a", "b"])
        #expect(loaded.conversations[0].messages.count == 1)
        #expect(loaded.conversations[1].messages.count == 2)
        #expect(loaded.skipped == [SkippedRow(conversationId: a.id, table: "messages", ordinal: 0, reason: loaded.skipped.first?.reason ?? "")])
        #expect(loaded.skipped.first?.reason.isEmpty == false)
        // The row is left on disk, not deleted.
        #expect(try store.counts(for: a.id).messages == 2)
    }

    @Test("a non-UTF8 message payload is skipped and reported, not a fatal crash")
    func nonUTF8PayloadIsSkipped() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a")
        try store.apply([created(a)])
        try store.rawWrite("UPDATE messages SET payload = X'FFFE' WHERE conversationId = ? AND ordinal = 0", arguments: [a.id.uuidString])
        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["a"])
        #expect(loaded.conversations[0].messages.count == 1)
        #expect(loaded.skipped.count == 1 && loaded.skipped.first?.table == "messages" && loaded.skipped.first?.conversationId == a.id)
    }

    @Test("a non-UTF8 history payload is skipped and reported, not a fatal crash")
    func nonUTF8HistoryPayloadIsSkipped() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a")
        try store.apply([created(a)])
        try store.rawWrite("UPDATE history SET payload = X'FFFE' WHERE conversationId = ? AND ordinal = 0", arguments: [a.id.uuidString])
        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["a"])
        #expect(loaded.conversations[0].history.count == 1)
        #expect(loaded.skipped.count == 1 && loaded.skipped.first?.table == "history" && loaded.skipped.first?.conversationId == a.id)
    }

    @Test("appending a shorter snapshot truncates the stale trailing rows")
    func shorterSnapshotTruncatesStaleRows() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        try store.apply([created(c)])
        c.messages.append(ChatMessage(role: .agent, content: "third"))
        c.history.append(Content(role: "model", parts: [Part(text: "third")]))
        try store.apply([write(c, .messagesAppended(from: 2), .historyAppended(from: 2))])
        #expect(try store.counts(for: c.id) == (3, 3))
        c.messages = Array(c.messages.prefix(1))
        c.history = Array(c.history.prefix(1))
        try store.apply([write(c, .messagesAppended(from: 0), .historyAppended(from: 0))])
        #expect(try store.counts(for: c.id) == (1, 1))
        #expect(try store.loadAll().conversations.first?.messages.count == 1)
    }

    @Test("one conversation's write failing does not block the rest of the batch, and is reported")
    func partialFailureIsolatesOneConversation() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a"), b = sample(title: "b")
        store.failInjection = { $0 == b.id }
        #expect(throws: ConversationStoreError.partialFailure(failedIds: [b.id])) {
            try store.apply([created(a), created(b)])
        }
        #expect(try store.loadAll().conversations.map(\.title) == ["a"])
        #expect(try store.isEmpty() == false)
        // Clearing the injection and replaying b alone succeeds.
        store.failInjection = nil
        try store.apply([created(b)])
        #expect(try store.loadAll().conversations.map(\.title).sorted() == ["a", "b"])
    }

    @Test("a cancelled write applies nothing")
    func cancelledWriteAppliesNothing() throws {
        let store = try ConversationStore.inMemory()
        let c = sample()
        try store.apply([created(c)], unlessCancelled: { true })
        #expect(try store.isEmpty())
        // The same batch with the stand-down cleared writes normally.
        try store.apply([created(c)])
        #expect(try store.isEmpty() == false)
    }

    @Test("a corrupted metadata row skips only that conversation")
    func corruptedMetadataIsIsolated() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a"), b = sample(title: "b")
        try store.apply([created(a), created(b)])
        try store.rawWrite("UPDATE conversations SET goalContract = 'nope' WHERE id = ?", arguments: [a.id.uuidString])
        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["b"])
        #expect(loaded.skipped.count == 1 && loaded.skipped.first?.table == "conversations" && loaded.skipped.first?.conversationId == a.id)
    }

    @Test("a write for an id the store has never seen upserts the row even without a created flag")
    func upsertWithoutCreated() throws {
        let store = try ConversationStore.inMemory()
        let c = sample()
        try store.apply([write(c, .metadata, .messagesAppended(from: 0), .historyAppended(from: 0))])
        #expect(try store.loadAll().conversations.count == 1)
        #expect(try store.counts(for: c.id) == (2, 2))
    }

    @Test("the on-disk store lives at IrisPaths.conversationsDB and persists across opens")
    func onDiskRoundTrip() throws {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-store-\(UUID().uuidString)")
        defer { try? FileManager.default.removeItem(at: root) }
        let paths = IrisPaths(root: root)
        #expect(paths.conversationsDB.lastPathComponent == "conversations.sqlite")
        try paths.ensureDirectories()
        let c = sample()
        do { let s = try ConversationStore.onDisk(at: paths.conversationsDB); try s.apply([created(c)]) }
        let again = try ConversationStore.onDisk(at: paths.conversationsDB)
        #expect(try again.loadAll().conversations.first?.id == c.id)
    }
}
