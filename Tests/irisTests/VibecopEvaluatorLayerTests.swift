import Testing
@testable import IrisKit

@Suite("Vibecop evaluator layer")
struct VibecopEvaluatorLayerTests {
    @Test("the evaluator caller role tightens the prompt and lists the allowed checks")
    func buildsGraderPrompt() {
        // The prompt assembly for the evaluator layer is exposed as a pure helper for testability.
        let text = VibecopService.evaluatorLayerText(allowedCommands: ["swift test", "swift build"])
        #expect(text.contains("CALLER ROLE: EVALUATOR"))
        #expect(text.contains("swift test"))
        #expect(text.contains("must not modify"))
    }
}
