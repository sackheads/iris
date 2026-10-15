import Testing
import Foundation
@testable import IrisKit

/// #469 §6. Causal hop depth bounds loops; a per-sender token bucket bounds fan-out. Replaces
/// the single global cascade budget (#185 §7) CascadeBudgetTests pinned.
@MainActor
@Suite("Peer limits", .timeLimit(.minutes(1)))
struct PeerLimitsTests {
    final class Clock: @unchecked Sendable { var now = Date(timeIntervalSince1970: 0) }

    @Test("the bucket allows its capacity, then refuses with the wait, then refills")
    func bucket() {
        let clock = Clock()
        var limiter = PeerRateLimiter(now: { clock.now })
        let a = UUID()
        for _ in 0..<PeerRateLimiter.capacity { #expect(limiter.take(for: a) == nil) }
        let wait = limiter.take(for: a)
        #expect(wait != nil && wait! > 0 && wait! <= PeerRateLimiter.refillInterval)
        clock.now += PeerRateLimiter.refillInterval
        #expect(limiter.take(for: a) == nil)
        #expect(limiter.take(for: UUID()) == nil, "buckets are per sender")
    }

    private func app(_ ids: [UUID]) -> AppState {
        let app = AppState(); app.conversations.removeAll()
        for id in ids { app.createNewConversation(id: id) }
        return app
    }

    @Test("a send carries the sender's depth plus one and raises the target's depth")
    func depthPropagates() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        #expect(app.decidePeerSend(to: b.uuidString, from: a, replyTarget: nil) == .allowed(target: b, depth: 1))
        app.notePeerArrival(depth: 1, at: b)
        #expect(app.decidePeerSend(to: a.uuidString, from: b, replyTarget: nil) == .allowed(target: a, depth: 2))
    }

    @Test("a loop of fresh messages (no in_reply_to) is refused past the limit")
    func loopWithoutReplies() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        let limit = ConfigManager.shared.maxSessionCascade
        var from = a, to = b
        for hop in 1...limit {
            guard case .allowed(_, let depth) = app.decidePeerSend(to: to.uuidString, from: from, replyTarget: nil)
            else { Issue.record("hop \(hop) refused early"); return }
            app.notePeerArrival(depth: depth, at: to)
            swap(&from, &to)
        }
        guard case .refused(let why) = app.decidePeerSend(to: to.uuidString, from: from, replyTarget: nil)
        else { Issue.record("hop past the limit was allowed"); return }
        #expect(why.contains("deep"))
    }

    @Test("the user typing into a session resets its depth only")
    func resetOnTyping() {
        let a = UUID(), b = UUID(), c = UUID()
        let app = app([a, b, c])
        app.notePeerArrival(depth: 5, at: b)
        app.notePeerArrival(depth: 5, at: c)
        app.selectedConversationId = b
        app.sendMessage("hello")
        #expect(app.peerDepth(for: b) == 0)
        #expect(app.peerDepth(for: c) == 5)
    }

    @Test("a refused send names the rate limit and the wait, and spends nothing else")
    func rateRefusal() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        let clock = Clock()
        app.peerRateLimiter = PeerRateLimiter(now: { clock.now })
        for _ in 0..<PeerRateLimiter.capacity { _ = app.decidePeerSend(to: b.uuidString, from: a, replyTarget: nil) }
        guard case .refused(let why) = app.decidePeerSend(to: b.uuidString, from: a, replyTarget: nil)
        else { Issue.record("expected the rate limit"); return }
        #expect(why.contains("rate limit") && why.contains("15s"))
    }

    @Test("an unresolvable address is refused without spending a token")
    func badAddressSpendsNothing() {
        let a = UUID(), b = UUID()
        let app = app([a, b])
        let clock = Clock()
        app.peerRateLimiter = PeerRateLimiter(now: { clock.now })
        guard case .refused = app.decidePeerSend(to: "role:nobody", from: a, replyTarget: nil)
        else { Issue.record("expected a refusal"); return }
        var allowed = 0
        for _ in 0..<PeerRateLimiter.capacity {
            if case .allowed = app.decidePeerSend(to: b.uuidString, from: a, replyTarget: nil) { allowed += 1 }
        }
        #expect(allowed == PeerRateLimiter.capacity, "the refused send must not have spent a token")
    }
}
