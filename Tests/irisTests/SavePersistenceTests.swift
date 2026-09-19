import Testing
import Foundation
@testable import iris

/// Regression tests for #62: a locked goal contract lost its criteria across a restart because
/// the debounced save never fired during sustained activity, and `_exit(0)` on quit discarded
/// whatever was still pending.
@MainActor
@Suite("Save persistence (#62)")
struct SavePersistenceTests {

    /// Reads the persisted blob back as conversations, so assertions are about real durable
    /// state rather than byte counts.
    private func persisted() -> [Conversation] {
        guard let data = IrisDefaults.store.data(forKey: "iris_conversations"),
              let decoded = try? JSONDecoder().decode([Conversation].self, from: data) else { return [] }
        return decoded
    }

    @Test("sustained mutation cannot starve the save past the max wait")
    func testMaxWaitDefeatsStarvation() async throws {
        let app = AppState()
        let convId = UUID()
        app.createNewConversation(id: convId)
        app.flushSave()

        // Mutate faster than the 0.5s debounce for longer than the max wait. Under a pure
        // trailing debounce every one of these cancels its predecessor and nothing is ever
        // written; the max wait must force a write anyway.
        let busyDeadline = Date().addingTimeInterval(AppState.saveMaxWait + 1.0)
        var sent = 0
        while Date() < busyDeadline {
            app.appendMessage(role: .agent, content: "chunk \(sent)", to: convId)
            sent += 1
            try await Task.sleep(nanoseconds: 100_000_000)
        }

        // Read the store WITHOUT going quiet first — a trailing-only debounce shows nothing here.
        let saved = persisted().first(where: { $0.id == convId })
        #expect(saved != nil, "conversation never reached the store during sustained mutation")
        #expect((saved?.messages.count ?? 0) > 0, "no messages persisted during sustained mutation")
    }

    @Test("flushSave persists immediately without waiting for the debounce")
    func testFlushSaveIsImmediate() throws {
        let app = AppState()
        let convId = UUID()
        app.createNewConversation(id: convId)
        app.appendMessage(role: .agent, content: "written before quit", to: convId)

        // No sleep: this is the applicationWillTerminate path, which runs just before _exit(0).
        app.flushSave()

        let saved = persisted().first(where: { $0.id == convId })
        #expect(saved?.messages.contains(where: { $0.content == "written before quit" }) == true,
                "flushSave did not persist synchronously")
    }

    @Test("a locked contract survives a flush during sustained mutation")
    func testLockedContractSurvivesBusyPeriod() async throws {
        let app = AppState()
        let convId = UUID()
        app.createNewConversation(id: convId)

        let contract = GoalContract(objective: "Ship the feature", criteria: [
            Criterion(text: "tests pass", kind: .executable, check: "swift test"),
            Criterion(text: "docs updated", kind: .qualitative, check: nil),
            Criterion(text: "no regressions", kind: .qualitative, check: nil),
            Criterion(text: "looks right to the user", kind: .humanJudged, check: nil)
        ])
        app.setGoalContract(for: convId, contract)

        // The agent immediately starts working: sustained mutation, exactly the #62 sequence.
        for i in 0..<12 {
            app.appendMessage(role: .agent, content: "working \(i)", to: convId)
            try await Task.sleep(nanoseconds: 100_000_000)
        }
        app.flushSave()   // the quit

        let saved = persisted().first(where: { $0.id == convId })
        #expect(saved?.goalContract?.criteria.count == 4, "locked contract lost criteria across the busy period")
        #expect(saved?.goalContract?.isLocked == true)
    }
}
