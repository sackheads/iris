import Testing
import Foundation
@testable import iris

@MainActor
@Suite("Conversation store selection and load (#163)")
struct ConversationStoreSelectionTests {
    @Test("the test process gets an in-memory store and never a file under the real paths")
    func testProcessIsIsolated() {
        let before = FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path)
        let a = AppState()
        a.createNewConversation(id: UUID())
        a.flushSave()
        // Assert the rule itself, not only its absence of side effects: "no file appeared" is also
        // true of an on-disk store that happened to fail to open.
        #expect(a.store.isOnDisk == false)
        #expect(a.store.path == nil)
        #expect(FileManager.default.fileExists(atPath: IrisPaths.standard.conversationsDB.path) == before)
    }

    @Test("the isolation rule: a store goes on disk only in a plain app process")
    func isolationTruthTable() {
        #expect(ConversationStore.shouldIsolate(xctestLinked: false, headless: false, volatileDefaults: false) == false)
        #expect(ConversationStore.shouldIsolate(xctestLinked: true, headless: false, volatileDefaults: false))
        #expect(ConversationStore.shouldIsolate(xctestLinked: false, headless: true, volatileDefaults: false))
        // The fake-lane perf run: volatile defaults but the real IrisPaths.
        #expect(ConversationStore.shouldIsolate(xctestLinked: false, headless: false, volatileDefaults: true))
        #expect(ConversationStore.shouldIsolate(xctestLinked: true, headless: true, volatileDefaults: true))
    }

    @Test("a fresh AppState loads what its store holds, in order, and applies the load-time repairs")
    func loadsFromStore() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "kept")
        c.lastGoalCompletionReport = .string("transient")
        var s = ChangeSet(); s.add(.created)
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        let a = AppState(store: store)
        #expect(a.conversations.map(\.title) == ["kept"])
        #expect(a.conversations.first?.lastGoalCompletionReport == nil)
        #expect(a.selectedConversationId == c.id)
    }

    @Test("the legacy blob in the defaults store is imported on first load and the key moved")
    func migratesBlob() throws {
        let store = try ConversationStore.inMemory()
        let legacy = [Conversation(id: UUID(), title: "from blob")]
        IrisDefaults.store.set(try JSONEncoder().encode(legacy), forKey: LegacyConversationBlob.key)
        defer { IrisDefaults.store.removeObject(forKey: LegacyConversationBlob.legacyKey) }
        let a = AppState(store: store)
        #expect(a.conversations.map(\.title) == ["from blob"])
        #expect(IrisDefaults.store.data(forKey: LegacyConversationBlob.key) == nil)
        #expect(IrisDefaults.store.data(forKey: LegacyConversationBlob.legacyKey) != nil)
    }

    @Test("skipped rows are surfaced as a system line, written once")
    func skippedRowsSurface() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "damaged")
        c.messages = [ChatMessage(role: .user, content: "ok"), ChatMessage(role: .agent, content: "also ok")]
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0))
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        try store.rawWrite("UPDATE messages SET payload = 'x' WHERE conversationId = ? AND ordinal = 0", arguments: [c.id.uuidString])

        let a = AppState(store: store)
        #expect(a.loadedSkippedRows.count == 1)
        #expect(a.conversations.first?.messages.contains { $0.role == .system && $0.content.contains("quarantine table") } == true)
        a.flushSave()

        // The corrupted row was quarantined by the first `loadAll`, so a second AppState against
        // the same store finds nothing left to skip: the one persisted notice is all there is.
        let b = AppState(store: store)
        #expect(b.loadedSkippedRows.isEmpty)
        let notices = b.conversations.first?.messages.filter { $0.role == .system && $0.content.contains("quarantine table") } ?? []
        #expect(notices.count == 1)
    }

    /// An unreadable conversation row is left exactly where it is, so — unlike a quarantined
    /// payload row — it is reported again on every launch. The notice is persisted like any other
    /// system message (everything in `messages` must have a row) and de-duplicated by its text, so
    /// it does not stack up.
    @Test("a recurring unreadable-conversation notice is written once, not once per launch")
    func metadataNoticeIsDeduplicated() throws {
        let store = try ConversationStore.inMemory()
        let c = Conversation(id: UUID(), title: "unreadable")
        var s = ChangeSet(); s.add(.created)
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        try store.rawWrite("UPDATE conversations SET title = X'FFFE' WHERE id = ?", arguments: [c.id.uuidString])

        func notices(_ app: AppState) -> [String] {
            app.conversations.flatMap { $0.messages }
                .filter { $0.role == .system && $0.content.contains("could not be read and") }
                .map(\.content)
        }

        // Pin `.provisioned` (#202 fix round 1) so this test's outcome does not depend on whether
        // this machine happens to have the real tier-3 gguf under `~/.iris/models` — without it, a
        // real `AppState` also emits the #202 tier-3-unprovisioned notice by default, which is
        // legitimate but unrelated to what this test verifies.
        let a = AppState(store: store, tier3Provisioning: .provisioned)
        #expect(a.loadedSkippedRows.count == 1)
        #expect(notices(a) == ["1 saved conversation could not be read and was left in place; see the console for details."])
        a.flushSave()

        // Launch 2 hits the same condition and finds its own wording already there.
        let b = AppState(store: store, tier3Provisioning: .provisioned)
        #expect(b.loadedSkippedRows.count == 1)
        #expect(notices(b).count == 1)
        b.flushSave()

        let loaded = try store.loadAll()
        // Filtered to this notice's own wording, not all system messages: a real `AppState` also
        // emits other launch notices independent of this scenario.
        #expect(loaded.conversations.flatMap { $0.messages }.filter { $0.role == .system && $0.content.contains("could not be read and") }.count == 1)
        for conv in loaded.conversations {
            #expect(try store.counts(for: conv.id).messages == conv.messages.count)
        }
    }

    /// #202 fix round 1: the tier-3-unprovisioned launch notice was wired with no seam and no
    /// coverage, so it behaved differently on a machine with the real gguf under `~/.iris/models`
    /// versus one without — and nothing pinned either behaviour. `tier3Provisioning:` lets these
    /// two tests assert both outcomes without touching the real models directory.
    @Test("the tier-3-unprovisioned notice is appended when the model is unprovisioned")
    func tier3UnprovisionedNoticeAppended() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier3Provisioning: .unprovisioned(modelName: "some-model.gguf"))
        let notices = app.conversations.flatMap { $0.messages }
            .filter { $0.role == .system && $0.content.contains("tier-3 guard model") }
            .map(\.content)
        #expect(notices == ["Prompt-injection protection is on, but the tier-3 guard model some-model.gguf is not downloaded. Tier 3 is skipped until it is (Settings \u{2192} Security)."])
    }

    @Test("no tier-3-unprovisioned notice is appended when the model is provisioned")
    func tier3UnprovisionedNoticeAbsentWhenProvisioned() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, tier3Provisioning: .provisioned)
        let notices = app.conversations.flatMap { $0.messages }
            .filter { $0.role == .system && $0.content.contains("tier-3 guard model") }
        #expect(notices.isEmpty)
    }

    /// The bug this pins: a launch notice that lived in `messages` without a row on disk shifted
    /// every ordinal after it. On the next launch the notice was absent, the indices shifted back,
    /// and the first append `INSERT OR REPLACE`d the previous session's last message.
    @Test("messages appended after a launch notice survive a relaunch")
    func appendsAfterANoticeSurviveARelaunch() throws {
        let store = try ConversationStore.inMemory()
        var c = Conversation(id: UUID(), title: "damaged")
        c.messages = [ChatMessage(role: .user, content: "kept"), ChatMessage(role: .agent, content: "also kept")]
        var s = ChangeSet(); s.add(.created); s.add(.messagesAppended(from: 0))
        try store.apply([ConversationWrite(id: c.id, snapshot: c, changes: s)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ? AND ordinal = 0", arguments: [c.id.uuidString])

        let a = AppState(store: store)
        #expect(a.conversations.first?.messages.contains { $0.content.contains("quarantine table") } == true)
        a.appendMessage(role: .user, content: "u1", to: c.id)
        a.flushSave()
        #expect(try store.counts(for: c.id).messages == a.conversations.first?.messages.count)

        let b = AppState(store: store)
        b.appendMessage(role: .user, content: "u2", to: c.id)
        b.flushSave()

        let live = try #require(b.conversations.first { $0.id == c.id })
        let reloaded = try #require(try store.loadAll().conversations.first { $0.id == c.id })
        #expect(reloaded.messages.map(\.content) == live.messages.map(\.content))
        #expect(try store.counts(for: c.id).messages == live.messages.count)
        let contents = reloaded.messages.map(\.content)
        let u1 = try #require(contents.firstIndex(of: "u1"))
        let u2 = try #require(contents.firstIndex(of: "u2"))
        #expect(u1 < u2)
        #expect(contents.filter { $0.contains("quarantine table") }.count == 1)
    }

    /// #189: a repair write that fails must not fail the whole load — the healthy conversation
    /// still loads, and the damaged one is reported by name rather than silently dropped.
    @Test("a failed repair excludes only the damaged conversation and is surfaced as a system line")
    func failedRepairSurfacesAsANotice() throws {
        let store = try ConversationStore.inMemory()
        let healthy = Conversation(id: UUID(), title: "healthy")
        var hs = ChangeSet(); hs.add(.created)
        var damaged = Conversation(id: UUID(), title: "damaged")
        damaged.messages = [ChatMessage(role: .user, content: "d0"), ChatMessage(role: .agent, content: "d1")]
        var ds = ChangeSet(); ds.add(.created); ds.add(.messagesAppended(from: 0))
        try store.apply([ConversationWrite(id: healthy.id, snapshot: healthy, changes: hs),
                         ConversationWrite(id: damaged.id, snapshot: damaged, changes: ds)])
        try store.rawWrite("UPDATE messages SET payload = '{not json' WHERE conversationId = ? AND ordinal = 0",
                           arguments: [damaged.id.uuidString])
        let damagedId = damaged.id
        store.failInjection = { $0 == damagedId }

        let a = AppState(store: store)
        #expect(a.conversations.map(\.title) == ["healthy"])
        #expect(a.loadedRepairFailed == [damagedId])
        // Exactly one notice: the repair-failed conversation's id is absent from `loadedIds`
        // (same shape as a "left in place" skip), so without excluding it explicitly its skipped
        // rows would also raise the "could not be read and was left in place" notice — untrue,
        // since it was read fine and only the repair failed (round 1 review finding).
        let systemNotices = a.conversations.first?.messages.filter { $0.role == .system } ?? []
        #expect(systemNotices.count == 1)
        #expect(systemNotices.first?.content.contains("could not be written") == true)
        #expect(systemNotices.first?.content.contains("retried at the next launch") == true)
        #expect(systemNotices.allSatisfy { !$0.content.contains("could not be read and") })

        // Left entirely untouched on disk: the bad row is still there, nothing quarantined.
        store.failInjection = nil
        #expect(try store.counts(for: damagedId).messages == 2)
        #expect(try store.quarantineCount(for: damagedId) == 0)
    }
}
