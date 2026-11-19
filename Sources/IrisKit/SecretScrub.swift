import Foundation

/// Removes a secret from text that may be shown, logged or handed to another context: a provider can
/// echo the key it was sent in an error body, and a tool result or a reply can carry a value the
/// owner holds (#974 Task 14, C2's defence in depth).
enum SecretScrub {
    /// A value shorter than this is not treated as a secret: it would redact ordinary words.
    static let minLength = 8
    static let replacement = "[redacted]"

    /// Each secret as it is likely to appear in text: as given; percent-encoded the way a URL or form
    /// encoder does it and the strict way; JSON-escaped (a value read out of a JSON file); base64 (standard
    /// and URL-safe, padded and unpadded: an `env | base64`, a debug dump); and hex (lower and upper).
    /// A secret inside a longer base64 value (an HTTP `Authorization: Basic` header is
    /// `base64("user:" + secret)`) is encoded at an offset that depends on what precedes it, so the
    /// interior of its encoding is added at each of the three alignments: the groups wholly inside the
    /// secret are the same whatever surrounds them, and only the one or two characters at each edge,
    /// which mix in the neighbours' bytes, are not matched. Longest first (see `scrubSecrets`).
    private static func spellings(of secret: String) -> [String] {
        var out: [String] = [secret]
        let unreserved = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        for allowed in [unreserved, CharacterSet.alphanumerics] {
            if let pct = secret.addingPercentEncoding(withAllowedCharacters: allowed), pct != secret { out.append(pct) }
        }
        if let data = try? JSONEncoder().encode(secret), let quoted = String(data: data, encoding: .utf8) {
            let inner = String(quoted.dropFirst().dropLast())
            if inner != secret { out.append(inner) }
        }
        let bytes = Array(secret.utf8)
        out.append(bytes.map { String(format: "%02x", $0) }.joined())
        out.append(bytes.map { String(format: "%02X", $0) }.joined())
        func base64Forms(_ chunk: ArraySlice<UInt8>) -> [String] {
            let std = Data(chunk).base64EncodedString()
            let url = std.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_")
            let unpadded = { (text: String) in text.trimmingCharacters(in: CharacterSet(charactersIn: "=")) }
            return [std, url, unpadded(std), unpadded(url)]
        }
        out.append(contentsOf: base64Forms(bytes[...]))
        // The interior at each alignment: whole 3-byte groups only, so no padding and no neighbour bytes.
        for skip in 0..<3 {
            let groups = (bytes.count - skip) / 3
            guard groups >= 2 else { continue }
            let chunk = bytes[skip..<(skip + groups * 3)]
            let std = Data(chunk).base64EncodedString()
            out.append(std)
            out.append(std.replacingOccurrences(of: "+", with: "-").replacingOccurrences(of: "/", with: "_"))
        }
        return out.filter { $0.count >= minLength }
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
    /// NOT all of Iris's secrets: only the `com.iris.secrets` item (provider keys, Google tokens, ...). The
    /// GitHub token, MCP header secrets, the MCP provider's guest tokens, plugin secrets and the A2A key
    /// live in their own Keychain items and are not here (tracked as #1220). Cached at launch, but
    /// `secretsSnapshot` reads the Keychain once after a Settings write invalidates the cache, so the first
    /// non-owner result after a key change can pay that read, on the main actor.
    ///
    /// Every secret value this manager already holds in memory: the cached secrets item, minus the
    /// guarded settings that live in the same item but are not secrets (a base URL, a repo list, a
    /// login). No Keychain read of its own: `secretsSnapshot` is the launch-time read, cached.
    var knownSecretValues: Set<String> {
        guard let keychain = guardedKeychain else { return [] }
        let settingKeys = Set(GuardedKey.allCases.map(\.rawValue)).union([GuardedSettings.markerKey])
        return Set(secretsSnapshot(keychain).filter { !settingKeys.contains($0.key) }.values.filter { $0.count >= SecretScrub.minLength })
    }
}
