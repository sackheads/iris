import Foundation

enum EmojiTokenizer {
    private static let colon = unichar(UInt16(UnicodeScalar(":").value))
    private static let allowed = CharacterSet(charactersIn:
        "abcdefghijklmnopqrstuvwxyzABCDEFGHIJKLMNOPQRSTUVWXYZ0123456789_+-")

    private static func isAllowed(_ c: unichar) -> Bool {
        guard let s = Unicode.Scalar(c) else { return false }
        return allowed.contains(s)
    }
    private static func isBoundary(before colon: Int, in text: NSString) -> Bool {
        guard colon > 0 else { return true }
        guard let s = Unicode.Scalar(text.character(at: colon - 1)) else { return true }
        return CharacterSet.whitespacesAndNewlines.contains(s)
    }

    /// The `:query` token the caret currently sits at the end of. A token is a `:`
    /// at a word boundary followed by allowed chars, with the caret within the run.
    static func activeToken(in text: NSString, caret: Int) -> (query: String, range: NSRange)? {
        guard caret >= 1, caret <= text.length else { return nil }
        var i = caret
        while i > 0 {
            let c = text.character(at: i - 1)
            if c == colon {
                let open = i - 1
                guard isBoundary(before: open, in: text) else { return nil }
                let queryLen = caret - i
                guard queryLen > 0 else { return nil }
                let query = text.substring(with: NSRange(location: i, length: queryLen))
                return (query, NSRange(location: open, length: caret - open))
            }
            if !isAllowed(c) { return nil }
            i -= 1
        }
        return nil
    }

    /// Reads a `:content:` segment whose closing colon is at `closing`. Returns the
    /// content and the opening colon index, or nil if the pattern doesn't hold.
    private static func segment(endingAt closing: Int, in text: NSString) -> (content: String, open: Int)? {
        guard closing >= 1, text.character(at: closing) == colon else { return nil }
        var i = closing
        while i > 0 {
            let c = text.character(at: i - 1)
            if c == colon {
                let open = i - 1
                let len = closing - i
                guard len > 0 else { return nil }
                return (text.substring(with: NSRange(location: i, length: len)), open)
            }
            if !isAllowed(c) { return nil }
            i -= 1
        }
        return nil
    }

    /// If a complete `:code:` (optionally `:code::skin-tone-N:`) ends exactly at the
    /// caret and resolves, return the glyph and the UTF-16 range to replace.
    static func completedReplacement(in text: NSString, caret: Int,
                                     catalog: EmojiCatalog,
                                     defaultTone: SkinTone) -> (glyph: String, range: NSRange)? {
        guard caret >= 1, text.character(at: caret - 1) == colon else { return nil }
        guard let last = segment(endingAt: caret - 1, in: text) else { return nil }

        if let tone = SkinTone.fromModifier(last.content) {
            // Form: :code::skin-tone-N:  — a base segment closes at last.open - 1.
            guard last.open >= 1, text.character(at: last.open - 1) == colon,
                  let base = segment(endingAt: last.open - 1, in: text),
                  isBoundary(before: base.open, in: text),
                  let glyph = catalog.glyph(for: base.content, tone: tone) else { return nil }
            return (glyph, NSRange(location: base.open, length: caret - base.open))
        } else {
            // Form: :code:  — apply the default tone (ignored when unsupported).
            guard isBoundary(before: last.open, in: text),
                  let glyph = catalog.glyph(for: last.content, tone: defaultTone) else { return nil }
            return (glyph, NSRange(location: last.open, length: caret - last.open))
        }
    }
}
