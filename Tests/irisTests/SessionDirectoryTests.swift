import Testing
import Foundation
@testable import IrisKit

/// #185 §3, §4. The peer set is bounded by the active predicate; the listing is bounded by a cap.
@Suite("Session directory")
struct SessionDirectoryTests {

    private func conv(_ title: String, archived: Bool = false, subagent: Bool = false,
                      background: Bool = false, card: SessionCard? = nil, workspace: String? = nil,
                      updated: Date = Date()) -> Conversation {
        var c = Conversation(id: UUID(), title: title, workspacePath: workspace)
        c.isArchived = archived
        c.isSubagent = subagent
        c.isBackground = background
        c.sessionCard = card
        c.updatedAt = updated
        return c
    }

    @Test("archived conversations and subagents are not peers")
    func excludesArchivedAndSubagents() {
        let me = conv("me")
        let all = [me, conv("active"), conv("archived", archived: true), conv("scratch", subagent: true)]
        let out = SessionDirectory.peers(in: all, excluding: me.id, busy: { _ in false })
        #expect(out.peers.count == 1)
        #expect(out.total == 1)
    }

    /// A job run gets a conversation of its own (#187), hidden from the sidebar and with nobody
    /// reading it. Listing it would advertise an address the harness then has to refuse, and
    /// would inflate the standing peer count with work that is not a session at all.
    @Test("a background run conversation is not a peer")
    func excludesBackgroundRuns() {
        let me = conv("me")
        let all = [me, conv("active"), conv("pr-sweep run", background: true)]
        let out = SessionDirectory.peers(in: all, excluding: me.id, busy: { _ in false })
        #expect(out.peers.count == 1)
        #expect(out.total == 1, "a hidden run must not inflate the count either")
    }

    @Test("the caller is never its own peer")
    func excludesSelf() {
        let me = conv("me")
        let out = SessionDirectory.peers(in: [me], excluding: me.id, busy: { _ in false })
        #expect(out.peers.isEmpty)
    }

    @Test("an uncarded session is still listed, by title and workspace")
    func uncardedIsListed() {
        let me = conv("me")
        let other = conv("Untitled", workspace: "/tmp/w")
        let out = SessionDirectory.peers(in: [me, other], excluding: me.id, busy: { _ in false })
        let p = try! #require(out.peers.first)
        #expect(p.name == nil && p.description == nil)
        #expect(p.workspace == "/tmp/w", "workspace is the deterministic relevance gate, card or not")
    }

    @Test("the listing is capped and reports the true total")
    func capsAndReportsTotal() {
        let me = conv("me")
        let many = (0..<30).map { conv("c\($0)") }
        let out = SessionDirectory.peers(in: [me] + many, excluding: me.id, busy: { _ in false })
        #expect(out.peers.count == SessionDirectory.listCap)
        #expect(out.total == 30, "a large peer set must not silently become a large context payload")
    }

    @Test("ordering is most-recently-active first, by conversation not card")
    func ordersByConversationActivity() {
        let me = conv("me")
        let old = Date(timeIntervalSince1970: 1_000)
        let new = Date(timeIntervalSince1970: 2_000)
        // A chatty self-describer must not outrank a recently-active session.
        let chatty = conv("chatty", card: SessionCard(name: "chatty", description: "d", updatedAt: new),
                          updated: old)
        let busy = conv("busy", updated: new)
        let out = SessionDirectory.peers(in: [me, chatty, busy], excluding: me.id, busy: { _ in false })
        #expect(out.peers.first?.id == busy.id)
    }

    @Test("busy comes from the harness, never from the card")
    func busyIsDerived() {
        let me = conv("me")
        // The card says idle; the harness says busy. A peer must not be able to misreport liveness.
        let liar = conv("liar", card: SessionCard(name: "liar", description: "idle, promise"))
        let out = SessionDirectory.peers(in: [me, liar], excluding: me.id,
                                         busy: { $0 == liar.id })
        #expect(out.peers.first?.status == .busy)
    }

