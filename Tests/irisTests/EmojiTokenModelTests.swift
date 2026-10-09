import Testing
import Foundation
@testable import IrisKit

@MainActor
@Suite("EmojiTokenModel")
struct EmojiTokenModelTests {
    @Test("update populates suggestions for a valid query")
    func populates() {
        let m = EmojiTokenModel()
        m.update(text: "hi :sm" as NSString, caret: 6)
        #expect(m.isShowing)
        #expect(m.activeRange == NSRange(location: 3, length: 3))
    }

    @Test("query shorter than the minimum clears the popup")
    func tooShort() {
        let m = EmojiTokenModel()
        m.update(text: "hi :s" as NSString, caret: 5)
        #expect(!m.isShowing)
    }

    @Test("moveSelection wraps around")
    func wraps() {
        let m = EmojiTokenModel()
        m.update(text: ":smi" as NSString, caret: 4)
        #expect(m.selectedIndex == 0)
        m.moveSelection(-1)
        #expect(m.selectedIndex == m.suggestions.count - 1)
        m.moveSelection(1)
        #expect(m.selectedIndex == 0)
    }

    @Test("commitSelection returns a glyph and the active range")
    func commit() {
        let m = EmojiTokenModel()
        m.update(text: ":smile" as NSString, caret: 6)
        let c = m.commitSelection()
        #expect(c?.glyph == "😄")
        #expect(c?.range == NSRange(location: 0, length: 6))
    }

    @Test("commitSelected forwards to performReplace and clears")
    func commitSelected() {
        let m = EmojiTokenModel()
        var captured: (String, NSRange)? = nil
        m.performReplace = { g, r in captured = (g, r) }
        m.update(text: ":smile" as NSString, caret: 6)
        m.commitSelected()
        #expect(captured?.0 == "😄")
        #expect(!m.isShowing)
    }

    @Test("displayGlyph honors the default tone")
    func toned() {
        let m = EmojiTokenModel()
        m.defaultTone = .medium
        let item = EmojiItem(shortcode: "wave", glyph: "👋", supportsSkinTone: true)
        #expect(m.displayGlyph(for: item) == "👋🏽")
    }
}
