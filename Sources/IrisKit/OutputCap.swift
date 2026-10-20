import Foundation

/// #709: the size of every tool result the model sees, and so of every tool result the injection
/// guard judges. Applied once, where results reach the guard (`IrisEngine.executeToolWithHooks`):
/// a long result keeps its head and its tail, with one line between them saying what was left out
/// and how to read it. Named constants, not settings (planner's ruling).
enum OutputCap {
    /// The first part of a long result kept: a build log's useful head.
    static let headBytes = 24 * 1024
    /// The last part kept: where a failing command's error usually is.
    static let tailBytes = 8 * 1024
    static var limitBytes: Int { headBytes + tailBytes }
    /// The most of each output stream a `run_command` keeps in memory while it runs. Past it the
    /// bytes are read and dropped, so the command never blocks on a full pipe.
    static let drainBytes = 10 * 1024 * 1024

    /// What the truncation line tells the model to do about the lines it didn't see.
    enum Advice: Equatable {
        case none
        /// `read_file`'s own range: the first line of this result is line `startLine` of the file.
        case readFile(startLine: Int)
        case runCommand
    }

    /// `text` as the model sees it: whole when it fits, else its head and tail cut on line
    /// boundaries (on a character boundary when a line is longer than the part), never inside a
    /// UTF-8 character.
    /// `droppedBytes` is what a bounded drain already left out of `text`'s middle (a command's
    /// output past `drainBytes`), counted in the line so the totals stay true.
    static func cap(_ text: String, advice: Advice = .none, droppedBytes: Int = 0) -> String {
        let bytes = Array(text.utf8)
        guard bytes.count > limitBytes || droppedBytes > 0 else { return text }
        guard bytes.count > limitBytes else {
            return text + (text.hasSuffix("\n") ? "" : "\n") + "[output truncated: \(droppedBytes) bytes from the middle weren't kept\(advice.sentence(firstHidden: 1, hidden: 0, lines: false))]"
        }
        let headEnd = cutBack(bytes, from: headBytes)
        let tailStart = cutForward(bytes, from: bytes.count - tailBytes, notBefore: headEnd)
        let head = bytes[..<headEnd], tail = bytes[tailStart...]
        let totalLines = lineCount(bytes[...])
        let headLines = newlines(head)
        let tailLines = lineCount(tail)
        let hidden = max(0, totalLines - headLines - tailLines)
        let total = droppedBytes > 0 ? "at least \(totalLines)" : "\(totalLines)"
        let line = "[output truncated: showed the first \(headLines) and the last \(tailLines) of \(total) lines "
            + "(\(head.count + tail.count) of \(bytes.count + droppedBytes) bytes)"
            + "\(advice.sentence(firstHidden: headLines + 1, hidden: hidden, lines: droppedBytes == 0))]"
        return String(decoding: head, as: UTF8.self) + (head.last == 0x0A ? "" : "\n") + line + "\n"
            + String(decoding: tail, as: UTF8.self)
    }

    /// How far a cut moves to reach a line boundary (#731 review). Farther than this, it stays
    /// where it is, on a character boundary: snapping to a newline at any distance turned a short
    /// first line and one huge line into a two-byte head.
    static let snapBytes = 1024

    /// Where the head ends: just after the last newline in the `snapBytes` before `limit`, or else
    /// at the last character boundary, so a long line is still cut cleanly.
    private static func cutBack(_ bytes: [UInt8], from limit: Int) -> Int {
        if let newline = bytes[max(0, limit - snapBytes)..<limit].lastIndex(of: 0x0A) { return newline + 1 }
        var end = limit
        while end > 0, bytes[end] & 0xC0 == 0x80 { end -= 1 }
        return end
    }

