import Testing
import Foundation
@testable import iris

/// 5b §0.4: `/new` in the pinned conversation rotates it — reflect, create a fresh Iris and move
/// the pin, summarise the old one into the new one, then archive the old one. The order is what
/// these tests pin: cards follow the pin from the moment it moves, and the archive comes last.
@MainActor
@Suite struct ConversationRotationTests {

    /// Answers the summary request per `summary`, every other request with plain text, and records
    /// each request with the tier it asked for. The summary request is recognised by its prompt,
    /// not by call order, so a turn that sneaks in between cannot shift the script.
    final class RotationClient: LLMClientProtocol, @unchecked Sendable {
        enum Summary { case reply(String), fail, gated(JobSchedulerTests.Gate, String) }

        private let lock = NSLock()
        private var recorded: [(request: GeminiRequest, tier: ModelTier)] = []
        private let summary: Summary

        init(summary: Summary) { self.summary = summary }

        var requests: [(request: GeminiRequest, tier: ModelTier)] { lock.withLock { recorded } }

        private func record(_ request: GeminiRequest, _ tier: ModelTier) {
            lock.withLock { recorded.append((request, tier)) }
        }

        static func texts(_ request: GeminiRequest) -> [String] {
            request.contents.flatMap { $0.parts.compactMap(\.text) }
        }

        static func isSummaryRequest(_ request: GeminiRequest) -> Bool {
            request.contents.first?.parts.first?.text?.hasPrefix(IrisEngine.rotationSummaryPrompt) == true
        }

