import Foundation

/// #314 decision 7: one entry of Anthropic's top-level `input_transformations`, present on every
/// response when the binding beta is sent (`[]` when nothing happened). Kept raw: an unknown type
/// or reason is stored and otherwise ignored (PTM:145). Only `type`, `path` and `reason` are kept;
/// any other key an entry carries (for example a `signature`) is dropped, not retained for later.
public struct InputTransformation: Codable, Sendable, Equatable {
    public var type: String
    public var path: String?
    public var reason: String?

    public init(type: String, path: String? = nil, reason: String? = nil) {
        self.type = type; self.path = path; self.reason = reason
    }

    static let knownTypes: Set<String> = ["thinking_dropped", "thinking_mismatch_allowed"]
    static let knownReasons: Set<String> = ["prefix_binding_mismatch", "model_binding_mismatch"]
    /// "Use it if present; never depend on it" (PTM:146).
    static let diagnosisHeader = "anthropic-thinking-prefix-mismatch"

    /// The entries of a decoded `input_transformations` value; nil when it is absent or not an array.
    /// An element that is not an object with a string `type` is skipped, not the whole array.
    static func list(_ value: Any?) -> [InputTransformation]? {
        guard let array = value as? [Any] else { return nil }
        return array.compactMap { element in
            guard let entry = element as? [String: Any] else { return nil }
            return (entry["type"] as? String).map {
                InputTransformation(type: $0, path: entry["path"] as? String, reason: entry["reason"] as? String)
            }
        }
    }

    static func diagnosis(in headers: [AnyHashable: Any]) -> String? {
        for (key, value) in headers where (key as? String)?.lowercased() == diagnosisHeader {
            return value as? String
        }
        return nil
    }

    /// Whether an entry is worth a console line. A known type is, whatever its reason: a
    /// `thinking_mismatch_allowed` is how an unenforced account shows a break, so it must never be
    /// dropped (ruling R7). A `thinking_dropped` with a reason this build does not know is not.
    static func isReported(_ entry: InputTransformation) -> Bool {
        guard knownTypes.contains(entry.type) else { return false }
        if entry.type == "thinking_dropped", let reason = entry.reason { return knownReasons.contains(reason) }
        return true
    }

    /// One console line for a round, or nil when there is nothing known to report. No pill.
    static func logLine(round: Int, model: String, entries: [InputTransformation]?, diagnosis: String?) -> String? {
        let known = (entries ?? []).filter(isReported)
        guard !known.isEmpty || diagnosis != nil else { return nil }
        var line = "Anthropic thinking (\(model), round \(round)): "
        line += known.isEmpty ? "no transformations"
            : known.map { "\($0.type)\($0.reason.map { "/\($0)" } ?? "") at \($0.path ?? "?")" }.joined(separator: ", ")
        if let diagnosis { line += "; \(diagnosisHeader): \(capped(diagnosis))" }
        return line
    }

    /// The most of the header a console line prints, in UTF-8 bytes; it is server-controlled text.
    static let diagnosisLogLimit = 512

    /// `value` cut on a character boundary to at most `diagnosisLogLimit` UTF-8 bytes, plus "…".
    static func capped(_ value: String) -> String {
        guard value.utf8.count > diagnosisLogLimit else { return value }
        var out = ""
        var bytes = 0
        for character in value {
            let size = character.utf8.count
            if bytes + size > diagnosisLogLimit { break }
            out.append(character); bytes += size
        }
        return out + "…"
    }
}