    /// Where the tail starts: just after the first newline in the `snapBytes` from `start`, or else
    /// at the first character boundary; never before the head's end.
    private static func cutForward(_ bytes: [UInt8], from start: Int, notBefore floor: Int) -> Int {
        let start = max(start, floor)
        if let newline = bytes[start..<min(bytes.count, start + snapBytes)].firstIndex(of: 0x0A),
           newline + 1 < bytes.count { return newline + 1 }
        var begin = start
        while begin < bytes.count, bytes[begin] & 0xC0 == 0x80 { begin += 1 }
        return begin
    }

    private static func newlines(_ slice: ArraySlice<UInt8>) -> Int { slice.reduce(0) { $0 + ($1 == 0x0A ? 1 : 0) } }

    /// Lines in `slice`, a last line without its newline counted too.
    private static func lineCount(_ slice: ArraySlice<UInt8>) -> Int {
        newlines(slice) + (slice.last.map { $0 == 0x0A ? 0 : 1 } ?? 0)
    }
}

extension OutputCap.Advice {
    /// `lines` is false when the counts aren't exact (a drain dropped part of the output), so no
    /// line numbers are offered.
    func sentence(firstHidden: Int, hidden: Int, lines: Bool = true) -> String {
        switch self {
        case .none: return ""
        case .readFile where !lines: return ""
        case .readFile(let startLine):
            return "; read the lines left out with read_file start_line=\(startLine + firstHidden - 1) line_count=\(hidden)"
        case .runCommand:
            return "; to see all of it, redirect the output to a file (`cmd > out.txt 2>&1`) and read it in parts with read_file's start_line and line_count"
        }
    }
}

/// `read_file`'s `start_line` and `line_count` (#709): the part of a file to return, counted in
/// lines from 1, so a result the cap cut can be read the rest of the way.
struct LineRange: Equatable, Sendable {
    let start: Int
    let count: Int?

    static func parse(start: JSONValue?, count: JSONValue?) -> Result<LineRange?, ToolMessage> {
        func number(_ value: JSONValue?, _ name: String) -> Result<Int?, ToolMessage> {
            switch value {
            case nil, .null?: return .success(nil)
            case .int(let n)?: return .success(n)
            case .double(let d)? where d.isFinite && d == d.rounded() && abs(d) < 1e15: return .success(Int(d))
            case .string(let text)?:
                let trimmed = text.trimmingCharacters(in: .whitespaces)
                if trimmed.isEmpty { return .success(nil) }
                if let n = Int(trimmed) { return .success(n) }
                return .failure(ToolMessage("Error: \(name) must be a whole number."))
            default: return .failure(ToolMessage("Error: \(name) must be a whole number."))
            }
        }
        let first: Int?, length: Int?
        switch number(start, "start_line") { case .failure(let m): return .failure(m); case .success(let v): first = v }
        switch number(count, "line_count") { case .failure(let m): return .failure(m); case .success(let v): length = v }
        if first == nil, length == nil { return .success(nil) }
        if let first, first < 1 { return .failure("Error: start_line counts from 1.") }
        if let length, length < 1 { return .failure("Error: line_count must be at least 1.") }
        return .success(LineRange(start: first ?? 1, count: length))
    }

    /// The lines of a read's text (never a failure's sentence: the caller only hands it content),
    /// or the text unchanged with no range. A start past the end says how many lines there are.
    /// The read itself is whole, so a range bounds what the model sees, not what's read; the read
    /// routes' own limits are what bound memory.
    static func apply(_ range: LineRange?, to text: String) -> String {
        guard let range else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        // A file ending in a newline has no line after it.
        let total = text.hasSuffix("\n") ? lines.count - 1 : lines.count
        guard range.start <= total else {
            return "Error: start_line \(range.start) is past the end of the file, which has \(total) line\(total == 1 ? "" : "s")."
        }
        let end = range.count.map { min(total, range.start - 1 + $0) } ?? total
        let picked = lines[(range.start - 1)..<end].joined(separator: "\n")
        return end < total || text.hasSuffix("\n") ? picked + "\n" : picked
    }
}
