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

    /// #469 §4.2: names are identifiers among active sessions, compared case-insensitively.
    static func sessions(named name: String, in conversations: [Conversation], excluding: UUID?) -> [UUID] {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        return conversations.filter {
            $0.id != excluding && !$0.isArchived && $0.isUserFacing
                && $0.sessionCard?.name.trimmingCharacters(in: .whitespaces).lowercased() == key
        }.map(\.id)
    }

    /// Restores the invariant after load: only a session that may hold a role has one, and each
    /// role has at most one holder — the most recently updated keeps it.
    static func normalize(_ conversations: inout [Conversation]) {
        var keeper: [String: Int] = [:]
        for i in conversations.indices {
            guard let role = conversations[i].role else { continue }
            guard mayHoldRole(conversations[i]) else { conversations[i].role = nil; continue }
            if let j = keeper[role] {
                if conversations[i].updatedAt > conversations[j].updatedAt {
                    conversations[j].role = nil; keeper[role] = i
                } else {
                    conversations[i].role = nil
                }
            } else {
                keeper[role] = i
            }
        }
    }
}
