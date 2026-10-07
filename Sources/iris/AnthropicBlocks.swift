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
        var stopped = false
    }

    /// The reply's array, or nil when it must not be stored: nothing to replay (no thinking
    /// block), a block that never stopped (the stream died inside it), a thinking block with no
    /// signature (cut before it was signed; replayed, it is a 400), or a type Iris does not store.
    /// `blocks` must be every block of the reply, in index order.
    ///
    /// An empty text block is left out of the stored array: sent back, the API rejects it with a
    /// 400, while a missing one can at worst mismatch a binding, which degrades instead of failing.
    static func render(_ blocks: [Streamed]) -> String? {
        guard !blocks.isEmpty,
              blocks.allSatisfy({ $0.stopped && storableTypes.contains($0.type) }),
              blocks.contains(where: { $0.type == "thinking" || $0.type == "redacted_thinking" }),
              blocks.allSatisfy({ $0.type != "thinking" || !$0.signature.isEmpty }) else { return nil }
        return "[" + blocks.filter { !isEmptyText($0) }.map(render).joined(separator: ",") + "]"
    }

    private static func isEmptyText(_ b: Streamed) -> Bool { b.type == "text" && b.text.isEmpty }

    private static func render(_ b: Streamed) -> String {
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
    /// An empty text block is cut out by its own bytes, so every other block stays as received.
    static func storable(_ raw: String) -> String? {
        guard let array = (try? JSONSerialization.jsonObject(with: Data(raw.utf8))) as? [[String: Any]],
              !array.isEmpty else { return nil }
        let types = array.map { $0["type"] as? String ?? "" }
        guard types.allSatisfy(storableTypes.contains),
              types.contains(where: { $0 == "thinking" || $0 == "redacted_thinking" }),
              array.allSatisfy({ ($0["type"] as? String) != "thinking"
                                 || !(($0["signature"] as? String) ?? "").isEmpty }) else { return nil }
        let empty = array.map { ($0["type"] as? String) == "text" && (($0["text"] as? String) ?? "").isEmpty }
        guard empty.contains(true) else { return raw }
        guard let elements = topLevelElements(raw), elements.count == array.count else { return nil }
        return "[" + zip(elements, empty).filter { !$0.1 }.map { String($0.0) }.joined(separator: ",") + "]"
    }

    /// The top-level elements of a JSON array as their own bytes, or nil if `raw` is not one.
    private static func topLevelElements(_ raw: String) -> [Substring]? {
        let u = raw.utf8
        var depth = 0, inString = false, escaped = false
        var start: String.Index?
        var out: [Substring] = []
        for i in u.indices {
            let c = u[i]
            if inString {
                if escaped { escaped = false } else if c == UInt8(ascii: "\\") { escaped = true }
                else if c == UInt8(ascii: "\"") { inString = false }
                continue
            }
            switch c {
            case UInt8(ascii: "\""): inString = true
            case UInt8(ascii: "["), UInt8(ascii: "{"):
                depth += 1
                if depth == 1 { start = u.index(after: i) }
            case UInt8(ascii: "]"), UInt8(ascii: "}"):
                if depth == 1, let s = start { out.append(raw[s..<i]) }
                depth -= 1
            case UInt8(ascii: ","):
                if depth == 1, let s = start { out.append(raw[s..<i]); start = u.index(after: i) }
            default: break
            }
        }
        let trimmed = out.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        guard depth == 0, !trimmed.contains(where: \.isEmpty) else { return nil }
        return trimmed.map { Substring($0) }
    }
}
