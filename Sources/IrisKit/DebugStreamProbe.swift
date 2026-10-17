import Foundation

#if DEBUG
/// A load generator for #541 (streaming costs 30-34% CPU): grows an agent message the way a
/// streamed reply grows, without a model. Debug builds only, with `IRIS_STREAM_PROBE` set:
/// - `idle`: selects the probe's own conversation and does nothing more (the A/B's off arm);
/// - `on`: selects it, then every `MessageStreamer.flushIntervalMs` appends a few words to a
///   new agent message through `updateMessageContent`, the path the real streamer takes,
///   starting a fresh message once one passes about 4,000 characters.
/// The probe's conversation is created once, under a fixed id, seeded with 40 messages so the list
/// is a realistic length, and found by that id on later launches. Its title is set after seeding
/// and again on every launch: the first user message names an untitled-looking conversation after
/// itself (AppState.appendMessage), which renamed the seeded one, and `measure-stream.sh` finds the
/// window by this title. Earlier probe conversations, seeded before the id was fixed, are deleted
/// through `deleteConversation`. Measurement branch only; not for merging.
@MainActor
enum DebugStreamProbe {
    static let title = "#541 stream probe"
    static let id = UUID(uuidString: "541541A0-0000-4000-8000-000000000541")!
    /// The long conversation, for `IRIS_STREAM_PROBE_MESSAGES=200`: what scales with length shows.
    static let longId = UUID(uuidString: "541541A0-0000-4000-8000-000000000200")!
    static let env = ProcessInfo.processInfo.environment
    static let messageCount = Int(env["IRIS_STREAM_PROBE_MESSAGES"] ?? "") ?? 40
    /// Floor arms on fix A (#541): no per-token scroll; no implicit animation on the streaming
    /// row; no bottom scroll anchor; and a thinking state, as a real turn has (the LED pulses, the
    /// spectrum line runs at its working speed), so the arm costs what a user really pays.
    static let noScroll = env["IRIS_STREAM_NOSCROLL"] == "1"
    static let animationNil = env["IRIS_STREAM_ANIMNIL"] == "1"
    static let noAnchor = env["IRIS_STREAM_NOANCHOR"] == "1"
    static let thinking = env["IRIS_STREAM_THINKING"] == "1"
    /// Fix D's arms (#541): the streaming row as completed blocks and a tail, and the reply's length.
    static let split = env["IRIS_STREAM_SPLIT"] == "1"
    static let maxChars = Int(env["IRIS_STREAM_MAXCHARS"] ?? "") ?? 4_000
    static let firstQuestion = "Question 1: what does the next step look like?"

    static func startIfAsked(state: AppState) {
        guard let mode = ProcessInfo.processInfo.environment["IRIS_STREAM_PROBE"] else { return }
        Task { @MainActor in
            try? await Task.sleep(nanoseconds: 3_000_000_000)   // let launch settle
            let id = conversation(in: state)
            state.selectedConversationId = id
            guard mode == "on" else { return }
            if thinking {
                state.beginThinking()
                state.beginEngineTurn(for: id)
                state.updateSessionPhase(id, .responding)
            }
            await stream(into: id, state: state)
        }
    }

    static func conversation(in state: AppState) -> UUID {
        // Seeded by an earlier probe build: its first user message is the seeder's own.
        let id = messageCount > 40 ? longId : id
        let stale = state.conversations.filter { conversation in
            conversation.id != Self.id && conversation.id != longId
                && conversation.messages.first(where: { $0.role == .user })?.content == firstQuestion
        }.map(\.id)
        for old in stale { state.deleteConversation(old) }
        // Reseeded on every launch (#583's A/B): a run's streamed replies stay in the conversation,
        // so without this each arm started longer than the last, and "40 messages" meant 728.
        if state.conversations.contains(where: { $0.id == id }) { state.deleteConversation(id) }
        do {
            _ = state.createNewConversation(id: id, title: title)
            for n in 0..<(messageCount / 2) {
                state.appendMessage(role: .user, content: "Question \(n + 1): what does the next step look like?", to: id)
                state.appendMessage(role: .agent, content: sample(paragraphs: 3), to: id)
            }
        }
        state.updateConversationTitle(id: id, title: title)
        return id
    }

    private static func stream(into conversationId: UUID, state: AppState) async {
        let words = sample(paragraphs: 40).split(separator: " ", omittingEmptySubsequences: false)
        var cursor = 0
        var ticks = 0
        let rateFile = env["IRIS_STREAM_RATE_FILE"]
        while !Task.isCancelled {
            let messageId = UUID()
            state.appendMessage(role: .agent, content: "", id: messageId, to: conversationId)
            var text = ""
            while text.count < maxChars, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: MessageStreamer.flushIntervalMs * 1_000_000)
                for _ in 0..<6 {
                    text += (text.isEmpty ? "" : " ") + words[cursor % words.count]
                    cursor += 1
                }
                state.updateMessageContent(id: messageId, content: text, in: conversationId, persist: false)
                ticks += 1
                // The rate the arm really streamed at, so a slow arm cannot pass for a cheap one.
                if let rateFile, ticks % 20 == 0 {
                    try? "\(ticks) \(Date().timeIntervalSince1970)\n".write(toFile: rateFile, atomically: true, encoding: .utf8)
                }
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
