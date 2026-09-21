import Testing
import Foundation
@testable import iris

/// #185 §3, §4. The peer set is bounded by the active predicate; the listing is bounded by a cap.
@Suite("Session directory")
struct SessionDirectoryTests {

    private func conv(_ title: String, archived: Bool = false, subagent: Bool = false,
                      card: SessionCard? = nil, workspace: String? = nil,
                      updated: Date = Date()) -> Conversation {
        var c = Conversation(id: UUID(), title: title, workspacePath: workspace)
        c.isArchived = archived
        c.isSubagent = subagent
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
        #expect(out.peers.first?.isBusy == true)
    }
}
