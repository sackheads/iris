import Foundation

/// 5b spec §0, decision 4, last paragraph: nothing rotates automatically. When the pinned
/// conversation's history passes ~150k estimated tokens, Iris posts a one-line suggestion to run
/// `/new`, once per crossing. The owner decides when context resets.
enum RotationSuggestion {
    static let threshold = 150_000

    static let text = "Iris's history is long (about 150k tokens). Run /new to start a fresh Iris with a summary; this one is archived and stays searchable."

    /// UTF-8 byte count of the history's text parts, divided by 4. Character count was ruled out
    /// as exploitable (a multi-byte character counts as one `Character` but costs more than one
    /// token), so this sums `utf8.count` instead. Only text parts are counted; inline image data
    /// (`Part.inlineData`) and function-call/response arguments are skipped, so this undercounts
    /// a history heavy with either — acceptable for a one-line nudge, not a billing figure.
    static func estimatedTokens(_ history: [Content]) -> Int {
        var bytes = 0
        for content in history {
            for part in content.parts {
                if let text = part.text {
                    bytes += text.utf8.count
                }
            }
        }
        return bytes / 4
    }
}
