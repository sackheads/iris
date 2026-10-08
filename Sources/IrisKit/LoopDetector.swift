import Foundation

/// Detects an agent stuck repeating the same tool call. Signatures are canonical so identical
/// arguments always compare equal regardless of dictionary ordering.
struct LoopDetector {
    private let threshold: Int
    private var recent: [String] = []

    init(threshold: Int) {
        self.threshold = max(2, threshold)
    }

    /// A stable signature for a tool call: name + args serialized with sorted keys.
    static func signature(toolName: String, args: [String: JSONValue]) -> String {
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.sortedKeys]
        let argsString: String
        if let data = try? encoder.encode(args), let s = String(data: data, encoding: .utf8) {
            argsString = s
        } else {
            argsString = "\(args)"   // fallback; still stable within a process for equal inputs
        }
        return "\(toolName)|\(argsString)"
    }

    /// Records a signature; returns true when the last `threshold` signatures are identical.
    mutating func record(_ signature: String) -> Bool {
        if recent.last != signature { recent.removeAll() }
        recent.append(signature)
        if recent.count > threshold { recent.removeFirst(recent.count - threshold) }
        return recent.count >= threshold && recent.allSatisfy { $0 == signature }
    }

    mutating func reset() { recent.removeAll() }
}
