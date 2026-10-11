import Foundation

/// #469 §4.3: roles are user-assigned standing responsibilities, unique among active sessions.
/// Uniqueness is enforced here and in `AppState`'s mutators, on the MainActor, which is the only
/// writer. Not a store index: each conversation is written in its own transaction, so a move
/// (clear the old holder, set the new one) would fail half-applied under a unique index.
enum SessionRoles {
    static let reserved: Set<String> = ["iris", "clear"]
    static let maxLength = 32

    /// Lowercased, trimmed; `[a-z0-9-]`, starting alphanumeric, at most 32. Nil when invalid or
    /// reserved, so `role:<name>` is always unambiguous to type.
    static func normalizedName(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...maxLength).contains(name.count), !reserved.contains(name),
              let first = name.unicodeScalars.first, CharacterSet.alphanumerics.contains(first),
              name.unicodeScalars.allSatisfy({ ("a"..."z").contains($0) || ("0"..."9").contains($0) || $0 == "-" })
        else { return nil }
        return name
    }

    /// Who holds `role` among sessions that may hold one.
    static func holder(of role: String, in conversations: [Conversation]) -> UUID? {
        conversations.first { $0.role == role && mayHoldRole($0) }?.id
    }

    static func mayHoldRole(_ c: Conversation) -> Bool {
        !c.isArchived && !c.isPinned && c.isUserFacing
    }

    /// #480 review item 2: NFKC, strips Unicode format (Cf — zero-width, bidi controls) and
    /// default-ignorable code points, then applies `flattenCardField`'s own substitutions
    /// (`"`→`'`, `|`→`/`, every newline, and — since that function now also maps it —
    /// `\u{FF02}`→`'`) so two names that render identically, or that differ only by an invisible
    /// character a card author slipped in, compare equal. Collapses whitespace runs, lowercases,
    /// and trims (the collapse's empty components double as the trim). One canonicalizer for
    /// both the uniqueness check below and `name:` resolution (`SessionDirectory.resolve`, which
    /// calls through `sessions(named:)`) — a second one would drift from this one the way
    /// `flattenCardField`'s own doc comment warns against for card fields generally.
    static func canonicalKey(_ value: String) -> String {
        let normalized = value.precomposedStringWithCompatibilityMapping
        let noIgnorables = String(String.UnicodeScalarView(normalized.unicodeScalars.filter {
            !$0.properties.isDefaultIgnorableCodePoint
        }))
        let flattened = IrisEngine.flattenCardField(noIgnorables, cap: Int.max)
        let collapsed = flattened.components(separatedBy: .whitespaces).filter { !$0.isEmpty }.joined(separator: " ")
        return collapsed.lowercased()
    }

    /// #469 §4.2: names are identifiers among active sessions, compared by `canonicalKey`.
    static func sessions(named name: String, in conversations: [Conversation], excluding: UUID?) -> [UUID] {
        let key = canonicalKey(name)
        return conversations.filter {
            guard $0.id != excluding, !$0.isArchived, $0.isUserFacing, let cardName = $0.sessionCard?.name else { return false }
            return canonicalKey(cardName) == key
        }.map(\.id)
    }

    /// Restores the invariant after load: only a session that may hold a role has one, each role
    /// has at most one holder — the most recently updated keeps it — and a role that does not
    /// survive `normalizedName` unchanged (a value written before validation existed, or edited
    /// directly in the store) is cleared too. §4.4: skills never survive a role loss, so every
    /// branch that nils `role` here clears `sessionCard?.skills` with it.
    static func normalize(_ conversations: inout [Conversation]) {
        var keeper: [String: Int] = [:]
        for i in conversations.indices {
            guard let role = conversations[i].role else { continue }
            guard mayHoldRole(conversations[i]), SessionRoles.normalizedName(role) == role else {
                conversations[i].role = nil; conversations[i].sessionCard?.skills = []; continue
            }
            if let j = keeper[role] {
                if conversations[i].updatedAt > conversations[j].updatedAt {
                    conversations[j].role = nil; conversations[j].sessionCard?.skills = []; keeper[role] = i
                } else {
                    conversations[i].role = nil; conversations[i].sessionCard?.skills = []
                }
            } else {
                keeper[role] = i
            }
        }
    }
}
