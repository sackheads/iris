import Testing
import Foundation
@testable import iris

/// Consecutive system messages collapse into one group whose header shows only the latest line.
/// An LLM error must not disappear into a collapsed run of tool-call pills, so it always forms a
/// group of its own, which the view renders expanded.
@Suite("MessageItem.group")
struct MessageGroupingTests {
    private let toolCall = "[TOOL_CALL]\n{\"name\": \"run_command\", \"args\": {\"command\": \"ls\"}}"
    private let llmError = LLMErrorMessage.encode(LLMErrorDisplay(headline: "Gemini HTTP 429", detail: nil))

    private func shape(_ items: [MessageItem]) -> [Int] {
        items.map { item in
            switch item {
            case .single: return 0
            case .systemGroup(_, let msgs): return msgs.count
            }
        }
    }

    @Test("consecutive system messages still group together")
    func systemRunsGroup() {
        let msgs = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .system, content: toolCall),
            ChatMessage(role: .system, content: toolCall),
            ChatMessage(role: .agent, content: "done"),
        ]
        #expect(shape(MessageItem.group(msgs)) == [0, 2, 0])
    }

    @Test("an LLM error splits out into its own group")
    func llmErrorIsItsOwnGroup() {
        let msgs = [
            ChatMessage(role: .user, content: "hi"),
            ChatMessage(role: .system, content: toolCall),
            ChatMessage(role: .system, content: toolCall),
            ChatMessage(role: .system, content: llmError),
            ChatMessage(role: .system, content: toolCall),
        ]
        let items = MessageItem.group(msgs)
        #expect(shape(items) == [0, 2, 1, 1])
        if case .systemGroup(_, let only) = items[2] {
            #expect(LLMErrorMessage.parse(only[0].content) != nil)
        } else {
            Issue.record("expected the error to be a system group")
        }
    }

    @Test("group ids are stable across regrouping")
    func stableIds() {
        let msgs = [ChatMessage(role: .system, content: toolCall), ChatMessage(role: .system, content: llmError)]
        let a = MessageItem.group(msgs).map(\.id)
        let b = MessageItem.group(msgs).map(\.id)
        #expect(a == b)
        #expect(a == [msgs[0].id, msgs[1].id])
    }
}
