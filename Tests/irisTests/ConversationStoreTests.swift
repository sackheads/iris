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
        c.checkpointHistory = [
            CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "Parser",
                              evaluation: GoalEvaluation(
                                  status: .graded,
                                  criteria: [CriterionVerdict(criterionId: UUID(), criterionText: "tests pass",
                                                              kind: .executable, verdict: .met,
                                                              evidence: "swift test exited 0", method: .check)],
                                  startedAt: Date(timeIntervalSince1970: 1_700_000_000)),
                              resolution: .autoAdvanced)
        ]
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
        // Slice D3's audit trail. It had no column at all until v3, so it was silently dropped on
        // every relaunch while the JSON-codec tests passed; this is the test that catches that.
        #expect(back.checkpointHistory.count == 1)
        #expect(back.checkpointHistory.first?.resolution == .autoAdvanced)
        #expect(back.checkpointHistory.first?.milestoneTitle == "Parser")
        #expect(back.checkpointHistory.first?.milestoneIndex == 0)
        #expect(back.checkpointHistory.first?.evaluation?.criteria.first?.verdict == .met)
        #expect(back.checkpointHistory.first?.evaluation?.criteria.first?.evidence == "swift test exited 0")
    }

    @Test("checkpointHistory survives a metadata-only update, and an empty one loads as []")
    func checkpointHistoryPersistsAcrossMetadataWrites() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        c.checkpointHistory = []
        try store.apply([created(c)])
        // NULL column, not a missing key: it must read back as empty rather than failing the load.
        #expect(try store.loadAll().conversations.first?.checkpointHistory.isEmpty == true)

        c.checkpointHistory = [
            CheckpointOutcome(milestoneIndex: 1, milestoneTitle: "Integration", resolution: .humanSentBack)
        ]
        try store.apply([write(c, .metadata)])
        let back = try #require(try store.loadAll().conversations.first)
        #expect(back.checkpointHistory.count == 1)
        #expect(back.checkpointHistory.first?.resolution == .humanSentBack)
        // Nil evaluation is a real state (nothing was graded), not an encoding accident.
        #expect(back.checkpointHistory.first?.evaluation == nil)
    }

    @Test("a v2-era database gains the checkpointHistory column and its rows load with []")
    func v2DatabaseMigratesToV3() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("iris-convstore-v2-\(UUID().uuidString)")
        let url = root.appendingPathComponent("conversations.sqlite")
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let id = UUID()
        do {
            let queue = try DatabaseQueue(path: url.path)
            try ConversationStore.migrator.migrate(queue, upTo: "v2_conversation_search")
            try queue.write { db in
                try db.execute(sql: """
                    INSERT INTO conversations (id, position, title, createdAt, updatedAt, tokenUsage)
                    VALUES (?, 1, 'old chat', datetime('now'), datetime('now'), ?)
                    """, arguments: [id.uuidString, String(decoding: try JSONEncoder().encode(TokenUsage()), as: UTF8.self)])
            }
            try queue.close()
        }

        let store = try ConversationStore.onDisk(at: url)
        var back = try #require(try store.loadAll().conversations.first)
        #expect(back.checkpointHistory.isEmpty)

        // And the upgraded row can then be written to and read back.
        back.checkpointHistory = [CheckpointOutcome(milestoneIndex: 0, milestoneTitle: "Parser",
                                                    resolution: .humanApproved)]
        try store.apply([write(back, .metadata)])
        #expect(try store.loadAll().conversations.first?.checkpointHistory.first?.resolution == .humanApproved)
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
        // The bad row is quarantined and the survivor renumbered, not left in place on disk.
        #expect(try store.counts(for: a.id).messages == 1)
        #expect(try store.quarantineCount(for: a.id) == 1)
    }

    @Test("a corrupted middle message row is quarantined and the survivors renumbered contiguous, so a later append neither clobbers nor loses a row")
    func middleMessageQuarantinedAndRenumbered() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        c.messages = [
            ChatMessage(role: .user, content: "m0"),
            ChatMessage(role: .agent, content: "m1"),
            ChatMessage(role: .agent, content: "m2"),
        ]
        try store.apply([created(c)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ? AND ordinal = 1", arguments: [c.id.uuidString])

        let loaded = try store.loadAll()
        let back = try #require(loaded.conversations.first)
        #expect(back.messages.map(\.content) == ["m0", "m2"])
        #expect(loaded.skipped.count == 1)
        #expect(try store.counts(for: c.id).messages == 2)
        #expect(try store.quarantineCount(for: c.id) == 1)

        // Idempotent: the bad row is gone, so a second load (no writes in between) reports nothing.
        #expect(try store.loadAll().skipped.isEmpty)

        // Append using the in-memory (already-compacted) index, exactly as AppState would after
        // a load with a skip. Before the fix this ordinal (2) collided with the still-occupied
        // original "m2" row on disk and its trailing DELETE dropped a good row.
        var next = back
        next.messages.append(ChatMessage(role: .agent, content: "new"))
        try store.apply([write(next, .messagesAppended(from: 2))])

        let reloaded = try store.loadAll()
        #expect(reloaded.conversations.first?.messages.map(\.content) == ["m0", "m2", "new"])
        #expect(reloaded.skipped.isEmpty)
    }

    @Test("a corrupted middle history row is quarantined and the survivors renumbered contiguous, so a later append neither clobbers nor loses a row")
    func middleHistoryQuarantinedAndRenumbered() throws {
        let store = try ConversationStore.inMemory()
        var c = sample()
        c.history = [
            Content(role: "user", parts: [Part(text: "h0")]),
            Content(role: "model", parts: [Part(text: "h1")]),
            Content(role: "user", parts: [Part(text: "h2")]),
        ]
        try store.apply([created(c)])
        try store.rawWrite("UPDATE history SET payload = '{not json' WHERE conversationId = ? AND ordinal = 1", arguments: [c.id.uuidString])

        let loaded = try store.loadAll()
        let back = try #require(loaded.conversations.first)
        #expect(back.history.map { $0.parts.first?.text } == ["h0", "h2"])
        #expect(loaded.skipped.count == 1)
        #expect(try store.counts(for: c.id).history == 2)
        #expect(try store.quarantineCount(for: c.id) == 1)

        #expect(try store.loadAll().skipped.isEmpty)

        var next = back
        next.history.append(Content(role: "model", parts: [Part(text: "new")]))
        try store.apply([write(next, .historyAppended(from: 2))])

        let reloaded = try store.loadAll()
        #expect(reloaded.conversations.first?.history.map { $0.parts.first?.text } == ["h0", "h2", "new"])
        #expect(reloaded.skipped.isEmpty)
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

    @Test("the stand-down flag is one-way and visible across threads")
    func writeStandDownSignals() async throws {
        let flag = WriteStandDown()
        #expect(flag.isSignalled == false)
        await Task.detached { flag.signal() }.value
        #expect(flag.isSignalled)
        flag.signal()
        #expect(flag.isSignalled)
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

    /// One bad row among good ones is rot: quarantine it and keep the rest. An entire table
    /// failing to decode is a bug (a schema or decoder regression), and emptying it into
    /// `quarantine` would turn something a fix could recover into real data loss — so the rows
    /// stay exactly where they are and the conversation is left out of this load.
    @Test("a conversation whose every message row is unreadable is reported once and left untouched on disk")
    func allRowsUnreadableIsNotQuarantined() throws {
        let store = try ConversationStore.inMemory()
        var c = sample(title: "all bad")
        c.messages = [
            ChatMessage(role: .user, content: "m0"),
            ChatMessage(role: .agent, content: "m1"),
            ChatMessage(role: .agent, content: "m2"),
        ]
        let other = sample(title: "fine")
        try store.apply([created(c), created(other)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ?", arguments: [c.id.uuidString])

        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["fine"])
        #expect(loaded.skipped == [SkippedRow(conversationId: c.id, table: "messages", ordinal: nil,
                                              reason: "all 3 rows unreadable; left in place")])
        // Nothing moved: the rows are still there, and its history was not renumbered either.
        #expect(try store.counts(for: c.id) == (3, 2))
        #expect(try store.quarantineCount(for: c.id) == 0)
        // And it repeats on the next load, because nothing was repaired.
        #expect(try store.loadAll().skipped.count == 1)
    }

    @Test("a bulk-broken table does not hide the other table's individual bad rows")
    func bulkBreakerStillReportsTheOtherTable() throws {
        let store = try ConversationStore.inMemory()
        var c = sample(title: "half bad")
        c.history = [
            Content(role: "user", parts: [Part(text: "h0")]),
            Content(role: "model", parts: [Part(text: "h1")]),
        ]
        try store.apply([created(c)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ?", arguments: [c.id.uuidString])
        try store.rawWrite("UPDATE history SET payload = '{not json' WHERE conversationId = ? AND ordinal = 1", arguments: [c.id.uuidString])

        let loaded = try store.loadAll()
        #expect(loaded.conversations.isEmpty)
        #expect(loaded.skipped.count == 2)
        #expect(loaded.skipped.contains { $0.table == "messages" && $0.ordinal == nil })
        #expect(loaded.skipped.contains { $0.table == "history" && $0.ordinal == 1 })
        // Still nothing repaired: the conversation is excluded, so nothing may be rewritten.
        #expect(try store.counts(for: c.id) == (2, 2))
        #expect(try store.quarantineCount(for: c.id) == 0)
    }

    @Test("a non-UTF8 metadata column skips the whole conversation rather than loading it half-read")
    func nonUTF8MetadataSkipsTheConversation() throws {
        for column in ["title", "goalContract", "subagentResult", "tokenUsage", "workspacePath", "activeGoal", "mainAgentSandbox"] {
            let store = try ConversationStore.inMemory()
            let a = sample(title: "a"), b = sample(title: "b")
            try store.apply([created(a), created(b)])
            try store.rawWrite("UPDATE conversations SET \(column) = X'FFFE' WHERE id = ?", arguments: [a.id.uuidString])
            let loaded = try store.loadAll()
            #expect(loaded.conversations.map(\.title) == ["b"], "\(column)")
            #expect(loaded.skipped == [SkippedRow(conversationId: a.id, table: "conversations", ordinal: nil,
                                                  reason: "unreadable \(column)")], "\(column)")
        }
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

    @Test("a corrupt checkpointHistory column degrades to [] and is reported, but the conversation still loads")
    func corruptedCheckpointHistoryIsNonFatal() throws {
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a")
        try store.apply([created(a)])
        try store.rawWrite("UPDATE conversations SET checkpointHistory = '{{{not json' WHERE id = ?", arguments: [a.id.uuidString])
        let loaded = try store.loadAll()
        #expect(loaded.conversations.map(\.title) == ["a"])
        #expect(loaded.conversations.first?.messages.count == a.messages.count)
        #expect(loaded.conversations.first?.checkpointHistory.isEmpty == true)
        #expect(loaded.skipped.count == 1 && loaded.skipped.first?.table == "conversations" && loaded.skipped.first?.conversationId == a.id)
    }

    @Test("a conversations row whose tokenUsage JSON lacks a key loads with that field defaulted, not skipped")
    func tokenUsageMissingKeyStillLoads() throws {
        // #204: TokenUsage had no hand-written init(from:), so a stored row missing any of its
        // three keys threw keyNotFound at decode time -- caught at the row level and skipping the
        // whole conversation. Invariant 1 requires every field default instead.
        let store = try ConversationStore.inMemory()
        let a = sample(title: "a")
        try store.apply([created(a)])
        try store.rawWrite("UPDATE conversations SET tokenUsage = '{\"promptTokenCount\":3}' WHERE id = ?", arguments: [a.id.uuidString])
        let loaded = try store.loadAll()
        #expect(loaded.skipped.isEmpty)
        #expect(loaded.conversations.map(\.title) == ["a"])
        #expect(loaded.conversations.first?.tokenUsage == TokenUsage(promptTokenCount: 3, candidatesTokenCount: 0, totalTokenCount: 0))
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
