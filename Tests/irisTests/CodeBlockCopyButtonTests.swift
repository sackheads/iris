import AppKit
import Testing
@testable import IrisKit

@MainActor
@Suite("CodeBlockCopyButton puts a code block's text on the clipboard (#32)")
struct CodeBlockCopyButtonTests {

    private final class RecordingPasteboard: CodeBlockPasteboard {
        var calls: [String] = []
        func clearContents() -> Int { calls.append("clear"); return 0 }
        func setString(_ string: String, forType dataType: NSPasteboard.PasteboardType) -> Bool {
            calls.append("string:\(string)"); return true
        }
    }

    @Test("clears before writing, so no poll ever sees a mix of old and new contents")
    func clearsFirst() {
        let board = RecordingPasteboard()
        CodeBlockCopyButton.copy("let x = 1", to: board)
        #expect(board.calls == ["clear", "string:let x = 1"])
    }

    @Test("writes the code block's own text, not a markdown-escaped or truncated form")
    func writesVerbatim() throws {
        let board = NSPasteboard(name: NSPasteboard.Name("iris-test-\(UUID().uuidString)"))
        defer { board.releaseGlobally() }
        let code = "func f() -> Int {\n    return 1\n}\n"
        CodeBlockCopyButton.copy(code, to: board)
        #expect(board.string(forType: .string) == code)
    }
}
