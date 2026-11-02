import Testing
import MLXLMCommon
@testable import IrisKit

@Suite("MLXEngine caps a canary's generation (#845)")
struct MLXEngineTokenCapTests {
    /// A stub that babbles until the cap it is given, or a runaway bound of its own.
    private static func babbler(emitted: @escaping @Sendable (Int) -> Void = { _ in }) -> MLXEngine.Respond {
        { _, parameters in
            let limit = parameters.maxTokens ?? 100_000
            emitted(limit)
            return Array(repeating: "blah", count: limit).joined(separator: " ")
        }
    }

    @Test func aBabblingModelStopsAtTheCap() async throws {
        let engine = MLXEngine(respond: Self.babbler())
        let out = try await engine.generate(prompt: "p", jsonSchema: nil)
        #expect(out.split(separator: " ").count == 128)
    }

    @Test func theCapMatchesLlamaCPPs() {
        #expect(MLXEngine.maxTokens == 128)
        #expect(MLXEngine.generateParameters.maxTokens == 128)
    }

    @Test func aUnloadedEngineStillRefuses() async {
        await #expect(throws: (any Error).self) {
            _ = try await MLXEngine().generate(prompt: "p", jsonSchema: nil)
        }
    }
}
