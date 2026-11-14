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

    @Test("headline extraction strips markdown framing, tracks the latest line, and advances by sentence on long lines (#1100)")
    func headlineStabilizesLeftEdge() {
        #expect(ThinkingNotes.extractHeadline(from: "**Checking workspace**\n\n") == "Checking workspace")
        #expect(ThinkingNotes.extractHeadline(from: "### Step 1\nReading `AppState.swift` now") == "Reading AppState.swift now")

        let longFirstSentence = String(repeating: "word ", count: 25).trimmingCharacters(in: .whitespaces) + "."
        let combined = "\(longFirstSentence) Now checking the second sentence"
        #expect(combined.count > ThinkingNotes.headlineClauseLimit)
        #expect(ThinkingNotes.extractHeadline(from: combined) == "Now checking the second sentence")
    }

    @Test("bubbleText retains up to bubbleLimit characters while text retains tailLimit (#1100)")
    func bubbleTextRetainsLongerWindow() {
        let notes = ThinkingNotes()
        let id = UUID()
        let longThought = String(repeating: "a", count: 600) + "\nFinal paragraph"
        notes.append(longThought, to: id)
        let note = notes.note(for: id)
        #expect(note.text.count == ThinkingNotes.tailLimit)
        #expect(note.bubbleText.count == longThought.count)
        #expect(note.headline == "Final paragraph")
    }

    @Test("thought bubble visibility is hover-only by default, and when pinned auto-fades on typing or reply streaming (#1100)")
    func bubbleVisibilityRules() {
        let notes = ThinkingNotes()
        let id = UUID()
        let note = notes.note(for: id)
        notes.append("Considering two approaches...", to: id)

        // Default (autoShow == false): hidden until hovered.
        #expect(note.shouldShowBubble(isThinking: true, autoShow: false, composerHasText: false) == false)
        note.isHoveringLine = true
        #expect(note.shouldShowBubble(isThinking: true, autoShow: false, composerHasText: false) == true)
        note.isHoveringLine = false
        note.isHoveringBubble = true
        #expect(note.shouldShowBubble(isThinking: true, autoShow: false, composerHasText: true) == true,
                "explicit hover still shows the bubble even when text is in the composer")
        note.isHoveringBubble = false

        // Pinned (autoShow == true): shows while thinking, fades out on composer typing, reply streaming, or dismiss.
        #expect(note.shouldShowBubble(isThinking: true, autoShow: true, composerHasText: false) == true)
        #expect(note.shouldShowBubble(isThinking: true, autoShow: true, composerHasText: true) == false,
                "typing in the composer fades out the auto-shown bubble")

        notes.markReplyStreaming(id)
        #expect(note.shouldShowBubble(isThinking: true, autoShow: true, composerHasText: false) == false,
                "streaming reply tokens fade out the auto-shown bubble so it never covers the answer")

        notes.clear(id)
        #expect(note.isStreamingReply == false)
        #expect(note.bubbleText.isEmpty)
    }

    @Test("ConfigManager.autoShowThinkingBubble defaults to false and persists to its store (#1100)")
    func configAutoShowDefaultsOffAndPersists() {
        let name = "iris-thinking-bubble-\(UUID().uuidString)"
        let store = UserDefaults(suiteName: name)!
        defer {
            store.removePersistentDomain(forName: name)
            IrisDefaults.removeSuiteFile(named: name, in: IrisDefaults.preferencesDirectory)
        }
        let config = ConfigManager(store: store)
        #expect(config.autoShowThinkingBubble == false)
        config.autoShowThinkingBubble = true
        #expect(store.bool(forKey: "AUTO_SHOW_THINKING_BUBBLE") == true)
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
