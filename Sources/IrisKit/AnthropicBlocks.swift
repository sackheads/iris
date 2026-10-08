import Foundation

/// #314 decision 1: an Anthropic reply's content array as it arrived. The stream path renders it
/// from the blocks it folded. A tool_use block's input is never re-serialised: its `partial_json`
/// goes in verbatim, so the key order and number spelling the model produced are what goes back.
enum AnthropicBlocks {
    /// The block types Iris stores. A reply holding anything else stores nothing and is replayed
    /// from `parts`, as before #314 (plan note 7).
    static let storableTypes: Set<String> = ["text", "thinking", "redacted_thinking", "tool_use"]

    /// One streamed block, folded from its `content_block_start` and deltas.
    struct Streamed: Sendable, Equatable {
        var type: String
        var text = ""
        var thinking = ""
        var signature = ""
        var data = ""
        var id = ""
        var name = ""
        var json = ""
        /// Members of `content_block_start`'s block that `render` does not rebuild (a direct-API
        /// tool_use's `caller`), as `"key":value` bytes joined by commas, in arrival order.
        var extra = ""
        var stopped = false
    }

    /// The members `render` writes itself for a block of `type`; any other member of the block's
    /// `content_block_start` is carried verbatim in `Streamed.extra`.
    static func renderedKeys(_ type: String) -> Set<String> {
        switch type {
        case "thinking": return ["type", "thinking", "signature"]
        case "redacted_thinking": return ["type", "data"]
        case "tool_use": return ["type", "id", "name", "input"]
        default: return ["type", "text"]
        }
    }

    /// What the storage rules read from a block, from either path. A missing key reads as "".
    struct Shape: Sendable, Equatable {
        var type: String
        var signature = ""
        var text = ""
        var id = ""
        var stopped = true

        init(type: String, signature: String = "", text: String = "", id: String = "", stopped: Bool = true) {
            self.type = type; self.signature = signature; self.text = text; self.id = id; self.stopped = stopped
        }
        init(_ b: Streamed) {
            self.init(type: b.type, signature: b.signature, text: b.text, id: b.id, stopped: b.stopped)
        }
        init(_ o: [String: Any]) {
            self.init(type: o["type"] as? String ?? "", signature: o["signature"] as? String ?? "",
                      text: o["text"] as? String ?? "", id: o["id"] as? String ?? "")
        }
    }

    /// The one storage rule, for every path. False when the reply must not be stored: nothing to
    /// replay (no thinking block), a block that never stopped (the stream died inside it), a
    /// thinking block with no signature (cut before it was signed; replayed, it is a 400), or a
    /// type Iris does not store. `blocks` must be every block of the reply, in order.
    static func admits(_ blocks: [Shape]) -> Bool {
        !blocks.isEmpty
            && blocks.allSatisfy { $0.stopped && storableTypes.contains($0.type) }
            && blocks.contains { $0.type == "thinking" || $0.type == "redacted_thinking" }
            && blocks.allSatisfy { $0.type != "thinking" || !$0.signature.isEmpty }
            // Sent back, an id outside this pattern is a 400 (live probe, opus-5-5).
            && blocks.allSatisfy { $0.type != "tool_use" || $0.id.range(of: "^[a-zA-Z0-9_-]+$", options: .regularExpression) != nil }
    }

