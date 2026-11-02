import Foundation

/// Pub/sub topics between sessions (#696, docs/specs/2026-11-02-pubsub-topics.md). A topic is a
/// name a session lists in its card's `topics`; `send_to_session` with `to: "topic:<name>"` is
/// shorthand for one send to every other subscriber. Nothing here creates a topic: it exists while
/// someone is subscribed or a message is retained.
enum Topics {
    /// A card lists at most this many.
    static let maxPerCard = 8
    /// A publish to more subscribers than this is refused.
    static let maxSubscribers = 20
    /// The body of one topic message, in bytes.
    static let maxBodyBytes = 2048
    /// A late subscriber is shown this many messages, from the last day.
    static let historyCount = 5
    static let historyWindow: TimeInterval = 86_400
    /// Kept per topic, and for how long.
    static let retainedPerTopic = 50
    static let retention: TimeInterval = 7 * 86_400
    static let nameMaxLength = 32

    /// A topic name: 1-32 characters of a-z, 0-9 and `-`, after trimming and lowercasing.
    static func normalize(_ raw: String) -> String? {
        let name = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard (1...nameMaxLength).contains(name.count),
              name.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return name
    }

    /// The topic a `to` addresses: nil when it is not a `topic:` address, `.some(nil)` when it is one
    /// with an unusable name.
    static func address(_ to: String) -> String?? {
        let raw = to.trimmingCharacters(in: .whitespacesAndNewlines)
        guard raw.lowercased().hasPrefix("topic:") else { return nil }
        return .some(normalize(String(raw.dropFirst(6))))
    }

    /// The valid, distinct names in a card's raw `topics` argument, in order, at most `maxPerCard`.
    static func parse(_ items: [JSONValue]) -> (names: [String], dropped: Bool) {
        var names: [String] = []
        var dropped = false
        for item in items {
            guard let name = normalize(item.stringValue) else { dropped = true; continue }
            if names.contains(name) { continue }
            if names.count == maxPerCard { dropped = true; continue }
            names.append(name)
        }
        return (names, dropped)
    }

    /// The other active sessions subscribed to `topic`, by the harness's stored cards.
    static func subscribers(of topic: String, in conversations: [Conversation], excluding selfId: UUID) -> [UUID] {
        conversations.filter {
            $0.id != selfId && !$0.isArchived && $0.isUserFacing && ($0.sessionCard?.topics.contains(topic) ?? false)
        }.map(\.id)
    }

    static func isSubscribed(_ id: UUID, to topic: String, in conversations: [Conversation]) -> Bool {
        conversations.first { $0.id == id }?.sessionCard?.topics.contains(topic) ?? false
    }
}
