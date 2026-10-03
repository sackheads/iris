import Foundation

/// 5b §0.5: another conversation, as the owner saw it. Only user and agent messages, numbered as
/// the search index numbers them, so a search hit's position opens on the hit.
///
/// `ConversationStore.indexMessage` filters OUT system/command/event rows before inserting into
/// `messages_fts` (`indexedRoles`), but the `ordinal` column it stores is the literal index into
/// the conversation's raw `messages` array (`ConversationStore.apply`'s
/// `for ordinal in from..<c.messages.count`), not a count restricted to the indexed roles. A hit's
/// `ordinal` is therefore a position in the RAW array, with gaps where harness chatter sits — so
/// `page` numbers the same way: by raw index, skipping non-visible rows without renumbering around
/// them. (The brief's draft assumed ordinals counted only user/agent messages; they don't.)
enum ConversationReader {
    static let maxMessages = 20
    static let maxCharacters = 32_000

    /// Indents every line after a message's first by two spaces. Message bodies may be multi-line;
    /// without this, a body line that happened to read like `#12 owner: ...` at column 0 would be
    /// indistinguishable from a real message boundary this reader just produced. Real boundary
    /// lines are never indented, so a forged one that is can't be mistaken for one. Splits on
    /// `.newlines` (not just `"\n"`) so a bare CR or U+2028 LINE SEPARATOR can't dodge it either.
    static func indentContinuationLines(_ content: String) -> String {
        let lines = content.components(separatedBy: .newlines)
        guard lines.count > 1 else { return content }
        return ([lines[0]] + lines.dropFirst().map { "  " + $0 }).joined(separator: "\n")
    }

    /// Pages through `messages`, starting at raw index `from`, for at most `count` (clamped to
    /// 1...`maxMessages`) visible (user/agent) messages, and at most `maxCharacters` of rendered
    /// text. `from` is clamped to >= 0. A single message that alone exceeds `maxCharacters` is
    /// truncated in place with a marker — never skipped, and never retried at the same position
    /// (the returned `next`, if any, always advances past it).
    static func page(_ messages: [ChatMessage], from: Int, count: Int) -> (text: String, next: Int?) {
        let start = max(from, 0)
        let limit = min(max(count, 1), maxMessages)
        guard start < messages.count else {
            return ("(no messages from #\(start); it has \(messages.count))", nil)
        }

        var lines: [String] = []
        var used = 0
        var emitted = 0
        var i = start
        var next: Int?

        while i < messages.count {
            guard emitted < limit else { next = i; break }
            let m = messages[i]
            guard m.role == .user || m.role == .agent else { i += 1; continue }

            let speaker = m.role == .user ? "owner" : "iris"
            let body = indentContinuationLines(m.content)
            var line = "#\(i) \(speaker): \(body)"

            if line.count > maxCharacters {
                let marker = "\n(truncated)"
                let keep = max(maxCharacters - marker.count, 0)
                line = String(line.prefix(keep)) + marker
                lines.append(line)
                used = maxCharacters
                i += 1
                emitted += 1
                next = i < messages.count ? i : nil
                break
            }

            if used + line.count > maxCharacters, !lines.isEmpty {
                next = i
                break
            }

            lines.append(line)
            used += line.count
            emitted += 1
            i += 1
        }

        if next == nil, emitted >= limit, i < messages.count {
            next = i
        }

        guard !lines.isEmpty else {
            return ("(no messages from #\(start); it has \(messages.count))", nil)
        }
        var text = lines.joined(separator: "\n\n")
        if let next {
            text += "\n\n(more from #\(next))"
        }
        return (text, next)
    }
}