    /// A blank text block is left out of what is stored: sent back, the API rejects it with a 400,
    /// while a missing one can at worst mismatch a binding, which degrades instead of failing.
    static func isOmitted(_ b: Shape) -> Bool {
        // 400: "text content blocks must be non-empty" / "must contain non-whitespace text".
        b.type == "text" && b.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// The reply's array, or nil when `admits` refuses it. `blocks` must be every block of the
    /// reply, in index order.
    static func render(_ blocks: [Streamed]) -> String? {
        guard admits(blocks.map(Shape.init)) else { return nil }
        return "[" + blocks.filter { !isOmitted(Shape($0)) }.map(render).joined(separator: ",") + "]"
    }

    private static func render(_ b: Streamed) -> String {
        let rebuilt = renderKnown(b)
        // So a streamed reply stores what the non-stream path would (#314 decision 1).
        return b.extra.isEmpty ? rebuilt : String(rebuilt.dropLast()) + "," + b.extra + "}"
    }

    private static func renderKnown(_ b: Streamed) -> String {
        switch b.type {
        case "thinking":
            return #"{"type":"thinking","thinking":\#(string(b.thinking)),"signature":\#(string(b.signature))}"#
        case "redacted_thinking":
            return #"{"type":"redacted_thinking","data":\#(string(b.data))}"#
        case "tool_use":
            let input = b.json.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? "{}" : b.json
            return #"{"type":"tool_use","id":\#(string(b.id)),"name":\#(string(b.name)),"input":\#(input)}"#
        default:
            return #"{"type":"text","text":\#(string(b.text))}"#
        }
    }

    /// `s` as a JSON string literal.
    static func string(_ s: String) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.withoutEscapingSlashes]
        return String(decoding: (try? encoder.encode(s)) ?? Data(#""""#.utf8), as: UTF8.self)
    }

    /// The same rules for an array that arrived whole (the non-stream path): `raw` itself, or nil.
    /// An omitted block is cut out by its own bytes, so every other block stays as received.
    static func storable(_ raw: String) -> String? {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]]
        else { return nil }
        let shapes = array.map(Shape.init)
        guard admits(shapes) else { return nil }
        let empty = shapes.map(isOmitted)
        guard empty.contains(true) else { return raw }
        guard let elements = RawJSON.elements(raw), elements.count == array.count else { return nil }
        return "[" + zip(elements, empty).filter { !$0.1 }.map(\.0).joined(separator: ",") + "]"
    }

    /// Whether `content`'s stored blocks can go out as received: an assistant reply whose array is
    /// storable and whose tool_use blocks name the same calls, in the same order, as its parts. A
    /// mismatch means something changed the parts after the blocks were stored. An array `storable`
    /// would change (a blank text block a hook supplied) is not echoed either: the API rejects it.
    static func echoable(_ content: Content) -> Bool {
        guard content.role == "model", let raw = content.anthropicBlocks, storable(raw) == raw,
              let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]] else { return false }
        let blockCalls = array.filter { $0["type"] as? String == "tool_use" }
            .map { "\($0["id"] as? String ?? "")|\($0["name"] as? String ?? "")" }
        let partCalls = content.parts.compactMap(\.functionCall).map { "\($0.id ?? "")|\($0.name)" }
        return blockCalls == partCalls
    }

    /// `raw` with `cacheControl` (a JSON object's text) merged into its last block, or `raw`
    /// unchanged when that block is a thinking block, which takes no `cache_control`.
    static func withCacheControl(_ raw: String, _ cacheControl: String) -> String {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]],
              let lastType = array.last?["type"] as? String,
              lastType != "thinking", lastType != "redacted_thinking",
              let last = RawJSON.elementRanges(raw)?.last else { return raw }
        let b = Array(raw.utf8)
        let brace = last.upperBound - 1     // the last block's closing brace
        guard b[brace] == UInt8(ascii: "}") else { return raw }
        return String(decoding: b[..<brace], as: UTF8.self) + #","cache_control":"# + cacheControl
            + String(decoding: b[brace...], as: UTF8.self)
    }
}

/// JSON cut as bytes without parsing values, so blocks are stored and sent exactly as they arrived
/// (#314 decision 1). The one byte-level JSON scanner: strings are skipped escape-aware, so a
/// brace, bracket, comma or quoted key inside a string is never taken for structure.
enum RawJSON {
    /// One member of an object: its decoded name (nil if the key does not decode), and its key
    /// and value as their own bytes.
    struct Member: Equatable {
        var name: String?
        var key: String
        var value: String
    }

    /// The bytes of `key`'s value in the top-level object `data`, or nil when `data` is not an
    /// object or has no such member.
    static func topLevelValue(_ key: String, in data: Data) -> String? {
        var s = Scanner([UInt8](data))
        return s.members(stoppingAt: key)?.last.flatMap { $0.name == key ? $0.value : nil }
    }

