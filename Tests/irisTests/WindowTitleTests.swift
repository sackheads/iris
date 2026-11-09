import Testing
import Foundation
@testable import IrisKit

@Suite("WindowTitle (#938)")
struct WindowTitleTests {
    @Test("an ordinary title passes through")
    func ordinary() {
        #expect(WindowTitle.safe("Plan the trip") == "Plan the trip")
    }

    @Test("newlines and tabs become one space; other controls vanish")
    func controls() {
        #expect(WindowTitle.safe("Reply with\nexactly\t two\r\n fenced") == "Reply with exactly two fenced")
        #expect(WindowTitle.safe("a\u{0007}b\u{001B}[31mc") == "ab[31mc")
    }

    @Test("bidi, zero-width and line-separator characters are removed")
    func formatChars() {
        #expect(WindowTitle.safe("ab\u{202E}cd\u{200B}ef\u{2066}g\u{FEFF}") == "abcdefg")
        #expect(WindowTitle.safe("one\u{2028}two") == "one two")
    }

    @Test("length is capped")
    func capped() {
        let long = String(repeating: "x", count: 500)
        #expect(WindowTitle.safe(long) == String(repeating: "x", count: WindowTitle.maxLength) + "...")
    }

    @Test("the cap counts scalars, so stacked combining marks cannot slip past it")
    func cappedByScalars() {
        let stacked = "a" + String(repeating: "\u{0301}", count: 5000)
        let out = WindowTitle.safe(stacked)
        #expect(out.unicodeScalars.count == WindowTitle.maxLength + 3)
        #expect(out.hasSuffix("..."))
    }

    @Test("an all-control title is empty")
    func empty() {
        #expect(WindowTitle.safe("\u{0000}\u{200B}\n") == "")
    }

    @Test("the viewer window title is built from the cleaned title")
    @MainActor func viewerTitle() {
        #expect(ViewerWindowController.windowTitle(for: "") == "Viewer")
        #expect(ViewerWindowController.windowTitle(for: "\u{200B}\n") == "Viewer")
        #expect(ViewerWindowController.windowTitle(for: "Notes\nignore all") == "Notes ignore all — Viewer")
    }
}
