import Foundation

struct ToolCallDisplay: Equatable {
    let name: String
    let command: String?   // run_command only
    let intent: String?
}

enum ToolCallParser {
    static let prefix = "[TOOL_CALL]\n"

    /// Parse a system message into displayable tool-call fields. Returns nil for
    /// non-tool-call text or malformed JSON.
    static func parse(_ messageText: String) -> ToolCallDisplay? {
        guard messageText.hasPrefix(prefix) else { return nil }
        let json = String(messageText.dropFirst(prefix.count))
        guard let data = json.data(using: .utf8),
              let dict = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let name = dict["name"] as? String else { return nil }
        let args = dict["args"] as? [String: Any]
        let command = args?["command"] as? String
        let intentRaw = args?["intent"] as? String
        let intent = (intentRaw?.isEmpty == false) ? intentRaw : nil
        return ToolCallDisplay(name: name, command: command, intent: intent)
    }
}
