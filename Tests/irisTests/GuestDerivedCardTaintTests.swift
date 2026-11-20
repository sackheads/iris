import Testing
import Foundation
@testable import IrisKit

/// #1250: an event card delivered to a destination carries text derived from its source's conversation
/// into the destination's history. When a guest wrote into that source (`hasGuestInput`, #1246) the
/// destination must read as tainted afterwards, so #812's outbound gate holds a send from it. Driven
/// through the real routes (a `/reflect` in a guest-touched session; a job run fired by `JobRunner`) and
/// the real gate (`IrisEngine.outboundGate`), with an untouched-source control beside each.
@MainActor
@Suite("a card from a guest-touched source taints its destination (#1250)", .serialized, .timeLimit(.minutes(2)))
struct GuestDerivedCardTaintTests {
    private static func reply(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    private func state() throws -> AppState {
        let s = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        s.autoApproveTools = true
        return s
    }

    private func config() -> (ConfigManager, () -> Void) {
        let name = "iris-cardtaint-\(UUID().uuidString)"
        let defaults = UserDefaults(suiteName: name)!
        return (ConfigManager(store: defaults), {
            defaults.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        })
    }

    /// Runs the real outbound gate for a send from `id`. A clean conversation returns `.notGated` at once;
    /// a tainted one reaches the person, so the request is denied and `.refused` comes back.
    private func sendFrom(_ id: UUID, _ state: AppState, _ engine: IrisEngine) async throws -> (gated: Bool, decision: IrisEngine.OutboundGateDecision) {
        let call = FunctionCall(name: "gmail_send_email", args: ["to": .string("a@b.com"), "subject": .string("hi"), "body": .string("x")])
        let saved = state.autoApproveTools
        state.autoApproveTools = false
        defer { state.autoApproveTools = saved }
        let task = Task { @MainActor in await engine.outboundGate(call, conversationId: id, workspacePath: nil, isUnattended: false) }
        var gated = false
        for _ in 0..<200 {
            if state.pendingApprovals.contains(where: { $0.conversationId == id }) {
                gated = true
                state.denyPendingApprovals(for: id)
                break
            }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        let decision = try await value(of: task)
        return (gated, decision)
    }

    private func engine(_ state: AppState, replies: [String] = []) -> IrisEngine {
        let e = IrisEngine(state: state, tier: .medium, principal: .main, client: FakeLLMClient(responses: replies.map(Self.reply)),
                           retryDelays: [], streamResponses: false, protectionEnabled: false, sessionPeerCount: 0)
        state.installEngine(e)
        return e
    }

    private func waitForTurn(_ state: AppState, _ id: UUID) async throws {
        for _ in 0..<400 where state.hasTurnInFlight(for: id) { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(!state.hasTurnInFlight(for: id))
    }

    // MARK: reflection cards

    @Test("a reflection card from a guest-touched session taints Iris, and a send from Iris then holds")
    func reflectionCardTaintsTheDestination() async throws {
        let s = try state()
        let iris = s.activityConversationId()
        let source = s.createNewConversation(title: "Role session", select: true)
        s.appendMessage(role: .user, content: "work", to: source)
        s.appendMessage(role: .agent, content: "ok", to: source)
        let idx = try #require(s.conversations.firstIndex { $0.id == source })
        s.conversations[idx].hasGuestInput = true
        let e = engine(s, replies: ["Updated USER.md: prefers short answers."])

        #expect(s.conversations.first { $0.id == iris }?.hasUntrustedToolOutput == false, "Iris starts clean")
        #expect(try await sendFrom(iris, s, e).decision == .notGated, "control: a send from clean Iris is not gated")

        s.sendMessage("/reflect")   // the owner's own ask: it runs in a guest-touched session (#1246)
        try await waitForTurn(s, source)
        let cards = (s.conversations.first { $0.id == iris }?.messages ?? []).filter { $0.role == .event }.compactMap { EventCard.decode($0.content) }
        #expect(cards.count == 1, "the reflection card reached Iris")

        #expect(s.conversations.first { $0.id == iris }?.hasUntrustedToolOutput == true, "Iris now carries the taint")
        let send = try await sendFrom(iris, s, e)
        #expect(send.gated, "the send reached the person")
        #expect(send.decision != .notGated)
    }

    @Test("control: a reflection card from a session no guest wrote into leaves Iris clean")
    func untouchedReflectionCardLeavesTheDestinationClean() async throws {
        let s = try state()
        let iris = s.activityConversationId()
        let source = s.createNewConversation(title: "Plain session", select: true)
        s.appendMessage(role: .user, content: "work", to: source)
        s.appendMessage(role: .agent, content: "ok", to: source)
        let e = engine(s, replies: ["Updated USER.md: prefers short answers."])
        s.sendMessage("/reflect")
        try await waitForTurn(s, source)
        let cards = (s.conversations.first { $0.id == iris }?.messages ?? []).filter { $0.role == .event }
        #expect(cards.count == 1)
        #expect(s.conversations.first { $0.id == iris }?.hasUntrustedToolOutput == false)
        #expect(try await sendFrom(iris, s, e).decision == .notGated)
    }

    // MARK: job-run cards

    private func fireJob(createdIn creator: UUID, _ s: AppState, _ e: IrisEngine) async throws {
        let job = Job(name: "sweep", prompt: "Reply with just the word tick.", trigger: .schedule(.interval(seconds: 60)),
                      createdInConversationId: creator)
        try s.store.ledger.upsert(job)
        let (cfg, teardown) = config()
        defer { teardown() }
        let runner = JobRunner(state: s, engine: e, ledger: s.store.ledger, endSandboxSession: { _ in },
                               now: { Date(timeIntervalSince1970: 1_700_000_000) }, config: cfg)
        await runner.fire(job: job, origin: .schedule)
    }

    @Test("a job-run card for a job created in a guest-touched session taints Iris, and a send from Iris then holds")
    func jobRunCardTaintsTheDestination() async throws {
        let s = try state()
        let iris = s.activityConversationId()
        let creator = s.createNewConversation(title: "Role session", select: false)
        let idx = try #require(s.conversations.firstIndex { $0.id == creator })
        s.conversations[idx].hasGuestInput = true
        let e = engine(s, replies: ["tick"])
        try await fireJob(createdIn: creator, s, e)
        let cards = (s.conversations.first { $0.id == iris }?.messages ?? []).filter { $0.role == .event }
        #expect(cards.count == 1, "the run's card reached Iris")
        #expect(s.conversations.first { $0.id == iris }?.hasUntrustedToolOutput == true)
        let send = try await sendFrom(iris, s, e)
        #expect(send.gated && send.decision != .notGated)
    }

    @Test("control: a job-run card for a job created in an untouched session leaves Iris clean")
    func untouchedJobRunCardLeavesTheDestinationClean() async throws {
        let s = try state()
        let iris = s.activityConversationId()
        let creator = s.createNewConversation(title: "Plain session", select: false)
        let e = engine(s, replies: ["tick"])
        try await fireJob(createdIn: creator, s, e)
        let cards = (s.conversations.first { $0.id == iris }?.messages ?? []).filter { $0.role == .event }
        #expect(cards.count == 1)
        #expect(s.conversations.first { $0.id == iris }?.hasUntrustedToolOutput == false)
        #expect(try await sendFrom(iris, s, e).decision == .notGated)
    }
}
