import Foundation
import Testing
@testable import IrisKit

/// #1437's experiment switch: `IRIS_PERF_SALT` gives a perf arm a system prompt of its own, so two arms run side by
/// side never read each other's cache entries, and nothing else about the request changes.
@MainActor
@Suite("A perf arm's salt is its system prompt's first line, and only that (#1437)", .timeLimit(.minutes(1)))
struct PerfSystemSaltTests {
    private func systemParts(salt: String?) async throws -> [String] {
        let state = AppState(store: try ConversationStore.inMemory(), tier2Provisioning: .provisioned,
                             tier3Provisioning: .provisioned, createIfEmpty: false, emitLaunchNotices: false)
        let id = state.createNewConversation(isBackground: false, select: true)
        let reply = GeminiResponse(candidates: [Candidate(content: Content(role: "model", parts: [Part(text: "ack")]))], usageMetadata: nil)
        let dumped = LockedBox<[GeminiRequest]>([])
        let engine = IrisEngine(state: state, tier: .medium, client: FakeLLMClient(responses: [reply]), retryDelays: [],
                                protectionEnabled: false, sessionPeerCount: 0,
                                requestDumpSink: { request, _, _ in dumped.withLock { $0.append(request) } },
                                perfSystemSalt: salt)
        await engine.processInput("tick", source: "Loop", conversationId: id)
        let request = try #require(dumped.withLock { $0 }.first)
        return (request.systemInstruction?.parts ?? []).compactMap(\.text)
    }

    @Test("the salt is prepended as its own part; without it the system prompt is unchanged")
    func saltIsFirstPartOnly() async throws {
        let plain = try await systemParts(salt: nil)
        let salted = try await systemParts(salt: "1h")
        #expect(salted.first == "[perf arm: 1h]")
        #expect(Array(salted.dropFirst()) == plain, "nothing but the salt differs")
        #expect(!plain.joined().contains("[perf arm:"))
    }

    @Test("IRIS_PERF_SALT is read from the environment; empty or absent is no salt")
    func environment() {
        #expect(PerfExperiments.fromEnvironment(["IRIS_PERF_SALT": "5m"]).systemSalt == "5m")
        #expect(PerfExperiments.fromEnvironment(["IRIS_PERF_SALT": ""]).systemSalt == nil)
        #expect(PerfExperiments.fromEnvironment([:]).systemSalt == nil)
    }
}
