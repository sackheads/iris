import Foundation

/// Detects a secret-shaped substring in an Always-Allow candidate's command text, so #1140's save
/// path can refuse to persist it to plaintext `permissions.json`. A named, testable pattern table,
/// not a bare entropy scan: a bare high-entropy check over hex would flag git SHAs, SHA-256
/// checksums and content hashes constantly, which are common and legitimate to generalize. A false
/// positive here costs one command that stays ungeneralized (the person re-approves it); a false
/// negative writes a credential to disk — so the generic fallback (3) still errs toward catching,
/// but only for shapes a SHA or UUID cannot produce.
enum SecretLikeDetector {
    struct Pattern {
        let name: String
        let regex: NSRegularExpression
    }

    private static func pattern(_ name: String, _ raw: String) -> Pattern {
        guard let regex = try? NSRegularExpression(pattern: raw) else {
            fatalError("SecretLikeDetector: invalid pattern \(name)")
        }
        return Pattern(name: name, regex: regex)
    }

    /// 1. Named provider/header token shapes: zero-to-low false positive, catch #1140's reported
    /// case (an OAuth bearer header) and the other common provider formats directly.
    /// 2. A named flag or key immediately followed by an opaque value of plausible secret length.
    /// 3. A generic, unlabeled token: a run of base64-alphabet characters at least 40 long that
    /// mixes an uppercase letter, a lowercase letter and a digit. The mixed-case+digit requirement
    /// is what excludes a 40-hex git SHA (lowercase hex only, no uppercase) and a UUID (lowercase
    /// hex and dashes) without naming either as an exception.
    static let patterns: [Pattern] = [
        pattern("authorization-header", "(?i)Authorization:\\s*(Bearer|Basic|Token)\\s+\\S{8,}"),
        pattern("jwt", "eyJ[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}\\.[A-Za-z0-9_-]{5,}"),
        pattern("openai-or-anthropic-key", "\\bsk-(ant-)?[A-Za-z0-9_-]{16,}\\b"),
        pattern("github-token", "\\b(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}\\b"),
        pattern("aws-access-key-id", "\\bAKIA[0-9A-Z]{16}\\b"),
        pattern("slack-token", "\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b"),
        pattern("named-flag-opaque-value", "(?i)\\b(token|apikey|api_key|access_token|password|secret)[=: ]\\S{16,}"),
        // No `-` or `/` in the charset: both are path and UUID separators, and letting the run
        // span them turned "ordinary-<UUID>" and a temp-dir path's "iris-NNN-<UUID>/..." segment
        // into one 40+-char run with all three character classes present (#1140 round 1, caught
        // by the full suite: ApprovalResolvedPathTests, GateScriptAlwaysAllowTests). `+` and `_`
        // stay, since neither is a common path or UUID separator.
        pattern("generic-mixed-case-token",
                "\\b(?=[A-Za-z0-9+_]{40,}\\b)(?=[A-Za-z0-9+_]*[a-z])(?=[A-Za-z0-9+_]*[A-Z])(?=[A-Za-z0-9+_]*[0-9])[A-Za-z0-9+_]{40,}\\b"),
    ]

    static func containsSecretLikeSubstring(_ text: String) -> Bool {
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.contains { $0.regex.firstMatch(in: text, range: range) != nil }
    }
}
