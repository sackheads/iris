import Testing
import Foundation
@testable import iris

/// The transcript sheet (#19) has to know roughly how tall its content is BEFORE the first layout
/// pass: a macOS `.sheet` takes its window size from the content's ideal size at presentation and
/// does not grow afterwards. These pin the pre-layout estimate and the clamp around it.
@Suite("TranscriptSizing")
struct TranscriptSizingTests {
    @Test("no messages estimate to zero")
    func empty() {
        #expect(TranscriptSizing.estimatedContentHeight(messages: [], width: 560) == 0)
    }

    @Test("one short line is a single row, not a screenful")
    func shortLine() {
        let h = TranscriptSizing.estimatedContentHeight(messages: [(role: ChatRole.agent, content: "Done.")], width: 560)
        #expect(h > 20)
        #expect(h < 90)
    }

    @Test("explicit newlines each add a line")
    func newlines() {
        let one = TranscriptSizing.estimatedContentHeight(messages: [(role: ChatRole.agent, content: "a")], width: 560)
        let forty = TranscriptSizing.estimatedContentHeight(
            messages: [(role: ChatRole.agent, content: Array(repeating: "a", count: 40).joined(separator: "\n"))], width: 560)
        #expect(forty - one > 39 * 12)
    }

    @Test("long text wraps and grows with width shrinking")
    func wraps() {
        let text = String(repeating: "kernel version details ", count: 30)
        let wide = TranscriptSizing.estimatedContentHeight(messages: [(role: ChatRole.user, content: text)], width: 900)
        let narrow = TranscriptSizing.estimatedContentHeight(messages: [(role: ChatRole.user, content: text)], width: 480)
        #expect(narrow > wide)
    }

    @Test("every message adds its own chrome")
    func perMessageChrome() {
        let one = TranscriptSizing.estimatedContentHeight(messages: [(role: ChatRole.agent, content: "a")], width: 560)
        let two = TranscriptSizing.estimatedContentHeight(messages: [(role: ChatRole.agent, content: "a"), (role: ChatRole.user, content: "b")], width: 560)
        #expect(two > one + 20)
    }

    @Test("system rows render as compact cards, so their raw text is capped")
    func systemRowsCapped() {
        let short = TranscriptSizing.estimatedContentHeight(messages: [(role: ChatRole.system, content: "$ ls")], width: 560)
        let long = TranscriptSizing.estimatedContentHeight(
            messages: [(role: ChatRole.system, content: String(repeating: "<untrusted_context> tool output line\n", count: 40))], width: 560)
        #expect(long - short <= TranscriptSizing.systemRowTextCap)
        #expect(long < 160)
    }

    @Test("sheet height clamps content plus chrome into the allowed band")
    func clamp() {
        #expect(TranscriptSizing.sheetHeight(forContent: 0) == TranscriptSizing.minSheetHeight)
        #expect(TranscriptSizing.sheetHeight(forContent: 300) == 300 + TranscriptSizing.chromeHeight)
        #expect(TranscriptSizing.sheetHeight(forContent: 10_000) == TranscriptSizing.maxSheetHeight)
    }
}
