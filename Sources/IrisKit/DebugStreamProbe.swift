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
    /// Attribution switches (#541): skip the per-token scroll; stream into `DebugStreamBuffer`
    /// instead of `conversations`, read only by the streaming row.
    static let noScroll = env["IRIS_STREAM_NOSCROLL"] == "1"
    static let useBuffer = env["IRIS_STREAM_BUFFER"] == "1"
    static let messageCount = Int(env["IRIS_STREAM_PROBE_MESSAGES"] ?? "") ?? 40
    /// Residual analysis (#541): how long a streamed message grows before the next one starts,
    /// and whether the streaming row renders as plain `Text` instead of Markdown.
    static let maxChars = Int(env["IRIS_STREAM_MAXCHARS"] ?? "") ?? 4_000
    static let plain = env["IRIS_STREAM_PLAIN"] == "1"

    /// Whether `message` is the one streaming into the buffer right now.
    static func isStreaming(_ message: ChatMessage) -> Bool {
        useBuffer && DebugStreamBuffer.shared.messageId == message.id
    }
    static let tick = Notification.Name("iris.debug.streamTick")

    /// What the agent row shows: the buffer's text for the message streaming into it.
    static func displayed(_ message: ChatMessage) -> String {
        guard useBuffer, DebugStreamBuffer.shared.messageId == message.id else { return message.content }
        return DebugStreamBuffer.shared.text
    }
    static let firstQuestion = "Question 1: what does the next step look like?"

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

    static func conversation(in state: AppState) -> UUID {
        // Seeded by an earlier probe build: its first user message is the seeder's own.
        let id = messageCount > 40 ? longId : id
        let stale = state.conversations.filter { conversation in
            conversation.id != Self.id && conversation.id != longId
                && conversation.messages.first(where: { $0.role == .user })?.content == firstQuestion
        }.map(\.id)
        for old in stale { state.deleteConversation(old) }
        if !state.conversations.contains(where: { $0.id == id }) {
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
            if useBuffer { DebugStreamBuffer.shared.messageId = messageId; DebugStreamBuffer.shared.text = "" }
            var text = ""
            while text.count < maxChars, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: MessageStreamer.flushIntervalMs * 1_000_000)
                for _ in 0..<6 {
                    text += (text.isEmpty ? "" : " ") + words[cursor % words.count]
                    cursor += 1
                }
                if useBuffer {
                    DebugStreamBuffer.shared.text = text
                    NotificationCenter.default.post(name: tick, object: nil)   // the scroll, without the root
                } else {
                    state.updateMessageContent(id: messageId, content: text, in: conversationId, persist: false)
                }
                ticks += 1
                // The rate the arm really streamed at, so a slow arm cannot pass for a cheap one.
                if let rateFile, ticks % 20 == 0 {
                    try? "\(ticks) \(Date().timeIntervalSince1970)\n".write(toFile: rateFile, atomically: true, encoding: .utf8)
                }
            }
            if useBuffer { state.updateMessageContent(id: messageId, content: text, in: conversationId, persist: false) }
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
/// The side buffer for `IRIS_STREAM_BUFFER` (#541's attribution arm): a stand-in for taking the
/// in-flight text off `conversations`, read only by the row it streams into.
@Observable @MainActor
final class DebugStreamBuffer {
    static let shared = DebugStreamBuffer()
    var messageId: UUID?
    var text = ""
}
#endif
