import Foundation

/// Detects a secret-shaped substring in what an Always-Allow click would actually persist, so
/// #1140's save path can refuse to write it to plaintext `permissions.json`. Checked against the
/// rule text `PermissionRule.forAlwaysAllow` would save, not the raw command: since #1102 a
/// `run_command` Always-Allow usually saves only a prefix (`swift test`, `git status`), never its
/// arguments, so an argument that merely looks secret-shaped protects nothing by losing the
/// button. An exact rule (no prefix — `curl ...`, `gh api ...`) still saves the whole text, so a
/// real credential there is still caught.
///
/// A named, testable pattern table, not a bare entropy scan: a bare high-entropy check over hex
/// would flag git SHAs, SHA-256 checksums and content hashes constantly, which are common and
/// legitimate to generalize. A false positive here costs one command that stays ungeneralized (the
/// person re-approves it); a false negative writes a credential to disk — so the generic fallback
/// (see `hasGenericMixedCaseToken`) still errs toward catching, but only for shapes a SHA or UUID
/// cannot produce.
///
/// Known gaps, accepted rather than chased: a 64-hex API key is indistinguishable from a SHA-256
/// digest by shape alone and is not flagged; an AWS secret access key (40 base64-ish chars,
/// commonly containing `/`) is split into short runs by the generic scan below, which deliberately
/// excludes `/` (a path separator) from its charset (round 1 regression). A `$VAR`/`${VAR}` shell
/// reference is excluded from firing a named pattern: it is not a literal secret, and is common in
/// real commands (`Authorization: Bearer $GITHUB_TOKEN`).
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

    /// Guards an opaque value against a shell-variable reference: `$TOKEN` or `${TOKEN}` is a
    /// placeholder, not a literal secret, and so is one quoted (`"$TOKEN"`, `'$TOKEN'`) — the
    /// quote character is the first char after the separator, not `$`, so the bare `(?!\$)`
    /// version missed it (round 2, dev-2's finding).
    private static let notAVarRef = "(?!['\"]?\\$)"

    /// Named provider/header token shapes and flag/URL/env-var shapes: all anchored, bounded
    /// quantifiers with no nested repetition over a shared alphabet, so none of these can
    /// backtrack catastrophically the way the old regex-based generic fallback did (round 2,
    /// dev-3's finding: 128s on an 80,000-char `a+a+...` run, on the main actor in
    /// `ToolApprovalRequest.init`).
    static let patterns: [Pattern] = [
        pattern("authorization-header", "(?i)Authorization:\\s*(Bearer|Basic|Token)\\s+" + notAVarRef + "\\S{4,}"),
        // Bounded ({5,500} per segment, not {5,}): three chained unbounded-quantifier-then-literal
        // segments made this the worst of the quadratic patterns (dev-2's round-3 finding: 26s on
        // a 99,000-char adversarial "eyJabcdef" repeat). 500 is generous for a real JWT segment.
        pattern("jwt", "eyJ[A-Za-z0-9_-]{5,500}\\.[A-Za-z0-9_-]{5,500}\\.[A-Za-z0-9_-]{5,500}"),
        pattern("openai-or-anthropic-key", "\\bsk-(ant-)?[A-Za-z0-9_-]{16,}\\b"),
        pattern("github-token", "\\b(ghp|gho|ghs|github_pat)_[A-Za-z0-9_]{16,}\\b"),
        pattern("aws-access-key-id", "\\b(AKIA|ASIA)[0-9A-Z]{16}\\b"),
        pattern("slack-token", "\\bxox[baprs]-[A-Za-z0-9-]{10,}\\b"),
        pattern("google-api-key", "\\bAIza[A-Za-z0-9_-]{35}\\b"),
        pattern("stripe-key", "\\b[sp]k_live_[A-Za-z0-9]{10,}\\b"),
        pattern("huggingface-token", "\\bhf_[A-Za-z0-9]{20,}\\b"),
        pattern("gitlab-token", "\\bglpat-[A-Za-z0-9_-]{20,}\\b"),
        pattern("npm-auth-token", "_authToken=npm_[A-Za-z0-9]{10,}"),
        // An uppercase ENV_VAR-shaped assignment ending in a credential-shaped suffix:
        // `NPM_TOKEN=`, `DB_PASSWORD=`, `GITHUB_TOKEN=`, `AWS_SECRET_ACCESS_KEY=`. No leading `\b`
        // before the suffix word is needed or wanted — `\b` would not match inside `NPM_TOKEN`
        // anyway, since `_` is a word character with no boundary before `TOKEN` (round 2, dev-2's
        // finding against the CLI-flag pattern below).
        pattern("env-var-assignment",
                "\\b[A-Z][A-Z0-9_]*_(TOKEN|SECRET|PASSWORD|API_?KEY|ACCESS_KEY|ACCESS_TOKEN|AUTH)=" + notAVarRef + "\\S{4,}"),
        // A CLI flag or key, named plainly (not an env-var): `--password=hunter2`,
        // `--password hunter2`, `--api-key abc`, `token: abc123`, `--private-key <path-or-value>`.
        // A real password is often short, so no length floor beyond 4 to exclude trivial
        // placeholders ("ok", "1").
        pattern("named-flag-opaque-value",
                "(?i)\\b(token|apikey|api-key|api_key|access_token|password|secret|private-key|private_key)" +
                "[=: ]\\s*" + notAVarRef + "\\S{4,}"),
        // A lowercase compound env-style assignment: `client_secret=`, `db_password=`,
        // `oauth_token=` (round 1's env-var pattern only matches UPPERCASE names; this is its
        // lowercase sibling, same `\b` reasoning). `[a-z0-9_]*` before the suffix word (not
        // `[a-z0-9]*`) lets a multi-segment prefix like `my_client_secret=` match — the first
        // cut stopped at the first underscore, so a name that long never reached the suffix word
        // at all (round 2, dev-2/dev-3's finding). `(_[a-z0-9]+)*` after the suffix word lets a
        // multi-segment SUFFIX like `aws_secret_access_key=` match too — the first cut required
        // the suffix word to be immediately followed by `=`, so `secret` followed by `_access_key`
        // never matched (round 2, the planner's ruling: this is a fix, not an accepted gap, since
        // `aws_secret_access_key` contains a whole `_secret_` segment, squarely in scope).
        // Deliberately still excludes a bare `_key=` suffix with no accompanying secret/token/
        // password segment: `primary_key=`/`foreign_key=` are common, non-secret database column
        // arguments, and "key" alone has no secret-shaped qualifier the other three do.
        pattern("lowercase-env-style-assignment",
                "\\b[a-z][a-z0-9_]*_(secret|token|password)(_[a-z0-9]+)*=" + notAVarRef + "\\S{4,}"),
        // A PEM (or PGP) private-key block marker — the shape alone is the credential, no value
        // floor needed. PGP's marker ends "PRIVATE KEY BLOCK-----", not "PRIVATE KEY-----" (round
        // 2, dev-2's finding).
        pattern("pem-private-key-marker", "-----BEGIN( [A-Z]+)? PRIVATE KEY( BLOCK)?-----"),
        // user:pass@host in a URL, e.g. a `git clone` with embedded basic-auth credentials.
        // Bounded quantifiers ({1,64}/{1,128}), not `+`: an unbounded negated-class quantifier
        // followed by a required literal is still quadratic to backtrack over an adversarial run
        // with no `@` (dev-3's round-3 finding: 1.13s at 40,000 chars). A real userinfo section is
        // short; the cap excludes nothing real and keeps the scan linear-bounded.
        pattern("url-userinfo", "://[^/\\s:@]{1,64}:[^@\\s]{1,128}@"),
        // `curl -u user:pass`.
        pattern("curl-basic-auth-flag", "\\s-u\\s+" + notAVarRef + "[^\\s:]+:\\S+"),
    ]

    /// The generic, unlabeled-token fallback: a run of base64-ish characters (letters, digits, `+`,
    /// `_` — no `-` or `/`, both path/UUID separators, round 1's regression) at least 40 long that
    /// mixes an uppercase letter, a lowercase letter and a digit. The mixed-case+digit requirement
    /// is what excludes a 40-hex git SHA (lowercase hex only) and a UUID (lowercase hex and dashes)
    /// without naming either as an exception.
    ///
    /// Hand-scanned, not a regex: splitting on the charset boundary first makes this linear in
    /// `text`'s length, with no lookahead to backtrack. A regex equivalent re-scanned the tail of
    /// a run from every `\b`, which a `+`-heavy run (a `\b` every other character) made quadratic
    /// (dev-3's finding: 2.7s at 10,000 chars, 128s at 80,000).
    static func hasGenericMixedCaseToken(_ text: String) -> Bool {
        func isTokenChar(_ c: Character) -> Bool { c.isASCII && (c.isLetter || c.isNumber || c == "+" || c == "_") }
        var run: [Character] = []
        func checkRun() -> Bool {
            defer { run.removeAll(keepingCapacity: true) }
            guard run.count >= 40 else { return false }
            var hasLower = false, hasUpper = false, hasDigit = false
            for c in run {
                if c.isLowercase { hasLower = true } else if c.isUppercase { hasUpper = true }
                else if c.isNumber { hasDigit = true }
            }
            return hasLower && hasUpper && hasDigit
        }
        for c in text {
            if isTokenChar(c) {
                run.append(c)
            } else if checkRun() {
                return true
            }
        }
        return checkRun()
    }

    static func containsSecretLikeSubstring(_ text: String) -> Bool {
        if hasGenericMixedCaseToken(text) { return true }
        let range = NSRange(text.startIndex..<text.endIndex, in: text)
        return patterns.contains { $0.regex.firstMatch(in: text, range: range) != nil }
    }
}
