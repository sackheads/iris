import Testing
import Foundation
@testable import iris

@Suite("CommandPillTimer")
struct CommandPillTimerTests {

    // MARK: formatDuration

    @Test("under one minute shows seconds only")
    func underOneMinute() {
        #expect(formatDuration(0)  == "0s")
        #expect(formatDuration(42) == "42s")
        #expect(formatDuration(59) == "59s")
    }

    @Test("one minute to one hour shows minutes and seconds")
    func minuteRange() {
        #expect(formatDuration(60)   == "1m 0s")
        #expect(formatDuration(83)   == "1m 23s")
        #expect(formatDuration(3599) == "59m 59s")
    }

    @Test("one hour and above shows hours and minutes")
    func hourRange() {
        #expect(formatDuration(3600) == "1h 0m")
        #expect(formatDuration(3723) == "1h 2m")
    }

    // MARK: AppState timing dicts

    @Test("commandStartTimes and commandDurations are initially empty")
    @MainActor func timingDictsStartEmpty() {
        let state = AppState()
        #expect(state.commandStartTimes.isEmpty)
        #expect(state.commandDurations.isEmpty)
    }

    @Test("appendMessage uses supplied id")
    @MainActor func appendMessageUsesSuppliedId() {
        let state = AppState()
        let convId = UUID()
        state.createNewConversation(id: convId)
        let msgId = UUID()
        state.appendMessage(role: .system, content: "hello", id: msgId, to: convId)
        let conv = state.conversations.first { $0.id == convId }
        #expect(conv?.messages.last?.id == msgId)
    }
}
