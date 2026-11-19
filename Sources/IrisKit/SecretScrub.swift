import Foundation

/// Removes a secret from text that may be shown, logged or handed to another context: a provider can
/// echo the key it was sent in an error body, and a tool result or a reply can carry a value the
/// owner holds (#974 Task 14, C2's defence in depth).
enum SecretScrub {
    /// A value shorter than this is not treated as a secret: it would redact ordinary words.
    static let minLength = 8
    static let replacement = "[redacted]"

    /// Each secret as it is likely to appear in text: as given, percent-encoded (a URL or form body)
    /// and JSON-escaped (a value read out of a JSON file). Longest first, so a secret that contains
    /// another is removed whole, never leaving the tail of the longer one.
    private static func spellings(of secret: String) -> [String] {
        var out: [String] = [secret]
        // Percent-encoded the way a URL or form encoder does it (unreserved characters kept), and
        // the stricter way (everything but letters and digits).
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for allowed in [unreserved, CharacterSet.alphanumerics] {
            if let pct = secret.addingPercentEncoding(withAllowedCharacters: allowed), pct != secret { out.append(pct) }
        }
        if let data = try? JSONEncoder().encode(secret), let quoted = String(data: data, encoding: .utf8) {
            let inner = String(quoted.dropFirst().dropLast())
            if inner != secret { out.append(inner) }
        }
        return out
    }

    static func scrub(_ text: String, _ secrets: [String]) -> String {
        scrubSecrets(text, known: Set(secrets))
    }

    /// `text` with every known secret value removed (#974 Task 14). Exact match only: a value the
    /// owner holds, in any of its likely spellings. A semantic leak (a paraphrase, a derived value) is
    /// not something a code filter can catch; this is the hard half of the envelope.
    static func scrubSecrets(_ text: String, known: Set<String>) -> String {
        let needles = known.filter { $0.count >= minLength }.flatMap(spellings(of:))
        return Set(needles).sorted { $0.count > $1.count }.reduce(text) { $0.replacingOccurrences(of: $1, with: replacement) }
    }

    static func scrub(_ data: Data, _ secrets: [String]) -> Data {
        guard secrets.contains(where: { $0.count >= minLength }), let text = String(data: data, encoding: .utf8) else { return data }
        return Data(scrub(text, secrets).utf8)
    }
}

extension ConfigManager {
    /// Every secret value this manager already holds in memory: the cached secrets item, minus the
    /// guarded settings that live in the same item but are not secrets (a base URL, a repo list, a
    /// login). No Keychain read of its own: `secretsSnapshot` is the launch-time read, cached.
    var knownSecretValues: Set<String> {
        guard let keychain = guardedKeychain else { return [] }
        let settingKeys = Set(GuardedKey.allCases.map(\.rawValue)).union([GuardedSettings.markerKey])
        return Set(secretsSnapshot(keychain).filter { !settingKeys.contains($0.key) }.values.filter { $0.count >= SecretScrub.minLength })
    }
}
