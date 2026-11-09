import Testing
import Foundation

/// #968: the user bubble renders through the agent bubble's Markdown helper, and that helper must
/// never take `.textSelection` (the AttributeGraph cycle, #28). Source scans: the view is not
/// constructible in a test, and the regression is a one-line edit.
@Suite("User bubble markdown (#968)", .timeLimit(.minutes(1)))
struct UserBubbleMarkdownTests {
    private static func chatViewSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        return try String(contentsOf: root.appendingPathComponent("Sources/IrisKit/ChatView.swift"), encoding: .utf8)
    }

    private static func helperBody(_ src: String) throws -> String {
        let start = try #require(src.range(of: "private func messageMarkdown("))
        let rest = src[start.upperBound...]
        let end = try #require(rest.range(of: "\n    }\n"))
        return String(rest[..<end.lowerBound])
    }

    @Test("the helper applies no .textSelection outside comments")
    func helperHasNoTextSelection() throws {
        let code = try Self.helperBody(Self.chatViewSource()).split(separator: "\n")
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
        #expect(!code.contains { $0.contains(".textSelection") })
    }

    @Test("the user bubble and the agent bubble both go through the helper")
    func bothBubblesUseHelper() throws {
        let src = try Self.chatViewSource()
        #expect(src.contains("messageMarkdown(message.content)"))
        #expect(src.contains("messageMarkdown(state.liveContent(of: message))"))
    }

    @Test("the user call site keeps typed newlines as line breaks")
    func userBubbleKeepsLineBreaks() throws {
        let src = try Self.chatViewSource()
        let call = try #require(src.range(of: "messageMarkdown(message.content)"))
        let next = src[call.upperBound...].prefix(80)
        #expect(next.contains(".markdownSoftBreakMode(.lineBreak)"))
    }
}
