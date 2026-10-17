import Foundation

/// Splits a reply that is still streaming into completed Markdown blocks and a live tail (#541).
///
/// A streamed reply re-rendered as one Markdown document re-parses and re-lays out every block on
/// every update, so each update cost more the longer the reply grew. A stream only appends, so
/// text before a safe cut never changes: the row renders each completed block once, as its own
/// view, and only the tail re-renders per token. At the final write the row goes back to one
/// Markdown over the whole message.
///
/// A cut is made only where the blocks either side render the same apart as together (the
/// CommonMark reasons are in `update`); when unsure, it does not cut. A text with a link reference
/// definition or an HTML block anywhere is never split: both reach across blank lines (a
/// definition resolves document-wide, an HTML block can hold blank lines), so the whole text is the
/// tail. `StreamingBlocksTests` checks that the split renders like the whole at every prefix.
///
/// Incremental: each update scans only the lines completed since the last one, resuming from the
/// saved fence and blank-line state, so the scan costs nothing that grows with the reply.
struct StreamingBlocks {
    private(set) var blocks: [String] = []
    /// The whole text renders unsplit: it has a link reference definition or an HTML block.
    private(set) var disabled = false
    /// Bytes examined so far, across every update: for the test that the scan is incremental.
    private(set) var scannedBytes = 0

    private enum Kind { case none, list, quote, other }

    private var length = 0            // bytes of text seen
    private var blockStart = 0        // where the block being built starts
    private var scanPos = 0           // the start of the first line not yet scanned
    private var blankStart: Int?      // where a run of blank lines after the block began
    private var kind = Kind.none      // the block's kind, from its first line
    private var fence: (char: UInt8, length: Int)?
    #if DEBUG
    private var lastBlock: (start: Int, bytes: [UInt8])?
    #endif

    /// Takes the reply as it now reads (the previous text plus what arrived) and returns the tail.
    mutating func update(_ text: String) -> String {
        var text = text
        return text.withUTF8 { bytes in
            precondition(bytes.count >= length, "a stream only appends")
            #if DEBUG
            // A block, once cut, never changes: the most recent one is checked, bounded in cost.
            if let last = lastBlock {
                assert(Array(bytes[last.start ..< last.start + last.bytes.count]) == last.bytes,
                       "a completed block changed")
            }
            #endif
            length = bytes.count
            guard !disabled else { return String(decoding: bytes, as: UTF8.self) }
            while let newline = Self.newline(in: bytes, from: scanPos) {
                scannedBytes += newline + 1 - scanPos
                scanLine(bytes, scanPos, newline)
                scanPos = newline + 1
                if disabled {
                    blocks = []
                    return String(decoding: bytes, as: UTF8.self)
                }
            }
            // A definition counts as one before its line ends (`[d]: h` already resolves `[d]`
            // above), so the line still arriving is checked too. Bounded: the check reads the
            // label, not the line.
            if fence == nil, scanPos < bytes.count, Self.isLinkDefinition(bytes[scanPos ..< bytes.count]) {
                disabled = true
                blocks = []
                return String(decoding: bytes, as: UTF8.self)
            }
            return String(decoding: bytes[blockStart...], as: UTF8.self)
        }
    }

    private static func newline(in bytes: UnsafeBufferPointer<UInt8>, from start: Int) -> Int? {
        var i = start
        while i < bytes.count {
            if bytes[i] == 0x0A { return i }
            i += 1
        }
        return nil
    }

    /// One complete line, `bytes[start..<end]` (its newline at `end`).
    private mutating func scanLine(_ bytes: UnsafeBufferPointer<UInt8>, _ start: Int, _ end: Int) {
        let line = bytes[start ..< end]
        if let open = fence {
            if Self.closesFence(line, open) { fence = nil }
            return
        }
        if Self.isBlank(line) {
            if blankStart == nil { blankStart = start }
            return
        }
        if Self.isLinkDefinition(line) || Self.opensHTMLBlock(line) {
            disabled = true
            return
        }
        if let blank = blankStart {
            blankStart = nil
            // Cut before this line only when it starts a block the one above cannot run into:
            // indented, it continues a list item, an indented code block or the like; a list
            // marker after a list keeps one list (split, a loose list became two tight ones); a
            // quote marker after a quote is kept the same way.
            let indented = line.first == 0x20 || line.first == 0x09
            let continuesList = kind == .list && Self.isListMarker(line)
            let continuesQuote = kind == .quote && Self.isQuote(line)
            if !indented && !continuesList && !continuesQuote && kind != .none {
                cut(bytes, at: start, blockEnd: blank)
            }
        }
        if kind == .none { kind = Self.kind(of: line) }
        if let open = Self.opensFence(line) { fence = open }
    }