    /// Every member of the object `raw`, in order, or nil when `raw` is not one.
    static func members(_ raw: String) -> [Member]? {
        var s = Scanner(Array(raw.utf8))
        guard let members = s.members(stoppingAt: nil), s.atEnd() else { return nil }
        return members
    }

    /// The elements of the array `raw` as their own bytes, or nil when `raw` is not one.
    static func elements(_ raw: String) -> [String]? {
        let b = Array(raw.utf8)
        return elementRanges(raw).map { $0.map { String(decoding: b[$0], as: UTF8.self) } }
    }

    /// The byte offsets of each element of the array `raw` (in its UTF-8), or nil when `raw` is
    /// not one.
    static func elementRanges(_ raw: String) -> [Range<Int>]? {
        var s = Scanner(Array(raw.utf8))
        s.skipSpace()
        guard s.peek(0x5B) else { return nil }
        s.i += 1
        var out: [Range<Int>] = []
        s.skipSpace()
        if s.peek(0x5D) { s.i += 1; return s.atEnd() ? out : nil }
        while true {
            s.skipSpace()
            let start = s.i
            guard s.skipValue() else { return nil }
            out.append(start..<s.i)
            s.skipSpace()
            if s.peek(0x2C) { s.i += 1; continue }
            guard s.peek(0x5D) else { return nil }
            s.i += 1
            return s.atEnd() ? out : nil
        }
    }

    private struct Scanner {
        let b: [UInt8]
        var i = 0
        init(_ b: [UInt8]) { self.b = b }

        func peek(_ c: UInt8) -> Bool { i < b.count && b[i] == c }

        mutating func atEnd() -> Bool { skipSpace(); return i == b.count }

        mutating func skipSpace() {
            while i < b.count, b[i] == 0x20 || b[i] == 0x09 || b[i] == 0x0A || b[i] == 0x0D { i += 1 }
        }

        mutating func skipString() -> Bool {      // at `"`; ends just past the closing quote
            guard peek(0x22) else { return false }
            i += 1
            while i < b.count {
                switch b[i] {
                case 0x5C: i += 2                     // a backslash escapes the next byte
                case 0x22: i += 1; return true
                default: i += 1
                }
            }
            return false
        }

        mutating func skipValue() -> Bool {
            skipSpace()
            guard i < b.count else { return false }
            if b[i] == 0x22 { return skipString() }
            if b[i] == 0x7B || b[i] == 0x5B {
                var depth = 0
                while i < b.count {
                    switch b[i] {
                    case 0x22:
                        guard skipString() else { return false }
                        continue
                    case 0x7B, 0x5B:
                        depth += 1
                    case 0x7D, 0x5D:
                        depth -= 1
                        if depth == 0 { i += 1; return true }
                    default:
                        break
                    }
                    i += 1
                }
                return false
            }
            let start = i
            while i < b.count, ![0x2C, 0x7D, 0x5D, 0x20, 0x09, 0x0A, 0x0D].contains(b[i]) { i += 1 }
            return i > start
        }

        /// The object's members up to and including the first named `stop` (all of them when
        /// `stop` is nil), leaving `i` just past the object; nil when it is not one.
        mutating func members(stoppingAt stop: String?) -> [Member]? {
            skipSpace()
            guard peek(0x7B) else { return nil }
            i += 1
            var out: [Member] = []
            skipSpace()
            if peek(0x7D) { i += 1; return out }
            while true {
                skipSpace()
                let keyStart = i
                guard skipString() else { return nil }
                let keyBytes = b[keyStart..<i]
                let name = try? JSONDecoder().decode(String.self, from: Data(keyBytes))
                skipSpace()
                guard peek(0x3A) else { return nil }
                i += 1
                skipSpace()
                let valueStart = i
                guard skipValue() else { return nil }
                out.append(Member(name: name, key: String(decoding: keyBytes, as: UTF8.self),
                                  value: String(decoding: b[valueStart..<i], as: UTF8.self)))
                if let stop, name == stop { return out }
                skipSpace()
                if peek(0x2C) { i += 1; continue }
                guard peek(0x7D) else { return nil }
                i += 1
                return out
            }
        }
    }
}