        private func text(_ s: String) -> GeminiResponse {
            GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: s)]))],
                           usageMetadata: nil)
        }

        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            record(request, tier)
            guard Self.isSummaryRequest(request) else { return text("No memory consolidation needed at this time.") }
            switch summary {
            case .reply(let s): return text(s)
            case .fail: throw APIError(message: "summary call failed")
            case .gated(let gate, let s):
                await gate.arriveAndWait()
                return text(s)
            }
        }
    }

    struct Harness {
        let state: AppState
        let client: RotationClient
        let oldId: UUID
        let now: Date
    }

    /// A fixed local-noon instant, so the archived title's date does not depend on when the suite runs.
    static let fixedNow: Date = {
        var c = DateComponents()
        c.year = 2026; c.month = 10; c.day = 1; c.hour = 12
        return Calendar(identifier: .gregorian).date(from: c)!
    }()

    private func harness(_ summary: RotationClient.Summary) throws -> Harness {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.autoApproveTools = true
        state.rotationNow = { Self.fixedNow }
        let old = state.activityConversationId()
        state.selectedConversationId = old
        state.appendMessage(role: .user, content: "plan the launch", to: old)
        state.appendMessage(role: .agent, content: "Launch is Friday.", to: old)
        let client = RotationClient(summary: summary)
        let engine = IrisEngine(state: state, tier: .medium, principal: .main, client: client,
                                retryDelays: [], streamResponses: false, protectionEnabled: false,
                                sessionPeerCount: 0)
        state.installEngine(engine)
        return Harness(state: state, client: client, oldId: old, now: Self.fixedNow)
    }

    private func pinnedId(_ state: AppState) throws -> UUID {
        let raw = try #require(try state.store.metaValue(forKey: AppState.activityConversationMetaKey))
        return try #require(UUID(uuidString: raw))
    }

    /// The §0.4 invariant: the meta key names a conversation that exists and is not archived.
    private func expectPinValid(_ state: AppState, _ where_: String,
                                sourceLocation: SourceLocation = #_sourceLocation) throws {
        let id = try pinnedId(state)
        let conv = state.conversations.first { $0.id == id }
        #expect(conv != nil, "pin names a missing conversation (\(where_))", sourceLocation: sourceLocation)
        #expect(conv?.isArchived == false, "pin names an archived conversation (\(where_))", sourceLocation: sourceLocation)
    }

    /// Starts `/new` and returns the rotation task; nil means the command did not start one.
    private func startRotation(_ state: AppState) -> Task<Void, Never>? {
        state.sendMessage("/new")
        return state.rotationTask
    }

    private func finish(_ task: Task<Void, Never>) async throws {
        try await withTimeout(seconds: 10) { await task.value }
    }

    private func waitForEntry(_ gate: JobSchedulerTests.Gate) async throws {
        try await withTimeout(seconds: 10) { await gate.waitForEntry() }
    }

    // MARK: -

    @Test func archivedTitleUsesTheLocalDate() {
        #expect(AppState.archivedTitle(last: Self.fixedNow) == "Iris — until 2026-10-01")
    }

    @Test func happyPath() async throws {
        let h = try harness(.reply("Decided: launch Friday. Open: the press list."))
        let task = try #require(startRotation(h.state))
        try await finish(task)
        let state = h.state

        let newId = try pinnedId(state)
        #expect(newId != h.oldId)
        let new = try #require(state.conversations.first { $0.id == newId })
        #expect(new.isPinned)
        #expect(new.title == "Iris")
        #expect(state.selectedConversationId == newId)
        let first = try #require(new.messages.first)
        #expect(first.content.hasPrefix("[Summary of the previous Iris conversation, \"Iris — until 2026-10-01\"]"))
        #expect(first.content.contains("launch Friday"))
        let history = try #require(new.history.first)
        #expect(history.role == "user", "providers reject a history that opens with a model entry")
        #expect(history.parts.first?.text?.hasPrefix("[Summary of the previous Iris conversation") == true)

        let old = try #require(state.conversations.first { $0.id == h.oldId })
        #expect(old.isArchived)
        #expect(!old.isPinned)
        #expect(old.title == AppState.archivedTitle(last: h.now))

        let requests = h.client.requests
        #expect(requests.contains { RotationClient.texts($0.request).contains { $0.contains("[Reflection Trigger]") } })
        let summary = try #require(requests.first { RotationClient.isSummaryRequest($0.request) })
        #expect(summary.tier == .easy)
        let input = RotationClient.texts(summary.request).joined()
        #expect(input.contains("owner: plan the launch"))
        #expect(input.contains("iris: Launch is Friday."))
        // Reflection precedes the summary, and runs in the OLD conversation (its history has it).
        let reflectIdx = requests.firstIndex { RotationClient.texts($0.request).contains { $0.contains("[Reflection Trigger]") } }
        let summaryIdx = requests.firstIndex { RotationClient.isSummaryRequest($0.request) }
        #expect(reflectIdx! < summaryIdx!)
        #expect(old.history.contains { $0.parts.contains { $0.text?.contains("[Reflection Trigger]") == true } })
        #expect(state.rotationTask == nil)
        try expectPinValid(state, "happy path")
    }

    /// The first draft ran the rotation as the old conversation's own thinking task, so
    /// `archiveRefusal` saw it as a turn in flight and the old conversation was never archived.
    @Test func rotationActuallyArchives() async throws {
        let h = try harness(.reply("summary"))
        let task = try #require(startRotation(h.state))
        try await finish(task)
        #expect(h.state.conversations.first { $0.id == h.oldId }?.isArchived == true)
        #expect(h.state.archiveRefusal(for: h.oldId) == nil)
    }

    /// Review Focus 1: the pin moves before the slow summary call, so a card delivered while it
    /// runs lands in the new Iris, never in the one about to be archived.
    @Test func cardMidRotationLandsInNewIris() async throws {
        let gate = JobSchedulerTests.Gate()
        let h = try harness(.gated(gate, "summary"))
        let task = try #require(startRotation(h.state))
        try await waitForEntry(gate)
        try expectPinValid(h.state, "mid-rotation")

        let card = EventCard(runId: UUID(), jobId: UUID(), jobName: "midway", status: .completed,
                             outcome: "tick", startedAt: Date(), finishedAt: Date())
        await h.state.deliverEvent(card, to: h.state.activityConversationId())
        await gate.open()
        try await finish(task)

        let newId = try pinnedId(h.state)
        let new = try #require(h.state.conversations.first { $0.id == newId })
        let old = try #require(h.state.conversations.first { $0.id == h.oldId })
        #expect(new.messages.contains { $0.role == .event && $0.content.contains("midway") })
        #expect(!old.messages.contains { $0.role == .event })
        // The summary still opens the model's history, ahead of the card's line.
        #expect(new.history.first?.parts.first?.text?.hasPrefix("[Summary of the previous Iris conversation") == true)
        #expect(new.history.contains { $0.parts.contains { $0.text?.contains("midway") == true } })
        try expectPinValid(h.state, "after card")
    }

    @Test func summaryFailureStillRotates() async throws {
        let h = try harness(.fail)
        let task = try #require(startRotation(h.state))
        try await finish(task)

        let newId = try pinnedId(h.state)
        #expect(newId != h.oldId)
        let new = try #require(h.state.conversations.first { $0.id == newId })
        let first = try #require(new.messages.first)
        #expect(first.content.contains("No summary was produced"))
        #expect(first.content.contains("Iris — until 2026-10-01"))
        #expect(new.history.first?.role == "user")
        #expect(h.state.conversations.first { $0.id == h.oldId }?.isArchived == true)
        try expectPinValid(h.state, "summary failure")
    }

    @Test func refusesDuringTurn() throws {
        let h = try harness(.reply("summary"))
        let before = h.state.conversations.count
        h.state.sendMessage("hello")   // tracked task registered synchronously
        #expect(h.state.hasTurnInFlight(for: h.oldId))

        h.state.sendMessage("/new")    // refused before any task starts

        #expect(h.state.rotationTask == nil)
        #expect(try pinnedId(h.state) == h.oldId)
        #expect(h.state.conversations.count == before)
        let old = try #require(h.state.conversations.first { $0.id == h.oldId })
        #expect(old.isPinned && !old.isArchived && old.title == "Iris")
        #expect(old.messages.last?.content.contains("a turn is still running") == true)
        h.state.interruptActiveConversation()
    }

    @Test func refusesDuringGoal() throws {
        let h = try harness(.reply("summary"))
        let before = h.state.conversations.count
        h.state.setGoal(for: h.oldId, goal: "ship it")

        h.state.sendMessage("/new")

        #expect(h.state.rotationTask == nil)
        #expect(try pinnedId(h.state) == h.oldId)
        #expect(h.state.conversations.count == before)
        let old = try #require(h.state.conversations.first { $0.id == h.oldId })
        #expect(old.isPinned && !old.isArchived && old.title == "Iris")
        #expect(old.messages.last?.content.contains("goal is active") == true)
        #expect(h.client.requests.isEmpty, "a refused rotation must not reach the model")
    }

    /// Once the pin has moved, the new Iris has no turn in flight, so a second `/new` would pass
    /// `archiveRefusal` and start a second rotation over the first one's half-built conversation.
    @Test func secondNewDuringRotationIsRefused() async throws {
        let gate = JobSchedulerTests.Gate()
        let h = try harness(.gated(gate, "summary"))
        let task = try #require(startRotation(h.state))
        try await waitForEntry(gate)
        let midId = try pinnedId(h.state)
        let count = h.state.conversations.count

        h.state.sendMessage("/new")

        #expect(h.state.rotationTask == task)
        #expect(h.state.conversations.count == count)
        #expect(try pinnedId(h.state) == midId)
        await gate.open()
        try await finish(task)
        #expect(try pinnedId(h.state) == midId)
        try expectPinValid(h.state, "second /new")
    }

    @Test func peerTurnDuringRotationSkipsArchive() async throws {
        let gate = JobSchedulerTests.Gate()
        let h = try harness(.gated(gate, "summary"))
        let task = try #require(startRotation(h.state))
        try await waitForEntry(gate)

        h.state.beginEngineTurn(for: h.oldId)   // a peer's turn arrives in the old conversation
        await gate.open()
        try await finish(task)

        let newId = try pinnedId(h.state)
        #expect(newId != h.oldId)
        let old = try #require(h.state.conversations.first { $0.id == h.oldId })
        #expect(!old.isArchived)
        #expect(!old.isPinned)
        #expect(old.title == "Iris — until 2026-10-01")
        let new = try #require(h.state.conversations.first { $0.id == newId })
        #expect(new.messages.first?.content.contains("busy") == true)
        #expect(new.history.first?.parts.first?.text?.contains("busy") == true)
        try expectPinValid(h.state, "peer turn")
        h.state.endEngineTurn(for: h.oldId)
    }

    @Test func pinNeverPointsAtArchived() async throws {
        for summary in [RotationClient.Summary.reply("s"), .fail] {
            let h = try harness(summary)
            try await finish(try #require(startRotation(h.state)))
            try expectPinValid(h.state, "\(summary)")
            #expect(try pinnedId(h.state) != h.oldId)
        }
        let gate = JobSchedulerTests.Gate()
        let h = try harness(.gated(gate, "s"))
        let task = try #require(startRotation(h.state))
        try await waitForEntry(gate)
        try expectPinValid(h.state, "peer, mid")
        h.state.beginEngineTurn(for: h.oldId)
        await gate.open()
        try await finish(task)
        try expectPinValid(h.state, "peer, after")
        h.state.endEngineTurn(for: h.oldId)
    }

    @Test func newElsewhereUnchanged() throws {
        let h = try harness(.reply("summary"))
        let other = UUID()
        h.state.createNewConversation(id: other)
        h.state.selectedConversationId = other
        let count = h.state.conversations.count

        h.state.sendMessage("/new")

        #expect(h.state.rotationTask == nil)
        #expect(h.state.conversations.count == count + 1)
        let created = try #require(h.state.conversations.last)
        #expect(!created.isPinned)
        #expect(h.state.selectedConversationId == created.id)
        #expect(try pinnedId(h.state) == h.oldId)
        #expect(h.state.conversations.first { $0.id == h.oldId }?.isArchived == false)
        #expect(h.client.requests.isEmpty)
    }
}
