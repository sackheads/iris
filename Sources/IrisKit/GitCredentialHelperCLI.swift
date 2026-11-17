import Foundation

/// `iris --git-credential-helper` (the GitHub account's git identity, #966 spec §4): a git credential
/// helper, invoked by git itself per its credential protocol
/// (https://git-scm.com/docs/gitcredentials#_custom_helpers) -- never by the model, never with
/// argv secrets. git writes a `get`/`store`/`erase` operation as the first argument and a
/// `key=value\n`-per-line request on stdin; only `get` is answered, with
/// `username=<login>\npassword=<token>\n` on stdout, or nothing at all.
///
/// **Exactness is the whole control.** `repoFromFields` only ever returns an `owner/name` it
/// derived from git's own already-split `protocol`/`host`/`path` fields -- never by regexing a
/// raw URL -- and only when `host` is exactly `github.com` (case-insensitive, no substring or
/// suffix match) and `path` resolves to the same strict two-segment shape
/// `GitHubProxyClient.isOwnerName` enforces before any API call. A lookalike host or a malformed
/// path never reaches the allowlist check at all: `isGitHubRepoAllowed` is called only with a
/// value already proven to be an exact, well-formed repo name.
enum GitCredentialHelperCLI {
    /// `get`, `store` and `erase` are git's three credential-helper operations; only `get` is
    /// answered. `store`/`erase` are no-ops (exit 0, nothing printed): the token is never cached
    /// by git and never needs erasing, since it is re-derived fresh from the Keychain and the
    /// live allowlist on every `get`.
    static func isGetOperation(_ op: String) -> Bool { op == "get" }

    /// Parses a `key=value` line-per-entry request body. A value may itself contain `=` (e.g. a
    /// `url=` field with a query string); only the first `=` on a line splits it. A line with no
    /// `=`, or a blank line, is ignored.
    static func parseFields(_ input: String) -> [String: String] {
        var fields: [String: String] = [:]
        for line in input.split(separator: "\n", omittingEmptySubsequences: true) {
            guard let eq = line.firstIndex(of: "=") else { continue }
            fields[String(line[line.startIndex..<eq])] = String(line[line.index(after: eq)...])
        }
        return fields
    }

    /// The `owner/name` a credential request names, or nil if anything about it isn't an exact,
    /// well-formed `https://github.com/<owner>/<name>` request. Refuses before any allowlist
    /// check ever runs: a lookalike host, a non-https protocol, or a path that doesn't resolve to
    /// `GitHubProxyClient.isOwnerName`'s strict shape (traversal, query, fragment, embedded
    /// control characters, extra segments) all give nil here.
    static func repoFromFields(_ fields: [String: String]) -> String? {
        guard fields["protocol"] == "https" else { return nil }
        guard let host = fields["host"], host.lowercased() == "github.com" else { return nil }
        guard var path = fields["path"] else { return nil }
        if path.hasPrefix("/") { path.removeFirst() }
        if path.hasSuffix(".git") { path.removeLast(4) }
        guard GitHubProxyClient.isOwnerName(path) else { return nil }
        return path
    }

    /// The full decision for one `get` request: the credential string for stdout, or empty if
    /// anything refuses -- a malformed/lookalike request, a repo not on the allowlist, or no
    /// token or no account login configured. Empty means git gets nothing from this helper and falls
    /// through (to another configured helper, or fails outright with `GIT_TERMINAL_PROMPT=0`).
    /// This refusal path is silent on purpose: it never builds a message naming the repo, the
    /// request, or anything else, so there is no string a refusal could leak the token into. The
    /// token appears in exactly one place in this whole type -- `run`'s single `print` of this
    /// return value on a `get` -- never stderr, never a log, never an error description.
    static func respond(fields: [String: String], keychain: KeychainManager, login: String?,
                        isRepoAllowed: (String) -> Bool) -> String {
        guard let repo = repoFromFields(fields), isRepoAllowed(repo),
              let login, case .ok = GitHubProxyClient.checkLogin(login),
              let token = GitHubProxyClient.token(keychain: keychain) else { return "" }
        return "username=\(login)\npassword=\(token)\n"
    }

    // MARK: - Real CLI entry point (IrisMain.swift)

    /// `operation` is whatever git appended after `--git-credential-helper` on its own argv
    /// (`get`, `store`, or `erase`) -- IrisMain finds that word, since where it lands in
    /// `CommandLine.arguments` depends on how the helper is invoked, not on anything this type
    /// should know.
    static func run(operation: String?) -> Int32 {
        guard let operation, isGetOperation(operation) else { return 0 }
        let input = String(decoding: FileHandle.standardInput.readDataToEndOfFile(), as: UTF8.self)
        let fields = parseFields(input)
        let output = respond(fields: fields, keychain: .shared, login: ConfigManager.shared.githubLogin(),
                             isRepoAllowed: { ConfigManager.shared.isGitHubRepoAllowed($0) })
        if !output.isEmpty { print(output, terminator: "") }
        return 0
    }
}
