import Foundation

enum MessageItem: Identifiable {
    case single(ChatMessage)
    case systemGroup(id: UUID, messages: [ChatMessage])
    
    var id: UUID {
        switch self {
        case .single(let msg): return msg.id
        case .systemGroup(let id, _): return id
        }
    }

    /// Consecutive system messages collapse into one group. An LLM error is always a group of
    /// its own so it renders expanded instead of vanishing behind a collapsed run of tool pills.
    static func group(_ messages: [ChatMessage]) -> [MessageItem] {
        var result: [MessageItem] = []
        var run: [ChatMessage] = []
        func flush() {
            if let first = run.first { result.append(.systemGroup(id: first.id, messages: run)) }
            run = []
        }
        for msg in messages {
            guard msg.role == .system else {
                flush()
                result.append(.single(msg))
                continue
            }
            if LLMErrorMessage.parse(msg.content) != nil {
                flush()
                result.append(.systemGroup(id: msg.id, messages: [msg]))
            } else {
                run.append(msg)
            }
        }
        flush()
        return result
    }
}

/// What the transcript's message selection becomes when something changes (#703). Cmd-C copies
/// the selection, so clearing it on a change that isn't the person's is a copy that beeps.
enum MessageSelection {
    enum Change {
        /// Another conversation is shown: nothing selected carries over.
        case conversationSwitched
        /// This conversation's messages changed (an append, a card, a loop tick): keep every
        /// selected item still in it. A system group's id is its first message's, so a group
        /// that grew keeps its id and stays selected; one whose first message went is dropped.
        case messagesChanged([MessageItem])
    }

    /// The messages a copy of `selected` takes, in transcript order; a group gives all of its own.
    static func messages(_ selected: Set<UUID>, in items: [MessageItem]) -> [ChatMessage] {
        items.filter { selected.contains($0.id) }.flatMap { item -> [ChatMessage] in
            switch item {
            case .single(let message): [message]
            case .systemGroup(_, let messages): messages
            }
        }
    }

    static func apply(_ change: Change, to selected: Set<UUID>) -> Set<UUID> {
        switch change {
        case .conversationSwitched: return []
        case .messagesChanged(let items): return selected.intersection(items.map(\.id))
        }
    }
}
