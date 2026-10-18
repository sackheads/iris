import Testing
import Foundation
@testable import IrisKit

/// #634: Vibecop's verdict must not wait for the main actor. The 5 s bound
/// (`AppState.boundedVibecopVerdict`) wraps the whole evaluation, so a hop to a busy main actor
/// after the engine had answered turned an instant verdict into a timeout and a person prompt.
@MainActor
@Suite("A Vibecop evaluation finishes while the main actor is held (#634)", .timeLimit(.minutes(1)))
struct VibecopMainActorTests {
    private final class Engine: AuxiliaryInferenceEngine, @unchecked Sendable {
        let answer: Result<String, Error>
        init(_ answer: Result<String, Error>) { self.answer = answer }
        func loadModel(config: AuxiliaryModelConfig) async throws {}
        func unloadModel() async {}
        func generate(prompt: String, jsonSchema: String?) async throws -> String { try answer.get() }
    }

    private struct Down: Error {}

    @Test("approve, unparseable and failed answers all come back without the main actor",
          arguments: [Result<String, Error>.success(#"{"decision":"APPROVE","reason":"routine"}"#),
                      .success("not json"), .failure(Down())])
    func noMainActorHop(answer: Result<String, Error>) {
        let engine = Engine(answer)
        let done = DispatchSemaphore(value: 0)
        Task.detached {
            _ = try? await AuxiliaryModelManager.$scopedEngines.withValue(["vibecop": engine]) {
                try await VibecopService.shared.evaluateAction(toolName: "run_command", details: "ls", workspace: nil,
                                                               vibecopEnabled: true)
            }
            done.signal()
        }
        // This test holds the main actor while it waits, so an evaluation that hops to it cannot
        // finish until the wait gives up. Bounded, so a regression fails here instead of hanging.
        #expect(done.wait(timeout: .now() + 3) == .success, "the evaluation waited for the main actor")
    }
}
