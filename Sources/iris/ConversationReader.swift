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

    /// Prefixes every line after a message's first with a distinct quote marker. Message bodies
    /// may be multi-line; without this, a body line that happened to read like `#12 owner: ...` or
    /// `(more from #99)` at column 0 would be indistinguishable from a real message boundary or
    /// paging marker this reader just produced. A plain two-space indent (the first cut at this)
    /// is too weak a signal — it reads as ordinary quoting, not as "this is not structure". `"  | "`
    /// is distinct enough that a forged line can only ever appear AFTER the marker, never in its
    /// place. Splits on `.newlines` (not just `"\n"`) so a bare CR or U+2028 LINE SEPARATOR can't
    /// dodge it either.
    static let continuationQuoteMarker = "  | "

    static func quoteContinuationLines(_ content: String) -> String {
        // "\r\n" first, as one line break: `.newlines` splits on each character separately, so an
        // unnormalized "\r\n" (pasted Windows text) would otherwise produce an empty line between
        // the `\r` and `\n` halves of the same break — a blank "  | " quote marker with nothing
        // after it.
        let lines = content.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: .newlines)
        guard lines.count > 1 else { return content }
        return ([lines[0]] + lines.dropFirst().map { continuationQuoteMarker + $0 }).joined(separator: "\n")
    }

    /// The next raw index at or after `start` holding a `.user`/`.agent` message, or nil if none
    /// remain. Without this, a page that stops because it hit the per-call message cap could point
    /// `next` at a run of trailing `.system`/`.command`/`.event` rows with nothing paginable behind
    /// them — a dead page the caller would read as "there's more" when there isn't.
    private static func nextVisibleIndex(_ messages: [ChatMessage], from start: Int) -> Int? {
        var i = start
        while i < messages.count {
            if messages[i].role == .user || messages[i].role == .agent { return i }
            i += 1
        }
        return nil
    }

    /// Pages through `messages`, starting at raw index `from`, for at most `count` (clamped to
    /// 1...`maxMessages`) visible (user/agent) messages, and at most `maxCharacters` of rendered
    /// text — the "\n\n" separators between messages and a trailing "(more from #N)" marker
    /// included, so the whole returned `text` never exceeds the cap, on any path. `from` is
    /// clamped to >= 0. A single message that alone (or alongside a trailing marker) exceeds
    /// `maxCharacters` is truncated in place — never skipped — but ONLY when it is the first thing
    /// on the page: a message that doesn't fit after earlier ones already filled the page is left
    /// whole for the next page instead of being split mid-page (fix round 1: an oversized message
    /// right after a full-size one landed as page-size-plus-oversize instead of opening its own
    /// page).
    ///
    /// Fix round 2: `used` previously counted only `line.count` for each accepted line, leaving
    /// out the "\n\n" joins between lines and the trailing "(more from #N)" marker's own length —
    /// a page with several messages near the cap, or a message sized to land exactly at it, could
    /// come back a few dozen characters over. `used` now tracks the page's real running length
    /// (separators included), and every later line's admission reserves room for the WORST-CASE
    /// marker this call could ever need to append — `"(more from #\(messages.count - 1))"`, the
    /// longest index this array can produce — before accepting it. The very first line on a page
    /// instead reserves the EXACT marker its own immediate successor would need (computed once,
    /// since at that point nothing else is competing for the budget), which is what lets a
    /// message sized to land precisely at the cap still leave room for its own "more" marker
    /// rather than being emitted whole and overflowing when the marker is appended after.
    ///
    /// `transform` runs on a visible message's raw content before it is quoted and laid out — the
    /// caller's hook for sanitizing untrusted text. It is applied only to messages this call
    /// actually emits (or considers emitting), not to the whole conversation, so paging a long
    /// history doesn't re-sanitize text nobody is about to read.
    static func page(_ messages: [ChatMessage], from: Int, count: Int,
                     transform: (String) -> String = { $0 }) -> (text: String, next: Int?) {
        guard !messages.isEmpty else {
            return ("(this conversation has no messages.)", nil)
        }
        let start = max(from, 0)
        let limit = min(max(count, 1), maxMessages)
        guard start < messages.count else {
            return ("(nothing at or after #\(start); positions here run 0...\(messages.count - 1).)", nil)
        }

        // The longest "(more from #N)" marker this call could ever need to append, since every
        // valid `next` is < messages.count. Reserved before admitting every line but the first (the
        // first reserves its own exact successor marker instead; see the doc comment above).
        let worstCaseMoreMarker = "\n\n(more from #\(messages.count - 1))".count

        var lines: [String] = []
        var used = 0
        var emitted = 0
        var i = start
        var next: Int?

        while i < messages.count {
            guard emitted < limit else { next = nextVisibleIndex(messages, from: i); break }
            let m = messages[i]
            guard m.role == .user || m.role == .agent else { i += 1; continue }

            let speaker = m.role == .user ? "owner" : "iris"
            let body = quoteContinuationLines(transform(m.content))
            let line = "#\(i) \(speaker): \(body)"

            if lines.isEmpty {
                // The first candidate line for this page. Reserve the EXACT marker its immediate
                // successor (if any) would need — not the conservative worst case — so a message
                // sized to land precisely at the cap still truncates just enough to leave room for
                // "more from #N", and an ordinary small first message is never truncated merely
                // because of an index that is, in practice, nowhere near the budget.
                let after = i + 1
                let followingVisible = nextVisibleIndex(messages, from: after)
                let moreMarker = followingVisible.map { "\n\n(more from #\($0))" } ?? ""
                let budget = maxCharacters - moreMarker.count
                if line.count > budget {
                    let truncMarker = "\n(truncated)"
                    let keep = max(budget - truncMarker.count, 0)
                    let truncatedLine = String(line.prefix(keep)) + truncMarker
                    return (truncatedLine + moreMarker, followingVisible)
                }
                lines = [line]
                used = line.count
                emitted += 1
                i += 1
                continue
            }

            // Not the first line: must fit alongside everything already on the page, with the
            // "\n\n" separator that will join it counted, AND still leave room for whatever
            // "(more from #N)" marker this call might end up needing to append afterward.
            let projected = used + 2 + line.count
            if projected + worstCaseMoreMarker > maxCharacters {
                // Doesn't fit: stop here so IT opens the next page, whole, rather than being split.
                next = i
                break
            }
            lines.append(line)
            used = projected
            emitted += 1
            i += 1
        }

        guard !lines.isEmpty else {
            return ("(no messages from #\(start) onward.)", nil)
        }
        var text = lines.joined(separator: "\n\n")
        if let next {
            text += "\n\n(more from #\(next))"
        }
        return (text, next)
    }
}
