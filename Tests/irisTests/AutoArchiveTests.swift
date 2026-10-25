import Testing
import Foundation
@testable import IrisKit

/// #231: a session nobody has touched for the TTL is archived on its own, so the peer set stays
/// bounded without depending on anyone archiving by hand. Brian's ruling: sessions only, on, 14
/// days. Every test sweeps with an explicit `days` and `now`, so none reads the shared setting.
@MainActor
@Suite("Auto-archive idle sessions")
struct AutoArchiveTests {
    static let days = 14
    let now = Date()
    var stale: Date { now.addingTimeInterval(-15 * 86_400) }

    /// An app with Iris and one open conversation the person is looking at, plus `id`: a session
    /// (it has a card) last touched 15 days ago.
    private func appWithIdleSession(_ id: UUID) -> AppState {
        let app = AppState(); app.conversations.removeAll()
        _ = app.activityConversationId()
        app.createNewConversation(id: UUID(), title: "open")
        app.createNewConversation(id: id, title: "idle-session", select: false)
        app.setSessionCard(for: id, SessionCard(name: "builder", description: "builds things", lane: nil, skills: []))
        setTouched(app, id, stale)
        return app
    }

    private func setTouched(_ app: AppState, _ id: UUID, _ date: Date?) {
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
        app.conversations[idx].lastTouchedAt = date
    }

    private func conv(_ app: AppState, _ id: UUID) -> Conversation? { app.conversations.first { $0.id == id } }

    private func irisLines(_ app: AppState) -> [String] {
        let iris = app.activityConversationId()
        return conv(app, iris)?.messages.filter { $0.role == .system }.map(\.content) ?? []
    }

    // MARK: What is archived

    @Test("an idle session is archived, marked, and named in one Iris line")
    func idleSessionArchived() {
        let id = UUID()
        let app = appWithIdleSession(id)
        let archived = app.sweepIdleSessions(days: Self.days, now: now)
        #expect(archived == [id])
        #expect(conv(app, id)?.isArchived == true)
        #expect(conv(app, id)?.archivedAutomaticallyAt == now)
        let lines = irisLines(app).filter { $0.hasPrefix("Archived 1 idle session") }
        #expect(lines.count == 1)
        #expect(lines.first?.contains("\"builder\"") == true)
        #expect(conv(app, id)?.autoArchiveNote?.contains("Untouched for 15 days") == true)
    }

    @Test("a session touched inside the TTL is kept")
    func recentKept() {
        let id = UUID()
        let app = appWithIdleSession(id)
        setTouched(app, id, now.addingTimeInterval(-13 * 86_400))
        #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty)
        #expect(conv(app, id)?.isArchived == false)
    }

    @Test("a sweep that archives nothing posts nothing")
    func nothingArchivedNoNotice() {
        let id = UUID()
        let app = appWithIdleSession(id)
        setTouched(app, id, now)
        let before = irisLines(app).count
        _ = app.sweepIdleSessions(days: Self.days, now: now)
        #expect(irisLines(app).count == before)
    }

    @Test("Never (0 days) archives nothing")
    func neverArchives() {
        let id = UUID()
        let app = appWithIdleSession(id)
        #expect(app.sweepIdleSessions(days: 0, now: now).isEmpty)
        #expect(conv(app, id)?.isArchived == false)
    }

    @Test("a plain chat, with no card, role or peer message, is never archived")
    func plainChatKept() {
        let app = AppState(); app.conversations.removeAll()
        _ = app.activityConversationId()
        app.createNewConversation(id: UUID(), title: "open")
        let chat = UUID()
        app.createNewConversation(id: chat, title: "old chat", select: false)
        setTouched(app, chat, stale)
        #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty)
        #expect(conv(app, chat)?.isArchived == false)
    }

    @Test("a chat that sent a peer message is a session, and stays one once the ledger is pruned")
    func peerMessageMakesASession() throws {
        let app = AppState(); app.conversations.removeAll()
        _ = app.activityConversationId()
        app.createNewConversation(id: UUID(), title: "open")
        let chat = UUID(), peer = UUID()
        app.createNewConversation(id: chat, title: "talker", select: false)
        app.createNewConversation(id: peer, title: "listener", select: false)
        try app.store.peers.insert(PeerMessageRecord(msgId: "aaaa0231", fromSession: chat, toSession: peer,
                                                     contextId: "ctx", inReplyTo: nil, depth: 1, firstLine: "hi",
                                                     sentAt: stale, expectsReply: false, closedAt: nil, closeReason: nil))
        setTouched(app, chat, now)
        setTouched(app, peer, now)
        _ = app.sweepIdleSessions(days: Self.days, now: now)
        #expect(conv(app, chat)?.inSessions == true)
        #expect(conv(app, peer)?.inSessions == true)

        try app.store.peers.prune(before: now)
        setTouched(app, chat, stale)
        #expect(app.sweepIdleSessions(days: Self.days, now: now).contains(chat))
    }

