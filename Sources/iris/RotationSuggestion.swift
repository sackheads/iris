import Foundation

/// 5b spec §0, decision 4, last paragraph: nothing rotates automatically. When the pinned
/// conversation's history passes ~150k estimated tokens, Iris posts a one-line suggestion to run
/// `/new`, once per crossing. The owner decides when context resets.
enum RotationSuggestion {
    static let threshold = 150_000

    static let text = "Iris's history is long (about 150k tokens). Run /new to start a fresh Iris with a summary; this one is archived and stays searchable."

    /// UTF-8 bytes of the history's text, divided by 4: text parts, and the strings inside tool
    /// calls and tool results (`functionCall` name and args, `functionResponse` name and payload).
    /// Tool output reaches history as a `functionResponse` with no text, so counting text alone let
    /// a tool-heavy Iris overflow the context before this fired. Bytes, not `Character`s: a
    /// grapheme cap was ruled exploitable. Inline image data is still skipped (it is stripped from
    /// history after the turn anyway), so this is a nudge, not a billing figure.
    static func estimatedTokens(_ history: [Content]) -> Int {
        var bytes = 0
        for content in history {
            for part in content.parts {
                if let text = part.text { bytes += text.utf8.count }
                if let call = part.functionCall {
                    bytes += call.name.utf8.count
                    for (k, v) in call.args { bytes += k.utf8.count + stringBytes(v) }
                }
                if let response = part.functionResponse {
                    bytes += response.name.utf8.count
                    for (k, v) in response.response { bytes += k.utf8.count + stringBytes(v) }
                }
            }
        }
        return bytes / 4
    }

    /// UTF-8 bytes of every string (and object key) in `value`. Numbers, bools and nulls are a
    /// handful of tokens each and are not worth walking for.
    private static func stringBytes(_ value: JSONValue) -> Int {
        switch value {
        case .string(let s): return s.utf8.count
        case .array(let items): return items.reduce(0) { $0 + stringBytes($1) }
        case .object(let fields): return fields.reduce(0) { $0 + $1.key.utf8.count + stringBytes($1.value) }
        case .int, .double, .bool, .null: return 0
        }
    }
}
