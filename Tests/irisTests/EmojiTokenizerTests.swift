import Testing
import Foundation
@testable import IrisKit

@Suite("EmojiTokenizer")
struct EmojiTokenizerTests {
    let catalog = EmojiCatalog.shared

    private func token(_ s: String, _ caret: Int? = nil) -> (query: String, range: NSRange)? {
        let ns = s as NSString
        return EmojiTokenizer.activeToken(in: ns, caret: caret ?? ns.length)
    }
    private func replace(_ s: String, tone: SkinTone = .none) -> (glyph: String, range: NSRange)? {
        let ns = s as NSString
        return EmojiTokenizer.completedReplacement(in: ns, caret: ns.length, catalog: catalog, defaultTone: tone)
    }

    @Test("active token at start of text")
    func atStart() {
        let t = token(":sm")
        #expect(t?.query == "sm")
        #expect(t?.range == NSRange(location: 0, length: 3))
    }

    @Test("active token mid-sentence")
    func midSentence() {
        let t = token("nice work :wav")
        #expect(t?.query == "wav")
        #expect(t?.range == NSRange(location: 10, length: 4))
    }

    @Test("time colon is not a token")
    func timeColon() {
        #expect(token("meet at 10:30") == nil)
    }

    @Test("mid-word colon is not a token")
    func midWord() {
        #expect(token("foo:bar") == nil)
    }

    @Test("bare colon is not a token")
    func bareColon() {
        #expect(token(":") == nil)
    }

    @Test("complete code replaces")
    func completeCode() {
        let r = replace("hi :smile:")
        #expect(r?.glyph == "😄")
        #expect(r?.range == NSRange(location: 3, length: 7))
    }

    @Test("explicit skin-tone modifier replaces and overrides default")
    func explicitTone() {
        let r = replace("hey :wave::skin-tone-4:", tone: .dark)
        #expect(r?.glyph == "👋🏽")
        #expect(r?.range == NSRange(location: 4, length: 19))
    }

    @Test("default tone applies to a bare capable emoji")
    func defaultTone() {
        #expect(replace(":wave:", tone: .medium)?.glyph == "👋🏽")
    }

    @Test("default tone ignored on non-capable emoji")
    func defaultToneIgnored() {
        #expect(replace(":rocket:", tone: .dark)?.glyph == "🚀")
    }

    @Test("invalid code is left literal")
    func invalid() {
        #expect(replace(":notacode:") == nil)
    }

    @Test("lone skin-tone modifier is left literal")
    func loneTone() {
        #expect(replace(":skin-tone-3:") == nil)
    }
}
