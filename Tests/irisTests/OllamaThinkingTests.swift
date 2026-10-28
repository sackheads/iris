import Testing
import Foundation
@testable import IrisKit

/// An engine asked not to think sends `think: false` to a thinking model only (#783); a model
/// without the capability, and every engine not asked, gets today's request.
@Suite("Ollama suppressThinking (#783)", .timeLimit(.minutes(1)))
struct OllamaThinkingTests {
    private final class Sent: @unchecked Sendable {
        private let lock = NSLock()
        private var bodies: [[String: Any]] = []
        private var shows = 0
        func add(_ data: Data) { lock.withLock { bodies.append((try? JSONSerialization.jsonObject(with: data) as? [String: Any]) ?? [:]) } }
        func showed() { lock.withLock { shows += 1 } }
        var all: [[String: Any]] { lock.withLock { bodies } }
        var showCount: Int { lock.withLock { shows } }
    }

    private static let reply = Data(#"{"response":"SAFE","done":true}"#.utf8)

    private func engine(suppress: Bool, capabilities: [String]?, sent: Sent) async throws -> OllamaEngine {
        var transport = OllamaEngine.Transport(ps: { nil }, preload: { _ in (200, Data("{}".utf8)) })
        transport.generate = { body in sent.add(body); return (200, Self.reply) }
        transport.show = { _ in
            sent.showed()
            guard let capabilities else { return nil }
            return try? JSONSerialization.data(withJSONObject: ["capabilities": capabilities])
        }
        let engine = OllamaEngine(tracker: ModelLoadTracker(log: { _ in }), transport: transport, suppressThinking: suppress)
        try await engine.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: "gemma4:12b"))
        if let task = await engine.pendingPreload { try await value(of: task, within: 10) }
        return engine
    }

    @Test func aThinkingModelIsAskedNotToThink() async throws {
        let sent = Sent()
        let engine = try await engine(suppress: true, capabilities: ["completion", "thinking"], sent: sent)
        #expect(try await engine.generate(prompt: "p", jsonSchema: nil) == "SAFE")
        _ = try await engine.generate(prompt: "p", jsonSchema: nil)
        #expect(sent.all.map { $0["think"] as? Bool } == [false, false])
        #expect(sent.showCount == 1, "the capability is asked once")
    }

    @Test func aModelThatDoesNotThinkGetsTodaysRequest() async throws {
        let sent = Sent()
        let engine = try await engine(suppress: true, capabilities: ["completion"], sent: sent)
        _ = try await engine.generate(prompt: "p", jsonSchema: nil)
        #expect(sent.all.count == 1)
        #expect(sent.all[0]["think"] == nil)
    }

    @Test func anUnansweredShowSendsNoThinkAndAsksAgain() async throws {
        let sent = Sent()
        let engine = try await engine(suppress: true, capabilities: nil, sent: sent)
        _ = try await engine.generate(prompt: "p", jsonSchema: nil)
        _ = try await engine.generate(prompt: "p", jsonSchema: nil)
        #expect(sent.all.allSatisfy { $0["think"] == nil })
        #expect(sent.showCount == 2)
    }

    @Test func anEngineNotAskedToSuppressNeverAsksOrSends() async throws {
        let sent = Sent()
        let engine = try await engine(suppress: false, capabilities: ["thinking"], sent: sent)
        _ = try await engine.generate(prompt: "p", jsonSchema: "vibecop_schema")
        #expect(sent.all.count == 1)
        #expect(sent.all[0]["think"] == nil)
        #expect(sent.all[0]["format"] as? String == "json")
        #expect(sent.showCount == 0)
    }

    @Test func aNon200ReplyStillThrows() async throws {
        var transport = OllamaEngine.Transport(ps: { nil }, preload: { _ in (200, Data("{}".utf8)) })
        transport.generate = { _ in (500, Data(#"{"error":"boom"}"#.utf8)) }
        transport.show = { _ in nil }
        let engine = OllamaEngine(tracker: ModelLoadTracker(log: { _ in }), transport: transport, suppressThinking: true)
        try await engine.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: "m"))
        await #expect(throws: (any Error).self) { _ = try await engine.generate(prompt: "p", jsonSchema: nil) }
    }
}
