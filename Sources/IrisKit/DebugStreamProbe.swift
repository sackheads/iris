import Foundation

#if DEBUG
/// A load generator for #541 (streaming costs 30-34% CPU): grows an agent message the way a
/// streamed reply grows, without a model. Debug builds only, with `IRIS_STREAM_PROBE` set:
/// - `idle`: selects the probe's own conversation and does nothing more (the A/B's off arm);
/// - `on`: selects it, then every `MessageStreamer.flushIntervalMs` appends a few words to a
///   new agent message through `updateMessageContent`, the path the real streamer takes,
///   starting a fresh message once one passes about 4,000 characters.
/// The probe's conversation is created once, seeded with 40 messages so the list is a realistic
/// length, and found by title on later launches. Measurement branch only; not for merging.
@MainActor
enum DebugStreamProbe {
    static let title = "#541 stream probe"

    static func startIfAsked(state: AppState) {
        guard let mode = ProcessInfo.processInfo.environment["IRIS_STREAM_PROBE"] else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let launch settle
            let id = conversation(in: state)
            state.selectedConversationId = id
            guard mode == "on" else { return }
            await stream(into: id, state: state)
        }
    }

    private static func conversation(in state: AppState) -> UUID {
        if let existing = state.conversations.first(where: { $0.title == title && !$0.isArchived }) { return existing.id }
        let id = state.createNewConversation(title: title)
        for n in 0..<20 {
            state.appendMessage(role: .user, content: "Question \(n + 1): what does the next step look like?", to: id)
            state.appendMessage(role: .agent, content: sample(paragraphs: 3), to: id)
        }
        return id
    }

    private static func stream(into conversationId: UUID, state: AppState) async {
        let words = sample(paragraphs: 40).split(separator: " ", omittingEmptySubsequences: false)
        var cursor = 0
        while !Task.isCancelled {
            let messageId = UUID()
            state.appendMessage(role: .agent, content: "", id: messageId, to: conversationId)
            var text = ""
            while text.count < 4_000, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: MessageStreamer.flushIntervalMs * 1_000_000)
                for _ in 0..<6 {
                    text += (text.isEmpty ? "" : " ") + words[cursor % words.count]
                    cursor += 1
                }
                state.updateMessageContent(id: messageId, content: text, in: conversationId, persist: false)
            }
        }
    }

    /// Markdown shaped like a real reply: paragraphs, a list, inline code and a code block.
    private static func sample(paragraphs: Int) -> String {
        let blocks = [
            "The change touches the **dispatcher** and the `ToolExecutor`, so the tests for both need to run before it lands. Nothing in the store changes shape.",
            "- read the current config\n- compare it with the defaults\n- write only what differs",
            "```swift\nlet result = await executor.execute(name: \"read_file\", args: args)\nprint(result)\n```",
            "Once that is done, the remaining work is mostly wiring: the view reads the new field, and the old fallback can go. I would keep the fallback for one release.",
        ]
        return (0..<paragraphs).map { blocks[$0 % blocks.count] }.joined(separator: "\n\n")
    }
}
#endif
