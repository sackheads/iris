import Testing
import Foundation
@testable import IrisKit

@Suite("run_command intent")
struct RunCommandIntentTests {
    @Test("run_command exposes an optional intent property after augmentation")
    func schemaHasOptionalIntent() async {
        let tools = ToolIntent.augment(await ToolExecutor.shared.getTools())
        let runCmd = tools.first { $0.name == "run_command" }
        #expect(runCmd?.parameters?.properties?["intent"] != nil)
        #expect(runCmd?.parameters?.required?.contains("intent") != true)
    }

    @Test("execute runs the command and ignores intent")
    func executeIgnoresIntent() async {
        let result = await ToolExecutor.shared.execute(
            name: "run_command",
            args: ["command": .string("echo transparency_ok"), "intent": .string("verifying")],
            useSandbox: false)
        #expect(result.contains("transparency_ok"))
    }
}
