import Testing
@testable import IrisKit

@Suite("Sandbox Setup Hint Tests")
struct SandboxSetupHintTests {

    @Test("maps a not-ready container runtime error to an actionable message")
    func testNotReadyErrorsMapped() {
        let notReady = [
            "Error: unauthorized request",
            "Error: Plugins are unavailable. Start the container system services and retry:",
            "No default kernel configured.",
            "Error: failed to read user input",
        ]
        for raw in notReady {
            let hint = ToolExecutor.sandboxSetupHint(for: raw)
            #expect(hint != nil, "expected a hint for: \(raw)")
            #expect(hint?.contains("container system start") == true)
            #expect(hint?.contains("disable sandboxing") == true)
        }
    }

    @Test("returns nil for ordinary command output (no false positives)")
    func testOrdinaryOutputPassesThrough() {
        #expect(ToolExecutor.sandboxSetupHint(for: "hello\n") == nil)
        #expect(ToolExecutor.sandboxSetupHint(for: "On branch main\nnothing to commit") == nil)
        #expect(ToolExecutor.sandboxSetupHint(for: "Success") == nil)
    }
}
