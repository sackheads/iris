import Testing
import Foundation
@testable import iris

/// The chat shows "Interrupted." or an error pill, but the model never sees those. A turn that
/// ends early must leave a marker in history, or the next turn finds an unanswered request above
/// the new message and finishes it unasked (#175).
@MainActor
@Suite("Turn ended early marker (#175)")
struct TurnMarkerTests {
    private func session(_ client: any LLMClientProtocol) -> (AppState, IrisEngine, UUID) {
        let app = AppState()
        app.autoApproveTools = true
        let id = UUID()
        app.createNewConversation(id: id)
        let engine = IrisEngine(state: app, tier: .medium, principal: .main, client: client, retryDelays: [], streamResponses: true)
        return (app, engine, id)
    }
    private func history(_ app: AppState, _ id: UUID) -> [Content] { app.conversations.first { $0.id == id }!.history }
    private func agentTexts(_ app: AppState, _ id: UUID) -> [String] {
        app.conversations.first { $0.id == id }!.messages.filter { $0.role == .agent }.map(\.content)
    }
    private var overloaded: APIError {
        APIError.http(provider: "Gemini", statusCode: 503, body: Data(#"{"error":{"message":"busy","status":"UNAVAILABLE"}}"#.utf8))
    }

    @Test("Stop records the marker after the partial text, and the next turn's request carries it before the new message")
    func stopRecordsMarker() async throws {
        let client = ScriptedStreamClient([[.event(.textDelta("part")), .hang],
                                           [.event(.textDelta("ok")), .event(.done(finishReason: nil))]])
        let (app, engine, id) = session(client)
        let turn = Task { await engine.processInput("first", source: "UI", conversationId: id) }
        for _ in 0..<300 where agentTexts(app, id).isEmpty { try? await Task.sleep(nanoseconds: 10_000_000) }
        turn.cancel()
        await turn.value
        let h = history(app, id)
        #expect(h.count == 3)
        #expect(h[1].role == "model" && h[1].parts.first?.text == "part")
        let marker = try #require(h.last?.parts.first?.text)
        #expect(h.last?.role == "user")
        #expect(marker.hasPrefix("\(IrisEngine.turnEndedEarlyPrefix): The user stopped this turn."))
        #expect(marker.contains("Do not resume the request above on your own"))

        await engine.processInput("next", source: "UI", conversationId: id)
        let contents = try #require(client.requests.last?.contents)
        #expect(contents.count >= 2)
        #expect(contents[contents.count - 2].parts.first?.text?.hasPrefix(IrisEngine.turnEndedEarlyPrefix) == true)
        #expect(contents.last?.parts.first?.text == "next")
        #expect(agentTexts(app, id) == ["part", "ok"])
    }

    @Test("a provider failure records the marker with the error headline")
    func providerFailureRecordsMarker() async throws {
        let client = ScriptedStreamClient([[.event(.textDelta("partial ")), .fail(overloaded)]])
        let (app, engine, id) = session(client)
        await engine.processInput("hi", source: "UI", conversationId: id)
        let marker = try #require(history(app, id).last?.parts.first?.text)
        #expect(marker.hasPrefix("\(IrisEngine.turnEndedEarlyPrefix): The model call failed ("))
        #expect(marker.contains("Gemini HTTP 503"))
    }

    @Test("an empty reply records the marker with the provider's reason")
    func emptyReplyRecordsMarker() async throws {
        let client = ScriptedStreamClient([[.event(.done(finishReason: "SAFETY"))]])
        let (app, engine, id) = session(client)
        await engine.processInput("hi", source: "UI", conversationId: id)
        let h = history(app, id)
        #expect(h.count == 2)
        let marker = try #require(h.last?.parts.first?.text)
        #expect(marker.hasPrefix("\(IrisEngine.turnEndedEarlyPrefix): The model returned no content (finishReason: SAFETY)."))
    }

    @Test("a turn that ends normally leaves no marker")
    func normalEndHasNoMarker() async {
        let client = ScriptedStreamClient([[.event(.textDelta("done")), .event(.done(finishReason: "STOP"))]])
        let (app, engine, id) = session(client)
        await engine.processInput("hi", source: "UI", conversationId: id)
        let h = history(app, id)
        #expect(h.count == 2)
        #expect(h.last?.role == "model")
    }

    @Test("a prompt already shaped as a System Event is not wrapped a second time")
    func preWrappedSystemEventNotDoubleWrapped() async throws {
        let client = ScriptedStreamClient([[.event(.textDelta("ok")), .event(.done(finishReason: nil))]])
        let (app, engine, id) = session(client)
        await engine.processInput("System Event [Rename Trigger]: rename it", source: "System", conversationId: id)
        let text = try #require(history(app, id).first?.parts.first?.text)
        #expect(text.hasPrefix("System Event [Rename Trigger]: rename it"))
        #expect(!text.contains("System Event [System]"))
        #expect(text.contains("Analyze this event"))
        let plain = ScriptedStreamClient([[.event(.textDelta("ok")), .event(.done(finishReason: nil))]])
        let (app2, engine2, id2) = session(plain)
        await engine2.processInput("job fired", source: "Scheduler", conversationId: id2)
        #expect(history(app2, id2).first?.parts.first?.text?.hasPrefix("System Event [Scheduler]: job fired") == true)
    }
}