    @Test("the ledger isn't needed: a send marks both ends at once")
    func markInSessionsBothEnds() {
        let app = AppState(); app.conversations.removeAll()
        let a = UUID(), b = UUID()
        app.createNewConversation(id: a)
        app.createNewConversation(id: b)
        app.markInSessions([a, b])
        #expect(conv(app, a)?.inSessions == true)
        #expect(conv(app, b)?.inSessions == true)
    }

    // MARK: What is never archived

    @Test("a session with a goal paused at a checkpoint is kept")
    func pausedGoalKept() {
        let id = UUID()
        let app = appWithIdleSession(id)
        let h = Criterion(text: "reads well", kind: .humanJudged, check: nil)
        let b = Criterion(text: "wired up", kind: .qualitative, check: nil)
        var c = GoalContract(objective: "Ship it", criteria: [h, b])
        c.milestones = [Milestone(title: "One", criterionIds: [h.id]), Milestone(title: "Two", criterionIds: [b.id])]
        app.setGoalContract(for: id, c)
        app.setCheckpointPaused(for: id)
        setTouched(app, id, stale)
        #expect(conv(app, id)?.goalContract?.checkpointStatus == .pausedForReview)
        #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty)
        #expect(conv(app, id)?.isArchived == false)
    }

    @Test("a role holder is kept")
    func roleKept() {
        let id = UUID()
        let app = appWithIdleSession(id)
        guard case .assigned = app.assignRole("planner", to: id) else { Issue.record("role refused"); return }
        setTouched(app, id, stale)
        #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty)
    }

    @Test("a session with a loop is kept, even paused")
    func loopKept() {
        let id = UUID()
        let app = appWithIdleSession(id)
        if let idx = app.conversations.firstIndex(where: { $0.id == id }) {
            app.conversations[idx].loop = ConversationLoop(prompt: "check CI", intervalSeconds: 600, cap: 10, paused: true)
        }
        #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty)
    }

    @Test("a session an enabled job delivers to, or was made in, is kept; a disabled job's isn't")
    func jobKept() throws {
        for field in ["destination", "createdIn"] {
            let id = UUID()
            let app = appWithIdleSession(id)
            var job = Job(name: "sweep-\(field)", prompt: "Do it.", trigger: .schedule(.interval(seconds: 60)), profile: .readOnly)
            if field == "destination" { job.destinationConversationId = id } else { job.createdInConversationId = id }
            try app.store.ledger.upsert(job)
            #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty, "\(field)")
            job.enabled = false
            try app.store.ledger.upsert(job)
            #expect(app.sweepIdleSessions(days: Self.days, now: now) == [id], "\(field), disabled")
        }
    }

    @Test("a request either way still awaiting its reply keeps both ends")
    func openExchangeKept() throws {
        for sent in [true, false] {
            let id = UUID(), peer = UUID()
            let app = appWithIdleSession(id)
            app.createNewConversation(id: peer, title: "peer", select: false)
            try app.store.peers.insert(PeerMessageRecord(msgId: sent ? "bbbb0231" : "cccc0231",
                                                         fromSession: sent ? id : peer, toSession: sent ? peer : id,
                                                         contextId: "ctx", inReplyTo: nil, depth: 1, firstLine: "q?",
                                                         sentAt: stale, expectsReply: true, closedAt: nil, closeReason: nil))
            setTouched(app, peer, stale)
            #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty, "sent: \(sent)")
            #expect(conv(app, id)?.isArchived == false)
        }
    }

    @Test("Iris, the open conversation and a background run are kept")
    func irisSelectedBackgroundKept() {
        let app = AppState(); app.conversations.removeAll()
        let iris = app.activityConversationId()
        let open = UUID()
        app.createNewConversation(id: open, title: "open")
        let run = app.createNewConversation(isBackground: true, title: "run", select: false)
        for id in [iris, open, run] {
            if let idx = app.conversations.firstIndex(where: { $0.id == id }) { app.conversations[idx].inSessions = true }
            setTouched(app, id, stale)
        }
        #expect(app.selectedConversationId == open)
        #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty)
    }

    // MARK: The clock

    @Test("only the person's actions move the clock: a card, a peer mark or a system line don't")
    func clockMovesOnlyForThePerson() {
        let id = UUID()
        let app = appWithIdleSession(id)
        app.setSessionCard(for: id, SessionCard(name: "builder2", description: "x", lane: nil, skills: []))
        app.markInSessions([id])
        app.appendMessage(role: .system, content: "a tick", to: id)
        #expect(conv(app, id)?.lastTouchedAt == stale)
        #expect(conv(app, id)!.updatedAt > stale, "updatedAt moved, which is why it isn't the clock")

        app.selectedConversationId = id
        #expect(conv(app, id)!.lastTouchedAt! > stale, "opening it touches it")
    }

