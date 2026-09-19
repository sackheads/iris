import Testing
import Foundation
@testable import iris

/// A client that plays scripted stream events, one script per call.
final class ScriptedStreamClient: LLMClientProtocol, @unchecked Sendable {
    enum Step: Sendable {
        case event(LLMStreamEvent)
        case fail(any Error)
        /// Never ends on its own; the consumer's cancellation ends it.
        case hang
    }
    private let lock = NSLock()
    private var scripts: [[Step]]
    private(set) var calls = 0
    init(_ scripts: [[Step]]) { self.scripts = scripts }
    var supportsStreaming: Bool { true }
    /// The same script, delivered as one finished response: what the provider would have returned
    /// with streaming off. Lets one script drive both sides of the streaming-off comparison.
    func generateContent(request: GeminiRequest, tier: ModelTier) async throws -> GeminiResponse {
        let script: [Step] = lock.withLock {
            calls += 1
            return scripts.isEmpty ? [] : scripts.removeFirst()
        }
        var assembler = StreamAssembler()
        for step in script {
            switch step {
            case .event(let e): assembler.apply(e, now: 0)
            case .fail(let error): throw error
            case .hang: try await Task.sleep(nanoseconds: 60_000_000_000)
            }
        }
        return assembler.response()
    }
    func streamContent(request: GeminiRequest, tier: ModelTier) -> AsyncThrowingStream<LLMStreamEvent, Error> {
        let script: [Step] = lock.withLock {
            calls += 1
            return scripts.isEmpty ? [] : scripts.removeFirst()
        }
        return AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    for step in script {
                        switch step {
                        case .event(let e): continuation.yield(e)
                        case .fail(let error): throw error
                        case .hang: try await Task.sleep(nanoseconds: 60_000_000_000)
                        }
                        await Task.yield()
                    }
                    continuation.finish()
                } catch { continuation.finish(throwing: error) }
            }
            continuation.onTermination = { _ in task.cancel() }
        }
    }
}