    /// `ordersByConversationActivity` above sets `updatedAt` by hand, so it stays green against a
    /// signal production never moves — which is exactly what happened: the field was written only
    /// at decode and at load, so the "most recently active" ordering was really "most recently
    /// loaded or created" and froze at launch (whole-branch review, M3). This drives real work
    /// through the public API and never assigns `updatedAt` after the setup line.
    @MainActor
    @Test("real activity through the public API moves a session up the listing")
    func activityReordersTheListing() {
        let app = AppState(); app.conversations.removeAll()
        let me = UUID(), quiet = UUID(), worker = UUID()
        for id in [me, quiet, worker] { app.createNewConversation(id: id) }

        // Backdate both peers so the starting order is unambiguous rather than a function of how
        // fast `createNewConversation` ran. This is the LAST hand-set timestamp in this test.
        func backdate(_ id: UUID, _ seconds: TimeInterval) {
            let idx = app.conversations.firstIndex { $0.id == id }!
            app.conversations[idx].updatedAt = Date(timeIntervalSince1970: seconds)
        }
        backdate(worker, 1_000)
        backdate(quiet, 2_000)

        let before = SessionDirectory.peers(in: app.conversations, excluding: me, busy: { _ in false })
        #expect(before.peers.first?.id == quiet, "the newer timestamp leads to begin with")

        // Real work on the stale one, through the API a session actually uses.
        app.setSessionCard(for: worker, SessionCard(name: "worker", description: "doing the thing"))

        let after = SessionDirectory.peers(in: app.conversations, excluding: me, busy: { _ in false })
        #expect(after.peers.first?.id == worker,
                "a session that is actually working must outrank one that has been idle since launch")
    }

    @Test("role-holders list first and are exempt from the cap")
    func rolesFirstAndUncapped() {
        var convs: [Conversation] = []
        let me = Conversation(title: "me")
        convs.append(me)
        for i in 0..<(SessionDirectory.listCap + 3) {
            var c = Conversation(title: "w\(i)"); c.updatedAt = Date(timeIntervalSince1970: Double(1000 + i)); convs.append(c)
        }
        var overseer = Conversation(title: "o"); overseer.role = "overseer"; overseer.updatedAt = Date(timeIntervalSince1970: 1)
        convs.append(overseer)
        let (peers, total) = SessionDirectory.peers(in: convs, excluding: me.id, now: Date(), status: { _ in .idle })
        #expect(peers.first?.role == "overseer")
        #expect(peers.first?.kind == .role)
        #expect(peers.count == SessionDirectory.listCap + 1)
        #expect(total == SessionDirectory.listCap + 4)
    }

    /// #480 review item 7: before this, Iris was only sorted last among whatever survived the
    /// cap — with enough workers ahead of it, the 20-row cap could cut Iris out of the listing
    /// entirely, making "Iris last" true only sometimes. Iris is now exempt from the cap the way
    /// a role-holder already was, so it survives alongside role rows regardless of worker count,
    /// and `renderPeerList`'s "last" ordering is appended after, never competed for a cap slot.
    @Test("the pinned Iris is exempt from the cap and always last")
    func irisExemptFromCapAndAlwaysLast() {
        var convs: [Conversation] = []
        let me = Conversation(title: "me")
        convs.append(me)
        for i in 0..<(SessionDirectory.listCap + 5) {
            var c = Conversation(title: "w\(i)"); c.updatedAt = Date(timeIntervalSince1970: Double(10_000 + i)); convs.append(c)
        }
        var iris = Conversation(title: "Iris"); iris.isPinned = true
        iris.updatedAt = Date(timeIntervalSince1970: 1)   // oldest of all — would be cut first under the old rule
        convs.append(iris)
        let (peers, total) = SessionDirectory.peers(in: convs, excluding: me.id, now: Date(), status: { _ in .idle })
        #expect(peers.contains { $0.id == iris.id }, "Iris must survive the cap regardless of worker count")
        #expect(peers.last?.kind == .iris, "Iris is always last")
        #expect(peers.count == SessionDirectory.listCap + 1, "the cap still bounds workers; Iris is the +1")
        #expect(total == SessionDirectory.listCap + 6)
    }

    @Test("the pinned conversation is kind iris; others are workers")
    func kinds() {
        let me = Conversation(title: "me")
        var iris = Conversation(title: "Iris"); iris.isPinned = true
        let w = Conversation(title: "w")
        let (peers, _) = SessionDirectory.peers(in: [me, iris, w], excluding: me.id, now: Date(), status: { _ in .idle })
        #expect(peers.first { $0.id == iris.id }?.kind == .iris)
        #expect(peers.first { $0.id == w.id }?.kind == .worker)
    }
}