    @Test("opening a session and the upgrade stamp leave updatedAt alone, so peers' listing doesn't move")
    func bookkeepingLeavesUpdatedAt() {
        let id = UUID()
        let app = appWithIdleSession(id)
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
        let old = now.addingTimeInterval(-3 * 86_400)
        app.conversations[idx].updatedAt = old
        app.selectedConversationId = id
        app.markInSessions([id])
        #expect(conv(app, id)?.updatedAt == old)

        app.selectedConversationId = nil
        app.conversations[idx].lastTouchedAt = nil
        _ = app.sweepIdleSessions(days: Self.days, now: now)
        #expect(conv(app, id)?.lastTouchedAt == old)
        #expect(conv(app, id)?.updatedAt == old)
    }

    @Test("typing into a session touches it")
    func typingTouches() {
        let id = UUID()
        let app = appWithIdleSession(id)
        app.selectedConversationId = id
        setTouched(app, id, stale)
        app.sendMessage("/unarchive")
        #expect(conv(app, id)!.lastTouchedAt! > stale)
    }

    @Test("upgrade: no clock yet starts from updatedAt, once")
    func upgradeStartsFromUpdatedAt() {
        let id = UUID()
        let app = appWithIdleSession(id)
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
        app.conversations[idx].lastTouchedAt = nil
        app.conversations[idx].updatedAt = now.addingTimeInterval(-86_400)
        #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty)
        #expect(conv(app, id)?.lastTouchedAt == now.addingTimeInterval(-86_400))

        app.conversations[idx].lastTouchedAt = nil
        app.conversations[idx].updatedAt = stale
        #expect(app.sweepIdleSessions(days: Self.days, now: now) == [id])
    }

    @Test("unarchive clears the mark and restarts the clock")
    func unarchiveResets() {
        let id = UUID()
        let app = appWithIdleSession(id)
        _ = app.sweepIdleSessions(days: Self.days, now: now)
        #expect(app.unarchiveConversation(id))
        #expect(conv(app, id)?.archivedAutomaticallyAt == nil)
        #expect(conv(app, id)!.lastTouchedAt! > stale)
        #expect(app.sweepIdleSessions(days: Self.days, now: now).isEmpty)
    }

    @Test("a manual archive carries no automatic mark")
    func manualArchiveUnmarked() {
        let id = UUID()
        let app = appWithIdleSession(id)
        #expect(app.archiveConversation(id) == nil)
        #expect(conv(app, id)?.archivedAutomaticallyAt == nil)
        #expect(conv(app, id)?.autoArchiveNote == nil)
    }

    // MARK: Persistence and addressing

    @Test("the clock, the mark and the session flag survive a relaunch")
    func persists() throws {
        let store = try ConversationStore.inMemory()
        let app = AppState(store: store, createIfEmpty: false, emitLaunchNotices: false)
        let id = UUID()
        app.createNewConversation(id: id, select: false)
        guard let idx = app.conversations.firstIndex(where: { $0.id == id }) else { return }
        app.conversations[idx].lastTouchedAt = stale
        app.conversations[idx].archivedAutomaticallyAt = now
        app.conversations[idx].inSessions = true
        app.markChanged(id, .metadata)
        app.flushSave()

        // Read the store itself: a second AppState would select the conversation at launch,
        // which touches it.
        let c = try #require(try store.loadAll().conversations.first { $0.id == id })
        #expect(abs(c.lastTouchedAt!.timeIntervalSince(stale)) < 0.01)
        #expect(abs(c.archivedAutomaticallyAt!.timeIntervalSince(now)) < 0.01)
        #expect(c.inSessions)
    }

    @Test("a conversation persisted before #231 decodes with no clock, no mark and not in sessions")
    func legacyDecodes() throws {
        let json = #"{"title":"old"}"#
        let c = try JSONDecoder().decode(Conversation.self, from: Data(json.utf8))
        #expect(c.lastTouchedAt == nil)
        #expect(c.archivedAutomaticallyAt == nil)
        #expect(c.inSessions == false)
    }

    @Test("an archived session's address says it's archived, not gone")
    func archivedAddressWording() {
        let me = UUID(), other = UUID()
        let app = AppState(); app.conversations.removeAll()
        app.createNewConversation(id: me)
        app.createNewConversation(id: other, select: false)
        _ = app.archiveConversation(other)
        let result = SessionDirectory.resolve(other.uuidString, in: app.conversations, excluding: me)
        #expect(result == .failure(.archived))
        #expect(SessionAddressError.archived.message == "That session is archived; the person can unarchive it.")
        let bg = app.createNewConversation(isBackground: true, title: "run", select: false)
        #expect(SessionDirectory.resolve(bg.uuidString, in: app.conversations, excluding: me) == .failure(.inactive))
    }
}
