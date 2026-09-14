import Testing
import Foundation
@testable import iris

/// The pill-timer dicts are keyed by message id and nothing removed from them, so every
/// `run_command` in a session left an entry behind that outlived the message it described (#100).
@MainActor
@Suite("Command timing purge")
struct CommandTimingPurgeTests {
    /// Records a command message with timing, the way IrisEngine does for a run_command pill.
    private func timedCommand(on app: AppState, in convId: UUID) -> UUID {
        let msgId = UUID()
        app.appendMessage(role: .system, content: "[TOOL_CALL]\n{}", id: msgId, to: convId)
        app.commandStartTimes[msgId] = Date()
        app.commandDurations[msgId] = 1.5
        return msgId
    }

    @Test("deleting a conversation drops its command timings")
    func deletePurges() {
        let app = AppState()
        let convId = UUID()
        app.createNewConversation(id: convId)
        let msgId = timedCommand(on: app, in: convId)

        app.deleteConversation(convId)

        #expect(app.commandStartTimes[msgId] == nil)
        #expect(app.commandDurations[msgId] == nil)
    }

    @Test("deleting one conversation leaves another's timings alone")
    func deleteIsScoped() {
        let app = AppState()
        let keep = UUID(), drop = UUID()
        app.createNewConversation(id: keep)
        app.createNewConversation(id: drop)
        let keptMsg = timedCommand(on: app, in: keep)
        let droppedMsg = timedCommand(on: app, in: drop)

        app.deleteConversation(drop)

        #expect(app.commandDurations[droppedMsg] == nil)
        #expect(app.commandDurations[keptMsg] != nil, "an unrelated conversation's pill must keep its timer")
        #expect(app.commandStartTimes[keptMsg] != nil)
    }

    @Test("/clear drops the cleared conversation's command timings")
    func clearPurges() {
        let app = AppState()
        let convId = UUID()
        app.createNewConversation(id: convId)
        let msgId = timedCommand(on: app, in: convId)
        app.selectedConversationId = convId

        app.sendMessage("/clear")

        #expect(app.conversations.first { $0.id == convId }?.messages.contains { $0.id == msgId } != true)
        #expect(app.commandStartTimes[msgId] == nil)
        #expect(app.commandDurations[msgId] == nil)
    }
}