    private mutating func cut(_ bytes: UnsafeBufferPointer<UInt8>, at start: Int, blockEnd: Int) {
        let block = Array(bytes[blockStart ..< blockEnd])
        blocks.append(String(decoding: block, as: UTF8.self))
        #if DEBUG
        lastBlock = (blockStart, block)
        #endif
        blockStart = start
        kind = .none
    }

    // MARK: Line tests (CommonMark, conservatively)

    private static func indent(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Int {
        var n = 0
        for b in line { if b == 0x20 { n += 1 } else { break } }
        return n
    }

    private static func isBlank(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        line.allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }

    /// Up to three spaces in, the rest of the line after them.
    private static func body(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Slice<UnsafeBufferPointer<UInt8>>? {
        let n = indent(line)
        return n <= 3 ? line.dropFirst(n) : nil
    }

    private static func kind(of line: Slice<UnsafeBufferPointer<UInt8>>) -> Kind {
        if isListMarker(line) { return .list }
        if isQuote(line) { return .quote }
        return .other
    }

    private static func isQuote(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        body(line)?.first == UInt8(ascii: ">")
    }

    /// `-`, `*`, `+` or 1-9 digits then `.` or `)`, followed by a space, a tab or the line's end.
    private static func isListMarker(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        guard let b = body(line), let first = b.first else { return false }
        var rest = b.dropFirst()
        if first == UInt8(ascii: "-") || first == UInt8(ascii: "*") || first == UInt8(ascii: "+") {
            // fallthrough to the space check
        } else if first >= 0x30 && first <= 0x39 {
            var digits = 1
            while let d = rest.first, d >= 0x30 && d <= 0x39 { digits += 1; rest = rest.dropFirst() }
            guard digits <= 9, let delimiter = rest.first,
                  delimiter == UInt8(ascii: ".") || delimiter == UInt8(ascii: ")") else { return false }
            rest = rest.dropFirst()
        } else {
            return false
        }
        guard let after = rest.first else { return true }
        return after == 0x20 || after == 0x09 || after == 0x0D
    }

    private static func opensFence(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> (char: UInt8, length: Int)? {
        guard let b = body(line), let c = b.first, c == UInt8(ascii: "`") || c == UInt8(ascii: "~") else { return nil }
        let run = b.prefix { $0 == c }.count
        guard run >= 3 else { return nil }
        // A backtick fence's info string cannot hold a backtick.
        if c == UInt8(ascii: "`"), b.dropFirst(run).contains(c) { return nil }
        return (c, run)
    }

    private static func closesFence(_ line: Slice<UnsafeBufferPointer<UInt8>>, _ open: (char: UInt8, length: Int)) -> Bool {
        guard let b = body(line) else { return false }
        let run = b.prefix { $0 == open.char }.count
        return run >= open.length && b.dropFirst(run).allSatisfy { $0 == 0x20 || $0 == 0x09 || $0 == 0x0D }
    }

    /// `[label]:` up to three spaces in.
    private static func isLinkDefinition(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        guard let b = body(line), b.first == UInt8(ascii: "[") else { return false }
        var sawLabel = false
        var i = b.index(after: b.startIndex)
        while i < b.endIndex {
            let c = b[i]
            if c == UInt8(ascii: "]") {
                let next = b.index(after: i)
                return sawLabel && next < b.endIndex && b[next] == UInt8(ascii: ":")
            }
            sawLabel = true
            i = b.index(after: i)
        }
        return false
    }

    /// CommonMark HTML blocks 1-5, which can hold blank lines: `<pre`, `<script`, `<style`,
    /// `<textarea`, `<!--`, `<?`, `<!X` and `<![CDATA[`.
    private static func opensHTMLBlock(_ line: Slice<UnsafeBufferPointer<UInt8>>) -> Bool {
        guard let b = body(line), b.first == UInt8(ascii: "<") else { return false }
        let after = String(decoding: b.dropFirst().prefix(9), as: UTF8.self).lowercased()
        if after.hasPrefix("!--") || after.hasPrefix("?") || after.hasPrefix("![cdata[") { return true }
        if after.hasPrefix("!"), let c = after.dropFirst().first, c.isLetter { return true }
        for tag in ["pre", "script", "style", "textarea"] where after.hasPrefix(tag) {
            let next = after.dropFirst(tag.count).first
            if next == nil || next == " " || next == ">" || next == "\t" || next == "\r" { return true }
        }
        return false
    }
}

import MarkdownUI

extension StreamingBlocks {
    /// How MarkdownUI reads `markdown`, as HTML: the structure the row renders, which the split
    /// must match the whole text's (`StreamingBlocksTests`).
    static func html(_ markdown: String) -> String { MarkdownContent(markdown).renderHTML() }
}
