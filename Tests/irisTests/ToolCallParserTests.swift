import Testing
import Foundation
@testable import IrisKit

@Suite("ToolCallParser")
struct ToolCallParserTests {
    private func msg(_ json: String) -> String { "[TOOL_CALL]\n" + json }

    @Test("run_command with command and intent")
    func withIntent() {
        let d = ToolCallParser.parse(msg(#"{"name":"run_command","args":{"command":"npm test","intent":"check the fix"}}"#))
        #expect(d == ToolCallDisplay(name: "run_command", command: "npm test", intent: "check the fix"))
    }

    @Test("run_command without intent")
    func noIntent() {
        let d = ToolCallParser.parse(msg(#"{"name":"run_command","args":{"command":"ls"}}"#))
        #expect(d?.command == "ls")
        #expect(d?.intent == nil)
    }

    @Test("non-run_command tool parses name, no command")
    func otherTool() {
        let d = ToolCallParser.parse(msg(#"{"name":"read_file","args":{"path":"/tmp/x"}}"#))
        #expect(d?.name == "read_file")
        #expect(d?.command == nil)
    }

    @Test("non-tool-call text returns nil")
    func notToolCall() {
        #expect(ToolCallParser.parse("Auto-continuing goal loop (iteration 2)...") == nil)
    }

    @Test("malformed JSON returns nil")
    func malformed() {
        #expect(ToolCallParser.parse(msg("{not json")) == nil)
    }

    @Test("empty intent is treated as nil")
    func emptyIntent() {
        let d = ToolCallParser.parse(msg(#"{"name":"run_command","args":{"command":"ls","intent":""}}"#))
        #expect(d?.intent == nil)
    }
}
