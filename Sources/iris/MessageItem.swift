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
