import Testing
import Foundation
@testable import IrisKit

/// #797: the canary's `/api/generate` call had no timeout, so URLSession's 60 s default applied
/// and a slow 32 KB tool result (61.0 s measured) failed tier 3 closed. The call has its own
/// bound now; a call that still runs out of time still throws.
@Suite("Ollama generate timeout (#797)", .timeLimit(.minutes(1)))
struct OllamaGenerateTimeoutTests {
    @Test func aRequestWithNoTimeoutGetsURLSessionsSixtySeconds() {
        // The defect: this is what `generate` sent.
        #expect(OllamaEngine.Transport.request("generate", Data()).timeoutInterval == 60)
    }

    @Test func theGenerateRequestOutlastsTheSlowestMeasuredCall() {
        let bound = OllamaEngine.Transport.generateTimeout
        #expect(bound > 61, "#797's 32 KB join took 61.0 s")
        #expect(bound <= 600, "still bounded: a hung server must not hold a turn for ever")
        #expect(OllamaEngine.Transport.generateRequest(Data()).timeoutInterval == bound)
    }

    @Test func aCallThatTimesOutStillFailsClosed() async throws {
        var transport = OllamaEngine.Transport(ps: { nil }, preload: { _ in (200, Data("{}".utf8)) })
        transport.generate = { _ in throw URLError(.timedOut) }
        let engine = OllamaEngine(tracker: ModelLoadTracker(log: { _ in }), transport: transport)
        try await engine.loadModel(config: AuxiliaryModelConfig(role: "canary", engineType: .ollama, modelPathOrName: "gemma4:12b"))
        if let task = await engine.pendingPreload { try await value(of: task, within: 10) }
        await #expect(throws: URLError.self) { _ = try await engine.generate(prompt: "p", jsonSchema: nil) }
    }
}
