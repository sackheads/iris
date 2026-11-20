import Testing
import Foundation
@testable import IrisKit

/// #974 Task 11 (C7): a memory reflection writes the OWNER's memory and reports into pinned Iris, so
/// a session whose binding is not the owner's never runs one. Driven through the real triggers
/// (`runReflection`, `/reflect`, and the every-30-messages path in `sendMessage`) on the one `.main`
/// engine, with the binding coming from the conversation's persisted `accessProfileId` (Task 12), and
/// an owner control beside each: the client's call count and the cards in Iris are what is asserted.
@MainActor
@Suite("a session bound to a profile does not reflect into the owner's memory (#974 Task 11, C7)", .serialized, .timeLimit(.minutes(2)))
struct ReflectionBindingTests {
    private struct Harness {
        let root: URL
        let state: AppState
        let client: FakeLLMClient
        let iris: UUID
        let source: UUID
        func tearDown() { try? FileManager.default.removeItem(at: root) }
    }

    private static func reply(_ s: String) -> GeminiResponse {
        GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))], usageMetadata: nil)
    }

    /// `profileId` is the source conversation's persisted profile (nil: the owner's). The profile store
    /// holds one real profile, `reader`; any other id names a profile that does not exist.
    private func harness(profileId: String?, replies: [String]) throws -> Harness {
        let root = FileManager.default.temporaryDirectory.appendingPathComponent("iris-974-t11-\(UUID().uuidString)")
        let paths = IrisPaths(root: root)
        try FileManager.default.createDirectory(at: paths.profilesDir, withIntermediateDirectories: true)
        try #"{"memoryRead":2}"#.write(to: paths.profilesDir.appendingPathComponent("reader.json"), atomically: true, encoding: .utf8)
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.autoApproveTools = true
        let iris = state.activityConversationId()
        let source = state.createNewConversation(title: "Launch plan", select: true)
        state.appendMessage(role: .user, content: "plan the launch", to: source)
        state.appendMessage(role: .agent, content: "Launch is Friday.", to: source)
        if let idx = state.conversations.firstIndex(where: { $0.id == source }) {
            state.conversations[idx].title = "Launch plan"
            state.conversations[idx].accessProfileId = profileId
        }
        let client = FakeLLMClient(responses: replies.map(Self.reply))
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client, retryDelays: [],
                                streamResponses: false, protectionEnabled: false, sessionPeerCount: 0,
                                accessProfileStore: AccessProfileStore(paths: paths))
        state.installEngine(engine)
        return Harness(root: root, state: state, client: client, iris: iris, source: source)
    }

    private static let report = "Updated USER.md: prefers short answers."

    private func cards(_ h: Harness) -> [EventCard] {
        (h.state.conversations.first { $0.id == h.iris }?.messages ?? []).filter { $0.role == .event }.compactMap { EventCard.decode($0.content) }
    }

    private func messages(_ h: Harness) -> [ChatMessage] {
        h.state.conversations.first { $0.id == h.source }?.messages ?? []
    }

    private func waitForTurn(_ h: Harness) async throws {
        for _ in 0..<400 where h.state.hasTurnInFlight(for: h.source) { try await Task.sleep(nanoseconds: 25_000_000) }
        #expect(!h.state.hasTurnInFlight(for: h.source), "turn did not finish within the bounded wait")
    }

    @Test("control: the owner's session reflects and its report reaches Iris as a card")
    func ownerReflects() async throws {
        let h = try harness(profileId: nil, replies: [Self.report]); defer { h.tearDown() }
        await h.state.runReflection(AppState.reflectionPrompt, in: h.source, moveReplyToIris: true)
        #expect(h.client.callCount == 1)
        #expect(cards(h).count == 1, "the owner's reflection still reports into Iris")
    }

    @Test("a session bound to a profile runs no reflection turn and posts no card into Iris")
    func boundSessionDoesNotReflect() async throws {
        let h = try harness(profileId: "reader", replies: [Self.report]); defer { h.tearDown() }
        await h.state.runReflection(AppState.reflectionPrompt, in: h.source, moveReplyToIris: true)
        #expect(h.client.callCount == 0, "no model turn, so no owner-memory tool was offered or called")
        #expect(cards(h).isEmpty, "nothing reaches the pinned conversation")
        #expect(!messages(h).contains { $0.role == .system && $0.content == AppState.reflectionReportedNotice })
    }

    @Test("a session whose persisted profile no longer exists fails closed: no reflection, never the owner's")
    func vanishedProfileDoesNotReflect() async throws {
        let h = try harness(profileId: "deleted", replies: [Self.report]); defer { h.tearDown() }
        await h.state.runReflection(AppState.reflectionPrompt, in: h.source, moveReplyToIris: true)
        #expect(h.client.callCount == 0)
        #expect(cards(h).isEmpty)
    }

    @Test("/reflect in a bound session says why nothing ran; the owner's /reflect still runs")
    func manualReflect() async throws {
        let bound = try harness(profileId: "reader", replies: [Self.report]); defer { bound.tearDown() }
        bound.state.sendMessage("/reflect")
        try await waitForTurn(bound)
        #expect(messages(bound).contains { $0.role == .system && $0.content == AppState.reflectionNotRunForBoundSession })
        #expect(!messages(bound).contains { $0.content == "Triggering manual memory reflection..." })
        #expect(bound.client.callCount == 0)
        #expect(cards(bound).isEmpty)

        let owner = try harness(profileId: nil, replies: [Self.report]); defer { owner.tearDown() }
        owner.state.sendMessage("/reflect")
        try await waitForTurn(owner)
        #expect(owner.client.callCount == 1)
        #expect(cards(owner).count == 1)
    }

    @Test("the automatic every-30-messages trigger: a bound session answers its message and then stays silent; the owner's reflects")
    func automaticTrigger() async throws {
        let bound = try harness(profileId: "reader", replies: ["Noted.", Self.report]); defer { bound.tearDown() }
        let idx = try #require(bound.state.conversations.firstIndex { $0.id == bound.source })
        bound.state.conversations[idx].messageCountSinceReflection = 29
        bound.state.sendMessage("and one more thing")
        try await waitForTurn(bound)
        #expect(bound.client.callCount == 1, "only the user's own turn ran, no reflection turn followed")
        #expect(!messages(bound).contains { $0.content == "Triggering automatic memory reflection..." })
        #expect(cards(bound).isEmpty)

        let owner = try harness(profileId: nil, replies: ["Noted.", Self.report]); defer { owner.tearDown() }
        let oidx = try #require(owner.state.conversations.firstIndex { $0.id == owner.source })
        owner.state.conversations[oidx].messageCountSinceReflection = 29
        owner.state.sendMessage("and one more thing")
        try await waitForTurn(owner)
        #expect(owner.client.callCount == 2, "the user's turn, then the reflection turn")
        #expect(cards(owner).count == 1)
    }
}
