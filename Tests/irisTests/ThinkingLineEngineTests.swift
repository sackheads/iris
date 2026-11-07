import Foundation
import Testing
@testable import IrisKit

/// #314 PR 7: the live path from a stream's thinking text to the status line, through the engine's
/// own stream consumer, with no network and no GUI. The view reads `ThinkingNotes.Note.text`.
@MainActor
@Suite("Thinking status line through the engine (#314 PR 7)", .timeLimit(.minutes(1)))
struct ThinkingLineEngineTests {
    /// Streams `events`, then parks before `tail` until the test lets it go, so the test can read
    /// the line while the reply is still in flight.
    private final class ScriptedStream: LLMClientProtocol, @unchecked Sendable {
        let head: [LLMStreamEvent]
        let tail: [LLMStreamEvent]
        private let gate = AsyncGate()
        var supportsStreaming: Bool { true }
        init(head: [LLMStreamEvent], tail: [LLMStreamEvent]) { self.head = head; self.tail = tail }
        func release() { let gate = gate; Task { await gate.open() } }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            GeminiResponse(candidates: nil, usageMetadata: nil)
        }
        func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { continuation in
                let task = Task {
                    for e in head { continuation.yield(e) }
                    await gate.wait()
                    for e in tail { continuation.yield(e) }
                    continuation.finish()
                }
                continuation.onTermination = { _ in task.cancel() }
            }
        }
    }

    private actor AsyncGate {
        private var isOpen = false
        private var waiters: [CheckedContinuation<Void, Never>] = []
        func open() { isOpen = true; waiters.forEach { $0.resume() }; waiters = [] }
        func wait() async { if isOpen { return }; await withCheckedContinuation { waiters.append($0) } }
    }

    /// Polls up to 10 s on the main actor's own turns; true as soon as `condition` holds.
    private func settles(_ condition: () -> Bool) async -> Bool {
        for _ in 0..<500 {
            if condition() { return true }
            try? await Task.sleep(nanoseconds: 20_000_000)
        }
        return false
    }

    private func consume(_ client: ScriptedStream) async throws -> (AppState, UUID, Task<IrisEngine.StreamOutcome, Error>) {
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)
        let id = app.createNewConversation(select: true)
        let streamer = await engine.makeStreamer(conversationId: id)
        let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        let task = Task { try await engine.consumeModelStream(request: request, streamed: true, streamer: streamer, conversationId: id) }
        return (app, id, task)
    }

    @Test("thinking text reaches the line while the reply is in flight, and the line is empty once it ends")
    func lineShowsThenClears() async throws {
        let client = ScriptedStream(head: [.thinkingText("Weighing "), .thinkingText("two options")],
                                    tail: [.textDelta("Done."), .done(finishReason: "STOP")])
        let (app, id, task) = try await consume(client)
        // The consumer applies events in order; the second fragment is the last thing before the park.
        #expect(await settles { app.thinkingNotes.note(for: id).text == "Weighing two options" })
        client.release()
        let outcome = try await value(of: task, within: 20)
        #expect(app.thinkingNotes.note(for: id).text.isEmpty)
        #expect(outcome.response.candidates?.first?.content?.parts.compactMap(\.text).joined() == "Done.")
    }

    @Test("a reply with no thinking text never shows a line, and nothing is made up")
    func absentThinkingShowsNothing() async throws {
        let client = ScriptedStream(head: [], tail: [.textDelta("Hi."), .done(finishReason: "STOP")])
        let (app, id, task) = try await consume(client)
        try await Task.sleep(nanoseconds: 150_000_000)   // long enough for any event to have been applied
        #expect(app.thinkingNotes.note(for: id).text.isEmpty)
        client.release()
        _ = try await value(of: task, within: 20)
        #expect(app.thinkingNotes.note(for: id).text.isEmpty)
    }

    @Test("a stream that fails after thinking text clears the line too")
    func failureClears() async throws {
        struct Boom: Error {}
        let app = AppState(store: try ConversationStore.inMemory(), createIfEmpty: false, emitLaunchNotices: false)
        let client = FailingAfterThinking()
        let engine = IrisEngine(state: app, client: client, retryDelays: [], protectionEnabled: false, sessionPeerCount: 0)
        app.installEngine(engine)
        let id = app.createNewConversation(select: true)
        let streamer = await engine.makeStreamer(conversationId: id)
        let request = GeminiRequest(contents: [Content(role: "user", parts: [Part(text: "hi")])], systemInstruction: nil, tools: nil)
        await #expect(throws: (any Error).self) {
            _ = try await engine.consumeModelStream(request: request, streamed: true, streamer: streamer, conversationId: id)
        }
        #expect(app.thinkingNotes.note(for: id).text.isEmpty)
    }

    private final class FailingAfterThinking: LLMClientProtocol, @unchecked Sendable {
        var supportsStreaming: Bool { true }
        func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
            GeminiResponse(candidates: nil, usageMetadata: nil)
        }
        func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
            AsyncThrowingStream { c in
                c.yield(.thinkingText("half a thought"))
                c.finish(throwing: URLError(.networkConnectionLost))
            }
        }
    }
}
