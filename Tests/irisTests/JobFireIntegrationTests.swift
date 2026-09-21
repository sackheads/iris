import Testing
import Foundation
@testable import iris

/// One scheduled job, end to end: parsed out of `schedule_job`'s arguments, stored through the
/// scheduler, and fired into a real `IrisEngine` over a `FakeLLMClient`.
///
/// The pieces below it each have their own suite — `ScheduleJobArgumentsTests` for the parse,
/// `JobSchedulerTests` for the tick, `ArchiveUnarchiveOnWorkTests` for the arrival — and all of
/// them pass with the wiring in `IrisEngine.start()` broken, because none of them uses it. This
/// one does: it takes the handler from `fireHandler()`, which is the same call `start()` makes.
@MainActor
@Suite("A scheduled job fires a turn")
struct JobFireIntegrationTests {

    /// A clock the test moves by hand, so the fire happens because `now` passed `nextFireAt`
    /// rather than because a real ten-second poll came round.
    final class MovableClock: @unchecked Sendable {
        private let lock = NSLock()
        private var value: Date
        init(_ value: Date) { self.value = value }
        var now: Date { lock.lock(); defer { lock.unlock() }; return value }
        func set(_ newValue: Date) { lock.lock(); value = newValue; lock.unlock() }
    }

    @Test("a due job runs one turn in the conversation it was created in, then reschedules")
    func dueJobFiresOneTurnIntoItsConversation() async throws {
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        state.conversations.removeAll()
        state.autoApproveTools = true          // non-interactive: never park on an approval prompt
        let conversationId = UUID()
        state.createNewConversation(id: conversationId)
        // A second, selected conversation: the fire must follow the job's own id, and a handler
        // that dropped it would land here instead and go unnoticed.
        let selectedId = UUID()
        state.createNewConversation(id: selectedId)
        state.selectedConversationId = selectedId

        let client = FakeLLMClient(responses: [
            Scenario.ScriptedResponse(kind: .text, text: "tick", calls: nil).asGeminiResponse()
        ])
        let engine = IrisEngine(state: state, tier: .medium, client: client,
                                protectionEnabled: false, sessionPeerCount: 0)

        // Exactly the arguments the model sends, through the tool's own parse and job builder.
        let arguments = try ScheduleJobArguments.parse([
            "prompt": .string("Reply with just the word tick."),
            "intervalSeconds": .int(60)
        ]).get()
        let job = try arguments.makeJob(defaultTimeZone: TimeZone.current.identifier,
                                        createdIn: conversationId, existingNames: []).get()

        let start = Date(timeIntervalSince1970: 1_700_000_000)
        let clock = MovableClock(start)
        let scheduler = JobScheduler(ledger: store.ledger, now: { clock.now })
        let stored = try await scheduler.schedule(job)
        #expect(stored.nextFireAt == start.addingTimeInterval(60))
        await scheduler.setFireHandler(engine.fireHandler())   // the wiring `start()` does

        #expect(await scheduler.tick() == 0, "not due yet")
        clock.set(start.addingTimeInterval(61))
        #expect(await scheduler.tick() == 1)

        let messages = state.conversations.first { $0.id == conversationId }?.messages ?? []
        #expect(messages.contains {
            $0.role == .system && $0.content.contains("Scheduled Job Triggered: Reply with just the word tick.")
        }, "the event landed in the creating conversation")
        let selectedMessages = state.conversations.first { $0.id == selectedId }?.messages ?? []
        #expect(!selectedMessages.contains { $0.content.contains("Scheduled Job Triggered:") },
                "and not in whatever the user happened to have open")
        #expect(client.callCount == 1, "one fire is one turn")
        #expect(try store.ledger.job(named: stored.name)?.nextFireAt == start.addingTimeInterval(121))
        #expect(await scheduler.tick() == 0, "the same now does not fire it twice")
    }

    @Test("bringing the scheduler up twice keeps one, rather than orphaning a polling loop")
    func schedulerIsReusedAcrossStarts() async throws {
        // `AppState.start()` is called from `onAppear` and can run more than once.
        let store = try ConversationStore.inMemory()
        let state = AppState(store: store, tier2Provisioning: .provisioned, tier3Provisioning: .provisioned)
        let engine = IrisEngine(state: state, client: FakeLLMClient(responses: []),
                                protectionEnabled: false, sessionPeerCount: 0)

        let first = await engine.adoptJobScheduler(ledger: store.ledger)
        let second = await engine.adoptJobScheduler(ledger: store.ledger)

        #expect(first === second, "the second call must not leave the first loop running unreferenced")
        #expect(await engine.jobScheduler === first)
        await first.stop()
    }
}