@MainActor
@Suite("IrisEngine streaming")
struct StreamingEngineTests {
    private func session(_ client: any LLMClientProtocol, retryDelays: [TimeInterval] = []) -> (AppState, IrisEngine, UUID) {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: retryDelays, streamResponses: true)
        return (app, engine, id)
    }
    private func conv(_ app: AppState, _ id: UUID) -> Conversation { app.conversations.first { $0.id == id }! }
    private func agentTexts(_ app: AppState, _ id: UUID) -> [String] { conv(app, id).messages.filter { $0.role == .agent }.map(\.content) }
    private func errorPills(_ app: AppState, _ id: UUID) -> [LLMErrorDisplay] { conv(app, id).messages.compactMap { LLMErrorMessage.parse($0.content) } }
    private var overloaded: APIError { APIError.http(provider: "Gemini", statusCode: 503, body: Data(#"{"error":{"message":"busy","status":"UNAVAILABLE"}}"#.utf8)) }

    @Test("a streamed text turn ends as one agent message, one model history turn, usage counted")
    func streamedText() async {
        let client = ScriptedStreamClient([[.event(.textDelta("Hel")), .event(.textDelta("lo")),
                                            .event(.usage(UsageMetadata(promptTokenCount: 5, candidatesTokenCount: 2, totalTokenCount: 7))),
                                            .event(.done(finishReason: "STOP"))]])
        let (app, engine, id) = session(client)
        await engine.processInput("hi", source: "User", conversationId: id)
        #expect(agentTexts(app, id) == ["Hello"])
        let history = conv(app, id).history
        #expect(history.last?.role == "model")
        #expect(history.last?.parts.first?.text == "Hello")
        #expect(conv(app, id).tokenUsage.candidatesTokenCount == 2)
        #expect(errorPills(app, id).isEmpty)
    }

    @Test("firstTokenMs is recorded for a native stream and nil for a replayed client")
    func firstTokenRecorded() async throws {
        let scenario = Scenario(name: "s", clientMode: .fake, turns: [Scenario.Turn(prompt: "hi")],
                                scriptedResponses: [Scenario.ScriptedResponse(kind: .text, text: "Hello", calls: nil)])
        let native = ScriptedStreamClient([[.event(.textDelta("Hello")), .event(.done(finishReason: nil))]])
        let streamed = await ScenarioRunner.run(scenario, clientOverride: native)
        let call = try #require(streamed.turnProfiles.first?.modelCalls.first)
        #expect(call.firstTokenMs != nil)
        #expect(call.firstTokenMs! >= 0 && call.firstTokenMs! <= call.latencyMs + 1)

        let replayed = await ScenarioRunner.run(scenario)   // FakeLLMClient: supportsStreaming == false
        #expect(replayed.turnProfiles.first?.modelCalls.first?.firstTokenMs == nil)
        #expect(replayed.finalTexts == streamed.finalTexts)
    }

    @Test("a streamed tool call dispatches once with its parsed arguments and the loop continues")
    func streamedToolCall() async {
        let call = FunctionCall(name: "run_command", args: ["command": .string("echo streamed")], id: "c1")
        let client = ScriptedStreamClient([[.event(.functionCall(call)), .event(.done(finishReason: "tool_use"))],
                                           [.event(.textDelta("done")), .event(.done(finishReason: "STOP"))]])
        let (app, engine, id) = session(client)
        await engine.processInput("run it", source: "User", conversationId: id)
        #expect(client.calls == 2)
        #expect(agentTexts(app, id) == ["done"])
        let toolCalls = conv(app, id).messages.filter { $0.content.hasPrefix("[TOOL_CALL]") }
        #expect(toolCalls.count == 1)
        #expect(toolCalls.first?.content.contains("echo streamed") == true)
    }

    @Test("a failure after the first delta keeps the partial text, shows the error after it, is not retried, and reaches history")
    func midStreamFailure() async throws {
        let client = ScriptedStreamClient([[.event(.textDelta("partial ")), .fail(overloaded)],
                                           [.event(.textDelta("never")), .event(.done(finishReason: nil))]])
        let (app, engine, id) = session(client, retryDelays: [0.01, 0.01])
        await engine.processInput("hi", source: "User", conversationId: id)
        #expect(client.calls == 1)
        #expect(agentTexts(app, id) == ["partial "])
        let pill = try #require(errorPills(app, id).first)
        #expect(pill.headline.hasPrefix("Response interrupted: Gemini HTTP 503"))
        let messages = conv(app, id).messages
        let agentIndex = messages.firstIndex { $0.role == .agent }!
        let pillIndex = messages.firstIndex { LLMErrorMessage.parse($0.content) != nil }!
        #expect(agentIndex < pillIndex)
        #expect(conv(app, id).history.last?.parts.first?.text == "partial ")
        #expect(!conv(app, id).messages.contains { $0.content.hasPrefix("[retry]") })
    }

    @Test("a failure before the first delta retries as before and leaves no partial row")
    func preDeltaRetry() async {
        let client = ScriptedStreamClient([[.fail(overloaded)],
                                           [.event(.textDelta("ok")), .event(.done(finishReason: nil))]])
        let (app, engine, id) = session(client, retryDelays: [0.01])
        await engine.processInput("hi", source: "User", conversationId: id)
        #expect(client.calls == 2)
        #expect(agentTexts(app, id) == ["ok"])
        #expect(conv(app, id).messages.contains { $0.content.hasPrefix("[retry]") })
        #expect(errorPills(app, id).isEmpty)
    }

    @Test("Stop mid-stream keeps the partial text, posts no error pill, and commits the partial text to history")
    func cancellation() async {
        let client = ScriptedStreamClient([[.event(.textDelta("part")), .hang]])
        let (app, engine, id) = session(client)
        let turn = Task { await engine.processInput("hi", source: "User", conversationId: id) }
        for _ in 0..<200 where agentTexts(app, id).isEmpty {
            try? await Task.sleep(nanoseconds: 10_000_000)
        }
        #expect(agentTexts(app, id) == ["part"])
        turn.cancel()
        await turn.value
        #expect(agentTexts(app, id) == ["part"])
        #expect(errorPills(app, id).isEmpty)
        #expect(conv(app, id).history.last?.role == "model")
        #expect(conv(app, id).history.last?.parts.first?.text == "part")
    }

    @Test("streaming off produces the same text and history as streaming on, and records no first-token time")
    func streamingOffMatchesOn() async throws {
        let script: [ScriptedStreamClient.Step] = [.event(.textDelta("Hel")), .event(.textDelta("lo")),
                                                   .event(.done(finishReason: "STOP"))]
        func turn(streamResponses: Bool) async -> (texts: [String], historyText: String?, firstTokenMs: Double?) {
            let app = AppState()
            app.autoApproveTools = true
            let id = UUID()
            app.createNewConversation(id: id)
            let engine = IrisEngine(state: app, tier: .medium, principal: .main,
                                    client: ScriptedStreamClient([script]), retryDelays: [],
                                    streamResponses: streamResponses)
            let collector = ProfileCollector()
            await PerformanceProfiler.$runSink.withValue({ collector.append($0) }) {
                await engine.processInput("hi", source: "User", conversationId: id)
            }
            return (agentTexts(app, id), conv(app, id).history.last?.parts.first?.text,
                    collector.all.first?.modelCalls.first?.firstTokenMs)
        }
        let on = await turn(streamResponses: true)
        let off = await turn(streamResponses: false)
        #expect(on.texts == ["Hello"])
        #expect(off.texts == on.texts)
        #expect(on.historyText == "Hello")
        #expect(off.historyText == on.historyText)
        #expect(on.firstTokenMs != nil)
        #expect(off.firstTokenMs == nil)
    }

    @Test("an empty stream produces the #136 pill and no agent row")
    func emptyStream() async {
        let client = ScriptedStreamClient([[.event(.done(finishReason: "SAFETY"))]])
        let (app, engine, id) = session(client)
        await engine.processInput("hi", source: "User", conversationId: id)
        #expect(agentTexts(app, id).isEmpty)
        #expect(errorPills(app, id).first?.headline.contains("finishReason: SAFETY") == true)
    }
}

/// Thread-safe sink for the turn profiles a test's own turns produce.
private final class ProfileCollector: @unchecked Sendable {
    private let lock = NSLock()
    private var items: [CommandProfile] = []
    func append(_ p: CommandProfile) { lock.lock(); items.append(p); lock.unlock() }
    var all: [CommandProfile] { lock.lock(); defer { lock.unlock() }; return items }
}
