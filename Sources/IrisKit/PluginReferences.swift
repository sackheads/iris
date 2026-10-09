import Foundation

/// Expansion of `${keychain:KEY}` / `${config:KEY}` references. Expansion happens in memory
/// at server launch only — expanded strings must never be written to disk or logs.
enum PluginReferences {
    private nonisolated(unsafe) static let refPattern = /\$\{(keychain|config):([A-Za-z0-9_]+)\}/

    static func expand(_ s: String, config: [String: String], secrets: [String: String]) throws -> String {
        var result = ""
        var index = s.startIndex
        while let match = s[index...].firstMatch(of: refPattern) {
            result += s[index..<match.range.lowerBound]
            let kind = String(match.1)
            let key = String(match.2)
            let value = (kind == "keychain") ? secrets[key] : config[key]
            guard let value else {
                throw IPFError.unknownReference("${\(kind):\(key)}")
            }
            result += value
            index = match.range.upperBound
        }
        result += s[index...]
        return result
    }

    static func keychainKeys(in s: String) -> Set<String> { keys(in: s, kind: "keychain") }
    static func configKeys(in s: String) -> Set<String> { keys(in: s, kind: "config") }

    private static func keys(in s: String, kind: String) -> Set<String> {
        var found: Set<String> = []
        for match in s.matches(of: refPattern) where String(match.1) == kind {
            found.insert(String(match.2))
        }
        return found
    }
}
